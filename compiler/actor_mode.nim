## HOW an actor gets its CPU — one choice per build, made on the CLI.
##
## The SEMANTICS are identical in all three modes: an actor is a singleton
## with a mailbox, it handles one message at a time, and nothing else touches
## its state. What changes is the machinery carrying a message from sender to
## mailbox, and that is a trade the compiler cannot make on the programmer's
## behalf — it turns on the workload, which only they can see.
##
##   thread  one OS thread per actor. Real parallelism across cores; a `send`
##           crosses a thread boundary (an atomic, a lock, and a futex wake
##           when the target is parked). Right for actors doing sustained CPU
##           work, wrong for a swarm of light ones: hundreds of OS threads
##           cost more in scheduler and cache traffic than they return.
##   single  every actor a coroutine on main's thread. A send is a push with
##           no atomics and no cross-core handoff, `[io]` still yields, so an
##           I/O-bound or event-driven program keeps its throughput — on one
##           core, which is the whole of the trade.
##   batch   thread-per-actor, but sends are STAGED on the sending thread and
##           handed over in groups, once `batch-count` have piled up or
##           `batch-timeout` has passed. One crossing per batch instead of
##           per message.
##
## WHAT BATCH GIVES UP, stated plainly: PROMPTNESS, and only that. A send is
## visible to the receiver when its batch crosses, not when it is made, so
## anything reading an actor's state shortly after sending to it sees up to
## `batch-timeout` of extra latency. Order is NOT among the casualties —
## per-actor order is what Tuck promises and a batch keeps it, while actors
## are orthogonal, so there was never an order between them to lose.
##
## What batch mode rests on (tuck_rt for the staging, tuck_async for the
## flush points). These are the edges that make it WRONG rather than slow,
## and each one was earned:
##   1. Every point where a thread stops making progress flushes first —
##      before parking, at `waitUntil`, at exit. A message left in an
##      unflushed batch is a deadlock, not a delay.
##   2. A flush at one of those points must WAKE the receiver. The
##      `tuckNotifySend` codegen emits fired when the message was merely
##      staged, so a later handover has no notify behind it. Skipping this
##      made an actor forwarding to a second actor print nothing at all.
##   3. Staging is per SENDING thread, so it needs no lock of its own — but
##      the batches are BORROWED from one pool per actor. Not because the
##      threads are many: they are main plus one per actor, all known at
##      compile time. Because staging is a THREADVAR, so private batches
##      come out of every thread's TLS and their depth has to be capped by a
##      constant instead of by `[queue: N]`. Measured both ways: capped at
##      64 batches, a program with `[queue: 1048576]` silently dropped after
##      4096 messages and its `waitUntil` never came true.
##
## `--actors:thread` is the default because it is the only mode that is
## correct for every program: `single` cannot use a second core, and `batch`
## changes when a message arrives.

import std/strutils

type
  ActorMode* = enum
    ## Named on the CLI. Keep the strings stable once published — they go in
    ## build scripts.
    amThread = "thread"
    amSingle = "single"
    amBatch = "batch"

  ActorPolicy* = object
    mode*: ActorMode
    batchCount*: int      ## flush after this many staged sends (0 = never)
    batchTimeoutMs*: int  ## ...or this long after the first (0 = never)

const
  DefaultBatchCount* = 64
    ## Enough sends to amortise one lock and one futex wake over many
    ## messages; small enough that the memory a staged batch holds is noise.
  DefaultBatchTimeoutMs* = 1
    ## The latency bound a straggler pays. A batch that fills faster than this
    ## never waits for it; one that does not is bounded by it.

  ImplementedModes* = {amThread, amSingle, amBatch}
    ## Modes the runtime actually has. The CLI refuses the others rather than
    ## accepting a flag and quietly building something else. Grows by one
    ## token as each lands.

proc nimDefinesFor*(p: ActorPolicy): string =
  ## What `tuck build` adds to its `nim c` line for this policy. The mode has
  ## to reach the RUNTIME, which is compiled as part of the program, and a
  ## define is how: it makes the choice a compile-time fact, so the machinery
  ## the mode does not use is not merely skipped but absent.
  case p.mode
  of amThread: ""                       # the default shape; nothing to say
  of amSingle: " -d:tuckActorsSingle "
  of amBatch:
    " -d:tuckActorsBatch -d:TuckBatchCount:" & $p.batchCount &
    " -d:TuckBatchTimeoutMs:" & $p.batchTimeoutMs & " "

var actorPolicy* = ActorPolicy(mode: amThread,
                               batchCount: DefaultBatchCount,
                               batchTimeoutMs: DefaultBatchTimeoutMs)
  ## The build's choice. Set once at startup from the CLI, read by codegen —
  ## the same shape as modules.buildTarget.

proc parseActorMode*(name: string): tuple[mode: ActorMode, ok: bool] =
  ## `--actors:X` → the mode. An unknown name is reported, never defaulted: a
  ## typo in a build script must not quietly mean "thread".
  for m in ActorMode:
    if $m == name: return (m, true)
  (amThread, false)

proc actorModeNames*(): string =
  ## Every mode, for an error message that says what WOULD have worked.
  var names: seq[string]
  for m in ActorMode: names.add($m)
  names.join(", ")
