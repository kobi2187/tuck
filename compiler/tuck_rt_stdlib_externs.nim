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
    when MailboxNeedsLock:
      flag: Atomic[bool]

  Batch*[T; C: static int] = object
    ## A run of messages written by one thread and read by one actor. It
    ## crosses as a pointer, so neither side ever copies it.
    ##
    ## Ownership is positional, not a flag: a batch is either on its actor's
    ## free list, or held by exactly one sender, or on that actor's handover
    ## queue. Never two of those, so neither side needs a lock to read or
    ## write the messages themselves.
    msgs*: array[C, T]
    n*: int

  Mailbox*[T; Cap: static int] = object
    ## TWO buffers, not one ring. Senders fill `buf[cur]`; the actor flips
    ## `cur` and then owns the buffer it just took outright — so the whole
    ## drain runs with no lock held and nothing copied out. A handover is one
    ## integer write, whatever the batch size.
    ##
    ## The ring this replaced took the lock once PER MESSAGE and copied each
    ## envelope out under it. Both costs are gone; what is left on the hot
    ## path is the sender's own acquire, one array write, and a release.
    ##
    ## Costs `2 * Cap` elements rather than `Cap`. `[queue: N]` therefore
    ## means "N messages may be waiting to be picked up", and an actor can
    ## hold up to another N it has already taken.
    ##
    ## Zero-initialized is a valid empty mailbox — no init call, which is why
    ## there is no initMailbox to forget.
    when TuckActorsBatch:
      ## Batch mode swaps the SAME two-buffer structure one level up: the
      ## elements are batch pointers, so a handover moves a pointer and a
      ## drain takes every pending batch in one flip.
      ##
      ## The batches themselves live HERE, in one pool per actor sized from
      ## `[queue: N]` — so N still means "about N messages may be waiting",
      ## shared across every sender, and nothing is paid out of TLS.
      pool*: array[max(TuckMinBatches, Cap div TuckBatchCount),
                   Batch[T, TuckBatchCount]]
      freeList*: array[max(TuckMinBatches, Cap div TuckBatchCount),
                       ptr Batch[T, TuckBatchCount]]
      freeTop*: int          ## stack pointer into freeList
      freeReady*: bool       ## freeList has been seeded with pool addresses
      qbuf*: array[2, array[max(TuckMinBatches, Cap div TuckBatchCount),
                            ptr Batch[T, TuckBatchCount]]]
      qfill*: array[2, int]
      qcur*: int
    else:
      buf*: array[2, array[Cap, T]]
      pad*: array[CacheLine, byte]
        ## Keeps the control block off the last line of `buf`. Without it the
        ## two share a cache line — measured, at offsets 8192..8224 for a
        ## 128-slot mailbox — so the consumer streaming through `buf` and the
        ## senders hammering `lock` invalidate each other's line for no
        ## reason. Worth ~10% under contention.
      fill*: array[2, int] ## how many messages are in each buffer
      cur*: int            ## the one senders fill; the actor owns 1-cur
    lock*: MailboxLock     ## guards the queue's `cur` and `fill` — nothing
                           ## else, and never across a handler

  Staging*[T; Cap: static int] = object
    ## One thread's outbound batch for ONE actor. A threadvar inside a
    ## generic, so Nim gives each (T, Cap) its own — and every Tuck actor has
    ## its own nominal `<Actor>Msg`, so that means one per actor per thread,
    ## with no registry to keep. Nothing here is shared, hence no lock.
    ##
    ## It BORROWS its batch from the actor's pool rather than owning private
    ## storage, and that is not about how many threads there are — the set is
    ## small and known (main, plus one per actor). It is about WHERE private
    ## storage would have to live. Staging is a threadvar, so a private ring
    ## is paid out of every thread's TLS, which means its depth has to be
    ## capped by a constant rather than by `[queue: N]`. Measured: capped at
    ## 64 batches, a program with `[queue: 1048576]` silently began dropping
    ## after 4096 messages and its `waitUntil` never came true.
    ##
    ## Borrowing costs one lock acquire per BATCH at each end — a fraction of
    ## an atomic per message, and measured at parity with single mode, which
    ## has no locks at all.
    cur*: ptr Batch[T, TuckBatchCount]  ## the borrowed batch, or nil
    sends*: int              ## counts down to the next deadline check
    opened*: MonoTime        ## when the current batch took its first message
    mb*: ptr Mailbox[T, Cap] ## where to hand over
    registered*: bool        ## already on this thread's flush-hook list

proc acquire(l: var MailboxLock) {.inline.} =
  ## Takes the mailbox spin lock (a no-op in single-thread mode).
  when MailboxNeedsLock:
    while l.flag.exchange(true, moAcquire):
      while l.flag.load(moRelaxed): cpuRelax()

proc release(l: var MailboxLock) {.inline.} =
  ## Releases the mailbox spin lock (a no-op in single-thread mode).
  when MailboxNeedsLock:
    l.flag.store(false, moRelease)

when TuckActorsBatch:
  proc seedFree[T; Cap: static int](mb: var Mailbox[T, Cap]) =
    ## Fill the free list with the pool's own addresses. Lazy, because a
    ## zero-initialized mailbox has to be a valid empty one — the same
    ## property the message-mode mailbox has, kept for the same reason.
    ## Called with the lock held.
    if mb.freeReady: return
    mb.freeReady = true
    for i in 0 ..< mb.pool.len:
      mb.freeList[i] = addr mb.pool[i]
    mb.freeTop = mb.pool.len

  proc takeFree[T; Cap: static int](mb: var Mailbox[T, Cap]): ptr Batch[T, TuckBatchCount] =
    ## Borrow a batch, or nil when the actor is that far behind. Once per
    ## BATCH, so a fraction of an atomic per message.
    acquire(mb.lock)
    seedFree(mb)
    if mb.freeTop == 0:
      release(mb.lock)
      return nil
    dec mb.freeTop
    result = mb.freeList[mb.freeTop]
    release(mb.lock)
    result.n = 0

  proc handOver[T; Cap: static int](st: var Staging[T, Cap]): bool
      {.discardable.} =
    ## Give the borrowed batch to the actor. A no-op when this thread holds
    ## nothing, so it is safe at every flush point whether or not anything
    ## was sent. Returns whether anything actually crossed — tuckFlushStaged
    ## needs that to decide whether a wake is owed.
    if st.cur == nil or st.cur.n == 0: return false
    let mb = st.mb
    acquire(mb.lock)
    let c = mb.qcur
    # Cannot overflow: the queue is as deep as the pool, and every batch on
    # it came out of that pool.
    mb.qbuf[c][mb.qfill[c]] = st.cur
    inc mb.qfill[c]
    release(mb.lock)
    st.cur = nil
    true

  proc flushHook[T; Cap: static int](p: pointer): bool {.nimcall, gcsafe.} =
    ## The flush entry registered for one thread's staging buffer: hands over
    ## whatever batch it holds.
    handOver(cast[ptr Staging[T, Cap]](p)[])

  proc flushDueHook[T; Cap: static int](p: pointer): bool {.nimcall, gcsafe.} =
    ## The same, but only once the batch has been open longer than
    ## `--batch-timeout`. Returns early without reading the clock when this
    ## thread is holding nothing for this actor, which is the common case on
    ## the send path.
    when TuckBatchTimeoutMs <= 0:
      false
    else:
      let st = cast[ptr Staging[T, Cap]](p)
      if st.cur == nil or st.cur.n == 0: return false
      if (getMonoTime() - st.opened).inMilliseconds < TuckBatchTimeoutMs:
        return false
      handOver(st[])

  proc stagingFor[T; Cap: static int](mb: var Mailbox[T, Cap]): ptr Staging[T, Cap] =
    ## This thread's staging buffer for mailbox `mb`, created (and registered
    ## for flushing) on first use.
    ##
    ## Keyed by the MAILBOX, not by its type. It was one threadvar per
    ## `[T, Cap]`, which was one per actor only while every mailbox had a
    ## message type of its own; an actor's `[urgent]` mailbox shares its
    ## ordinary one's type, and their sends landed in one staging buffer,
    ## handed to whichever mailbox registered first.
    var all {.threadvar.}: seq[ptr Staging[T, Cap]]
    for st in all:
      if st.mb == addr mb: return st
    # One per (thread, mailbox), for the thread's life: never freed.
    let st = create(Staging[T, Cap])
    st.registered = true
    st.mb = addr mb
    # So the thread can flush everything it holds without naming any of it
    # — see tuck_async.tuckFlushStaged.
    tuckRegisterFlush(flushHook[T, Cap], flushDueHook[T, Cap], st)
    all.add st
    st



proc flushNow*[T; Cap: static int](mb: var Mailbox[T, Cap]) =
  ## Hand over what this thread has staged for `mb` at once: an `[urgent]`
  ## send does not wait for its batch to fill. A no-op outside batch mode,
  ## where every send is already handed over as it is made.
  when TuckActorsBatch:
    handOver(stagingFor(mb)[])

proc enqueue*[T; Cap: static int](mb: var Mailbox[T, Cap], msg: T): bool =
  ## Sends `msg` to the mailbox; false when it is full and the message was
  ## not taken — the actor's `on_full` decides what then (R6: sendWaiting,
  ## sendAsserting, or `drop`'s bare enqueue). In batch mode the message is
  ## staged and handed over when the batch fills or its deadline passes.
  when TuckActorsBatch:
    let st = stagingFor(mb)
    if st.cur == nil:
      st.cur = takeFree(mb)
      if st.cur == nil:
        return false          # the pool is out: full, as a full ring is
      st.opened = getMonoTime()
    let b = st.cur
    b.msgs[b.n] = msg
    inc b.n
    inc st.sends
    if b.n >= TuckBatchCount:
      handOver(st[])
    elif st.sends >= TuckBatchCheckEvery:
      # Sweep THIS THREAD'S batches, not just this one. The deadline used to
      # be tested here against `st` alone, which kept `--batch-timeout`'s
      # promise for every mailbox except the one that needed it — see
      # tuck_async.tuckFlushDueStaged.
      st.sends = 0
      tuckFlushDueStaged()
    return true
  else:
    acquire(mb.lock)
    let c = mb.cur
    if mb.fill[c] >= Cap:
      release(mb.lock)
      return false            # full: the actor's on_full decides (R6)
    mb.buf[c][mb.fill[c]] = msg
    inc mb.fill[c]
    release(mb.lock)
    return true

proc sendWaiting*[T; Cap: static int](mb: var Mailbox[T, Cap], msg: T,
                                       handle: pointer, actor: string) {.inline.} =
  ## A send to an actor declaring `on_full: wait`, the default (R6): when the
  ## mailbox is full, wait for room. `msg` is built once, by the caller.
  while not enqueue(mb, msg): tuckAwaitRoom(handle, actor)

proc sendAsserting*[T; Cap: static int](mb: var Mailbox[T, Cap], msg: T,
                                         actor: string) {.inline.} =
  ## A send to an actor declaring `on_full: assert` (R6): a full mailbox stops
  ## the program.
  if not enqueue(mb, msg):
    tuckMailboxFull(actor, "the actor declares `on_full: assert` (queue: " &
                    $Cap & ")")

iterator messages*[T; Cap: static int](mb: var Mailbox[T, Cap]): var T =
  ## Take everything waiting and yield it IN PLACE. The swap happens once, up
  ## front, under the lock; every yield after that touches a buffer no sender
  ## can reach, so a handler runs with no lock held and no message copied.
  ##
  ## `fill` is cleared before the first yield rather than after the last, so
  ## an early exit from the loop body leaves the mailbox consistent instead of
  ## re-delivering a batch.
  when TuckActorsBatch:
    # The same swap, one level up: take every pending BATCH in one flip, then
    # walk each batch's messages in place. A batch is returned to its sender
    # only after its last message has been handled, which is what makes
    # `inFlight` a complete ownership protocol rather than a hint.
    acquire(mb.lock)
    let c = mb.qcur
    let n = mb.qfill[c]
    if n > 0:
      mb.qcur = 1 - c
      mb.qfill[c] = 0
    release(mb.lock)
    for i in 0 ..< n:
      let b = mb.qbuf[c][i]
      for j in 0 ..< b.n:
        yield b.msgs[j]
      b.n = 0
      # Returned only after its LAST message has been handled, so a sender
      # cannot be writing into it while a handler reads.
      acquire(mb.lock)
      mb.freeList[mb.freeTop] = b
      inc mb.freeTop
      release(mb.lock)
  else:
    acquire(mb.lock)
    let c = mb.cur
    let n = mb.fill[c]
    if n > 0:
      mb.cur = 1 - c          # THE SWAP: the actor now owns buf[c]
      mb.fill[c] = 0
    release(mb.lock)
    for i in 0 ..< n:
      yield mb.buf[c][i]

proc hasRoom*[T; Cap: static int](mb: var Mailbox[T, Cap]): bool =
  ## Sender's opt-in backpressure check. sendX drops silently on a full
  ## mailbox (fast, non-blocking, spec §9.1) — the sender may check first if
  ## it cares. Answers for the buffer senders are filling now; the actor's
  ## own half is not a sender's business.
  when TuckActorsBatch:
    # Room means "this thread holds a batch, or the pool can lend it one" —
    # the two ways the next send can succeed.
    let st = stagingFor(mb)
    if st.cur != nil: return true
    acquire(mb.lock)
    seedFree(mb)
    result = mb.freeTop > 0
    release(mb.lock)
  else:
    acquire(mb.lock)
    result = mb.fill[mb.cur] < Cap
    release(mb.lock)



# ---------- stdlib externs (std/*.tuck) ----------
# Nim's portable stdlib IS Tuck's OS layer. Exceptions never escape: every
# fallible fn catches and returns terr(errCode("Enum.Variant")) — matching
# the error enums declared in the std/*.tuck signatures.
#
# Imported HERE rather than at the facade below because the blocking externs
# route through tuck_async.tuckSubmitBlocking — see readLine.
when not defined(freestanding):
  import std/[os, times, syncio, sysrand, algorithm, osproc]
  from std/nativesockets import getHostname
  from std/posix import nil
import ./tuck_async

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
    ## Which file operation a request to the blocking worker performs.
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
    ## One file operation for the blocking worker. Every pointer is C memory the
    ## caller owns, so no GC memory crosses to the worker thread.
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
  ## The whole file at `path`, read on the blocking worker so other coroutines
  ## keep running. Fails with an fs error code.
  var r = runFileOp(fopRead, path)
  if r.status != iosOk: return fsErr[tuple[content: string]](r.status)
  var content = newString(r.outLen)
  if r.outLen > 0:
    copyMem(addr content[0], r.outBuf, r.outLen)
  if r.outBuf != nil: cFree(r.outBuf)
  tok((content: tuckMove(content)))

proc writeFile*(path: string, content: string): TuckResult[tuple[]] =
  ## Replaces the file at `path` with `content`, on the blocking worker.
  let r = runFileOp(fopWrite, path, content)
  if r.status == iosOk: tokVoid() else: fsErr[tuple[]](r.status)

proc appendFile*(path: string, content: string): TuckResult[tuple[]] =
  ## Appends `content` to the file at `path`, creating it if needed, on the
  ## blocking worker.
  let r = runFileOp(fopAppend, path, content)
  if r.status == iosOk: tokVoid() else: fsErr[tuple[]](r.status)

proc removeFile*(path: string): TuckResult[tuple[]] =
  ## Deletes the file at `path`, on the blocking worker.
  let r = runFileOp(fopRemove, path)
  if r.status == iosOk: tokVoid() else: fsErr[tuple[]](r.status)

proc fileExists*(path: string): bool =
  ## NOT offloaded: a stat is a metadata lookup, microseconds on any live
  ## filesystem. Paying a thread handoff and a pipe round-trip for it would
  ## cost more than the call.
  os.fileExists(path)

proc listDir*(path: string): seq[string] =
  ## The names (not paths) of what is directly inside `path`, sorted; empty
  ## when `path` is missing or not a directory. Like fileExists, a metadata
  ## lookup: not offloaded.
  if not os.dirExists(path): return @[]
  for _, p in os.walkDir(path, relative = true): result.add p
  algorithm.sort(result)

proc fsErrno[T](e: cint): TuckResult[T] =
  ## errno from a metadata call (stat, rename, rmdir) onto the FsError
  ## variants, the same buckets in all three runtimes.
  if e == posix.ENOENT or e == posix.ENOTDIR: terr[T](errCode("fs/FsError.NotFound"))
  elif e == posix.EACCES or e == posix.EPERM: terr[T](errCode("fs/FsError.AccessDenied"))
  elif e == posix.ENOTEMPTY or e == posix.EEXIST: terr[T](errCode("fs/FsError.NotEmpty"))
  else: terr[T](errCode("fs/FsError.IoFailed"))

proc pathInfo*(path: string): TuckResult[tuple[isFolder: bool, isLink: bool,
                                                bytes: int, modifiedMs: int]] =
  ## lstat: a final symbolic link is reported as a link, not followed. NOT
  ## offloaded, same rationale as fileExists.
  var st: posix.Stat
  if posix.lstat(path.cstring, st) != 0:
    return fsErrno[tuple[isFolder: bool, isLink: bool, bytes: int,
                         modifiedMs: int]](posix.errno)
  let ms = int(st.st_mtim.tv_sec) * 1000 + int(st.st_mtim.tv_nsec) div 1_000_000
  tok((isFolder: posix.S_ISDIR(st.st_mode), isLink: posix.S_ISLNK(st.st_mode),
       bytes: int(st.st_size), modifiedMs: ms))

proc cRename(a, b: cstring): cint {.importc: "rename", header: "<stdio.h>".}

proc renamePath*(path, to: string): TuckResult[tuple[]] =
  ## rename(2): atomic within one filesystem, replacing a file at `to`.
  if cRename(path.cstring, to.cstring) != 0: return fsErrno[tuple[]](posix.errno)
  tokVoid()

proc removeFolder*(path: string): TuckResult[tuple[]] =
  ## rmdir(2): an empty folder only.
  if posix.rmdir(path.cstring) != 0: return fsErrno[tuple[]](posix.errno)
  tokVoid()

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

proc print*(text: string) =
  ## Writes `text` to stdout with no newline.
  stdout.write(text)
proc printLine*(text: string) =
  ## Writes `text` and a newline to stdout. Two plain writes: `writeLine` takes
  ## a varargs of `$` conversions, which copies every string it is given.
  stdout.write(text)
  stdout.write("\n")

proc printError*(text: string) =
  ## Writes `text` and a newline to stderr, at once.
  stderr.write(text)
  stderr.write("\n")
  stderr.flushFile()

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
    tok((line: tuckMove(line)))
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
  ## Puts `fd` in non-blocking mode, so the reactor can wait on it instead of
  ## the call blocking the thread.
  let fl = posix.fcntl(fd, posix.F_GETFL, 0)
  discard posix.fcntl(fd, posix.F_SETFL, fl or posix.O_NONBLOCK)

proc listen*(port: int): TuckResult[tuple[fd: int]] =
  ## A non-blocking TCP socket listening on all interfaces at `port`
  ## (SO_REUSEADDR set, backlog 64), or the classified errno.
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
      tuckStrTruncate(buf, n)
      return tok((data: tuckMove(buf)))
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
  ## Closes an fd. Errors are ignored: there is nothing a caller can do.
  discard posix.close(cint(fd))

proc runCommand*(line: string): int =
  ## Runs `line` through the shell, output going where the program's own
  ## goes, and returns its exit code. Blocks the caller until it ends.
  osproc.execCmd(line)

proc cPopen(cmd, mode: cstring): pointer {.importc: "popen", header: "<stdio.h>".}
proc cPclose(f: pointer): cint {.importc: "pclose", header: "<stdio.h>".}
proc cFread(buf: pointer, size, n: csize_t, f: pointer): csize_t
  {.importc: "fread", header: "<stdio.h>".}

proc captureCommand*(line: string): tuple[code: int, output: string] =
  ## Runs `line` through the shell (C's popen, as the Odin and D runtimes do)
  ## and answers its stdout and exit status: the code it exited with, or 128 +
  ## N when signal N ended it. stderr is not captured.
  let f = cPopen(cstring(line), "r")
  if f == nil: return (code: 127, output: "")
  var buf: array[4096, char]
  while true:
    let n = cFread(addr buf[0], 1, csize_t(buf.len), f)
    if n == 0: break
    for i in 0 ..< int(n): result.output.add(buf[i])
  let status = int(cPclose(f))
  result.code = if (status and 0x7f) == 0: (status shr 8) and 0xff
                else: 128 + (status and 0x7f)

# --- child processes with pipes (std/sys) --------------------------------------
# A child is started with posix_spawnp and three pipes. The PARENT ends are
# plain descriptors (non-blocking, close-on-exec) that Tuck holds as ints and
# reads and writes through fdRead / fdWrite, which suspend only the calling task
# on the reactor, exactly as a socket does. The child's ends are closed in the
# parent the moment it starts.
type SpawnFileActions {.importc: "posix_spawn_file_actions_t",
                        header: "<spawn.h>".} = object
proc c_spawnp(pid: ptr cint, file: cstring, fa: ptr SpawnFileActions, attr: pointer,
              argv: cstringArray, envp: cstringArray): cint
  {.importc: "posix_spawnp", header: "<spawn.h>", cdecl.}
proc c_fa_init(fa: ptr SpawnFileActions): cint
  {.importc: "posix_spawn_file_actions_init", header: "<spawn.h>", cdecl.}
proc c_fa_destroy(fa: ptr SpawnFileActions): cint
  {.importc: "posix_spawn_file_actions_destroy", header: "<spawn.h>", cdecl.}
proc c_fa_dup2(fa: ptr SpawnFileActions, fd, newfd: cint): cint
  {.importc: "posix_spawn_file_actions_adddup2", header: "<spawn.h>", cdecl.}
proc c_fa_close(fa: ptr SpawnFileActions, fd: cint): cint
  {.importc: "posix_spawn_file_actions_addclose", header: "<spawn.h>", cdecl.}
var c_environ {.importc: "environ", header: "<unistd.h>".}: cstringArray
var gSpawnedOnce = false

proc spawnProcess*(argv: string): tuple[pid: int, input: int, output: int, errors: int] =
  ## Starts the program (searched on PATH) named by the first of the
  ## NUL-separated `argv`. pid < 0: it could not be started. `input` is the
  ## write end of the child's stdin; `output` and `errors` are the read ends of
  ## its stdout and stderr.
  let failed = (pid: -1, input: -1, output: -1, errors: -1)
  if not gSpawnedOnce:
    posix.signal(posix.SIGPIPE, posix.SIG_IGN)   # a closed pipe is an error, not a kill
    gSpawnedOnce = true
  var parts: seq[string]
  var cur = ""
  for c in argv:
    if c == '\0':
      parts.add cur
      cur = ""
    else: cur.add c
  parts.add cur
  if parts[0].len == 0: return failed
  var inP, outP, errP: array[2, cint]
  if posix.pipe(inP) != 0 or posix.pipe(outP) != 0 or posix.pipe(errP) != 0:
    return failed
  var fa: SpawnFileActions
  discard c_fa_init(addr fa)
  discard c_fa_dup2(addr fa, inP[0], 0)
  discard c_fa_dup2(addr fa, outP[1], 1)
  discard c_fa_dup2(addr fa, errP[1], 2)
  for fd in [inP[0], inP[1], outP[0], outP[1], errP[0], errP[1]]:
    discard c_fa_close(addr fa, fd)
  var args = allocCStringArray(parts)
  var pid: cint
  let rc = c_spawnp(addr pid, parts[0].cstring, addr fa, nil, args, c_environ)
  deallocCStringArray(args)
  discard c_fa_destroy(addr fa)
  discard posix.close(inP[0]); discard posix.close(outP[1]); discard posix.close(errP[1])
  if rc != 0:
    discard posix.close(inP[1]); discard posix.close(outP[0]); discard posix.close(errP[0])
    return failed
  for fd in [inP[1], outP[0], errP[0]]:
    discard posix.fcntl(fd, posix.F_SETFD, posix.FD_CLOEXEC)
    let fl = posix.fcntl(fd, posix.F_GETFL)
    discard posix.fcntl(fd, posix.F_SETFL, fl or posix.O_NONBLOCK)
  (pid: int(pid), input: int(inP[1]), output: int(outP[0]), errors: int(errP[0]))

proc fdRead*(fd: int, max: int): tuple[data: string] =
  ## Up to `max` bytes from a pipe or file descriptor, suspending the calling
  ## task until some are there. "" is the end of the stream (every writer has
  ## closed it).
  if max <= 0: return (data: "")
  var buf = newString(max)
  while true:
    tuckAwaitRead(fd)
    let n = posix.read(cint(fd), addr buf[0], max)
    if n > 0:
      tuckStrTruncate(buf, n)
      return (data: tuckMove(buf))
    if n == 0: return (data: "")
    if posix.errno != posix.EAGAIN and posix.errno != posix.EWOULDBLOCK:
      return (data: "")

proc fdReadWithin*(fd: int, max: int, timeoutMs: int): TuckResult[tuple[data: string]] =
  ## As fdRead, but nothing (none) when `timeoutMs` passes first. "" is still
  ## the end of the stream.
  if max <= 0: return tok((data: ""))
  var buf = newString(max)
  while true:
    if not tuckAwaitReadOrTimeout(fd, timeoutMs):
      return tnone[tuple[data: string]]()
    let n = posix.read(cint(fd), addr buf[0], max)
    if n > 0:
      tuckStrTruncate(buf, n)
      return tok((data: tuckMove(buf)))
    if n == 0: return tok((data: ""))
    if posix.errno != posix.EAGAIN and posix.errno != posix.EWOULDBLOCK:
      return tok((data: ""))

proc fdWrite*(fd: int, data: string): tuple[sent: int] =
  ## Writes ALL of `data`, suspending on write-readiness while the pipe is
  ## full. Fewer than len(data) is reported when the reader has gone.
  var sent = 0
  while sent < data.len:
    let n = posix.write(cint(fd), unsafeAddr data[sent], data.len - sent)
    if n > 0:
      sent += n
    elif posix.errno == posix.EAGAIN or posix.errno == posix.EWOULDBLOCK:
      tuckAwaitWrite(fd)
    else:
      break
  (sent: sent)

proc fdClose*(fd: int) =
  discard posix.close(cint(fd))

proc statusCode(st: cint): int =
  if (st and 0x7f) == 0: int((st shr 8) and 0xff)
  else: 128 + int(st and 0x7f)

proc waitProcess*(pid: int): tuple[code: int] =
  ## Waits for the child and answers its exit code (128 + N when signal N
  ## ended it). BLOCKS the caller: read the child's output first.
  var st: cint
  while true:
    let r = posix.waitpid(posix.Pid(pid), st, 0)
    if r >= 0: return (code: statusCode(st))
    if posix.errno != posix.EINTR: return (code: 127)

proc pollProcess*(pid: int): TuckResult[tuple[code: int]] =
  ## How the child ended, or none while it still runs.
  var st: cint
  let r = posix.waitpid(posix.Pid(pid), st, posix.WNOHANG)
  if r == 0: return tnone[tuple[code: int]]()
  if r < 0: return tok((code: 127))
  tok((code: statusCode(st)))

proc killProcess*(pid: int, sig: int): tuple[code: int] =
  (code: int(posix.kill(posix.Pid(pid), cint(sig))))

proc setEnv*(name: string, value: string): tuple[code: int] =
  ## Sets (or replaces) an environment variable of this process.
  try:
    os.putEnv(name, value)
    (code: 0)
  except OSError:
    (code: -1)

proc unsetEnv*(name: string): tuple[code: int] =
  try:
    os.delEnv(name)
    (code: 0)
  except OSError:
    (code: -1)

proc currentDir*(): tuple[path: string] =
  (path: os.getCurrentDir())

proc changeDir*(path: string): tuple[code: int] =
  try:
    os.setCurrentDir(path)
    (code: 0)
  except OSError:
    (code: -1)

proc cpuCount*(): tuple[cores: int] =
  (cores: max(1, osproc.countProcessors()))

proc hostName*(): tuple[name: string] =
  (name: (try: getHostname() except OSError: ""))

proc osName*(): tuple[name: string] =
  (name: hostOS)

proc exePath*(): tuple[path: string] =
  (path: (try: os.getAppFilename() except OSError: ""))

proc argCount*(): tuple[total: int] =
  ## How many command-line arguments were passed, not counting the program.
  ## `total`, not `count`: std/seq's fn `count` would make a `count` field
  ## unreadable in any module importing both (A83).
  (total: paramCount())
proc argAt*(index: int): tuple[arg: string] =
  ## Command-line argument `index` (1-based; 0 is the program); "" outside
  ## 0 .. argCount, as on Odin and D (A85) — paramStr raises instead.
  if index < 0 or index > paramCount(): return (arg: "")
  (arg: paramStr(index))

# --- signals as values (std/sys) ----------------------------------------------
# One signalfd for the process: every watched signal is blocked for normal
# delivery and read from it instead, so receiving one is reading a descriptor,
# which the reactor can await like a socket.
type SignalfdInfo {.importc: "struct signalfd_siginfo",
                   header: "<sys/signalfd.h>".} = object
  ssi_signo: uint32
var SFD_NONBLOCK {.importc, header: "<sys/signalfd.h>".}: cint
var SFD_CLOEXEC {.importc, header: "<sys/signalfd.h>".}: cint
proc c_signalfd(fd: cint, mask: ptr posix.Sigset, flags: cint): cint {.
  importc: "signalfd", header: "<sys/signalfd.h>".}
proc c_pthread_sigmask(how: cint, s, old: ptr posix.Sigset): cint {.
  importc: "pthread_sigmask", header: "<signal.h>".}
proc c_raise(sig: cint): cint {.importc: "raise", header: "<signal.h>".}

var gSigMask: posix.Sigset
var gSigFd: cint = -1

proc watchSignal*(number: int) =
  ## Block `number` for the calling thread and route it to the signalfd.
  if gSigFd < 0: discard posix.sigemptyset(gSigMask)
  discard posix.sigaddset(gSigMask, cint(number))
  discard c_pthread_sigmask(posix.SIG_BLOCK, addr gSigMask, nil)
  gSigFd = c_signalfd(gSigFd, addr gSigMask, SFD_NONBLOCK or SFD_CLOEXEC)

proc nextSignal*(timeoutMs: int): TuckResult[tuple[number: int]] =
  ## The next watched signal, or none after `timeoutMs`. In a task the wait
  ## suspends only that task; from main, the scheduler runs while it waits.
  if gSigFd < 0: return tnone[tuple[number: int]]()
  var info: SignalfdInfo
  while true:
    let n = posix.read(gSigFd, addr info, sizeof(info))
    if n == sizeof(info): return tok((number: int(info.ssi_signo)))
    if n >= 0 or (posix.errno != posix.EAGAIN and posix.errno != posix.EWOULDBLOCK):
      return tnone[tuple[number: int]]()
    if not tuckAwaitReadOrTimeout(int(gSigFd), timeoutMs):
      return tnone[tuple[number: int]]()

proc raiseSignal*(number: int) =
  ## raise(3): to the calling thread, which is the one that blocked it.
  discard c_raise(cint(number))

proc getEnv*(name: string): TuckResult[tuple[value: string]] =
  ## The environment variable `name`, or none when it is unset.
  if os.existsEnv(name):
    tok((value: os.getEnv(name)))
  else:
    tnone[tuple[value: string]]()

proc exit*(code: int) =
  ## Ends the process with `code` at once.
  quit(code)

proc monoNs*(): tuple[ns: uint64] =
  ## Monotonic nanoseconds: never steps back, unlike the wall clock.
  (ns: uint64(getMonoTime().ticks))

proc nowMs*(): tuple[epochMs: uint64] =
  ## Wall-clock time in milliseconds since the Unix epoch.
  (epochMs: uint64(epochTime() * 1000))
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
  tuckSleep(int(ms))   # from main, the scheduler runs for the duration

# Memory-mapped registers (spec 8): every access is a volatile load or store, so
# the optimiser cannot cache a read across statements or drop a write.
proc tuckVolatileLoad*(p: ptr uint32): uint32 {.inline.} =
  {.emit: "`result` = *(volatile NU32*)`p`;".}

proc tuckVolatileStore*(p: ptr uint32, v: uint32) {.inline.} =
  {.emit: "*(volatile NU32*)`p` = `v`;".}

# std/random — the generator itself is Tuck (std/random.tuck); only the OS
# entropy read is a shim.
proc osSeed*(): tuple[seed: uint64] =
  var seed: uint64
  let bytes = sysrand.urandom(sizeof(seed))
  copyMem(addr seed, unsafeAddr bytes[0], sizeof(seed))
  (seed: seed)

# std/math — elementary float functions, direct passthroughs to Nim's own.
proc sqrt*(value: float64): float64 =
  ## Square root.
  stdmath.sqrt(value)
proc pow*(base, exp: float64): float64 =
  ## `base` raised to `exp`.
  stdmath.pow(base, exp)
proc sin*(value: float64): float64 =
  ## Sine of an angle in radians.
  stdmath.sin(value)
proc cos*(value: float64): float64 =
  ## Cosine of an angle in radians.
  stdmath.cos(value)
proc ln*(value: float64): float64 =
  ## Natural logarithm; the caller has already ruled out zero and negatives.
  stdmath.ln(value)

# std/hash — FNV-1a, 64-bit. Same algorithm as errCode above (32-bit,
# compile-time only); this is the runtime, arbitrary-length variant.
proc hash*(data: string): uint64 =
  ## 64-bit FNV-1a of the string's bytes.
  result = 14695981039346656037'u64
  for c in data:
    result = (result xor uint64(ord(c))) * 1099511628211'u64

proc tuckMix(x: uint64): uint64 =
  ## splitmix64's finalizer: spreads an integer's bits so the low ones, which a
  ## table indexes by, depend on all of them. The same on every backend.
  var z = x + 0x9e3779b97f4a7c15'u64
  z = (z xor (z shr 30)) * 0xbf58476d1ce4e5b9'u64
  z = (z xor (z shr 27)) * 0x94d049bb133111eb'u64
  z xor (z shr 31)

proc hashKey*[T](key: T): uint64 =
  ## The hash of any key a table can hold: a string by its bytes (FNV-1a, as
  ## `hash`), an integer, bool or enum by value, anything else by its text.
  when T is string: hash(key)
  elif T is SomeUnsignedInt: tuckMix(uint64(key))
  elif T is SomeSignedInt: tuckMix(cast[uint64](int64(key)))
  elif T is bool or T is enum: tuckMix(uint64(ord(key)))
  else: hash($key)

# The single runtime facade: tuck_rt re-exports the async runtime so every
# emitted program imports ONLY tuck_rt and reaches rt AND async names
# (readFile, waitUntil, openSource, ...) uniformly. arsenal is bundled as the
# base runtime. A name defined in both modules is a Nim redefinition error at
# stdlib-compile time — the intended hard error, the stdlib author's to fix.
# (The import itself is up with the externs, which call into it.)
proc tuckPingUs*(handle: pointer, withinMs: int): TuckResult[int] =
  ## `Actor.pingUs {withinMs: n}` — the actor's answer delay in microseconds,
  ## or absent when it did not answer in time. The probe is tuck_async's; the
  ## result type is here because that module cannot see TuckResult.
  let ns = tuckPingNs(handle, withinMs)
  if ns < 0: tnone[int]() else: tok(int(ns div 1000))

export tuck_async
