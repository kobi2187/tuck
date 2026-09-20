# compiler/tuck_rt.nim
## Shared Tuck compiler runtime implementation for static environments.
import std/macros
import std/strutils
import std/math as stdmath

type
  AccessMode* = enum
    ReadOnly, WriteOnly, ReadWrite

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

# `xs[i]` bracket sugar lowers to tuckAt/tuckSetAt, NOT to std/seq's `at` —
# brackets are grammar, so they must work without `import seq`, and the
# reserved `tuck` prefix (same convention as tuckConcat/tuckSat above) is
# what keeps them from colliding with a user's own `fn at`. std/seq.tuck's
# `at`/`setAt` stay as the explicit spelling and delegate here.
proc tuckAt*[T](items: seq[T], index: int): T =
  tuckSeqBounds(index, items.len, "at")
  items[index]

proc at*[T](items: seq[T], index: int): T = tuckAt(items, index)

proc charAt*(s: string, index: int): string =
  tuckSeqBounds(index, s.len, "charAt")
  $s[index]

proc containsChar*(s: string, ch: string): bool = strutils.contains(s, ch)

proc splitLines*(s: string): seq[string] = strutils.splitLines(s)

proc ord*(ch: string): int =
  tuckSeqBounds(0, ch.len, "ord")
  system.ord(ch[0])

proc tuckSetAt*[T](items: var seq[T], index: int, value: T) =
  tuckSeqBounds(index, items.len, "setAt")
  items[index] = value

proc setAt*[T](items: var seq[T], index: int, value: T) =
  tuckSetAt(items, index, value)

# `Array[N, T]` needs its OWN pair, separate from tuckAt/tuckSetAt above.
# core.array's `at`/`setAt` cannot be plain Tuck functions using `items[i]`:
# the bracket-index dispatch (typecheck.nim's indexCallee) routes to whatever
# `fn at` is in scope, which — inside `at`'s OWN body — is `at` itself. A
# Tuck-body `at` for Array[N, T] self-recurses infinitely rather than
# indexing. std/seq.tuck's `at`/`setAt` dodge this because THIS proc, not a
# Tuck fn, is what the bracket actually lowers to; core.array's `at`/`setAt`
# must be `extern` declarations bound to these, with no Tuck body to recurse
# in — same shape, one container over.
proc tuckArrayAt*[N: static int, T](items: array[N, T], index: int): T =
  tuckSeqBounds(index, N, "at")
  items[index]

proc tuckArraySetAt*[N: static int, T](items: var array[N, T], index: int,
                                       value: T) =
  tuckSeqBounds(index, N, "setAt")
  items[index] = value

# Value semantics: `items` is copied on return, same as any other Tuck
# record/seq — growing the result never mutates the caller's seq, unlike
# setAt's in-place write through a `var` receiver.
#
# No sibling `len` extern: a top-level `proc len*[T](items: seq[T]): int`
# in THIS module makes every seq operation inside tuck_rt.nim itself —
# `add`, `newSeq`, `setLen`, all of which expand unqualified `len(x)` deep
# in Nim's own seqs_v2.nim templates — an ambiguous call between
# `system.len` and this module's own `len`. Not the readFile-style
# caller-side collision (that one is dodgeable by qualifying the call
# site); this one fires from inside tuck_rt.nim's own module scope no
# matter how a caller spells it, so there is no workaround short of not
# declaring it. `Seq.len`'s existing accidental-UFCS behavior (TODO.md §3)
# is the only way to get a count today.
proc getLength*[T](x: T): int = system.len(x)
  ## Behind `len`. Named so nothing can be ambiguous with it: a runtime proc
  ## actually called `len` collides with `system.len` at every unqualified
  ## `.len` in this module. FULLY GENERIC on purpose — `len` has to answer for
  ## a Seq AND a str, which a `seq[T]`-only signature cannot.

proc count*[T](items: seq[T]): int = system.len(items)
  ## PROTOCOLS.md's verb for "how many". Named `count` rather than `len`
  ## precisely so it does not make every unqualified `len` in this module
  ## ambiguous — see std/seq.tuck.

proc byteCount*(s: string): int = s.len

proc fromBytes*(bytes: seq[uint8]): string =
  result = newString(bytes.len)
  for i, b in bytes: result[i] = char(b)

proc byteAt*(s: string, index: int): uint8 =
  tuckSeqBounds(index, s.len, "byteAt")
  uint8(s[index])

proc joinStr*(parts: seq[string], sep: string): string =
  ## One pass, one allocation path — `acc = acc & part` in a loop is O(n^2).
  parts.join(sep)

proc push*[T](items: seq[T], value: T): seq[T] =
  result = items
  result.add(value)

# --- bit operations -------------------------------------------------------
#
# Tuck has no bitwise OPERATORS. `|` is already sum-variant syntax, and a
# word operator is refused outright (TK-PA11: `mod`/`div` "parses as a postfix
# call and silently drops the right operand"), so the spelling of `&`/`^`/`<<`
# is a language-surface question with no answer yet.
#
# These are the answer that needs no syntax: ordinary postfix calls, declared
# in std/bits.tuck exactly the way std/seq.tuck declares at/setAt. Everything
# that wants bits — core.num's whole bitset half, core.hash's FNV-1a fold —
# is written against these, and swapping in real operators later changes no
# caller that used them.
#
# u64 throughout: bit work is on the widest unsigned type, and Tuck's own
# `int` is signed, where a shift would be arithmetic rather than logical.
proc bitAnd*(a, b: uint64): uint64 {.inline.} = a and b
proc bitOr*(a, b: uint64): uint64 {.inline.} = a or b
proc bitXor*(a, b: uint64): uint64 {.inline.} = a xor b
proc bitNot*(a: uint64): uint64 {.inline.} = not a

proc shiftLeft*(a: uint64, by: int): uint64 {.inline.} =
  ## A shift at or past the width is 0, not undefined. C leaves `x << 64`
  ## undefined and the three backends inherit that from their own codegen, so
  ## the guard is here rather than in each of them.
  if by >= 64 or by < 0: 0'u64 else: a shl by

proc shiftRight*(a: uint64, by: int): uint64 {.inline.} =
  if by >= 64 or by < 0: 0'u64 else: a shr by

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

proc parseFloat*(s: string): TuckResult[float] =
  ## Absent, not an error: "that text is not a number" is a question with a
  ## legitimate no, which is what `?T` is for.
  try: tok(strutils.parseFloat(s))
  except ValueError: tnone[float]()

proc tfwd*[T](status: TuckStatus, err: uint16): TuckResult[T] {.inline.} =
  ## `?` propagation: forward failure OR absence unchanged (status-preserving)
  TuckResult[T](status: status, err: err)

proc tuckReportUnhandled*(code: uint16, site: string) =
  stderr.writeLine("TUCK UNHANDLED: error " & $code & " at " & site)

proc tuckInvariantFailed*(cond, typeName: string) =
  ## An invariant violation (spec 4.7) — abort naming the condition.
  ##
  ## NOT Nim's `assert`: `-d:release` strips asserts outright by default, so
  ## a guard built on one silently evaporates in exactly the build where a
  ## violated invariant means corrupt data. ROADMAP's 2026-08-25 ruling 5
  ## says invariants stay on in release by default, opt-out only, so the
  ## check has to be real code the optimizer keeps — same fix as the D
  ## backend's `tuckInvariantFailed`, from the direction Nim needed it.
  stderr.writeLine("Invariant violated on " & typeName & ": " & cond)
  quit(1)

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
proc tuckPoolMisuse*(what: string) =
  ## A pool operation that cannot be honoured: a handle for a slot nobody
  ## holds, or one whose tenancy has ended. Aborts rather than returning,
  ## because the alternative is the silent corruption this replaced — a
  ## release that matched the wrong cell freed a slot still in use and leaked
  ## the one being returned, and said nothing.
  stderr.writeLine("TUCK POOL: " & what)
  quit(1)

type
  PoolHandle* = object
    ## What `acquire` hands back: WHICH cell, and WHICH TENANCY of it.
    ##
    ## The value used to be the cell's contents, which meant the cell's
    ## identity was gone by the time `release` needed it — it searched by
    ## equality, every slot held the same zero value, and so every release
    ## matched slot 0. Carrying the index is what makes release O(1) and
    ## correct; carrying the generation is what makes a stale handle a caught
    ## error instead of a write into someone else's slot.
    ##
    ## Opaque on the Tuck side: `<Pool>Handle` is emitted per pool as an alias
    ## of this, so the CHECKER separates two pools' handles even though the
    ## target type is shared (spec 7.4's "handles, not refs", reached through
    ## 7.2's machinery, which 7.4 says is the same machinery).
    slot*: int32
    gen*: uint32

  ObjectPool*[T; Count: static int] = object
    storage*: array[Count, T]
    gen*: array[Count, uint32]  ## tenancy counter per cell; 0 = never handed out
    occupied*: uint64        # ponytail: 64 slots max; widen to an array if needed

proc acquire*[T; Count: static int](pool: var ObjectPool[T, Count]): TuckResult[PoolHandle] =
  for i in 0 ..< Count:
    if (pool.occupied and (1'u64 shl i)) == 0:
      pool.occupied = pool.occupied or (1'u64 shl i)
      pool.gen[i] = pool.gen[i] + 1'u32
      return tok(PoolHandle(slot: int32(i), gen: pool.gen[i]))
  tnone[PoolHandle]()

proc release*[T; Count: static int](pool: var ObjectPool[T, Count], h: PoolHandle) =
  ## The handle names the cell, so there is nothing to search for and nothing
  ## to guess. Every way of being wrong is caught rather than absorbed.
  let i = int(h.slot)
  if i < 0 or i >= Count:
    tuckPoolMisuse("release of a handle that names no slot (" & $i & ")")
  elif (pool.occupied and (1'u64 shl i)) == 0:
    tuckPoolMisuse("double release of slot " & $i)
  elif pool.gen[i] != h.gen:
    tuckPoolMisuse("release of a stale handle for slot " & $i & ": tenancy " &
                   $h.gen & ", slot is on " & $pool.gen[i])
  else:
    pool.occupied = pool.occupied and not(1'u64 shl i)

# ---------------------------------------------------------------------------
# spec 7.4: the resource registry.
#
# Scope-based RAII is the wrong model for an OS handle: a hot loop that opens
# and closes a file per iteration thrashes on syscalls. The true model is the
# one the OS already uses — a global table of handles, the process fd table —
# so Tuck makes that table explicit and per kind.
#
# This is 7.2's pool machinery with three additions, each of which 7.4 asks
# for by name: an `isFinished` flag (marking and closing are SPLIT, so
# durability never depends on sweep timing), a registration order (close-all
# runs LIFO — a file flushes before the directory holding it closes), and an
# acquire site per entry (the OPEN RESOURCES report has to say WHERE).

type
  ResourceHandle* = object
    ## What an acquire hands back: WHICH entry, and WHICH TENANCY of it.
    ## A plain value — copyable, comparable, Tier 1 (7.1) — and never the
    ## resource itself. The ref stays in the table, which is what closes the
    ## fd-reuse bug class by construction: a handle whose generation no longer
    ## matches its slot is a caught error, not a write to the wrong file.
    ##
    ## Emitted per kind as `<Kind>Handle`, an alias of this, exactly as each
    ## pool emits `<Pool>Handle` over PoolHandle — so the CHECKER keeps two
    ## kinds' handles apart while the backends need only the one target type.
    slot*: int32
    gen*: uint32

  RtResourcePolicy* = enum
    ## When the OS handle actually closes. MARKING is identical under all
    ## three — the handle dies at mark time whichever is in force — so buggy
    ## code behaves the same way in every mode and a use-after-finish is the
    ## same caught error in a debug build and a shipped one.
    rtStrict   ## close at the mark. Deterministic; the embedded/debug default
    rtLazy     ## mark only; the inline watermark sweep reclaims
    rtExit     ## close-all at program end

  RtOnFull* = enum
    ## What a CAPPED table does when it fills.
    rtoAbsent  ## report absence; the caller decides (the default)
    rtoError   ## abort, naming the kind and its cap

  ResourceCloser* = proc(reference: int64) {.nimcall.}
    ## How THIS kind's OS handle is released, and what `on_finish` does for it.
    ## A callback because the runtime cannot know: closing an fd, an mmap and
    ## a TLS session are three different syscalls, and the library that
    ## declared the kind is the only thing that knows which. nil = no-op,
    ## which is what a kind with no OS side (a test, a counter) wants.

  ResourceEntry* = object
    reference*: int64   ## the OS handle: an fd, or a pointer cast to int
    gen*: uint32        ## tenancy; bumped at the MARK, so the handle dies there
    live*: bool         ## this slot is occupied at all
    finished*: bool     ## marked; awaiting reclamation. Only these are evicted
    site*: string       ## where it was acquired — the report's whole value

  ResourceTable* = object
    kind*: string            ## the declared kind name, for messages
    cap*: int                ## 0 = unbounded (seq-backed); >0 = the bound
    policy*: RtResourcePolicy
    onFull*: RtOnFull        ## only consulted when `cap` > 0
    sweepBatch*: int         ## 0 = evict every finished entry; >0 = that many
    onFinish*: ResourceCloser  ## runs at the MARK, always (file: flush)
    onClose*: ResourceCloser   ## runs at reclamation
    entries*: seq[ResourceEntry]
    order*: seq[int32]       ## registration order — close-all walks it backwards
    finishedCount*: int

proc tuckResourceMisuse*(table: string, what: string) =
  ## A registry operation that cannot be honoured. Aborts rather than
  ## returning, for the reason tuckPoolMisuse does: the alternative is silent
  ## corruption, and a stale handle that writes to a REUSED slot is exactly
  ## the bug 7.4 exists to make impossible.
  stderr.writeLine("TUCK RESOURCE [" & table & "]: " & what)
  quit(1)

proc initResourceTable*(t: var ResourceTable, kind: string, cap: int,
                        policy: RtResourcePolicy, sweepBatch: int,
                        onFull = rtoAbsent) =
  t.kind = kind
  t.cap = cap
  t.policy = policy
  t.sweepBatch = sweepBatch
  t.onFull = onFull
  if cap > 0 and t.entries.len < cap:
    # A capped kind is array-shaped from the start: the cap is a LINK-TIME
    # memory budget on a standalone target, not a limit discovered at runtime.
    t.entries.setLen(cap)

proc setResourceHooks*(t: var ResourceTable, onFinish, onClose: ResourceCloser) =
  ## The kind's two callbacks, bound by whichever library declared it.
  t.onFinish = onFinish
  t.onClose = onClose

proc reclaim(t: var ResourceTable, i: int) =
  ## Release one FINISHED entry's OS handle and free its slot. Never called on
  ## a live one: 7.4 has no time-based eviction, and an entry nobody finished
  ## is still in use by definition.
  if not t.entries[i].live or not t.entries[i].finished: return
  if t.onClose != nil: t.onClose(t.entries[i].reference)
  t.entries[i].live = false
  t.entries[i].site = ""
  t.finishedCount.dec
  for k in 0 ..< t.order.len:
    if t.order[k] == int32(i):
      t.order.delete(k)
      break

proc sweep*(t: var ResourceTable): int {.discardable.} =
  ## Reclaim finished entries, up to `sweepBatch` of them (0 = all). Returns
  ## how many were taken. Also the `kind::sweep` an explicit scheduled cleanup
  ## calls — the inline trigger below and the explicit one are the same code,
  ## so a program that sweeps by hand and one that lets the marks do it cannot
  ## drift apart.
  let limit = if t.sweepBatch > 0: t.sweepBatch else: t.entries.len
  for i in 0 ..< t.entries.len:
    if result >= limit: break
    if t.entries[i].live and t.entries[i].finished:
      t.reclaim(i)
      result.inc

proc watermarkReached(t: ResourceTable): bool =
  ## ~75% of cap, 7.4's trigger. An uncapped table has no watermark: its bound
  ## is the OS ulimit, and sweeping it early would be work with no budget to
  ## measure against.
  t.cap > 0 and (t.finishedCount * 4) >= (t.cap * 3)

proc acquire*(t: var ResourceTable, reference: int64,
              site: string): TuckResult[ResourceHandle] =
  ## Register a freshly opened OS handle. Exhaustion is ABSENCE, not an error —
  ## the caller decides what running out means, exactly as 7.2's pool does.
  ##
  ## Sizes a capped table on first use, so a table built as a plain literal
  ## behaves exactly as one built through initResourceTable. That is what lets
  ## each backend emit the declaration as a STATIC initializer with no
  ## start-up code at all — the knobs are the declaration, and the shape
  ## follows from them.
  if t.cap > 0 and t.entries.len < t.cap:
    t.entries.setLen(t.cap)
  for i in 0 ..< t.entries.len:
    if t.entries[i].live: continue
    t.entries[i].gen.inc
    t.entries[i].reference = reference
    t.entries[i].live = true
    t.entries[i].finished = false
    t.entries[i].site = site
    t.order.add(int32(i))
    return tok(ResourceHandle(slot: int32(i), gen: t.entries[i].gen))
  if t.cap > 0:
    # The cap is the leak alarm as much as the budget: a table that FILLS is a
    # bug surfacing early rather than an OOM three days in. Which of those two
    # readings applies is the kind's own `on_full`: shed load, or stop.
    if t.onFull == rtoError:
      tuckResourceMisuse(t.kind, "table is full (cap " & $t.cap &
                         ") and the kind declares `on_full: error`")
    return tnone[ResourceHandle]()
  t.entries.add(ResourceEntry(reference: reference, gen: 1, live: true,
                              site: site))
  t.order.add(int32(t.entries.len - 1))
  tok(ResourceHandle(slot: int32(t.entries.len - 1), gen: 1))

proc entryFor(t: var ResourceTable, h: ResourceHandle,
              what: string): int =
  ## The slot this handle names, or an abort. Every way of being wrong is
  ## caught rather than absorbed: out of range, never handed out, and — the
  ## one that matters — a generation that has moved on, which is a handle held
  ## past its finish.
  let i = int(h.slot)
  if i < 0 or i >= t.entries.len:
    tuckResourceMisuse(t.kind, what & " of a handle that names no slot (" & $i & ")")
  elif not t.entries[i].live:
    tuckResourceMisuse(t.kind, what & " of slot " & $i & ", which nobody holds")
  elif t.entries[i].gen != h.gen:
    tuckResourceMisuse(t.kind, what & " of a stale handle for slot " & $i &
                       ": tenancy " & $h.gen & ", slot is on " & $t.entries[i].gen)
  i

proc deref*(t: var ResourceTable, h: ResourceHandle): int64 =
  ## The OS handle behind a live tuck handle. This is the only way to reach
  ## one, which is what makes the generation check unavoidable rather than
  ## something a caller can forget.
  t.entries[t.entryFor(h, "use")].reference

proc finish*(t: var ResourceTable, h: ResourceHandle) =
  ## 7.4's mark: release INTENT, not necessarily release.
  ##
  ## Three things happen here under every policy — `on_finish` runs, the entry
  ## is marked, and the generation is bumped so the handle dies AT THE MARK.
  ## Only the fourth, reclaiming the OS handle, is policy. That split is what
  ## makes durability independent of sweep timing: a write-heavy loop under
  ## lazy policy has already flushed by the time anything is evicted.
  let i = t.entryFor(h, "finish")
  if t.onFinish != nil: t.onFinish(t.entries[i].reference)
  t.entries[i].finished = true
  t.entries[i].gen.inc
  t.finishedCount.inc
  case t.policy
  of rtStrict: t.reclaim(i)
  of rtLazy:
    # Sweeping is INLINE — no thread, no background actor. The trigger lives
    # in the mark itself, so a loop acquiring ten thousand times against a cap
    # in the thousands never blocks: each iteration's mark reclaims once the
    # watermark trips. Amortized, and on the thread that made the garbage.
    if t.watermarkReached(): t.sweep()
  of rtExit: discard

proc closeAll*(t: var ResourceTable) =
  ## Program end, or an explicit shutdown. LIFO in REGISTRATION order: files
  ## flush before the directories holding them close, a TLS session shuts down
  ## before the socket under it.
  for k in countdown(t.order.len - 1, 0):
    let i = int(t.order[k])
    if not t.entries[i].live: continue
    if not t.entries[i].finished and t.onFinish != nil:
      t.onFinish(t.entries[i].reference)
    if t.onClose != nil: t.onClose(t.entries[i].reference)
    t.entries[i].live = false
    t.entries[i].finished = false
    t.entries[i].site = ""
  t.order.setLen(0)
  t.finishedCount = 0

iterator openEntries*(t: ResourceTable): tuple[slot: int, site: string] =
  ## Everything acquired and never finished — the OPEN RESOURCES report, in
  ## the same spirit as PENDING and SHORTCUTS. In registration order, so the
  ## list reads as the program ran.
  for k in 0 ..< t.order.len:
    let i = int(t.order[k])
    if t.entries[i].live and not t.entries[i].finished:
      yield (i, t.entries[i].site)

proc openCount*(t: ResourceTable): int =
  for _ in t.openEntries(): result.inc

proc reportOpenResources*(t: ResourceTable) =
  ## 7.4's OPEN RESOURCES report, in the same spirit as PENDING and SHORTCUTS:
  ## say what is unfinished and WHERE it was acquired, so the answer is a line
  ## number rather than a hunt.
  ##
  ## Debug builds only, and silent when there is nothing to say — a report
  ## that prints "0" every run is one people stop reading.
  when not defined(release) and not defined(danger):
    let n = t.openCount()
    if n == 0: return
    stderr.writeLine("OPEN RESOURCES [" & t.kind & "] (" & $n & "):")
    for e in t.openEntries():
      stderr.writeLine("  slot " & $e.slot & " acquired at " & e.site)

proc shutdownResources*(t: var ResourceTable) =
  ## What a program does with one registry at exit: SAY what leaked, then
  ## close everything. In that order — close-all empties the table, so a
  ## report after it would always be empty and always be silent.
  t.reportOpenResources()
  t.closeAll()

import std/atomics

type
  MailboxLock = object
    ## A spinlock, not a pthread Lock: the critical section it guards is a
    ## bounds check plus one array write and an index bump — a handful of
    ## instructions, never a syscall or an allocation. Measured against
    ## std/locks.Lock on this exact shape (one sender thread, one actor
    ## thread, both hammering the same mailbox): the spinlock won every
    ## interleaved trial, 20-90% ahead, because a busy actor never pays a
    ## futex syscall to find the lock free. Wrong tool if the section held it
    ## across anything blocking — it never does here.
    flag: Atomic[bool]

  Mailbox*[T; Cap: static int] = object
    data*: array[Cap, T]
    head*: int
    tail*: int
    lock*: MailboxLock   # sends come from other threads; drain from the
                         # scheduler thread — enqueue/dequeue must be guarded

proc acquire(l: var MailboxLock) {.inline.} =
  while l.flag.exchange(true, moAcquire):
    while l.flag.load(moRelaxed): cpuRelax()

proc release(l: var MailboxLock) {.inline.} =
  l.flag.store(false, moRelease)

proc enqueue*[T; Cap: static int](mb: var Mailbox[T, Cap], msg: T): bool =
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
import std/[os, times, syncio, sysrand]
import ./tuck_async
from std/posix import nil

# spec 7.4's `on_finish` vocabulary, as real syscalls on the entry's reference.
#
# Defined HERE rather than beside the registry above because both need posix,
# which this file only reaches at this point. The declaration picks one of
# these by name and the emitted table binds it, so there is ONE mechanism —
# `setResourceHooks` still overrides, which is the escape hatch for a kind
# whose reference is not an fd at all.
#
# A failed syscall is deliberately not reported: `on_finish` runs at the MARK,
# where the program has already said it is done with the handle, and there is
# nothing left to do about an error nobody asked for. The close-all path and
# the OPEN RESOURCES report are where an unfinished resource surfaces.
proc tuckResFlush*(reference: int64) {.nimcall.} =
  ## `file: flush` — the durability half of finishing, which is exactly why
  ## §7.4 splits marking from reclamation: a write-heavy loop under `lazy` has
  ## already hit the disk by the time anything is evicted.
  discard posix.fsync(cint(reference))

proc tuckResShutdown*(reference: int64) {.nimcall.} =
  ## the net case — both directions, so a peer sees the close immediately
  ## rather than when the fd is finally reclaimed.
  discard posix.shutdown(posix.SocketHandle(reference), cint(posix.SHUT_RDWR))

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

  NetErrKind = enum
    ## The errno classes a Tuck program can act on differently, mirroring the
    ## NetError variants in std/net.tuck.
    nekRefused
    nekAddressInUse
    nekUnreachable
    nekClosed
    nekIoFailed

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

proc makeDir*(path: string): TuckResult[tuple[]] =
  ## NOT offloaded, same rationale as fileExists. Idempotent by an explicit
  ## check rather than relying on os.createDir's own already-exists
  ## behavior, so all three backends agree on the same contract.
  if os.dirExists(path): return tokVoid()
  try:
    os.createDir(path)
    tokVoid()
  except OSError as e:
    if e.errorCode == 13: fsErr[tuple[]](iosAccessDenied)
    else: fsErr[tuple[]](iosIoFailed)

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
    terr[tuple[line: string]](errCode("console/IoError.EndOfInput"))
  of iosOk:
    var line = newString(req.len)
    for i in 0 ..< req.len: line[i] = req.buf[i]
    tok((line: line))
  of iosIoFailed, iosNotFound, iosAccessDenied:
    terr[tuple[line: string]](errCode("console/IoError.IoFailed"))

# --- std/net: TCP over the reactor ------------------------------------------
#
# Sockets have real readiness, so every one of these SUSPENDS the calling task
# through the reactor rather than blocking the process. None of them touch the
# blocking worker — that is only for files, path metadata and DNS, which have
# no readiness to await (thoughts/async-endgame-measurements.md).
#
# Raw posix rather than std/net: Nim's Socket is a blocking abstraction over
# the same fds, and the whole point is to hand codegen a plain int fd that
# `on select | read fd` can await directly.

proc netErr[T](e: NetErrKind): TuckResult[T] =
  ## One place mapping an errno class onto the NetError variants declared in
  ## std/net.tuck. Exhaustive, so a new kind is a compile error here.
  case e
  of nekRefused: terr[T](errCode("net/NetError.Refused"))
  of nekAddressInUse: terr[T](errCode("net/NetError.AddressInUse"))
  of nekUnreachable: terr[T](errCode("net/NetError.Unreachable"))
  of nekClosed: terr[T](errCode("net/NetError.Closed"))
  of nekIoFailed: terr[T](errCode("net/NetError.IoFailed"))

proc classifyErrno(): NetErrKind =
  ## errno at the moment of failure, bucketed into what a Tuck program can act
  ## on. Anything unrecognised is IoFailed rather than a guess.
  let e = osLastError().int32
  if e == posix.ECONNREFUSED: nekRefused
  elif e == posix.EADDRINUSE: nekAddressInUse
  elif e == posix.ENETUNREACH or e == posix.EHOSTUNREACH: nekUnreachable
  elif e == posix.EPIPE or e == posix.ECONNRESET: nekClosed
  else: nekIoFailed

proc setNonBlocking(fd: cint) =
  let fl = posix.fcntl(fd, posix.F_GETFL, 0)
  discard posix.fcntl(fd, posix.F_SETFL, fl or posix.O_NONBLOCK)

proc listen*(port: int): TuckResult[tuple[fd: int]] =
  let sh = posix.socket(posix.AF_INET, posix.SOCK_STREAM, 0)
  if cint(sh) < 0: return netErr[tuple[fd: int]](classifyErrno())
  let fd = cint(sh)
  # SO_REUSEADDR so a restarted server does not trip over its own TIME_WAIT
  # sockets — without it, rebinding within ~60s of a shutdown fails.
  var yes: cint = 1
  discard posix.setsockopt(posix.SocketHandle(fd), posix.SOL_SOCKET,
                           posix.SO_REUSEADDR, addr yes,
                           posix.SockLen(sizeof(yes)))
  var sa: posix.Sockaddr_in
  sa.sin_family = posix.TSa_Family(posix.AF_INET)
  sa.sin_port = posix.htons(uint16(port))
  sa.sin_addr.s_addr = posix.INADDR_ANY
  if posix.bindSocket(posix.SocketHandle(fd), cast[ptr posix.SockAddr](addr sa),
                      posix.SockLen(sizeof(sa))) < 0:
    let k = classifyErrno()
    discard posix.close(fd)
    return netErr[tuple[fd: int]](k)
  if posix.listen(posix.SocketHandle(fd), 64) < 0:
    let k = classifyErrno()
    discard posix.close(fd)
    return netErr[tuple[fd: int]](k)
  setNonBlocking(fd)
  tok((fd: fd.int))

proc accept*(fd: int): TuckResult[tuple[fd: int]] =
  ## Suspends on the listening fd until a client arrives. The loop re-parks on
  ## a spurious wake (another coroutine took the connection first).
  while true:
    tuckAwaitRead(fd)
    let c = cint(posix.accept(posix.SocketHandle(fd), nil, nil))
    if c >= 0:
      setNonBlocking(c)
      return tok((fd: c.int))
    let e = osLastError().int32
    if e != posix.EAGAIN and e != posix.EWOULDBLOCK:
      return netErr[tuple[fd: int]](classifyErrno())

proc connect*(host: string, port: int): TuckResult[tuple[fd: int]] =
  ## Non-blocking connect: the syscall returns posix.EINPROGRESS immediately and the
  ## fd becomes WRITABLE when the handshake finishes, so the task suspends on
  ## write-readiness rather than blocking.
  let sh = posix.socket(posix.AF_INET, posix.SOCK_STREAM, 0)
  if cint(sh) < 0: return netErr[tuple[fd: int]](classifyErrno())
  let fd = cint(sh)
  setNonBlocking(fd)
  var sa: posix.Sockaddr_in
  sa.sin_family = posix.TSa_Family(posix.AF_INET)
  sa.sin_port = posix.htons(uint16(port))
  sa.sin_addr.s_addr = posix.inet_addr(host)
  if sa.sin_addr.s_addr == posix.InAddrScalar(0xFFFFFFFF'u32) and
     host != "255.255.255.255":
    # inet_addr only parses dotted quads; a hostname needs DNS, which blocks
    # and therefore belongs on the worker. Not wired yet — say so rather than
    # connecting somewhere unintended.
    discard posix.close(fd)
    return netErr[tuple[fd: int]](nekUnreachable)
  let rc = posix.connect(posix.SocketHandle(fd),
                         cast[ptr posix.SockAddr](addr sa),
                         posix.SockLen(sizeof(sa)))
  if rc < 0:
    let e = osLastError().int32
    if e != posix.EINPROGRESS:
      let k = classifyErrno()
      discard posix.close(fd)
      return netErr[tuple[fd: int]](k)
    tuckAwaitWrite(fd.int)
    # The handshake's real outcome lands in SO_ERROR, not in connect's return.
    var soErr: cint = 0
    var sl = posix.SockLen(sizeof(soErr))
    discard posix.getsockopt(posix.SocketHandle(fd), posix.SOL_SOCKET,
                             posix.SO_ERROR, addr soErr, addr sl)
    if soErr != 0:
      discard posix.close(fd)
      return netErr[tuple[fd: int]](
        if soErr == posix.ECONNREFUSED: nekRefused
        elif soErr == posix.ENETUNREACH or soErr == posix.EHOSTUNREACH: nekUnreachable
        else: nekIoFailed)
  tok((fd: fd.int))

proc recv*(fd: int, max: int): TuckResult[tuple[data: string]] =
  ## An EMPTY result means the peer closed cleanly — not an error, so callers
  ## test `.data.len == 0` rather than matching a variant.
  if max <= 0: return tok((data: ""))
  var buf = newString(max)
  while true:
    tuckAwaitRead(fd)
    let n = posix.recv(posix.SocketHandle(fd), addr buf[0], max, 0)
    if n > 0:
      buf.setLen(n)
      return tok((data: buf))
    if n == 0: return tok((data: ""))
    let e = osLastError().int32
    if e != posix.EAGAIN and e != posix.EWOULDBLOCK:
      return netErr[tuple[data: string]](classifyErrno())

proc send*(fd: int, data: string): TuckResult[tuple[sent: int]] =
  ## Sends ALL of it, suspending on write-readiness whenever the kernel buffer
  ## fills. A partial write is not surfaced: the caller asked to send a value.
  if data.len == 0: return tok((sent: 0))
  var sent = 0
  while sent < data.len:
    let n = posix.send(posix.SocketHandle(fd), unsafeAddr data[sent],
                       data.len - sent, 0)
    if n > 0:
      sent += n
    else:
      let e = osLastError().int32
      if e == posix.EAGAIN or e == posix.EWOULDBLOCK:
        tuckAwaitWrite(fd)
      else:
        return netErr[tuple[sent: int]](classifyErrno())
  tok((sent: sent))

proc close*(fd: int) =
  discard posix.close(cint(fd))

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

# std/random — PCG32 (O'Neill 2014). State is threaded through every call
# as plain fields (state, inc), not an object: see std/random.tuck's header
# for why a named cross-boundary type isn't an option today.
const pcgMult = 6364136223846793005'u64

proc pcgStep(state, inc: uint64): tuple[state: uint64, value: uint32] =
  let newState = state * pcgMult + inc
  let xorshifted = uint32(((state shr 18) xor state) shr 27)
  let rot = int(state shr 59)
  let value = (xorshifted shr rot) or (xorshifted shl ((-rot) and 31))
  (state: newState, value: value)

proc newDice*(seed: uint64): tuple[state: uint64, inc: uint64] =
  let inc = (seed shl 1) or 1'u64
  let (warm, _) = pcgStep(0'u64, inc)
  let (state, _) = pcgStep(warm + seed, inc)
  (state: state, inc: inc)

proc newDiceFromOs*(): tuple[state: uint64, inc: uint64] =
  var seed: uint64
  let bytes = sysrand.urandom(sizeof(seed))
  copyMem(addr seed, unsafeAddr bytes[0], sizeof(seed))
  newDice(seed)

proc rollRange*(state, inc: uint64, low, high: int64):
    tuple[state: uint64, inc: uint64, value: int64] =
  let (newState, value) = pcgStep(state, inc)
  let span = uint64(high - low + 1)
  (state: newState, inc: inc, value: low + int64(uint64(value) mod span))

# std/math — elementary float functions, direct passthroughs to Nim's own.
proc sqrt*(value: float64): float64 = stdmath.sqrt(value)
proc pow*(base, exp: float64): float64 = stdmath.pow(base, exp)

# std/hash — FNV-1a, 64-bit. Same algorithm as errCode above (32-bit,
# compile-time only); this is the runtime, arbitrary-length variant.
proc hash*(data: string): uint64 =
  result = 14695981039346656037'u64
  for c in data:
    result = (result xor uint64(ord(c))) * 1099511628211'u64

# The single runtime facade: tuck_rt re-exports the async runtime so every
# emitted program imports ONLY tuck_rt and reaches rt AND async names
# (readFile, waitUntil, openSource, ...) uniformly. arsenal is bundled as the
# base runtime. A name defined in both modules is a Nim redefinition error at
# stdlib-compile time — the intended hard error, the stdlib author's to fix.
# (The import itself is up with the externs, which call into it.)
export tuck_async
