# Tuck — language overview

*Ground-truth snapshot, 2026-08-05.*

**Every claim here is backed by a test or a run-gated example, cited by
`file:line`.** Where a feature is declared but unverified, it says so. Where a
feature does not exist, it says that too — this document is written against a
work-in-progress compiler, and the most useful thing it can do is be honest
about the edges.

**How to check any claim:** `./run-all-tests.sh`, or `tests/run <suite>` for
one of them. The suite is the source of truth; this file explains it.
Assertion vocabulary (`tests/harness.nim`):

| Assertion | Means |
|---|---|
| `okCheck` / `badCheck` | `tuck ch` must pass / must fail with a matching message |
| `runs NAME, CODE` | build and execute; **exit code must equal CODE** — the real gate |
| `emits` / `emitsOdin` | grep the emitted Nim / Odin |
| `frozen NAME` | the emitted Nim must match `tests/golden/<suite>/` byte for byte |
| `bugOpen` | the assertion is *expected to fail*; if it starts passing the suite FAILS and demands you flip it |

---

## 0. Read this first: what will surprise you

Tuck features that behave differently from what a reader of C, Go, Rust, Nim
or Python would assume. Each one has bitten someone — including an AI agent
auditing this compiler, who read a payload binding as a checker bug and nearly
"fixed" a working feature. Skim this table before deciding anything is broken.

| # | It looks like… | It actually is | Where |
|---|---|---|---|
| 1 | `{wrong: 1} f` should fail — the name is wrong | **Legal.** A payload field claims a parameter BY TYPE when unambiguous, so a producer's output feeds a consumer with different names, no `alias()` needed. Wrong *types* still fail. | §2 |
| 2 | Extra payload fields are an error | **Ignored.** Subset matching: pass a big struct to a small signature. | §2 |
| 3 | `getFive` is a function reference | **A call.** A bare name invokes. `:getFive` is the reference. | §2 |
| 4 | Records are copied when passed | **Passed without copying** — but with value semantics enforced: a callee cannot write through a parameter (`TK-TY15`). Both backends emit a pointer; the guarantee is in the checker, not a copy. | §3, §7.1 |
| 5 | `..` is a range | **`..name` mutates** a `var`; a range is spaced (`0 .. n`). Whitespace distinguishes them. | §16 |
| 6 | `/` divides | **Not an operator.** `/i` is integer divide, `/f` float. Bare `/` is a parse error. | §7 |
| 7 | Interfaces are pointers/vtables | **A copying tagged variant.** An interface value OWNS its data; dispatch is a switch on a tag. | §5 |
| 8 | Actors are objects you construct | **Singletons.** One instance per declared type, no construction, no reference. | §10 |
| 9 | `[io]` propagates automatically | **You declare it at every level.** An undeclared effect is an error, not an inference. | §11 |
| 10 | An unhandled event is fine | **Compile error.** Every registry event needs a handler (`TK-RG03`), and one registry per program. | §10, Part 10 |
| 11 | `self ..field` is banned like any parameter | **Legal for object members and actor fields** — state the callee OWNS. A plain fn whose param is merely NAMED `self` gets no exemption. | §5.1, §7.1 |
| 12 | Concurrency targets microcontrollers | **Hosted OS today** — stackful minicoro coroutines over `mmap`, epoll/kqueue reactor. Tier 3, not Tier 1. | §10 |
| 13 | A list literal can wrap across lines | **It cannot.** `[a, b, c]` is one line; a line break inside the brackets is a parse error. A ruled ceiling, not a gap (`tests/suites/syntax_ceilings.nim`). | §0 |
| 14 | `t + if hot: 1 else: 2` works, since `if` is an expression | **A value-`if` is a whole right-hand side, never an operand.** `let add = if hot: 1 else: 2` then use `add`. Also a ruled ceiling. | §0, and `examples/39` for the forms that DO work |

**If something here looks like a bug:** read the cited section first, then
`grep` for a suite named after it (`tests/suites/auto_alias.nim` exists
entirely for #1). A dedicated suite is strong evidence the behaviour is
intended.

---

## 1. The shape of a program

A module is **declarations only**. Top-level statements are rejected —
`top-level statements` (`tests/suites/typecheck.nim`). A file with no `fn main` builds as
a library and produces no binary (`tests/suites/cli_smoke.nim`).

`const` is the exception, and it evaluates at compile time:

```tuck
const maxRetries = 3
const defaults = {port: 80, host: "local"}
const timeout = 5.ms
const sum = {a: 2, b: 3} plus        # pure computation, folded
```

A `const` initializer must be pure — an `[io]` call is rejected with `pure`
(`tests/suites/typecheck.nim`), and a record construction with `record` (`:976`).

---

## 2. Calls: one convention, several spellings

Tuck has one calling convention — **a payload struct flows into a function** —
with several equivalent surface forms. From `examples/41-tostr-concat.tuck:8`:

> `x doSth`, `x.doSth` and `{value: x} doSth` are the same call.

```tuck
{a: 5, b: 10} plus          # payload-prefix, the canonical form
n.toStr                     # postfix on a variable
n toStr                     # the same, no dot
bump {x: 41}                # prefix-name + braces
getFive                     # a bare name IS a call, for a nullary fn
:plus                       # a REFERENCE to plus, not a call
{8080} double               # bare braces = {value: 8080}
9 addOne                    # bare scalar receiver
```

All verified (`tests/suites/cli_smoke.nim` exits 12 through two nullary call forms;
`tests/suites/typecheck.nim`; `tests/suites/end_to_end.nim`).

Chaining is the idiom for data flow:

```tuck
let response = request fetch parse selectEpisodes   # examples/01:15
```

### How arguments actually bind

Three passes, in order (`tests/suites/typecheck.nim`, run-verified in
`tests/suites/auto_alias.nim`):

1. **Subset** — extra payload fields are ignored.
2. **By name** — `{id: 1, byteCount: 999}` into `{id: int, size: int}` binds
   `id` by name, giving `n1/999` not `n999/1` (`tests/suites/auto_alias.nim`).
3. **By type**, for whatever is left — `{trackId: 42, title: "Slow Jam",
   active: true}` binds cleanly into `{id: int, name: str, ok: bool}`.

Position is irrelevant; scrambled field order still binds (`tests/suites/auto_alias.nim`).
Ambiguity is an error, not a guess: two unmatched fields of the same type →
`missing required field` (`tests/suites/typecheck.nim`).

**Implementation note.** The checker records the mapping it decided, and
lowering *uses that record* rather than re-deriving it. `tests/suites/cli_smoke.nim`
asserts the emitted Nim is literally `tuck_pick(42, "x", true)` — proof the
by-type mapping survives to codegen.

### `input` — the whole payload

```tuck
fn header({episode: Episode, n: int}) -> str:
  return input.episode.title      # examples/17:17
```

### Returns

Explicit `return`, or an **implicit tail return** — the last expression is the
result (`tests/suites/typecheck.nim`). A trailing `match` is the result and gets wrapped
(`tests/suites/cli_smoke.nim`, exit 9).

### `.name` resolution

- A declared **field wins over a same-named fn** — and the clash is caught at
  *declaration* time: declaring `fn port()` beside `type Server: port: int` is
  an error, `rename` (`tests/suites/typecheck.nim`).
- `.name` with no such field becomes a **call** with the receiver as first
  param (`tests/suites/typecheck.nim`).
- `.fn {args}` — receiver first, braces fill the rest.
- A brace after `.name` is **always** a call; an undeclared callee is a clean
  error, not a silent field read (`tests/suites/known_bugs.nim`).

### `..` — the mutation operator

```tuck
server ..withDefaults ..port {8080} ..timeout {60}     # examples/02:22
```

Either sets a field or calls a mutator whose first param is the receiver; the
result is reassigned. On a `let` → `declared with 'let'` (`tests/suites/typecheck.nim`).

---

## 3. Types

### Records — `type`, value semantics

```tuck
type ServerConfig:
  port: int
  timeout: u32

type Feed = {episodes: int}       # inline
type Box[T] = {value: T}          # generic
```

Construction is postfix: `{port: 80} Server`.

**Records are values.** `tests/suites/cli_smoke.nim` (exit 17) verifies `==` compares
fields, a copy is independent of its source, and the emitted Nim says
`= object`, not `ref object`.

A record var passed as a whole payload **explodes into params** — emitted Nim
is `advance(p.position, p.step)` (`tests/suites/cli_smoke.nim`).

### Objects — `object`, with members and contracts

```tuck
object Dog:
  name: str
  satisfies Speaker
  fn speak({volume: int}) -> str:
    return self.name
```

Objects carry fields, `+ Composed` entries, `satisfies` lines, member fns, and
`self`. Two objects may share a member fn name — Nim overloads on `self`, Odin
cannot, so the emitter mangles to `tuck_Dog_noise` (`tests/suites/member_names.nim`,
gated by a real `odin build`).

### Mixins — `mixin`, fns only, never fields

```tuck
mixin Helpers:
  fn double({self: Self}) -> int:
    return self.x + self.x
```

Asserted to contribute **no field named after the mixin**
(`tests/suites/object_composition.nim`).

### Composition `+` is set union

For both records and objects: `object O: + A` emits `x*: int` directly, and
*omits* any nested `tuck_A*: tuck_A` field (`tests/suites/object_composition.nim`). Same
for `type M = A + B`.

### Sum types

```tuck
type PlayerState:
  | Unloaded({config: Config})
  | Loading({config: Config, progress: int})
  | Ready({config: Config, feed: Feed})

type Door: | Closed | Open | Locked     # payloadless
type Color = {Red, Green, Blue}         # inline
```

Construction:

```tuck
let p = {config, feed} PlayerState.Ready   # {config, feed} is field shorthand
let fresh = MqttSession.Disconnected       # bare
return Red                                 # bare, unqualified — carries its sum type
```

> ⚠️ **OPEN BUG — cross-sum-type assignment is unchecked.** Returning a `Light`
> variant where `Colour` is declared is currently *accepted*
> (`tests/suites/bare_variant.nim`). The fix belongs in `compatible`, which does not
> compare sum types nominally.

### match

Two arm styles, both real (`examples/39:13`):

```tuck
let code = match c:
  Red:   1
  Green: 2

let name = match c:
  | Red   -> 10
  | Green -> 20
```

**Exhaustiveness is enforced** over any closed domain: a missing variant errors
naming it (`tests/suites/typecheck.nim`); `_` satisfies it. `match` is an expression and
nests.

### Generics

```tuck
fn identity[T]({x: T}) -> T
fn firstOf[T]({xs: Seq[T]}) -> T
type Box[T] = {value: T}
```

Inference flows through calls and construction: `{value: 5} Box` infers the
instantiation (`tests/suites/typecheck.nim`); `{} Box` → `cannot infer` (`:1372`). A
binding conflict — `{a: 1, b: "s"} pair` — errors naming `'T'` (`:1327`).

> ⚠️ **OPEN BUG — a type argument named like an attribute fails to parse.**
> `Box[error]` in a parameter position is misread, because the
> attribute-vs-generic decision is a hardcoded 19-name word list. Reserved in
> brackets: `error`, `stack`, `queue`, `align`, `priority`, `volatile`, and ~13
> more. The *diagnostic* is good (`is an attribute name`), but the fix is to
> decide by declared set, not a literal list (`tests/suites/known_bugs.nim`).

---

## 4. The error model

### Constructors

`!T` fallible, `?T` optional, `!?T` both. Postfix forms also parse:
`{amount: int}?` and `{amount: int}?!` (`tests/suites/typecheck.nim`).

**A fallible fn must be `[io]`** — otherwise `must be marked [io]`
(`tests/suites/typecheck.nim`). `?T` carries no such requirement.

### Handling

```tuck
let r = {n} mightFail
if r.ok:
  return r.value.amount
```

Accessing `.value` without a guard → `guard it first`. A guard that *falls
through* does not narrow (`tests/suites/typecheck.nim`). An **early-return guard does**
narrow — `if not r.ok: return 0` then `r.value.v` (`tests/suites/known_bugs.nim`, exit 5).

Every unhandled shape is rejected with `unhandled`: arithmetic on `!T`, payload
access, `or`-defaulting, a bare statement drop, an unhandled pool `acquire`.
Multiple sites are all listed at once: `2 unhandled` (`tests/suites/typecheck.nim`).

### Raising

```tuck
err Empty                        # shorthand
return err FsError.NotFound      # qualified
err r.err                        # re-raise — THIS is propagation
```

> **There is no `?` propagation operator.** Do not look for one; propagation is
> `err r.err` (`examples/14:12`). Nothing in the tests or examples uses `?` in
> that position.

### Error enums

```tuck
fn fetchIt({url: str}) -> !{content: str} [io, error: FsError | NetError]:
```

`match r.err:` validates arms against the declared enums; a typo errors with
`not a variant of ParseError` (`tests/suites/typecheck.nim`). Run-verified through the
`Empty` arm, exit 42 (`tests/suites/cli_smoke.nim`).

### errors policy

```tuck
errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    ...
```

Three policies (`examples/22:1`): `strict` (default — compile error listing all
sites), `continue` (handler runs, execution continues, no value fabricated),
`exit` (handler runs at the first site, program exits).

`continue` legalizes **statement drops only** — not value positions
(`tests/suites/typecheck.nim`). Declaring a policy with no handler → `needs an 'on
unhandled'`.

> **Test coverage caveat:** only `continue` is tested. `strict` is exercised
> implicitly as the default; **`exit` is untested.**

---

## 5. Interfaces — the most thoroughly specified feature

```tuck
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  name: str
  satisfies Animal
  fn noise({self: Dog}) -> int:
    return 1

fn hear({a: Animal}) -> int:
  return a.noise
```

### Conformance rules (`tests/suites/interfaces.nim`)

- Params and return match **exactly, names included** — payload fields bind by
  name, so a renamed param is an error (`:122`).
- **Effects may be a subset** — an impl may declare fewer effects than the
  contract (`:62`), never more (`:172`).
- `Self` means the implementing type.
- An object may satisfy several interfaces (`:38`).
- An unsatisfied interface is legal (`:96`); a body-less member does not
  implement (`:202`).

**Conformance is explicit, never structural.** An object with all the right
members but no `satisfies` line is *rejected* (`tests/suites/interface_wrap.nim`).

### How dispatch actually works

**A tagged variant that copies — not a vtable, not a fat pointer.**
`tests/suites/interface_dispatch.nim` asserts the emission shape directly:

```
emits  'AnimalTag'                    # a tag enum
emits  'case tag'                     # the value is a variant over its types
emits  'tuck_DogVal'                  # the payload is the object itself
omits  'AnimalVT'                     # NO function table
omits  'Animal_tuck_Dog_noise'        # NO thunks
```

Every satisfying type is a branch, whether or not anything wraps it (`:88`).
Because the value **copies**, an interface value may be returned from a local,
stored in a field (`object Keeper: pet: Animal`), and collected into a
`Seq[Animal]` — all three were illegal under the old pointer design
(`tests/suites/interface_seq.nim`).

Run-verified: two objects through one param → 1 + 41 = **42**, a number neither
implementation reaches alone (`tests/suites/interface_dispatch.nim`).

> ⚠️ **OPEN (Odin)** — a list literal cannot reach a `Seq` parameter:
> "Compound literals of dynamic types are disabled by default". Affects
> `Seq[Record]` identically; needs statement hoisting in the Odin emitter
> (`tests/suites/interface_seq.nim`).

---

## 6. State machines: transitions

```tuck
type PlayerState:
  | Unloaded({config: Config})
  | Loading({config: Config, progress: int})
  | Ready({config: Config, feed: Feed})

  transitions:
    Unloaded -> Loading
    Loading  -> Ready
    Loading  -> Unloaded     # cancel
```

**Reassignment IS the transition, and it is checked statically.** This is real
flow analysis (`tests/suites/typecheck.nim`):

| Situation | Result |
|---|---|
| declared edge | ok |
| undeclared edge | error `Open -> Locked` |
| same-variant reassignment | ok (payload refresh) |
| branch merge, edge legal from both | ok |
| branch merge, edge missing from one | error |
| a **parameter** starts at the FULL variant set | error |
| `match` narrowing unlocks the edge | ok |
| a fn returning a construction narrows its caller | ok |

### `[sealed]`

Only the initial variant may be constructed directly; every other variant must
be reached through a transition (`examples/12:24`). A variant unreachable from
the initial one → `unreachable from initial`.

The escape hatch, for deserialization:

```tuck
let session = {socket, keepalive: 60} MqttSession.Connected [unsafe]
```

---

## 7. Numeric behaviour is always named

### Division (ruling R1)

**There is no bare `/`.**

```tuck
let q = 7 /i 2       # 3, truncating
let r = 7.0 /f 2.0   # 3.5
budget /i= 8
```

Why (`examples/38:1`): Nim's `/` returns float even for two ints; Odin's
follows the operand type. Leaving it to inference meant *the same source could
produce different arithmetic per backend*. Mixed operands are a type error, not
a silent widen. Run-gated 0 on both backends.

### Overflow attributes

```tuck
type SafeRPM    = u16 [saturating]   # clamps at 65535
type PacketSeq  = u8  [wrapping]
type ErrorCount = u32 [trapping]
```

`[saturating]` is fully run-gated on both backends: `70000 SafeRPM` → 65535
(wrapping would give 4464). **The clamp is a store-guard, not per-operator** —
`a + b - c` with all 60000 yields 60000, not 5535, because clamping runs on a
wider intermediate (`tests/suites/known_bugs.nim`).

An overflow attribute **implies `distinct`** on both backends
(`tests/suites/known_bugs.nim`).

> **`[wrapping]` and `[trapping]` have no behavioural test** — declaration-only.

### distinct and units

```tuck
distinct Milliseconds = u32
fn ms(value: u32) -> Milliseconds:
  value Milliseconds
```

`5.ms` is **not compiler magic** — `ms` is an ordinary fn and `5.ms` is postfix
application (`examples/23:1`). The type system does the rest:

- `{ms: 5.us}` into a `Milliseconds` param → rejected
- `{ms: 5}` (bare int) → rejected
- `Milliseconds + Microseconds` → rejected, `arithmetic`

> **Known codegen gap:** distinct→base readback (u32 vs uint32). Example 32
> proves construction and typing, then returns a hardcoded value rather than
> reading back (`examples/32:11`).

---

## 8. Invariants

```tuck
type Temperature:
  celsius: f32
  invariant:
    celsius >= -273.15
```

**Run-verified aborting in four positions** (`tests/suites/cli_smoke.nim`), each with
`Invariant violated`:

1. at construction
2. at a `..` mutation site — validated *after* the chain completes
3. inside a `!T`-wrapped return — the payload validates before `tok()` wraps it
4. at an **extern call site** returning an invariant-carrying type

`when not defined(release)` strips them in release builds.

---

## 9. Decision tables

```tuck
decision classifyPacket({priority: Priority, size: SizeClass, encrypted: bool}) -> Action:
  | high    big   true  -> QueueSecure
  | high    big   false -> QueueFast
  | high    small _     -> QueueImmediate
  | low     _     _     -> QueueDefer
```

When every column is an enum, **the compiler proves completeness and
reachability exactly — no catch-all needed** — and emits a single `case` over a
packed integer key, so the running program does zero comparisons.

| Case | Result |
|---|---|
| enum domain, complete, no catch-all | ok |
| enum domain with a gap | error `has a gap` |
| non-enum domain, no catch-all | error `catch-all` |
| unreachable row | error `unreachable` |
| enum symbol typo | error `not a value of` |

First-match-wins, run-verified: row `| 2 64 _ -> 3` is the first match for
`(2, 64, false)`, exit 3 (`tests/suites/end_to_end.nim`).

**Implementation:** a decision table is a `dkFn` carrying `isDecision`, not its
own AST node kind (`tests/suites/end_to_end.nim`). The combinatorics live in
`compiler/codegen_table.nim`, shared by both backends.

---

## 10. Concurrency: actors and tasks

The model is **stackful coroutines on one cooperative scheduler, plus an
epoll/kqueue reactor.** No preemption, no OS threads in the scheduler. Both
backends drive the same vendored C library (minicoro), so they cannot diverge
on switch semantics.

### Actors — global singletons

```tuck
actor Counter [queue: 128]:
  total: int = 0                 # public: main's predicate reads it

  on add({n: int}):
    total += n
```

No construction, no reference. The scheduler auto-registers every declared
actor and runs it as a daemon alongside `main`; `main` owns the lifecycle.

```tuck
Counter send add {n: i}          # send
Counter.total                    # read public state
```

Handlers may return, assigning `result`:

```tuck
on get() -> {count: int}:
  result = {count}
```

`on select` gives message arms plus a reserved `shutdown`:

```tuck
on select:
  | add -> {n: int}:  total += n
  | finish -> {}:     done = true
  | shutdown -> {}:   total = total
```

Run-verified 55 on both backends.

> ⚠️ **OPEN ×2** — `result` in a *void* handler is not rejected, and an
> **undeclared assignment target is not caught anywhere**: `nosuchfield += n`
> typechecks, in actors *and in plain fns*, where the real fix belongs
> (`tests/suites/actor_result.nim`).

> ⚠️ **OPEN — a generic `fnsig` does not parse.** `fnsig Mapper[T, U] = {x: T} -> U`
> fails with `Expected 'Assign' here, found '['` — `fnsig` has no
> type-parameter slot, though `fn`/`type` both do. Writing the params bare
> (`fnsig Mapper = {x: T} -> U`) *appears* to typecheck, but only because
> gradual typing reads the unbound `T`/`U` as `Unknown` — it is not real
> generic binding, and is the trap §0 warns about (sketch code and a broken
> tree both read `Unknown`). Blocks every higher-order generic API
> (`map`/`fold`/`keep` over `Seq[T]`), since `bake` needs a `fnsig`-typed
> field to fill. Same family as the generic-actor gap below.

> ⚠️ **OPEN — a generic actor declaration does not parse.**
> `actor Box[T] [queue: 4]:` fails with `Expected 'Colon' here, found '['` —
> the actor grammar has no type-parameter slot the way `type`/`fn` do
> (`fn identity[T]`, `type Box[T] = {value: T}` both parse fine; `actor` does
> not). Found while designing a stdlib service actor generic over its
> payload type. Unclear which side of the line this falls on: it could be a
> straightforward grammar gap (the `actor` rule simply never grew the `[T]`
> slot), or it could be pointing at something semantically unresolved —
> an actor is a compile-time singleton with no construction step (§10
> above), so it isn't obvious what "one instance, but generic over `T`"
> would even mean, since nothing ever supplies `T` at a call site the way
> an ordinary generic fn does. Flagged rather than triaged; the closest
> precedent (`Box[error]` as a parameter, §3) turned out to be a *ruling*
> ("attribute names are reserved in brackets") rather than a bug, so this
> one shouldn't be assumed to be a bug either without someone deciding.

### Tasks — async that looks synchronous

```tuck
task compute({base: int}) -> {r: int} [io]:
  let a = {n: base} stepIo      # [io] -> yield point
  let b = {n: base} stepIo      # [io] -> yield point
  return {r: a.v + b.v}

fn main() -> int:
  let res = {base: 21} compute  # schedule AND await
  return res.r                  # 42
```

From `examples/28:1`:

> A task is an async coroutine: `[io]` calls are implicit yield points — the
> effect marker IS the async annotation, no async/await keyword. Calling a task
> schedules it; **binding its result awaits completion.** It looks exactly like
> a synchronous call.

**Fire-and-forget vs awaited is decided by binding:**

```tuck
{lfd: fd} serve        # not bound => scheduled, not awaited
let r = {base: 21} compute   # bound => awaited
```

> ⚠️ **This is a design sharp edge.** Binding a server task before starting a
> client deadlocks: the server parks on `accept` waiting for a client that
> cannot run. It is spec §9.2 working as designed, but the failure mode is a
> silent hang.

### Timeouts — `on select` in a task

```tuck
task readOrGiveUp({fd: int}) -> {code: int} [io]:
  on select:
    | read fd          -> {}:  return {code: 1}
    | timeout {30.ms}  -> {}:  return {code: 2}
```

**Both race outcomes are run-verified**, which is the real evidence of genuine
non-blocking I/O: source at 500ms vs a 30ms deadline → exit 2; source at 5ms vs
100ms → exit 1 (`tests/suites/cli_smoke.nim`).

Working arm sources are `read <fd>` and `timeout {N.ms}`.

> ⚠️ **Task select is Nim-only so far** — examples 29 and 30 are not in the Odin
> gate. Example 16's *dotted* sources (`resp.ok`, `timer.1s`) parse as opaque
> strings and do not work at all; that is why 16 is ungated.

> ⚠️ **OPEN (Odin)** — a task **with arguments** is not spawned as a coroutine.
> Odin proc literals cannot capture, so the args need a heap context. Nullary
> tasks are fixed.

### Blocking I/O

Files cannot be epolled — a regular file is always "ready" — so the reactor is
structurally incapable of awaiting one. Blocking externs (`readFile`,
`readLine`, …) run on a **single offload worker thread** and park the calling
coroutine on a completion pipe the reactor already watches.

Measured (`thoughts/async-endgame-measurements.md`): 300ms of blocking work
beside a 10ms ticker gives **1 tick on-thread, 30 offloaded**. Sockets go
through the reactor instead and scale flat — **32 concurrent connections in
108ms** where serial would be 3200ms.

`sleepMs` is *not* offloaded: it is a reactor timer, which suspends only the
calling task.

---

## 11. Effects

Markers that appear in working code: `[io]`, `[irq_safe]`, `[stack: N]`,
`[unsafe]`, `[priority]`, `[error: E]`, `[emit: "..."]`.

**`[io]` is the only enforced effect.** A pure fn calling an `[io]` fn →
`requires effect [io]` (`tests/suites/typecheck.nim`). Effects cross module boundaries
from source *and from the cache* — `tests/suites/cli_smoke.nim` runs the check twice,
cold and warm, and both must reject identically.

> **`[no_alloc]` and `[may_block]` appear in NO example and NO test.** They
> parse and propagate; they have no checker meaning. Do not rely on them.

> **`[irq_safe]` and `[stack: N]` are compile-gated only** — the comment in
> `examples/11:17` states an intent ("compiler verifies worst-case stack usage
> ≤ 128 bytes") that **nothing tests**.

---

## 12. Modules

```tuck
import fs
import io

let w = {path: "/tmp/x", content: "hi"} fs::writeFile   # qualified
{text: "hi"} printLine                                  # unqualified — idiomatic
```

Both forms work. Unqualified is idiomatic (`examples/41:5`). An unknown module
prefix stays **gradual** — `{volume: 3} audio::play` typechecks
(`tests/suites/typecheck.nim`), so a sketch compiles before its modules exist.

Module resolution needs `--root:`.

### Name mangling

A whole-program pass before either backend (`tests/suites/mangle.nim`): fns and types
get a `tuck_` prefix; **fields, params and locals stay bare** (namespaced by
their record); **externs are never mangled** — they bind foreign symbols by
name. Idempotent, since each backend lowers its own deep copy.

---

## 13. Externs and C FFI

Four flavours, all run-gated.

**(a) Runtime extern** — implemented by `tuck_rt`; all of `std/*`:

```tuck
extern:
  fn readFile({path: str}) -> !{content: str} [io, error: FsError]
```

**(b) `[impl:]`** — bind a backend-language module, no compiler edit:

```tuck
extern [impl: nim "std/strutils", odin "core:strings"]:
  fn startsWith({s: str, prefix: str}) -> bool
```

`./` or `../` marks a path relative to the .tuck source and gets rebased off
the output dir; anything else is a backend module name passed through.

**(c) `[c, header:, lib:]`** — direct C FFI:

```tuck
extern [c, header: "zlib.h", lib: "z"]:
  fn compressBound({sourceLen: u64}) -> u64 [emit: "compressBound"]
```

Types declared *inside* an extern block are foreign. Structs by value both
directions, C enums with explicit values (`= 10` is load-bearing — a
mis-numbered tag is silently the wrong constant at the ABI boundary), and
callbacks all run-gated on both backends.

**(d) Opaque handles** — a fieldless extern type:

```tuck
type Counter = {}
```

Nothing to read, size unknown, so it can only ever be a pointer. Nim emits
`{.incompleteStruct.}` + a `ptr` alias; Odin emits `rawptr`. **Lifetime is
manual — C allocated it, C frees it, and nothing in Tuck tracks that yet.**

### The pointer rule

> A pointer may be produced by an extern and consumed by another extern, but it
> **may never be stored.**

Three rules, not one — the distinction is about **memory**, not pointers
(`tests/suites/pointer_containment.nim` is the authority):

| | `cstring` / `Buf` | opaque handle (`type C = {}`) |
|---|---|---|
| extern **parameter** | legal | legal |
| extern **return** | **illegal** — *"never returned out of it"* | **legal** (exempt) |
| **stored** anywhere | illegal | illegal |

The exemption exists because a fieldless extern type has no definition:
"there is nothing to dereference and no memory Tuck can read. It is a token
the library hands out and takes back — every real C API works this way
(`FILE*`, `sqlite3*`). Barring it left `counterNew` unwritable in ANY form,
since a handle has no by-value equivalent to copy out." A returned
`cstring`, by contrast, points at bytes whose lifetime is C's and
unknowable here — so that binding must return a safe type and copy in the
impl module (`examples/34-ffi-cstring.tuck`, build-and-run gated).

`tests/suites/pointer_containment.nim` is the most systematic negative test in the
suite (196 lines). Pointer-kinds are `cstring`, `Buf`, and any fieldless extern
type. Legal as an extern *parameter*; illegal as an extern *return* — even
buried in a wrapper (`-> !cstring`) — and illegal in a record field, a plain fn
signature, a `Seq` element, a mixin member, or an actor field.

### fnsig — named function signatures

```tuck
fnsig Adder = {a: int, b: int} -> int
type Calc = {add: Adder}

let c = {add: :plus} Calc
let r = {a: 40, b: 2} c.add
```

Run-gated 42 on both backends.

> ⚠️ **OPEN — storing into a `fnsig` slot is not signature-checked.** A
> plainly mismatched fn reference is accepted: with
> `fnsig Predicate = {x: int} -> bool`,
> `type Query = {items: Seq[int], test: Predicate}` and
> `fn wrongShape({a: str}) -> str`, both `{items: [1,2,3], test: :wrongShape} Query`
> and `{items: [1,2,3]} bake {test: :wrongShape}` typecheck clean.
> `tests/suites/typecheck.nim:1805` covers the other direction — a *call
> through* a fnsig slot checks arity — so the gap is specifically on the
> store, not on use. `bake`'s intended semantics is that it matches the
> signature declared on the record's slot, which makes this the check that
> makes the feature safe.

---

## 14. Composition helpers

```tuck
let withOp = x bake {op: :plus}    # compile-time partial application
let ctx = {episode, prefs} merge   # flatten member structs into one
let t = ext alias(trackId: id, title: name)   # explicit rename; PARENS, source: target
```

`bake` slots emit as generic params, so calls through a baked slot are direct —
no boxing, no runtime dispatch. `merge` rejects a field-name collision
(`collides`) and a non-struct member (`must be a struct`).

> **`bake` is checked and emitted but never run** — example 03 is compile-gated
> on both backends with no run gate.

---

## 15. Memory: pools, arenas

```tuck
pool RxBuffers = Array[512, u8] [count: 4]

let b = RxBuffers.acquire        # -> ?T
if b.ok:
  RxBuffers.release {b.value}
```

From `examples/25:3`, worth quoting:

> A pool moves an allocation decision from runtime to compile time. You are not
> caching and you are not reusing for speed: you are declaring "at most N of
> these can exist at once", so the memory is fixed at link time and malloc
> never appears. The count is always a REAL-WORLD FACT, never a guess.

**Exhaustion is absence (`?T`), not an error** — the caller decides what running
out means. Run-verified exhaustion cycle: acquire 2 of 2, third fails, release
one, fourth succeeds, exit 42 (`tests/suites/cli_smoke.nim`).

> **`arena` (`.alloc`, `.reset`) is compile-gated only — zero behavioural
> assertions.** Same for `registry` (`.raise`, `on Reg.Variant`) and MMIO
> `register` read-only enforcement.

---

## 16. Loops

```tuck
loop:                # infinite
for n > 0:           # while-style
for i in 0 .. 3:     # inclusive
for i in 0 ..< 3:    # exclusive
for idx, item in xs: # indexed
```

`break` / `continue` target the innermost loop; there are **no labels, ever**
(a ruling). Run-verified exit 17 through every form (`tests/suites/cli_smoke.nim`).

Loop variables carry real types — a field typo on a loop var is caught, in both
the plain and indexed forms, and nested loops keep separate element types
(`tests/suites/loop_var_type.nim`).

List literals and indexing:

```tuck
let xs = [10, 20, 30]
xs[1] = 5
xs[0] += 5
```

Bracket sugar desugars to `seq::at` / `seq::setAt`. **Bounds are a
precondition, not a result** — out of range aborts with `out of bounds for seq
of length 3`, reported at the caller's line.

---

## 17. What does NOT exist

Listed because their absence is easy to assume away:

| Not a thing | Use instead |
|---|---|
| `?` propagation operator | `err r.err` |
| `~T` lossy conversion | named as a future ruling only (`examples/40:12`) |
| bare `/` | `/i` or `/f` |
| `async` / `await` keywords | `[io]` IS the annotation |
| `[no_alloc]`, `[may_block]` semantics | parse and propagate; no checker meaning |
| loop labels | innermost only, by ruling |
| dotted select sources (`resp.ok`, `timer.1s`) | parse as opaque strings; example 16 is ungated |

---

## 18. Open bugs (3)

Each has a failing test pinning the *correct* behaviour. Fixing one means
flipping `bug_open` → `bug_fixed`, which locks it in permanently.

| # | Bug | Test |
|---|---|---|
| 1 | A **bare** attribute marker cannot be a type argument (`Box[sealed]`) — genuinely ambiguous, since a bare `sealed` is a real attribute | `tests/suites/known_bugs.nim` |
| 2 | A member fn shadows a top-level fn of the same name — needs a change to call resolution, not just emission | `tests/suites/member_names.nim` |
| 3 | Odin: a list literal cannot reach a `Seq` parameter — needs statement hoisting in the emitter | `tests/suites/interface_seq.nim` |

Plus, tracked without a test yet: on Odin a **task with arguments** is not
spawned as a coroutine (proc literals cannot capture).

Fixed earlier the same day, listed because older notes still name them: an
undeclared assignment target is now caught (this also fixed the void-handler
`result` case), sum types are nominal, and `Box[error]` parses.

---

## 19. Backend parity

Nim is the reference; Odin is the second backend, not a port target. The rule,
from `codegen.nim`'s header:

> **Share the logic, never share the syntax.**

Queries that ask the AST a question live in `codegen_common.nim` and are shared.
Emitters, which interleave traversal with target syntax, stay twinned and
diffable.

Current coverage: **41 examples compile-gated**, 36 Odin compiles, 14 Odin runs
pinned to exact exit codes.

Nim-only so far: task select/timeouts (29, 30), `42-net-echo`, `14-task`.

> **The gate lists ARE the coverage.** Anything off a list is unchecked — that
> is how an Odin actor emitting undefined send procs, and a `24-stdlib` whose
> file round-trip never actually ran, both survived for weeks.
