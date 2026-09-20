# Applications

Not benchmarks. A benchmark is built to be measured; these are built to be
*written*, because the question they answer is whether an ordinary program
can be expressed in Tuck at all. Throughput is the secondary result.

The distinction earned its keep immediately: the Savina ports in
`../savina/` produced timing tables and **zero** compiler bugs. The first
application produced five, four of which no test in the suite covers.

## What is here

| app | domain | why an actor is the right shape |
|---|---|---|
| `matching_engine.tuck` | trading | a venue's engine is single-threaded *by necessity* — orders must be applied in one determined sequence or the book is not a book |

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

## What it cost to write

Five bugs, in one file, none of them exotic. Each is written up in
`../../KNOWN-BUGS-EVENTS.md` with a minimal repro.

| | what | who breaks |
|---|---|---|
| EV-8 | `actor Book` + `fn book` are one identifier after mangling | nim |
| EV-9 | an actor field assigned from a call that takes it loses its `self.` | d, odin |
| EV-10 | two handlers binding the same local name: the second is undeclared | all |
| EV-11 | a feed that outruns its actor drops messages, then deadlocks | all |
| EV-12 | Odin never frees a heap value: 75 KB leaked per order | odin |

Two are worth reading even if the others are not.

**EV-11** is the one a user would hit first. A full mailbox drops silently
(spec §9.1, and the ruling is that backpressure is the sender's job) — but
`hasRoom`, the primitive that would do that job, appears in the compiler
only in the backends' reserved-identifier lists. No Tuck syntax calls it.
The sender is assigned a job the language gives it no verb for, so the queue
here is sized past the whole burst, which is not backpressure but hoping.

**EV-12** is the one that would survive review. It compiles, runs, and
prints the right answer at every size small enough to finish; at 200 000
orders the OOM killer takes it at 13.6 GB while Nim and D run the same
program in 17-21 MB. It is also where two merely-bad bugs compose into a
fatal one: EV-9's mandatory workaround defeats the move optimisation that
was keeping the allocation at zero.

## Not written yet

Ordered by what they would newly exercise:

- **IRC / chat server** — fan-out to many recipients, which nothing here or
  in `../savina/` measures at all, plus `[io]` tasks per connection. The
  natural next one.
- **Multiplayer game tick loop** — a fixed-rate actor with a deadline,
  which would exercise timers rather than throughput.
- **Telephony call routing** — supervision and failure, the Erlang case
  Tuck is furthest from: no actor references means no supervisor.
