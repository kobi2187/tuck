# Applications

Not benchmarks. A benchmark is built to be measured; these are built to be
*written*, because the question they answer is whether an ordinary program
can be expressed in Tuck at all. Throughput is the secondary result.

The distinction earned its keep immediately: the Savina ports in
`../savina/` produced timing tables and **zero** compiler bugs. The first
application produced five and the second three, and in both cases most were
things no test in the suite covered.

## What is here

| app | domain | why an actor is the right shape |
|---|---|---|
| `matching_engine.tuck` | trading | a venue's engine is single-threaded *by necessity* — orders must be applied in one determined sequence or the book is not a book |
| `world_server.tuck` | a shared voxel world | the world is sliced into zones, each owned outright by one server — which is what makes concurrent edits safe at all, not an optimisation on top of something safe |

`matching_engine` is ONE actor. `world_server` is six in a pipeline —
gateway, four shards, journal — and that is the difference between them:
routing, fan-out, fan-in, a drain barrier, and messages produced BY an actor
rather than by the feed. Everything below that concerns ordering or
initialisation was invisible to the single-actor program.

The actor is the **processing** half only. Nothing in these programs moves
data: the order flow is a plain loop, and a real deployment feeds it from
`[io]` tasks over a socket the way `examples/42-net-echo.tuck` does. That is
the shape Tuck actors are for — a singleton service in a narrow role, not
Erlang's millions of cheap processes.

## What the matching engine measured

200 000 orders against a 1024-level price ladder, `--release`, Nim backend.
All three modes print the same book (`trades=111063 volume=272223
resting=327777`), which is the result that mattered most — a mode flag that
changed the answer would make the mode flag useless.

| mode | median |
|---|---|
| `--actors:batch` | 133 ms |
| `--actors:single` | 135 ms |
| `--actors:thread` | 140 ms |

**The modes converge when the handler does real work**, and that is the
headline. On `../savina/threadring.tuck` the same three modes span **80x**
(10 ms vs 796 ms), because every message there is a bare handoff and the
handoff is the entire cost. Here each message walks a price ladder, so the
handoff is noise and the mode barely registers — 5% across all three.

So `--actors:` is not a throughput knob to be tuned per program. It matters
enormously for handoff-dominated workloads and almost not at all for
compute-dominated ones, and which kind a program is can be read off its
handlers before measuring anything.

`--actors:` is currently **Nim-only** — `actor_mode.nim` emits `-d:` defines
and nothing else, so `--odin` and `--dlang` always build thread mode.

### The backends do not agree, and the gap is 55x

Same program, same 200 000 orders, same printed book, thread mode:

| backend | median | peak RSS |
|---|---|---|
| nim | 143 ms | 21 MB |
| d | 7 991 ms | 22 MB |
| odin | 6 747-17 503 ms | 5 580 MB |

This is the largest number the applications have produced and it has nothing
to do with actors. It is **value semantics meeting three different memory
models**. `takeLevel` binds a ladder to a local, which Tuck says is a copy;
Nim's backend gets that for free from `sink` plus ARC and emits a move, while
D emits a real `.dup` and Odin a real `tuckSeqCopy` — roughly 700 000 copies
of an 8 KB ladder over the run. D pays for it in GC churn, Odin in an
element-by-element copy loop *and* in never freeing the result (EV-12).

Worth stating plainly because the project rule is that runtime
characteristics do not depend on the backend. Here they depend on almost
nothing else.

**Stage 1 of the ownership work closed part of that gap.** `analysis_provenance`
asks whether a callee built the value it returns or merely handed back one of
its arguments, so a binding whose value is provably fresh keeps no defensive
copy. Measured A/B on Odin, interleaved, same machine state:

| | emitted copies | time | peak RSS |
|---|---|---|---|
| before | 15 | 13 957-29 891 ms | 5 589 MB |
| after | 10 | 3 102-3 686 ms | 4 003 MB |

The remaining 4 GB is #77 — Odin still frees nothing — and the remaining
copies are ones the analysis is right to keep: `rest` has an early return
that hands its parameter straight back.

## What it cost to write

Five bugs, in one file, none of them exotic. Each is written up in
`../../KNOWN-BUGS-EVENTS.md` with a minimal repro.

| | what | who breaks | |
|---|---|---|---|
| EV-8 | `actor Book` + `fn book` are one identifier after mangling | nim | open |
| EV-9 | an actor field as assignment target loses its `self.` | nim, d, odin | **fixed** |
| EV-10 | two handlers binding the same local name: the second is undeclared | all | open |
| EV-11 | a feed that outruns its actor drops messages, then deadlocks | all | open |
| EV-12 | Odin never frees a heap value | odin | open |

Two are worth reading even if the others are not.

**EV-11** is the one a user would hit first. A full mailbox drops silently
(spec §9.1, and the ruling is that backpressure is the sender's job) — but
`hasRoom`, the primitive that would do that job, appears in the compiler
only in the backends' reserved-identifier lists. No Tuck syntax calls it.
The sender is assigned a job the language gives it no verb for, so the queue
here is sized past the whole burst, which is not backpressure but hoping.

**EV-12** is the one that would survive review. It compiles, runs, and
prints the right answer at every size small enough to finish; at 200 000
orders the OOM killer took it at 13.6 GB while Nim and D ran the same
program in 17-21 MB. It is also where two merely-bad bugs composed into a
fatal one: EV-9's mandatory workaround defeated the move optimisation that
was keeping the allocation at zero. **Fixing EV-9 turned the OOM into a
completing run** — 5.58 GB instead of 13.6 GB — which is worth recording as
the shape these bugs take: neither was fatal alone.

EV-9 is fixed, with a regression guard in `tests/suites/known_bugs.nim` that
runs on all three backends. The other four are open.

## What the world server measured

100 000 edits into a 1024-column world, four shards, `--release`. The
per-message work is a lighting update — a bounded relaxation over the
31 columns an edit can reach, which is where the cost genuinely is in a
voxel engine, breaking a torch being the expensive direction.

All three modes and all three backends print the same five numbers
(`routed=100000 logged=100000 relit=847086 denied=11120 world=355520`).
That is the result that mattered most and it is a stronger claim than the
matching engine's: the four shards interleave differently in every mode, so
the checksum is a SUM rather than a rolling hash, and it agreeing means the
same edits landed in the same places however they were scheduled.

| mode | median |
|---|---|
| `--actors:batch` | 191 ms |
| `--actors:thread` | 201 ms |
| `--actors:single` | 364 ms |

`single` is now 1.8x off the pace where the matching engine had all three
modes within 5%. That is not a reversal of the matching engine's finding —
it is the other half of it. Six actors in a pipeline can use six cores;
`single` has one. The matching engine could not show this because one actor
has no parallelism to lose. So the rule is a little sharper than "modes
converge when the handler does real work": they converge when the work is
real AND the topology is serial.

### The backends still do not agree, and the shape of the gap has changed

Same program, same 100 000 edits, same printed world, thread mode:

| backend | before EV-15 | after EV-15 |
|---|---|---|
| nim | 191 ms / 80 MB | 201 ms / 80 MB |
| odin | 2 876 ms / **4 948 MB** | **311 ms / 543 MB** |
| d | **54 196 ms** / 16 MB | **14 714 ms** / 16 MB |

The move information always EXISTED — every fn in the lighting path gets
`sink` on the Nim side, so liveness had already proved the argument dead at
the call, which is why the Nim column barely moves. Odin and D reached their
MOVED twin only through `movedCallInto`, which wants `x = f(x, ...)`. The
innermost loop has that shape and compiled to no copy at all. One level up,
`let r = {f: a, ...} pass` did not, so `a` was copied although it was dead
and then abandoned: twelve arrays allocated per lighting update, one
returned, nothing freed.

EV-15 closed that — an argument that is a last use AND one the body owns now
reaches the twin, at every syntactic position rather than the two the
assignment emitters happened to cover. What remains is EV-14: three arrays
per edit that nothing frees, 546 MB of the original 4.9 GB.

## What the world server cost to write

| | what | who breaks | |
|---|---|---|---|
| EV-14 | dead intermediates of a threading chain are never freed | odin | [#82](https://github.com/kobi2187/tuck/issues/82) |
| EV-15 | a dead container handed to a threading fn still copies | odin, d | **fixed** |
| EV-16 | a `match` arm whose body is a `send` emits Nim that will not compile | nim | **fixed** |
| EV-17 | `--batch-timeout` is not kept for a batch nobody sends to any more | all | **fixed** |
| EV-18 | no ordering between two senders to one mailbox; thread mode hides it | all | open |
| EV-19 | an actor field with no initialiser is silently a zero value | all | open |

**EV-16 is the one that says something about the corpus.** A router over N
shards has nothing to index — an actor is a compile-time singleton with no
reference type — so `match` with one arm per actor is the only spelling
available. It emitted Nim that would not compile, and had done all along:
every `match` arm anywhere in the tree was a block or a one-line `return`,
and a bare `send` is neither. A whole construct pairing was simply absent
from the corpus until a program needed it.

**The ordering bug is the one worth reading**, and chasing it to the bottom
turned one symptom into three separate findings.

`main` used to send `start` to the four shards itself, then pump 100 000
edits at the gateway. In `thread` mode that works. In `batch` mode a send is
staged on the SENDING THREAD, so main's four-message batch sat unflushed
while the gateway's fat edit batches crossed first — and a shard indexed a
`Slice` whose seqs were still empty. `index 0 out of bounds for seq of
length 0`, at n=1000 and not at n=100.

**EV-18, the actual cause.** Tuck promises per-MAILBOX order and batch mode
keeps it. What it does not promise, and what thread mode hands you by
accident, is any order between two DIFFERENT senders to one mailbox. The
program's fix is architectural rather than a workaround — the gateway brings
its own shards up, so `start` and `edit` leave the same thread in that order
— and it is also how real deployments work. Whether the language should
guarantee an initialisation barrier is a design decision, not a patch.

**EV-17, found on the way and fixed.** `--batch-timeout` promises a staged
batch crosses within N ms. The deadline was tested inside `enqueue` against
the mailbox being sent to, so a thread that staged for one actor and then
only ever sent to another never tested the first one's deadline again: the
promise was kept for every mailbox except the one that needed it. Measured
at 300 000 sends against a 1 ms deadline with the batch never crossing. The
sweep is now thread-wide.

It is worth being clear that **EV-17 does not fix EV-18** — checked, not
assumed. With the sweep in place the old shape still dies, because 1 ms is
thousands of messages: the window narrows from "until the sender parks" to
"up to a millisecond", and the ordering violation lives comfortably inside
it.

**EV-19, the reason it lands as a crash.** An actor field with no
initialiser is silently a zero value. Tuck already rejects reading a field a
CONSTRUCTION did not supply — `<uninit>`, spec §4.8 — and even offers the
fix in the message. Actor fields get none of that, so "never initialised" is
indistinguishable from "initialised empty" and the failure surfaces far from
its cause, inside generated code.

## Not written yet

Ordered by what they would newly exercise:

- **IRC / chat server** — fan-out to many recipients. `world_server.tuck`
  fans out one message to ONE of four shards; a channel broadcast fans one
  message out to all of N, which nothing here measures. Plus `[io]` tasks
  per connection. Still the natural next one.
- **Multiplayer game tick loop** — a fixed-rate actor with a deadline.
  `world_server.tuck` covers the shared-world topology but not TIME: it runs
  as fast as it can, and a game server's real constraint is finishing a tick
  before the next one is due.
- **Telephony call routing** — supervision and failure, the Erlang case
  Tuck is furthest from: no actor references means no supervisor.
