# A Tour of Tuck

*Written 2026-07-13 against the working compiler. Every snippet shown as
"runs" was built and executed; every "checks" passed `tuck check`. Gaps hit
while writing are marked ⚠ and detailed in [TOUR-GAPS.md](TOUR-GAPS.md).*

Tuck is a small systems language where **every piece of data flows as a
named struct**, the program is a set of declarations plus one `fn main`,
and correctness is declared — invariants, decision tables, transition
graphs — rather than hand-coded.

## 1. A program is declarations + main

```tuck
import io

fn main() -> void [io]:
  {text: "hello, tuck"} io::printLine
```

*(runs)* — There are no top-level statements, not even `let`. A module
declares things; `main` runs. `tuck build file.tuck` makes a binary; a
file without `main` builds as a library. `[io]` marks the effect: pure
fns can't call io fns.

⚠ Printing a *number* is not expressible yet — `io::printLine` wants
`str` and there is no int→str or interpolation (gap 1).

## 2. Structs flow; fns pick what they need

```tuck
type Episode:
  title: str
  minutes: int

fn shortEnough({minutes: int}) -> bool:
  return minutes < 30

fn main() -> void:
  let e = {title: "Deep Dive", minutes: 25} Episode
  let ok = e shortEnough
  return
```

*(runs)* — `{fields} TypeName` constructs. `e shortEnough` passes `e`
whole; because `shortEnough`'s params don't fit `e` as one value, `e`'s
**fields** fill them by name (subset matching — extra fields are fine).
That's the one call rule: offer the value to the first parameter whole,
else match fields by name. Whitespace, `.name`, and `.name {args}` are the
same call written three ways.

## 3. Constants are compile-time data

```tuck
const maxShort = 30
const defaults = {minutes: maxShort, title: "untitled"}
```

*(runs)* — `const` is a declaration: literals, structs and lists of them,
arithmetic over them. Nothing runs at startup. Runtime state has three
homes: pass it down from main, let an actor own it, or the resource
registry (§7.4).

⚠ `const timeout = 5.ms` is rejected — unit sugar is a fn call, and const
initializers can't call (gap 6).

## 4. Mutation is explicit: `..` on a var

```tuck
type ServerConfig:
  port: int
  timeout: u32

fn withDefaults({self: ServerConfig}) -> ServerConfig:
  return {port: 80, timeout: 30} ServerConfig

fn main() -> void:
  var server = {port: 0, timeout: 0} ServerConfig
  server ..withDefaults ..port {8080} ..timeout {60}
  return
```

*(runs)* — `..field {value}` sets a field (one bare value, type-checked).
`..fn` calls a *mutator* — first param takes the receiver, the result is
reassigned into the var. `..` on a `let` is a compile error. Fields never
shadow fn names (declaring both is an error), so `.name` is never
ambiguous.

## 5. Invariants: declare once, checked everywhere

```tuck
type Temperature:
  celsius: int
  invariant:
    celsius >= -273
```

*(runs)* — `validate()` is auto-inserted at every production site:
construction, returns, `..` mutation chains, and calls into `extern`
fns returning the type (values entering from outside get checked).
Stripped in release builds.

## 6. State machines: sum types + transitions

```tuck
type Player:
  | Stopped({config: Config})
  | Playing({config: Config, position: int})

  transitions:
    Stopped -> Playing
    Playing -> Stopped
```

*(checks; runtime matrix verified elsewhere)* — Constructing any variant
is fine on an unsealed type; `[sealed]` types allow only the first
variant directly (deserialization escapes with `[unsafe]`). The compiler
proves every variant reachable; `transitionTo` enforces the graph at
runtime.

⚠ Actually *making* a transition is a hoop today: `transitionTo` wants
the fully-constructed target (payload and all), so there's no light
`{p, target: Playing} transition` call (gap 4).

## 7. Branching: match (and decision tables when it's tabular)

```tuck
fn describe({p: Player}) -> int:
  match p:
    Stopped: 0
    Playing: 1
```

*(runs)* — match arms are `pattern: value`; arms must agree on type.

When the logic is a table, *write* a table — the compiler proves it
complete and reachable, exactly, and emits a single packed switch:

```tuck
type Priority:
  | high
  | low

decision route({priority: Priority, encrypted: bool}) -> int:
  | high  true  -> 1
  | high  false -> 2
  | low   _     -> 3
```

*(runs)* — note the two syntaxes: match uses `:`, decision rows use `->`
(⚠ inconsistency worth unifying — gap 7).

## 8. Errors are values

```tuck
import io

type ParseError:
  | Empty
  | TooLong

fn parseTitle({raw: str}) -> !str [io, error: ParseError]:
  if raw == "":
    err Empty
  return raw

fn main() -> void [io]:
  let r = {raw: "hello"} parseTitle
  if r.ok:
    {text: r.value} io::printLine
  return
```

*(runs)* — `!T` is a result; fallible fns must be `[io]` (the pure core
is total). `err Empty` raises against the declared enum. `.value` is
readable only under `if r.ok` — the checker enforces the narrowing.
A dropped `!T` is a compile error, or routes to the global handler under
`errors [policy: continue|exit]`.

⚠ Reacting to *which* error occurred (`match r.err: Empty: ...`) checks
but emits broken code — error codes aren't enum-typed yet (gap 5).

## 9. The walking skeleton: pending

```tuck
pending:
  fn fetch({url: str}) -> {status: int}

fn main() -> void:
  let r = {url: "https://x"} fetch
  return
```

*(runs)* — Declare the fns your program needs as typed holes. The
skeleton compiles AND runs from day one: stubs log and return zero
values, and every debug build prints the TODO list. Implementing a fn
while it's still in the pending block is an error.

## 10. Partial application: bake

```tuck
fn plus({a: int, b: int}) -> int:
  return a + b

fn applyOperation({a: int, b: int, op: fn}) -> int:
  op.invoke {a, b}

fn main() -> void:
  let x = {a: 5, b: 10}
  let withOp = x bake {op: :plus}   # fill the fn slot
  let smaller = withOp bake {b: 2}  # bake argument values too
  let r = smaller applyOperation    # plus(5, 2) = 7
  return
```

*(runs; exit-code verified)* — A struct is a fn's context; `bake` fills
slots — a fn reference (`:name`) or argument values. Slots lower to
generic params, so calls are direct: no boxing, no dispatch.

## 11. Reshaping data: alias, merge, input

```tuck
fn playTrack({id: int, name: str}) -> void:
  return

fn play({episode: Episode, prefs: PlayerPrefs}) -> str:
  let all = input                    # the whole incoming payload
  let ctx = {episode, prefs} merge   # ONE flat struct: union of fields
  ctx describe                       # subset matching picks what it needs

fn adapt({track: External}) -> void:
  let normalized = track alias(trackId: id, title: name)
  normalized playTrack
  return
```

*(all three verified)* — `alias` renames fields (external layout → local
shape), `merge` flattens structs into one (collisions are errors),
`input` is the fn's whole payload as one value. All compile-time
rewrites; zero cost.

## 12. Composition: managers, not hierarchies

```tuck
interface Storable:
  fn save({item: Self}) -> !void [io]

mixin bulkOperations:
  fn setMany(self, {pairs: Seq[Pair]}) -> !void [io]:
    ...

object PodcastApp:
  + AudioPlayer        # a record type: embeds as a field (carries data)
  + NetworkClient
  + bulkOperations     # a mixin: its fns materialize on this object

  fn play({episode: Episode}) -> void:
    self ..loadEpisode {episode} ..startAudio
```

*(runs)* — Pull capabilities in with `+`. Interfaces are contracts (emit
nothing); mixin fns with `self` appear on every composing object;
member fns see a mutable `self`.

## 13. Units that don't mix

```tuck
distinct Milliseconds = u32

fn ms(value: u32) -> Milliseconds:
  value Milliseconds

fn delay({ms: Milliseconds}) -> {done: bool}:
  {done: true}

fn main() -> void:
  let r = {ms: 5.ms} delay    # 5.ms is just postfix application of fn ms
  return
```

*(runs)* — no unit magic: `ms` is an ordinary fn; the distinct type
refuses bare ints and other units at compile time.

## 14. Towards the metal

```tuck
register RCC_CR at 0x40021000:
  HSION:  bit 0  [read, write]
  HSIRDY: bit 1  [read]

extern [c, header: "uart.h"]:
  fn uartSend({byte: u8}) -> void
```

*(checks)* — Registers declare MMIO layout with access enforcement;
`extern [c]` is the C seam. `tuck build --nim:"--os:standalone
--cpu:arm"` forwards cross-compilation flags; `--beef` builds the same
program through the Beef backend.

## 15. Actors (API today, runtime tomorrow)

```tuck
actor Counter:
  count: int

  on increment({by: int}) -> void:
    count = count + by
```

*(checks; envelopes + typed send helpers emit)* — the scheduler/runtime
strategy is still an open ruling, so an actor program doesn't *run* yet
(gap 9).

---

**The process this serves** (see VISION.md): imagine the finished app,
declare its fns as `pending` holes, watch the skeleton run, fill holes,
compose managers, declare invariants and tables instead of writing
checks, and let the compiler keep everything honest at every step.
