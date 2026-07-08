# Tuck: a small language where everything is a named struct

*A tour of Tuck as it exists today — every example below goes through the real
compiler (`tuck ch` / `tuck c`) and most compile to runnable Nim.*

C is fifty years old. C++ hides costs. Rust's ownership model fights embedded
patterns. Tuck aims at that gap: a language for constrained systems that is
**obvious, auditable, and refactorable without fear** — and it gets there with
one radical constraint:

> Every piece of data flows through the system as a named struct.

## Data flows postfix

There is one call syntax. The payload flows left to right into each function:

```tuck
let request = {url: "example.com", timeout: 5.ms}
let response = request fetch parse episodes
```

No `f(x)`. No arity puzzles — every function takes exactly **one** struct, so
"multiple arguments" are just fields, assembled with punning:

```tuck
{player, level: 5} setVolume     # one payload, two fields
```

This is what kills stack shuffling: Forth shuffles because its stack is
positional; Tuck's "stack frame" is a named struct. Names are the anti-shuffle.

If a flowing struct has *more* fields than a function needs, the extras are
ignored (subset matching) — refactoring a producer never breaks consumers:

```tuck
# data is {id, name, email}; sendEmail wants {email, name} — fine.
data sendEmail
```

## Functions are pipelines

Return types are mandatory (they seed the two-pass type checker; mutual
recursion needs no forward declarations). The value flowing at the end of the
body **is** the result — `return` exists only for early exit:

```tuck
fn double({n: int}) -> {v: int}:
  {v: n + n}
```

The checker guards the flow: if branches and match arms in value position must
agree on one type, and the tail must match the signature:

```
Type Error: 'f' flows {v: str} out of its body but declares {v: int}
```

Mutation is deliberately different-looking. `..` works only on `var` bindings
and reads as a builder chain:

```tuck
var server = ServerConfig {}
server ..port {8080} ..timeout {30.seconds} ..start
```

## Errors are values, and the pure core cannot fail

`!T` means "may fail", `?T` means "may be absent" — one character each, no
exceptions, no nil, no unwinding. Both lower to a single tri-state value type
(`ok / err / absent`). Error names are ordinary enums declared in your domain
modules; at runtime they are 16-bit codes — zero allocation, embedded-friendly.

```tuck
fn readSensor({port: u8}) -> !{value: u16} [io]:
  if port > 3:
    return Error.badPort
  {value: 42}
```

Three rules with teeth:

1. **Fallible functions must be `[io]`.** Errors exist only at I/O and
   unknown-input boundaries. The pure core of a Tuck program is *total* — its
   correctness comes from decision tables, invariants, and exhaustive
   matching, not error returns.
2. **`?` propagates, visibly.** `let r = {n} mightFail?` marks every hop an
   error takes — greppable, type-checked (`?` only inside a `!` function, and
   absence cannot masquerade as failure: a `?T` cannot propagate through a
   `!T` signature).
3. **You cannot silently drop a result.** A discarded `!T` is a compile error…

…unless you *declare* the shortcut. Everyone log-and-continues during rapid
development; Tuck formalizes it in one visible place, like the event registry:

```tuck
errors [policy: continue]:        # strict | continue | exit
  on unhandled({code: u16, site: str}):
    ...
```

- `strict` (the default): every unhandled site is a compile error — **all of
  them listed at once**.
- `continue`: the global handler runs, execution continues. Statement
  position only; no value is ever fabricated.
- `exit`: handler fires at the first unhandled site, then the program exits —
  the hook for diagnostics and trace dumps.

`continue`/`exit` builds print a `SHORTCUTS (n)` report on every compile, so
the shortcuts stay findable and retire one by one. Shipping firmware builds
`strict`.

## The walking skeleton: `pending`

Top-down design needs typed holes. Declare what you haven't written; the
compiler nags and stubs:

```tuck
pending:
  fn fetchFeed({url: str}) -> !{feed: Feed} [io]
```

Every build prints the TODO list (`PENDING (6 unimplemented): …`). Calls to
pending functions are **strictly type-checked** against their signatures, and
the generated stubs log and return zero values — the skeleton *runs*. When you
implement one and forget to remove it from the block, that's a compile error.
TODO is part of the language.

## State machines the compiler understands

Sum types model lifecycles; transitions declare the legal graph:

```tuck
type MqttSession [sealed]:
  | Disconnected
  | Connecting({host: str, port: u16})
  | Connected({socket: Socket, keepalive: u16})
  transitions:
    Disconnected -> Connecting
    Connecting   -> Connected
    Connecting   -> Disconnected
    Connected    -> Disconnected
```

The compiler verifies transition endpoints exist (typos die at compile time)
and that every variant of a sealed type is reachable from the initial one.
`[sealed]` means only the first variant constructs directly:

```tuck
let s = {} MqttSession.Disconnected                        # fine
let s = {keepalive: 60} MqttSession.Connected              # compile error
let s = {keepalive: 60} MqttSession.Connected [unsafe]     # deserialization hatch
```

Codegen emits a real tagged union plus a pure transition matrix — invalid
transitions raise with `"Invalid transition Ready -> Loading"` at runtime.

## Decision tables: dispatch you can prove

Multi-condition logic as a table the compiler verifies:

```tuck
type Priority:
  | High
  | Low

decision route({priority: Priority, encrypted: bool}) -> int:
  | High  true  -> 1
  | High  false -> 2
  | Low   _     -> 3
```

When every column is enumerable (bools, enums) the analysis is **exact**: a
gap is reported with the literal missing combination —
`no row matches (priority: High, encrypted: false)` — unreachable rows are
proven, and no catch-all is required. The generated code is one `case` over a
packed integer key: zero comparison chains at runtime.

## Effects the checker enforces

```tuck
fn queuePush({msg: Msg}) -> !void [no_alloc, irq_safe]:
  ...
```

Markers propagate: a pure function calling an `[io]` function is a compile
error unless it declares `[io]` itself. `[irq_safe]` code cannot reach
blocking I/O by construction.

## Memory without a heap

Tier 1 code is stack-only. When a library needs more, the runtime provides
fixed pools and bump arenas — O(1), zero fragmentation, sizes checked at
compile time:

```tuck
arena ScratchSpace [size: 2048]:
  let buf = ScratchSpace.alloc Array[128, u8]
  ScratchSpace.reset          # entire arena freed in one assignment
```

Unit types are distinct types plus ordinary functions — no compiler magic:

```tuck
distinct Milliseconds = u32

fn ms(value: u32) -> Milliseconds:
  value Milliseconds        # calling the type's name converts from its base

delay {ms: 5.ms}            # fine — 5.ms is postfix application of fn ms
delay {ms: 5}               # compile error — bare int is not Milliseconds
delay {ms: 5.us}            # compile error — Microseconds is not Milliseconds
```

Same bits at runtime (Nim's native `distinct`), strictly incompatible at
compile time — no widening, no resolving through to the base.

Hardware access is typed MMIO — writing a read-only register field is a
compile error:

```tuck
register RCC_CR at 0x40021000:
  HSION:  bit 0 [read, write]
  HSIRDY: bit 1 [read]
```

## One event surface, one error surface

The entire signal surface of an application is two declarations: the
`registry` (events, one handler per variant, verified) and the `errors`
policy. Reading those two blocks tells you everything that can happen out of
band. No dynamic subscriptions, no invisible control flow.

## The toolchain is the feedback loop

```
$ tuck ch app.tuck
PENDING (2 unimplemented):
  fetchFeed({url: str}) -> !{feed: Feed} [io]   line 15
SHORTCUTS (1 routed to the global error handler):
  !{value: u16} at poll line 18
OK (1.8 ms)
```

`lex`, `parse`, `check`, `compile` (shorthands `l p ch c`). Fail fast: the
first error prints as `file:line:col` with a caret into your source — always a
**Tuck** error; you never read a Nim diagnostic. Today's (small) example files
check in 1–2ms against a 100ms budget; real numbers wait for real programs.
Tuck transpiles to readable Nim (Beef backend in progress), so the escape
hatch is a language you can read, not a binary blob.

## Status

Working today: the postfix core, bidirectional type checker (subset matching,
branch agreement, implicit returns), errors-as-values with the three-mode
policy, pending blocks, distinct unit types, sealed transitions with
tagged-union codegen, exact decision-table analysis with packed-key codegen,
effect checking, the event registry, typed MMIO, pools/arenas, and the CLI.
Actors have their runtime library (typed mailboxes, message envelopes) and
the syntax already transforms to Nim targeting it; the scheduler backing is
the next layer. Designed but not yet built: `bake` compile-time
specialization, generics, the module system, and the incremental cache.
