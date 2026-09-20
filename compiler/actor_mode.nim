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
## WHAT BATCH GIVES UP, stated plainly: a send is no longer visible to the
## receiver when it is made, but when its batch flushes. Anything that reads
## an actor's state shortly after sending to it — a `waitUntil` predicate, a
## request/response ping-pong — sees up to `batch-timeout` of extra latency.
## Per-actor order is still preserved (a batch keeps its messages in order);
## what is lost is order BETWEEN actors and promptness.
##
## Contract for the batch implementation, written here because these are the
## edges that make it wrong rather than slow:
##   1. Staged sends MUST flush before anything waits — `tuckWaitOn` and
##      `tuckDrainActors` both block, and a message stuck in an unflushed
##      batch is a deadlock, not a delay.
##   2. Staging is per SENDING thread, so it needs no lock of its own; the
##      lock is paid once per flush.
##   3. A flush must be ordered against the wake, exactly as a single send is
##      now: stage, flush, then notify.
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

  ImplementedModes* = {amThread}
    ## Modes the runtime actually has. The CLI refuses the others rather than
    ## accepting a flag and quietly building something else. Grows by one
    ## token as each lands.

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
