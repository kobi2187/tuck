# compiler/tuck_rt.nim
## Shared Tuck compiler runtime implementation for static environments.
import std/macros

type
  AccessMode* = enum
    ReadOnly, WriteOnly, ReadWrite

macro registerMMIO*(name: untyped, address: static[int], body: untyped): untyped =
  result = newStmtList()
  
  # Generate: type name* = ref object
  let typeSection = newTree(nnkTypeSection,
    newTree(nnkTypeDef,
      postfix(name, "*"),
      newEmptyNode(),
      newTree(nnkRefTy, newTree(nnkObjectTy, newEmptyNode(), newEmptyNode(), newEmptyNode()))
    )
  )
  result.add(typeSection)
  
  for child in body:
    if child.kind in {nnkCall, nnkCommand} and child.len >= 2:
      let fieldName = child[0]
      let bitCall = child[1]
      if bitCall.kind == nnkCall and bitCall.len >= 3:
        let bitIndex = bitCall[1]
        let modeName = bitCall[2].repr
        
        # Getter
        let getterNode = quote do:
          proc `fieldName`*(): bool {.inline.} =
            let p = cast[ptr uint32](`address`)
            return (p[] and (1'u32 shl `bitIndex`)) != 0
        result.add(getterNode)
        
        # Setter
        if modeName == "ReadWrite" or modeName == "WriteOnly":
          let setterNameNode = newIdentNode("`" & fieldName.repr & "=`")
          let setterNode = quote do:
            proc `setterNameNode`*(val: bool) {.inline.} =
              let p = cast[ptr uint32](`address`)
              if val:
                p[] = p[] or (1'u32 shl `bitIndex`)
              else:
                p[] = p[] and not(1'u32 shl `bitIndex`)
          result.add(setterNode)

# --- Errors and absence: !T / ?T lower to one value type (no alloc, no nil) ---
# ?T is an option: absence is a first-class state, not a reserved error code.
# !T uses tsOk/tsErr, ?T uses tsOk/tsAbsent, !?T may be any of the three.
type
  TuckStatus* = enum
    tsOk, tsErr, tsAbsent
  TuckResult*[T] = object
    status*: TuckStatus
    err*: uint16   # app-wide error code; meaningful only when status == tsErr
    value*: T

proc toStr*[T](value: T): string = $value

# seq access. Bounds are a PRECONDITION: violating one is a program error,
# reported with the caller's file/line, not an error value the caller matches.
proc tuckSeqBounds(index, length: int, op: string) =
  if index < 0 or index >= length:
    raise newException(IndexDefect,
      op & ": index " & $index & " out of bounds for seq of length " & $length)

proc at*[T](items: seq[T], index: int): T =
  tuckSeqBounds(index, items.len, "at")
  items[index]

proc setAt*[T](items: var seq[T], index: int, value: T) =
  tuckSeqBounds(index, items.len, "setAt")
  items[index] = value

proc tuckConcat*(a, b: string): string {.inline.} = a & b

# `[saturating]` (spec 4.1): clamp at the type's bounds instead of wrapping.
# This is VALUE SEMANTICS, not an assertion — unlike validate() it is never
# stripped in release, because removing it would change results.
#
# The guard runs where a value is STORED, on a wider intermediate, so a
# chain like `a + b - c` clamps once against the final value rather than at
# every operator (an intermediate that overshoots and comes back is not an
# overflow). Compiles to a branchless cmov: ~3 instructions.
#
# ponytail: u64 has no wider intermediate, so a chain that overflows u64
# itself wraps before this sees it. Exact for u8/u16/u32. See known_bugs.
proc tuckSat*[T: SomeUnsignedInt](v: uint64): T {.inline.} =
  if v > uint64(T.high): T.high else: T(v)

proc tuckSatI*[T: SomeSignedInt](v: int64): T {.inline.} =
  if v > int64(T.high): T.high
  elif v < int64(T.low): T.low
  else: T(v)

proc errCode*(name: static string): uint16 =
  # compile-time FNV-1a, folded to 16 bits; stable across builds, no tables
  var h = 2166136261'u32
  for c in name:
    h = (h xor uint32(c)) * 16777619'u32
  uint16((h xor (h shr 16)) and 0xFFFF'u32)

proc ok*[T](r: TuckResult[T]): bool {.inline.} = r.status == tsOk

proc tok*[T](v: T): TuckResult[T] {.inline.} =
  TuckResult[T](status: tsOk, value: v)

proc tokVoid*(): TuckResult[tuple[]] {.inline.} =
  TuckResult[tuple[]](status: tsOk)

proc terr*[T](code: uint16): TuckResult[T] {.inline.} =
  TuckResult[T](status: tsErr, err: code)

proc tnone*[T](): TuckResult[T] {.inline.} =
  TuckResult[T](status: tsAbsent)

proc tfwd*[T](status: TuckStatus, err: uint16): TuckResult[T] {.inline.} =
  ## `?` propagation: forward failure OR absence unchanged (status-preserving)
  TuckResult[T](status: status, err: err)

proc tuckReportUnhandled*(code: uint16, site: string) =
  stderr.writeLine("TUCK UNHANDLED: error " & $code & " at " & site)

type
  BumpArena*[Size: static int] = object
    buffer*: array[Size, byte]
    cursor*: int

proc alloc*[Size: static int](arena: var BumpArena[Size], bytes: int): pointer =
  if arena.cursor + bytes > Size:
    raise newException(OutOfMemoryDefect, "Arena buffer exhausted")
  result = addr arena.buffer[arena.cursor]
  arena.cursor += bytes

proc reset*[Size: static int](arena: var BumpArena[Size]) =
  arena.cursor = 0

# spec 7.2: N slots of an arbitrary T plus an occupancy bitmask. Fixed size,
# no fragmentation, O(1) release. Exhaustion is ABSENCE (?T), not nil and not
# an error — the caller decides what running out means for its situation.
type
  ObjectPool*[T; Count: static int] = object
    storage*: array[Count, T]
    occupied*: uint64        # ponytail: 64 slots max; widen to an array if needed

proc acquire*[T; Count: static int](pool: var ObjectPool[T, Count]): TuckResult[T] =
  for i in 0 ..< Count:
    if (pool.occupied and (1'u64 shl i)) == 0:
      pool.occupied = pool.occupied or (1'u64 shl i)
      return tok(pool.storage[i])
  tnone[T]()

proc release*[T; Count: static int](pool: var ObjectPool[T, Count], item: T) =
  # Which slot did this come from? Compare by address within the storage
  # array — the value was handed out from one of these cells.
  for i in 0 ..< Count:
    if pool.storage[i] == item:
      pool.occupied = pool.occupied and not(1'u64 shl i)
      return

import std/locks

type
  Mailbox*[T; Cap: static int] = object
    data*: array[Cap, T]
    head*: int
    tail*: int
    lock*: Lock          # sends come from other threads; drain from the
                         # scheduler thread — enqueue/dequeue must be guarded
    inited*: bool

proc initMailbox*[T; Cap: static int](mb: var Mailbox[T, Cap]) =
  if not mb.inited:
    initLock(mb.lock)
    mb.inited = true

proc enqueue*[T; Cap: static int](mb: var Mailbox[T, Cap], msg: T): bool =
  initMailbox(mb)
  acquire(mb.lock)
  let next = (mb.tail + 1) mod Cap
  if next == mb.head:
    release(mb.lock)
    return false
  mb.data[mb.tail] = msg
  mb.tail = next
  release(mb.lock)
  return true

proc dequeue*[T; Cap: static int](mb: var Mailbox[T, Cap], msg: var T): bool =
  initMailbox(mb)
  acquire(mb.lock)
  if mb.head == mb.tail:
    release(mb.lock)
    return false
  msg = mb.data[mb.head]
  mb.head = (mb.head + 1) mod Cap
  release(mb.lock)
  return true

proc hasRoom*[T; Cap: static int](mb: var Mailbox[T, Cap]): bool =
  ## Sender's opt-in backpressure check. sendX drops silently on a full ring
  ## (fast, non-blocking, spec §9.1) — the sender may check first if it cares.
  initMailbox(mb)
  acquire(mb.lock)
  result = ((mb.tail + 1) mod Cap) != mb.head
  release(mb.lock)


# ---------- stdlib externs (std/*.tuck) ----------
# Nim's portable stdlib IS Tuck's OS layer. Exceptions never escape: every
# fallible fn catches and returns terr(errCode("Enum.Variant")) — matching
# the error enums declared in the std/*.tuck signatures.
#
# Imported HERE rather than at the facade below because the blocking externs
# route through tuck_async.tuckSubmitBlocking — see readLine.
import std/[os, times, syncio]
import ./tuck_async
from std/posix import nil
template posixRead(fd: cint, buf: pointer, n: int): int =
  ## stdin's raw read, spelled explicitly so it cannot be confused with
  ## syncio's buffered readLine (which must never run on the worker).
  posix.read(fd, buf, n)

# C's allocator, not Nim's. The worker may not allocate through the collector
# (see the cross-thread contract in tuck_async), so a result buffer it fills
# has to come from here and be freed by the scheduler thread after the copy.
proc cMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cRealloc(p: pointer, size: csize_t): pointer
  {.importc: "realloc", header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}

# --- file externs, offloaded ------------------------------------------------
#
# All of these block: a regular file is always "ready" to epoll, so the reactor
# cannot await one. They run on the worker via tuckSubmitBlocking, under the
# contract in tuck_async — no GC memory crosses the boundary.
#
# That is why these use raw open/read/write rather than syncio: the argument
# is a caller-owned C buffer, the result is a malloc'd buffer the worker fills
# and the SCHEDULER thread copies into a Nim string and frees. Nothing on the
# worker allocates through Nim, and nothing the worker wrote outlives the copy.

type
  FileOp = enum
    fopRead, fopWrite, fopAppend, fopRemove

  IoStatus = enum
    ## What the worker concluded. An enum rather than a coded int so a `case`
    ## over it is exhaustive-checked and a new outcome cannot be silently
    ## unhandled at a call site.
    iosOk
    iosNotFound
    iosIoFailed
    iosAccessDenied
    iosEndOfInput

  FileReq = object
    op: FileOp
    path: cstring          ## caller-owned, alive for the whole call
    data: cstring          ## write/append payload; caller-owned
    dataLen: int
    outBuf: pointer        ## fopRead: malloc'd by the worker, freed by caller
    outLen: int
    status: IoStatus

proc fileWorker(arg: pointer) {.nimcall, gcsafe.} =
  ## Runs on the blocking thread. Raw syscalls only.
  let r = cast[ptr FileReq](arg)
  case r.op
  of fopRemove:
    if posix.unlink(r.path) != 0:
      r.status = if posix.errno == posix.ENOENT: iosNotFound
                 else: iosAccessDenied
  of fopWrite, fopAppend:
    let flags = posix.O_WRONLY or posix.O_CREAT or
                (if r.op == fopAppend: posix.O_APPEND else: posix.O_TRUNC)
    let fd = posix.open(r.path, flags, posix.Mode(0o644))
    if fd < 0:
      r.status = iosAccessDenied
      return
    var off = 0
    while off < r.dataLen:
      let n = posix.write(fd, cast[pointer](cast[uint](r.data) + uint(off)),
                          r.dataLen - off)
      if n <= 0:
        r.status = iosAccessDenied
        break
      off += n
    discard posix.close(fd)
  of fopRead:
    let fd = posix.open(r.path, posix.O_RDONLY)
    if fd < 0:
      r.status = if posix.errno == posix.ENOENT: iosNotFound
                 else: iosIoFailed
      return
    # Grow-on-demand with malloc, not seq: the worker may not allocate through
    # Nim. Starts at 64K and doubles, so an ordinary file is one allocation.
    var cap = 65536
    var buf = cMalloc(cap.csize_t)
    var len = 0
    while true:
      if len == cap:
        cap *= 2
        let bigger = cRealloc(buf, cap.csize_t)
        if bigger == nil:
          cFree(buf); r.status = iosIoFailed; return
        buf = bigger
      let n = posix.read(fd, cast[pointer](cast[uint](buf) + uint(len)),
                         cap - len)
      if n < 0:
        cFree(buf); discard posix.close(fd)
        r.status = iosIoFailed; return
      if n == 0: break
      len += n
    discard posix.close(fd)
    r.outBuf = buf
    r.outLen = len

proc runFileOp(op: FileOp, path: string, data: string = ""): FileReq =
  ## Set up the request on the SCHEDULER thread, hand it to the worker, park.
  ## `path`/`data` stay alive here for the whole call — the coroutine cannot
  ## proceed until the worker signals, so the worker's view is always valid.
  result = FileReq(op: op, path: path.cstring, data: data.cstring,
                   dataLen: data.len, outBuf: nil, outLen: 0, status: iosOk)
  tuckSubmitBlocking(fileWorker, addr result)

proc fsErr[T](s: IoStatus): TuckResult[T] =
  ## One place mapping a worker outcome onto the FsError variants declared in
  ## std/fs.tuck. Exhaustive, so a new IoStatus is a compile error here rather
  ## than a silently-wrong error code at four call sites.
  case s
  of iosNotFound: terr[T](errCode("fs/FsError.NotFound"))
  of iosAccessDenied: terr[T](errCode("fs/FsError.AccessDenied"))
  of iosOk, iosIoFailed, iosEndOfInput: terr[T](errCode("fs/FsError.IoFailed"))

proc readFile*(path: string): TuckResult[tuple[content: string]] =
  var r = runFileOp(fopRead, path)
  if r.status != iosOk: return fsErr[tuple[content: string]](r.status)
  var content = newString(r.outLen)
  if r.outLen > 0:
    copyMem(addr content[0], r.outBuf, r.outLen)
  if r.outBuf != nil: cFree(r.outBuf)
  tok((content: content))

proc writeFile*(path: string, content: string): TuckResult[tuple[]] =
  let r = runFileOp(fopWrite, path, content)
  if r.status == iosOk: tokVoid() else: fsErr[tuple[]](r.status)

proc appendFile*(path: string, content: string): TuckResult[tuple[]] =
  let r = runFileOp(fopAppend, path, content)
  if r.status == iosOk: tokVoid() else: fsErr[tuple[]](r.status)

proc removeFile*(path: string): TuckResult[tuple[]] =
  let r = runFileOp(fopRemove, path)
  if r.status == iosOk: tokVoid() else: fsErr[tuple[]](r.status)

proc fileExists*(path: string): bool = os.fileExists(path)
  ## NOT offloaded: a stat is a metadata lookup, microseconds on any live
  ## filesystem. Paying a thread handoff and a pipe round-trip for it would
  ## cost more than the call.

proc print*(text: string) = stdout.write(text)
proc printLine*(text: string) = stdout.writeLine(text)

type
  ReadLineReq = object
    ## Caller-allocated, caller-freed, and reachable only from the parked
    ## coroutine's stack — see the cross-thread contract in tuck_async. The
    ## buffer is a fixed array rather than a string precisely because the
    ## worker may not touch GC memory.
    buf: array[4096, char]
    len: int
    status: IoStatus

proc readLineWorker(arg: pointer) {.nimcall, gcsafe.} =
  ## Runs on the blocking thread. Raw read(2) on stdin — no Nim I/O, no
  ## allocation, nothing that could reach the collector.
  let r = cast[ptr ReadLineReq](arg)
  var i = 0
  while i < r.buf.len:
    var c: char
    let n = posixRead(cint(0), addr c, 1)
    if n < 0:
      r.status = iosIoFailed
      return
    if n == 0:                      # EOF
      if i == 0: r.status = iosEndOfInput
      break
    if c == '\n': break
    r.buf[i] = c
    i.inc
  r.len = i

proc readLine*(): TuckResult[tuple[line: string]] =
  ## Blocks on user input, so it runs on the blocking thread: stdin has no
  ## readiness the reactor could await, and waiting for it inline would stop
  ## every timer and actor in the process until someone hits enter.
  var req = ReadLineReq(len: 0, status: iosOk)
  tuckSubmitBlocking(readLineWorker, addr req)
  case req.status
  of iosEndOfInput:
    terr[tuple[line: string]](errCode("io/IoError.EndOfInput"))
  of iosOk:
    var line = newString(req.len)
    for i in 0 ..< req.len: line[i] = req.buf[i]
    tok((line: line))
  of iosIoFailed, iosNotFound, iosAccessDenied:
    terr[tuple[line: string]](errCode("io/IoError.IoFailed"))

proc argCount*(): tuple[count: int] = (count: paramCount())
proc argAt*(index: int): tuple[arg: string] = (arg: paramStr(index))

proc getEnv*(name: string): TuckResult[tuple[value: string]] =
  if os.existsEnv(name):
    tok((value: os.getEnv(name)))
  else:
    tnone[tuple[value: string]]()

proc exit*(code: int) = quit(code)

proc nowMs*(): tuple[ms: uint64] = (ms: uint64(epochTime() * 1000))
proc sleepMs*(ms: uint32) =
  ## The reactor's timer, NOT the worker and NOT os.sleep. A sleep is the one
  ## "blocking" op that was never blocking-by-nature: waiting for a deadline is
  ## exactly what a timerfd does, so tuckSleep suspends only this coroutine
  ## while everything else keeps running. Offloading it would burn a thread to
  ## reproduce what the reactor already does for free.
  ##
  ## os.sleep here used to halt the process: the scheduler, the reactor, every
  ## actor and every timer, for the full duration.
  ## inCoroutine rather than a bare `running()`: --threads:on puts
  ## system.running(Thread) in scope, which otherwise wins overload resolution.
  if inCoroutine(): tuckSleep(int(ms))
  else: os.sleep(int(ms))   # no scheduler to yield to

# The single runtime facade: tuck_rt re-exports the async runtime so every
# emitted program imports ONLY tuck_rt and reaches rt AND async names
# (readFile, waitUntil, openSource, ...) uniformly. arsenal is bundled as the
# base runtime. A name defined in both modules is a Nim redefinition error at
# stdlib-compile time — the intended hard error, the stdlib author's to fix.
# (The import itself is up with the externs, which call into it.)
export tuck_async
