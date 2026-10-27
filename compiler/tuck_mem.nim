# compiler/tuck_mem.nim
## The runtime's memory section: what the ownership rules decide, printed as
## calls (see the comment below). Imported by tuck_rt, which re-exports it, and
## by tuck_async / tuck_coro, which manage their own storage the same way.
import std/typetraits

# --- memory: the ownership rules, printed ------------------------------------
# A Tuck program is compiled with `--mm:none -d:useMalloc`: no collector, no
# destructors, so storage is freed where the rules say (`tuckDrop`) and
# nowhere else. Under that setting Nim copies a seq, a string or an object
# holding one on every assignment from a place and never frees the old
# value, so what the rules decide is printed in terms of bits:
#
#   tuckCopy     a value that shares no storage with its argument (rule S)
#   tuckMove     the value, and the place it came from emptied (rule M)
#   tuckStore    a value built here, stored by its bits (no copy of a copy)
#   tuckReplace  drop what the place held, store the new value (rule D)
#   tuckDrop     free what a value owns, deeply (rule D)
#   tuckPush / tuckStrAppend   grow in place, freeing the block it left
#
# A seq and a string are one pointer to a block that begins with two words,
# the length and the capacity; `tuckPush` and `tuckStrAppend` know that
# layout (Nim 2.2.4, pinned in CI), `static` below checks the part they rely on.
proc heapAlloc(n: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc heapGrow(p: pointer, n: csize_t): pointer {.importc: "realloc", header: "<stdlib.h>".}
proc heapFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

type SeqHead = object
  len, reserved: int

const
  seqShallowFlag = 1 shl (sizeof(int) * 8 - 1)   # a seq Nim does not own
  strLitFlag = 1 shl (sizeof(int) * 8 - 2)       # a string literal: static
  flagBits = seqShallowFlag or strLitFlag
  headSize = sizeof(SeqHead)

static:
  doAssert not defined(nimSeqsV2) and not defined(gcDestructors),
    "tuck_rt's memory section expects --mm:none (the classic seq layout)"

template headOf(x: typed): ptr SeqHead = cast[ptr SeqHead](cast[pointer](x))

template ownsNothingToFree(T: typedesc): bool =
  ## A value of `T` holds no storage a drop could free.
  supportsCopyMem(T) or T is ref or T is ptr or T is pointer or
    T is proc or T is cstring

proc tuckDrop*[T](x: var T)

proc dropBlock[T](x: var T) =
  ## A string's or seq's block: freed unless Nim did not allocate it (a
  ## literal, a shallow seq), and `x` left empty.
  let h = headOf(x)
  if h != nil and (h.reserved and flagBits) == 0: heapFree(h)
  zeroMem(addr x, sizeof(T))

proc dropSeq[T](x: var seq[T]) =
  ## Each element first when it owns storage, then the block.
  mixin tuckDrop
  if headOf(x) != nil:
    when not supportsCopyMem(T):
      for e in x.mitems: tuckDrop(e)
    dropBlock(x)

proc tuckDrop*[T](x: var T) =
  ## Free what `x` owns, deeply, and leave it empty. A string literal and a
  ## seq Nim did not allocate are left alone.
  mixin tuckDrop
  when ownsNothingToFree(T): discard
  elif T is string: dropBlock(x)
  elif T is seq: dropSeq(x)
  elif T is array:
    when not supportsCopyMem(typeof(x[0])):
      for e in x.mitems: tuckDrop(e)
  else:
    for f in fields(x): tuckDrop(f)

proc tuckCopy*[T](x: T): T {.inline.} =
  ## A value sharing nothing with `x`: Nim's own assignment, which under
  ## `--mm:none` copies a seq or string and what they hold.
  ##
  ## A seq of plain values (no storage of their own) is copied as one block:
  ## Nim's assignment walks it element by element through genericAssign,
  ## which was most of a copy's cost (benches/game, fannkuch).
  when T is seq:
    when supportsCopyMem(typeof(x[0])):
      result = newSeqUninit[typeof(x[0])](x.len)
      if x.len > 0:
        copyMem(addr result[0], unsafeAddr x[0], x.len * sizeof(x[0]))
    else:
      result = x
  else:
    result = x

proc tuckBits*[T](x: T): T {.inline.} =
  ## `x`'s bits as a value of its own: a parameter the body owns, adopted
  ## (`var x = tuckBits(x)`). The caller's storage is now this one's.
  copyMem(addr result, unsafeAddr x, sizeof(T))

proc tuckStore*[T](dst: var T, src: T) {.inline.} =
  ## `dst = src` by bits. `src` is built here or moved in; the assignment
  ## Nim would write copies it again, and loses the original.
  copyMem(addr dst, unsafeAddr src, sizeof(T))

proc tuckReplace*[T](dst: var T, src: T) {.inline.} =
  ## An overwrite that drops the old value (rule D). `src` is already built.
  mixin tuckDrop
  tuckDrop(dst)
  copyMem(addr dst, unsafeAddr src, sizeof(T))

proc tuckReset*[T](x: var T) {.inline.} =
  ## Empty a place whose value moved away, so its drop frees nothing.
  zeroMem(addr x, sizeof(T))

proc tuckMove*[T](x: var T): T {.inline.} =
  ## The value in `x` (its final read), and `x` emptied.
  copyMem(addr result, addr x, sizeof(T))
  zeroMem(addr x, sizeof(T))

proc tuckPush*[T](xs: var seq[T], v: T) =
  ## `xs` grown by `v`, in place; `v` is stored by its bits. A block that
  ## had to move is freed (Nim's own `add` leaves it behind).
  var h = headOf(xs)
  if h == nil or (h.reserved and flagBits) != 0:
    let n = if h == nil: 0 else: h.len
    let cap = max(4, n + n div 2 + 1)
    let nh = cast[ptr SeqHead](heapAlloc(csize_t(headSize + cap * sizeof(T))))
    if n > 0:
      copyMem(cast[pointer](cast[int](nh) + headSize),
              cast[pointer](cast[int](h) + headSize), n * sizeof(T))
    nh.len = n
    nh.reserved = cap
    h = nh
  elif h.len >= h.reserved:
    let cap = max(4, h.reserved * 2)
    h = cast[ptr SeqHead](heapGrow(h, csize_t(headSize + cap * sizeof(T))))
    h.reserved = cap
  copyMem(cast[pointer](cast[int](h) + headSize + h.len * sizeof(T)),
          unsafeAddr v, sizeof(T))
  inc h.len
  copyMem(addr xs, addr h, sizeof(pointer))

proc tuckStrAppend*(s: var string, t: string) =
  ## `s &= t`, in place, freeing the block a growth left behind.
  let m = t.len
  if m == 0: return
  let n = s.len
  var h = headOf(s)
  let th = headOf(t)
  let aliased = th == h
  if h == nil or (h.reserved and flagBits) != 0:
    let cap = max(16, (n + m) * 2)
    let nh = cast[ptr SeqHead](heapAlloc(csize_t(headSize + cap + 1)))
    if n > 0:
      copyMem(cast[pointer](cast[int](nh) + headSize),
              cast[pointer](cast[int](h) + headSize), n)
    nh.reserved = cap
    h = nh
  elif n + m > h.reserved:
    let cap = max(16, (n + m) * 2)
    h = cast[ptr SeqHead](heapGrow(h, csize_t(headSize + cap + 1)))
    h.reserved = cap
  let src = if aliased: h else: th
  copyMem(cast[pointer](cast[int](h) + headSize + n),
          cast[pointer](cast[int](src) + headSize), m)
  h.len = n + m
  cast[ptr char](cast[int](h) + headSize + n + m)[] = '\0'
  copyMem(addr s, addr h, sizeof(pointer))


proc tuckStrTruncate*(s: var string, n: int) =
  ## `s` cut to its first `n` bytes, in place (Nim's `setLen` would copy it
  ## into a new block and leave this one behind).
  let h = headOf(s)
  if h == nil or n >= h.len: return
  h.len = n
  cast[ptr char](cast[int](h) + headSize + n)[] = '\0'
