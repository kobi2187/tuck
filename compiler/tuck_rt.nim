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

# ---------- actor scheduler (spec §9, Phase A) ----------
# ONE background OS thread; actors are opaque drain closures polled
# cooperatively. minicoro joins in Phase C for [io] yield. See the plan at
# ~/.claude/plans/jolly-toasting-elephant.md.
#
# Model (Erlang/Elixir-flavoured): actors NEVER exit — they are daemons that
# run alongside main until the PROGRAM exits. MAIN owns the lifecycle: it runs
# independently, and decides when to end. A CLI ends when main returns; a
# program that must wait for actor work to finish calls Scheduler.waitUntil
# with a predicate over public actor state (`Counter.total == 55`) — main
# blocks there, cond-var-woken after each drain sweep, until the predicate
# holds. A mailbox always accepts sends; a full ring drops silently.
type
  DrainProc* = proc(): bool {.gcsafe.}   # drain my mailbox; did I do work?

  Scheduler* = object
    thread: Thread[void]
    lock: Lock
    wake: Cond          # main → scheduler: work is waiting
    progress: Cond      # scheduler → waiters: a drain sweep just completed
    actors: seq[DrainProc]
    started: bool
    hasWork: bool

var tuckScheduler*: Scheduler            # one per program (rt-owned global)

proc schedulerLoop() {.thread.} = {.cast(gcsafe).}:
  # The seq[DrainProc] is GC'd; we serialize all access with s.lock, so the
  # conservative gcsafe check is satisfied by construction. Runs forever —
  # process exit tears it down.
  let s = addr tuckScheduler
  while true:
    acquire(s.lock)
    while not s.hasWork:
      wait(s.wake, s.lock)
    s.hasWork = false
    let drains = s.actors
    release(s.lock)
    for d in drains:
      discard d()
    # a sweep finished — wake any waitUntil predicate to re-check
    acquire(s.lock)
    broadcast(s.progress)
    release(s.lock)

proc tuckSchedulerStart*() =
  ## Emitted at the top of main() when the program declares any actor.
  if tuckScheduler.started: return
  tuckScheduler.started = true
  initLock(tuckScheduler.lock)
  initCond(tuckScheduler.wake)
  initCond(tuckScheduler.progress)
  createThread(tuckScheduler.thread, schedulerLoop)

proc tuckStartActor*(drain: DrainProc) =
  ## Register + wake. Emitted once per declared actor (auto-registered).
  acquire(tuckScheduler.lock)
  tuckScheduler.actors.add(drain)
  tuckScheduler.hasWork = true
  release(tuckScheduler.lock)
  signal(tuckScheduler.wake)

proc tuckNotifySend*() =
  ## Emitted by each send after enqueue: wake the scheduler to drain.
  acquire(tuckScheduler.lock)
  tuckScheduler.hasWork = true
  release(tuckScheduler.lock)
  signal(tuckScheduler.wake)

proc waitUntil*(pred: proc(): bool) =
  ## `scheduler::waitUntil {pred: :done}` — main blocks until the predicate
  ## holds, re-checking it each time the scheduler completes a drain sweep
  ## (cond-var, no busy-poll). The predicate reads public actor fields; it runs
  ## on the MAIN thread (not the scheduler), so no gcsafe requirement — a plain
  ## field read racing the scheduler's write is benign (the loop re-checks).
  ## The name matches std/scheduler.tuck's extern signature.
  if not tuckScheduler.started:
    # no scheduler running (no actors) — the predicate can only be decided by
    # main itself; check once and return rather than block forever
    discard pred()
    return
  acquire(tuckScheduler.lock)
  while not pred():
    wait(tuckScheduler.progress, tuckScheduler.lock)
  release(tuckScheduler.lock)

# ---------- stdlib externs (std/*.tuck) ----------
# Nim's portable stdlib IS Tuck's OS layer. Exceptions never escape: every
# fallible fn catches and returns terr(errCode("Enum.Variant")) — matching
# the error enums declared in the std/*.tuck signatures.
import std/[os, times, syncio]

proc readFile*(path: string): TuckResult[tuple[content: string]] =
  try:
    if not fileExists(path):
      return terr[tuple[content: string]](errCode("fs/FsError.NotFound"))
    tok((content: syncio.readFile(path)))
  except IOError, OSError:
    terr[tuple[content: string]](errCode("fs/FsError.IoFailed"))

proc writeFile*(path: string, content: string): TuckResult[tuple[]] =
  try:
    syncio.writeFile(path, content)
    tokVoid()
  except IOError, OSError:
    terr[tuple[]](errCode("fs/FsError.AccessDenied"))

proc appendFile*(path: string, content: string): TuckResult[tuple[]] =
  try:
    let f = open(path, fmAppend)
    f.write(content)
    f.close()
    tokVoid()
  except IOError, OSError:
    terr[tuple[]](errCode("fs/FsError.AccessDenied"))

proc removeFile*(path: string): TuckResult[tuple[]] =
  try:
    if not fileExists(path):
      return terr[tuple[]](errCode("fs/FsError.NotFound"))
    os.removeFile(path)
    tokVoid()
  except OSError:
    terr[tuple[]](errCode("fs/FsError.AccessDenied"))

proc fileExists*(path: string): bool = os.fileExists(path)

proc print*(text: string) = stdout.write(text)
proc printLine*(text: string) = stdout.writeLine(text)

proc readLine*(): TuckResult[tuple[line: string]] =
  try:
    tok((line: stdin.readLine()))
  except EOFError:
    terr[tuple[line: string]](errCode("io/IoError.EndOfInput"))
  except IOError:
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
proc sleepMs*(ms: uint32) = os.sleep(int(ms))
