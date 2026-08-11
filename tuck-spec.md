# The Tuck Language — Canonical Specification
### Version 0.1 — Working Draft

---

## Part 1: Philosophy

Tuck is a systems-capable language designed primarily for embedded and constrained
environments, suitable for general application development. It targets the gap where
C is fifty years old, C++ brings hidden costs, and Rust's ownership model fights
against embedded patterns.

The goal is not academic novelty. The goal is **maintainability, obviousness, and
fearless refactoring**. Programs always grow. Debugging is hard and slow. Therefore
the language must make everything explicit, locatable, and auditable.

Tuck achieves this through a single radical constraint:

> **Every piece of data flows through the system as a named struct.**

By restricting the shape of code, Tuck frees the programmer to focus entirely on
the shape of data. The result is a language that feels like a catalog of tiny,
obvious, unbreakable blocks snapping together.

### The Three Answers

For every major concern, Tuck has exactly one answer. There are no two ways to do
any of these things:

| Concern | Answer |
|---|---|
| State | Sum types with sealed transitions |
| Errors | `!T` results carrying declared error enums, unwrapped under `if r.ok` |
| Absence | `?T` option values — no nil, ever |
| Side effects | Effect markers `[io, no_alloc, ...]` |
| Shared mutable state | Actors with typed message queues |
| Short async operations | Tasks — `[io]` functions yield implicitly |
| App-wide signals | One `registry`, one handler per event |
| Hardware access | Register declarations, units, packed types |
| Correctness | Decision tables, transition graphs, invariant asserts |
| Composition | Domain files, mixins, manager objects |

---

## Part 2: The Universal Shape

### 2.1 Named Structs Are the Only Container

In Lisp, everything is a list. In Forth, everything is a stack. In Tuck, everything
is a named struct. A single integer is conceptually `{value: 5}`. The compiler
allows syntactic sugar (`5.ms`) but semantically it is always a struct. The
backend optimizes the wrapping away completely.

```tuck
fn main() -> void:
  # Data flows through postfix chains
  let request = {url: "example.com", timeout: 5.ms}
  let response = request fetch parse selectEpisodes

  # Bind to a variable to branch
  var feed = {url: "..."} fetch
  if feed.hasNew:
    feed.episodes process
  else:
    feed.metadata log
```

### 2.2 No Destructuring

You do not unpack a struct into local variables. If you need a field, you access
it via `.fieldName` on the flowing struct or the bound variable. The struct flows
as a whole.

### 2.3 Postfix Invocation vs. Mutation

The object is the struct — the object's state. A fn operates on it. Calls
resolve **semantically, not by syntax**: whitespace, `.name`, and
`.name {args}` are the same call form (empty braces are merely redundant).

**Call resolution** (one rule everywhere): the value on the left is offered
to the fn's FIRST parameter whole; if the types are compatible, it binds
whole (structurally when the receiver type has no name) and the braced
struct fills the remaining parameters by name. Otherwise the value's
**fields** fill the parameters by name (subset matching, §2.5).

```tuck
fn describe({self: Server}) -> str: ...
fn scaled({self: Server, factor: int}) -> int: ...
fn advance({position: int, step: int}) -> int: ...

s describe            # whole-bind: describe(s)
s.describe            # identical
s.describe {}         # identical (empty braces: harmless, unnecessary)
s.scaled {factor: 2}  # whole-bind + braced args: scaled(s, 2)
p advance             # Player has no param-1 match → fields fill params:
                      # advance(p.position, p.step)
```

`.name` on a struct that HAS a field `name` reads the field; otherwise it
resolves to a fn by lookup. A field takes no arguments — `s.port {8080}`
is a compile error pointing at `..`.

**Either/or namespace**: a field name may never shadow a declared fn name.
Declaring both (`fn port` + a type with field `port`) is a compile error —
rename one. Resolution is by lookup, so a shadow would silently change
what `.port` means; the compiler refuses the ambiguity instead.

**`..` (DotDot) — mutation/builder.** Only on a `var`; the compiler rejects
`..` on `let` bindings (friction is intentional — it encourages extraction
and keeps functions tiny). Each `..name {arg}` step either:

- **sets a field** — `name` is a field of the var's type; the payload is
  one BARE value: `{8080}` (sugar for `{value: 8080}`) or a bare var
  `{episode}`. A named pair (`..port {host: 80}`) is rejected — setting
  several fields is a mutator fn's job. The value must match the field's
  type and nothing else, or
- **calls a mutator fn** — resolution as above, and the RESULT is
  reassigned into the var. An ordinary reassignment type-check applies, so
  the fn must return the receiver's type. Mutators should just update
  state (enforcing purity via effect markers: future work).

Either way the chain continues on the same var.

```tuck
type ServerConfig:
  port: int
  timeout: u32

fn withDefaults({self: ServerConfig}) -> ServerConfig: ...
fn start({self: ServerConfig}) -> bool: ...

var server = {port: 0, timeout: 0} ServerConfig
server ..withDefaults ..port {8080} ..timeout {60.seconds}
let ok = server.start   # NOT ..start — start returns bool, not the receiver
```

**What errors, and why:**

| Form | Error |
|---|---|
| `s.port {8080}` | `port` is a field — fields take no arguments; set with `..port {…}` on a var |
| `let s = …; s ..port {1}` | `..` on a `let` — use `var` |
| `s ..describe` | mutator must return the receiver's type (describe returns `str`) |
| `n ..withPort {80}` (n: int) | fn's first parameter expects `ServerConfig`, receiver is `int` |
| `s ..mystery {1}` | no field or fn `mystery` on the receiver's type |
| `s ..port {"x"}` | field `port` is `int` but got `str` |
| `s ..port {host: 80}` | setting a field takes one bare value — use a mutator fn for several |
| `fn port` + field `port` | field shadows a declared fn — rename one |

### 2.4 Field Access Auto-Wrap

Accessing a single field wraps it automatically into a single-field struct so
function uniformity is preserved:

```tuck
player.volume normalize   # volume: int → {value: int} → passed to normalize
```

This is a compile-time rewrite. Zero runtime cost.

### 2.3b Program Structure: Declarations and `main`

A module's top level is DECLARATIONS ONLY: imports, types, fns, objects,
actors, mixins, interfaces, registries, registers, pools, errors,
resources, pending/extern blocks. No top-level statements — not even pure
`let`s; constants live inside the fns that use them. The runnable program
is `fn main`, period (ruling 2026-07-13).

- A top-level statement is a compile error pointing at `fn main`.
- `const name = <expr>` IS a declaration: arbitrary PURE computation,
  evaluated at compile time by the backend's const evaluator (codegen
  emits an explicit `static:` block — Nim's VM runs it). Calls to pure
  fns, unit sugar (`5.ms`), computed tables: all fine. Rejected at the
  Tuck level: `[io]` calls (const must be pure), record-type
  constructions (reference values — not const-able), unknown callees.
  Baked into the binary; nothing runs at startup. Runtime-initialized
  state has three homes: pass it down from main, an actor owns it
  (shared mutable state), or the resource registry §7.4 (OS handles).
- `tuck build` with `fn main` → executable; without → LIBRARY build (the
  emitted code is the artifact, no binary).
- Rationale: predictable startup (no hidden module-init order), effects
  stay on fns only, and both backends share one entry mechanism.

### 2.4b `input` and `merge`

**`input`** is a reserved name: the fn's whole incoming payload as one
struct. `input.x` reads the param `x`; bare `input` is the whole payload
where a struct is expected. Fully typed (the checker binds it as the param
record); codegen rewrites `input.x` to the param directly — zero cost.

**`merge`** flattens: `{a, b} merge` produces ONE struct carrying the
union of the member structs' fields. A field-name collision between
members is a compile error (no silent shadowing); a non-struct member is
an error. merge changes the structure — contrast with `bake` (fills
values/slots) and `alias` (renames fields).

```tuck
fn play({episode: Episode, prefs: PlayerPrefs}) -> str:
  let ctx = {episode, prefs} merge   # title, duration, ..., volume, speed
  ctx describe                        # subset matching picks what it needs
```

### 2.4c `alias`

Renames fields on a flowing struct, without touching its values — the
explicit tool for the "the field names don't match, but the data is right"
handoff between two parts of a program that were not written expecting each
other (an external API's payload feeding a function that expects its own
naming convention, say). Contrast with `merge` (changes the field SET) and
`bake` (fills fn-reference/value slots, §3.5): `alias` only ever renames.

```tuck
let ext = {trackId: 42, title: "SlowJam", durationMs: 215000}
let norm = ext alias(trackId: id, title: name, durationMs: length)
# norm: {id: 42, name: "SlowJam", length: 215000}
norm describe   # subset/name matching now applies against the RENAMED fields
```

The call takes **parentheses**, not the `{}` struct-literal braces every
other postfix call in this spec uses — a deliberate, sole exception, so a
rename step is visually distinct from an ordinary call at a glance. Each
`oldName: newName` pair says which of the receiver's fields to rename and
what to call it in the result; fields not mentioned pass through unchanged.
Renaming a field that does not exist on the receiver is a compile error. The
result is a fresh, fully-typed struct (not a view over the original) — the
usual subset-matching and missing-field checks (§2.5, §4.8) apply to it
exactly as they would to any other struct.

Two fields ending up with the same name in the RESULT — whether one rename
target collides with an untouched field, or two renames target the same new
name — is intended to be a compile error, the same "no silent shadowing"
rule `merge` enforces above. That check is not implemented yet: today
`alias` does not validate the result for collisions, which can silently drop
a field or (worse) produce emitted code that fails to compile downstream.
Treat multi-field `alias` calls carefully until this is closed.

### 2.5 Subset Matching

If a flowing struct contains more fields than a function requires, the extra fields
are silently ignored. The function receives exactly the subset it declared:

```tuck
# data is {id: int, name: str, email: str}
# sendEmail requires {email: str, name: str}
data sendEmail   # valid — id is ignored
```

**Ambiguity rule:** if two functions in scope both match the flowing struct's shape,
it is a compile error. The call site must qualify explicitly.

**Rename at composition:** if a type union produces a field name conflict, the
conflict must be resolved at the composition site:

```tuck
type C = A + B {state -> bState}   # rename B's 'state' field
```

Renaming is validated left-to-right. Renaming to an already-present name is a
compile error.

### 2.6 Control Flow: Loops

One iteration keyword (`for`, Odin-inspired unification) plus `loop` for the
infinite form. No `while` keyword, no C-style 3-clause form (a post-step is
just the last statement in the body), and no labels — ever.

```tuck
loop:                        # infinite (while-true)
  poll()
  if done(): break

for ready():                 # while-style — condition directly after for
  tick()

for i in 0 .. 10:            # inclusive range (Nim convention), 0..10
  ...

for i in 0 ..< 10:           # exclusive range, 0..9
  ...

for item in items:           # iterate values
  ...

for idx, item in items:      # iterate with index (idx: int)
  ...
```

`break` and `continue` affect the nearest enclosing loop, usable anywhere in
its body including nested `if`/`match`. The loop condition must be `bool`.

**Ranges are spaced `..`.** The chain mutator is always tight (`s ..port`),
a range operator always has spaces around it (`0 .. n`); the lexer separates
the two by spacing. `..<` needs no space rule (`<` can never start a field).
Range bounds must be integers.

**No labeled break/continue.** Multi-level early exit is a decomposition
signal, not a control-flow feature: extract the inner loop into its own
function and react to its return value. This is the same stance as the
cyclomatic-complexity ceiling (§6.1) — nested-break-through-two-loops is
exactly the code that should become a named function. To make that
extraction free on embedded targets, `fn inline` (§3.6b) guarantees the
helper compiles away.

---

## Part 3: Functions

### 3.1 Functions Are Catalog Entries

There is no `self` keyword. A function is a standalone entry in the catalog. If it
operates on a specific shape, it takes that shape as its first argument explicitly.

```tuck
fn setVolume({player: AudioPlayer, level: int}) -> AudioPlayer:
  player ..level {level}
```

### 3.2 Signatures

Return types are **required** on all function signatures. This seeds the two-pass
type checker with enough information to resolve mutual recursion without forward
declarations. Everything else (local variable types, intermediate expression types)
is inferred.

```tuck
fn classify({celsius: f32}) -> {state: ThermalState}:
  ...
```

### 3.3 Infix Operators in Function Bodies

Inside function bodies, standard infix arithmetic and comparison operators are
permitted. Outside bodies (top-level postfix chains), postfix only. Operators are
just functions with infix calling convention, as in Nim:

```tuck
fn add({a: int, b: int}) -> {result: int}:
  result = a + b       # infix allowed in body

{a: 5, b: 10}.add     # postfix at call site
```

Precedence (high to low): `* / %` → `+ -` → `>= <= != > < ==` → `and or`

### 3.4 Higher-Order Functions via Struct Fields

Passing a function is just passing a struct with a function reference field:

```tuck
fn applyOperation({a: int, b: int, op: fn}) -> {result: int}:
  result = op.invoke {a, b}
```

### 3.5 `bake` — Compile-Time Specialization

`bake` replaces a function-field placeholder with a concrete function reference at
compile time. It is a Factor-language-inspired quotation — the compiler rewrites
the IR, swapping the placeholder for the concrete function, then inlines. No
runtime cost, no boxing:

```tuck
let x = {a: 5, b: 10, someFunc}
let y = x.bake {someFunc: :add}
# y is now exactly: {a: 5, b: 10} with add inlined at the call site
```

`bake` unifies partial application, dependency injection, and the strategy pattern
into one compile-time operation.

### 3.6 Function Prefix Modifiers — proposed, then dropped

`pred`/`set` keyword prefixes (purity declared by which keyword opens the
signature, mirroring `fn`) were proposed in an earlier draft of this spec and
never implemented — no lexer keyword, no parser rule, no checker constraint
ever existed for either. Formally dropped rather than left as a stale
proposal: everything they would have enforced is already enforced by
mechanisms this spec specifies elsewhere, so a second, keyword-level purity
system would have duplicated a rule rather than added one.

- "Does this function have side effects" is answered by effect markers
  (§3.7) — a fn with no `[io]` (etc.) in its budget cannot perform one, and
  the checker verifies every call transitively, not just the fn's own body.
- "Does this function mutate its receiver" is answered by `..`-on-`var`-only
  (§2.3) — a `let`-bound receiver already cannot be mutated through a chain.

Every function is declared `fn`; there is no other opening keyword.

### 3.6b Codegen Attributes: `fn inline`

An optional keyword slot right after `fn`, before the name:

```tuck
fn inline queuePush({msg: Msg}) -> !void [no_alloc, irq_safe]:
  ...
```

`inline` is not an effect marker (§3.7 — those are checker-enforced
propagating contracts). It is a codegen hint, the function-level sibling of a
type's `[packed, align: N]` attributes: no propagation, no semantic effect.
Lowers to Nim `{.inline.}` / Odin `@(require_results=false)`.

It exists so the no-labels ruling (§2.6) costs nothing: extracting a hot
inner loop into a helper and marking it `inline` produces codegen
indistinguishable from hand-inlined code. Future attributes in this slot
(`cold`, `noinline`) are possible; none are specified today.

### 3.7 Effect Markers

A closed set of operational markers in `[]` after the return type. These allow the
checker to enforce constraints without changing language semantics:

```tuck
fn readSensor({port: u8}) -> !{value: u16} [io]:
  ...

fn queuePush({msg: Msg}) -> !void [no_alloc, irq_safe]:
  ...
```

**Initial marker set:** `io`, `alloc`, `no_alloc`, `may_block`, `irq_safe`, `unsafe`

**Declaration is explicit, not inferred.** A function's effect budget is
exactly the markers written on its own signature — nothing more. Calling a
function that performs an effect your own signature did not declare is a
compile error naming the missing marker, even if the call is one level deep:

```tuck
fn readSensor({port: u8}) -> !{value: u16} [io]: ...

fn poll({port: u8}) -> !{value: u16}:        # no [io] declared
  return {port} readSensor                    # Error: requires effect [io],
                                                # which is not allowed here
```

This is a deliberate ruling, not an inference gap the checker will one day
close: requiring every effectful function to say so, at every level, is the
same "everything explicit, locatable, auditable" stance the rest of this
spec takes (Part 1) — a reader on the fence about whether some deeply-nested
helper touches I/O should never need to trace the call graph to find out; the
signature already says so. What *does* propagate is the obligation: a
function cannot perform an effect it did not declare, so declaring `[io]`
anywhere in a call chain forces every caller up that chain to declare it too,
transitively — the checker enforces the whole chain, not just the immediate
call.

`main` is exempt: it is assumed impure (the program's entry point always
does something), so it may call anything without declaring effects itself.

An `[irq_safe]` function calling an `[io]` function is a compile error — one
instance of the general rule above (`io` is simply not in an `[irq_safe]`
fn's declared budget), not a special case.

---

## Part 4: Types

### 4.1 Primitive Types

`bool`, `u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`, `i64`, `f32`, `f64`,
`str`, `usize`

Integers carry an overflow mode declared on the type:

```tuck
type SafeRPM    = u16 [saturating]   # clamps at max, never wraps
type PacketSeq  = u8  [wrapping]     # intentional wraparound
type ErrorCount = u32 [trapping]     # debug: panic, release: defined behavior
```

Default for primitive integers: `trapping` in debug, `wrapping` in release.

The **attribute** is what changes behaviour — an overflow mode implies
`distinct`, since it is meaningless on a bare alias (an alias *is* the base
type and cannot carry different semantics). `type X = u16 [saturating]` and
`distinct X = u16 [saturating]` are the same declaration.

`[saturating]` clamps where a value is **stored** — construction, `let`/`var`
init, field mutation — against a wider intermediate. It is not clamped at
every operator: in `a + b - c` an intermediate may overshoot and come back,
and only the stored result is checked, so a chain whose true value fits is
never corrupted by a transient overflow. Unlike `invariant` (spec 4.7), the
clamp is **never stripped in release** — it is value semantics, not an
assertion. Cost is ~3 branchless instructions (a `cmov`).

Ceiling: `u64 [saturating]` has no wider intermediate, so a chain that
overflows `u64` itself wraps before the guard sees it. Exact for u8/u16/u32.

### 4.2 Distinct Types / Units

Unit types are `distinct` wrappers — same bits at runtime, different types at
compile time. Arithmetic between different unit types is a compile error:

```tuck
distinct Milliseconds = u32
distinct Microseconds = u32
distinct Hertz        = u32

fn delay({ms: Milliseconds}) -> void: ...

delay {5.ms}    # fine
delay {5.us}    # compile error — wrong unit
delay {5}       # compile error — bare int rejected
```

`5.ms` is syntactic sugar for `Milliseconds {5}`. Unit constructor functions are
auto-generated for every `distinct` type.

### 4.3 Sum Types

Sum types model lifecycles and state. You cannot access a field that doesn't exist
on the current variant — the type system enforces valid states without boilerplate:

```tuck
type PodcastPlayerLifecycle:
  | Unloaded({config: Config})
  | Loading({config: Config, progress: int})
  | Ready({config: Config, feed: Feed})
  | Error({config: Config, reason: str})
```

**Exhaustive matching is required.** The compiler rejects any `match` that does not
cover every variant or provide a `_` wildcard.

### 4.4 Sealed Sum Types — Protocol State Machines

The `[sealed]` attribute restricts direct construction to the first (initial)
variant only. All other variants must be reached via declared transitions:

```tuck
type MqttSession [sealed]:
  | Disconnected
  | Connecting({host: str, port: u16})
  | Connected({socket: Socket, keepalive: u16})

  transitions:
    Disconnected -> Connecting
    Connecting   -> Connected
    Connecting   -> Disconnected   # timeout or failure
    Connected    -> Disconnected   # close
```

```tuck
let s = MqttSession.Disconnected        # fine — initial variant
let s = MqttSession.Connected {..}      # compile error — sealed
let s = MqttSession.Connected [unsafe] {..}  # allowed with explicit escape
```

`[sealed]` is narrow: it only restricts *direct construction* syntax to the
initial variant. It is independent of — and much smaller than — static
transition checking below, which applies to every type that declares
`transitions:`, sealed or not.

### 4.4b Static Transition Checking — `Type@Variant`

A value of a type that declares `transitions:` is always typed not just as
`Type`, but as `Type@Variant` — the SET of variants it could statically be
in at that point. This is the real type; bare `Type` is shorthand for the
full set of all declared variants (no narrowing information yet). A fresh
construction (`{...} Type.Variant`) narrows to the single variant
constructed. `@Variant` is compiler notation for diagnostics and this
spec — it is never written in `.tuck` source.

**A new variant is never assigned from scratch onto a tracked var** — a
plain reassignment that changes the tracked variant is checked exactly
like a transition, against the same table, at compile time. There is no
separate `transitionTo` call for the user to write; the compiler proves
the edge itself wherever the change happens:

```tuck
var d = Door.Closed              # d: Door@Closed
d = {} Door.Open                 # checked: Closed -> Open must be in the
                                  # table. Legal here -> d: Door@Open
```

**Merging** (branches, loop bodies) UNIONS the possible-variant sets —
narrowing is never discarded to bare `Type`:

```tuck
var d = Door.Closed              # d: Door@Closed
if cond:
  d = {} Door.Open                # this arm: Door@Open
# after the if (no else): Door@{Closed | Open}
```

A transition attempted against a set `@{A | B}` is legal only if the
target is reachable from EVERY member of the set (the edge must exist
from `A` and from `B`). Loops get no special treatment — the loop body is
checked once against the entry set, same as any other block; there is no
fixed-point iteration or loop simulation. A bogus edge inside a loop body
fails at that transition site regardless of how many times the loop could
run.

**Function boundaries carry the narrowing, not the signature.** A fn's
declared param/return type stays the general `Type` (no `@Variant` in
signatures) — but the checker still knows, at each call site, which set
the argument value carried, and checks any transition inside the callee's
body against that set. A callee's return narrows the caller's result only
when the checker can trace it to a construction site (a literal
`{...} Type.Variant`, or a variable whose set is known); an opaque return
(e.g. relayed straight through from an untraceable source) yields the
unnarrowed full-variant set at the call site.

**No implicit runtime fallback, ever.** If the checker cannot determine a
set precisely enough to prove a transition legal, it is a compile error —
never a silent drop to a runtime check. (A future explicit escape hatch,
symmetrical to `[unsafe]` on sealed construction, is not yet designed.)

**Sealed interplay**: the RHS of a checked transition assignment may
construct a non-initial variant of a `[sealed]` type — the proven
transition IS the legal path (static analogue of the old
transitionTo-chain exemption). Helper fns constructing sealed variants
outside such an assignment still need `[unsafe]`.

*Implemented 2026-07-13* (checker-only; the runtime `transitionTo`
remains available for dynamic cases). Known ceilings: return-site tracing
is module-local (cross-module calls yield the full set); match-arm bodies
are single-line today, which constrains narrowing blocks.

### 4.5 Type Composition

Types are composed via set union. There is no inheritance:

```tuck
type PodcastPlayer = PodcastPlayerLifecycle + PlaybackControls + CacheManager
```

Field name conflicts are compile errors. Resolve at the composition site with
rename syntax (see 2.5).

### 4.6 Type Attributes

All compiler directives on types use `[]` brackets after the type name, consistent
with effect markers on functions:

```tuck
type EthernetFrame [packed, align: 2]:
  dst:       Array[6, u8]
  src:       Array[6, u8]
  ethertype: u16 [big_endian]    # field-level attribute
```

**Available type attributes:** `packed`, `align: N`, `sealed`,
`saturating`, `wrapping`, `trapping` (invariants are a block inside the type
body, not an attribute — §4.7)

**Available field attributes:** `big_endian`, `little_endian`, `volatile`

### 4.7 Invariants

Invariants are runtime asserts — inserted by the compiler at every point where a
value of that type is produced: construction, return value, after mutation, after
deserialization. Stripped in release builds. Zero compiler complexity.

Block form only — `invariant:` inside the type body, one predicate per line:

```tuck
type Percentage:
  value: u8
  invariant:
    value >= 0
    value <= 100
```

The invariants fire automatically everywhere. The developer writes them once.
(There is no inline or attribute form; predicates that belong together still
read as separate declared facts.)

### 4.8 Error and Absence

- `!T` — the operation might fail
- `?T` — the value might be absent
- `!?T` (or `?!T`) — both

Wrappers may also be written postfix: `int?`, `{feed: Feed}!`, `u16?!` —
identical meaning, canonical form is postfix.

**Errors are declared enums.** An error definition is an ordinary fieldless
sum type. A fallible signature names the enums it can raise in the effect
bracket — a list, since one function can fail in several domains:

```tuck
type FsError:
  | NotFound
  | AccessDenied

fn loadFeed({path: str}) -> !{feed: Feed} [io, error: FsError | NetError]:
  if {path} missing:
    return err FsError.NotFound   # qualified
  ...
  err AccessDenied                # shorthand: resolved against the declared
                                  # list; ambiguous across enums = error
```

`err X` builds the error result and returns it — an early exit, like
`return`. The enum value never flows bare: it rides inside the result struct
`{ok, err, value}`. Re-raising an existing code is `err r.err`. The compiler
validates every raise site against the declared `[error: ...]` list.

**Error ids** are 16-bit FNV-1a hashes over `"module/Enum.Variant"` — the
namespace rides inside the id, so the same enum name in two modules gets
distinct codes, and codes are stable across builds (name-derived, no
central table). The compiler checks the whole program for hash collisions
(a collision is a compile error naming both ids). **Handling**:
`match r.err` arms are variants of the producer's declared enums —
validated (typo, cross-enum ambiguity) and compiled to id-constant
comparisons; `_` is the catch-all. Debug builds embed a reverse table
(id → name) so unhandled-error reports print `module/Enum.Variant`
instead of a raw code.

**Handling is unwrapping, and it is scoped.** A result flows **whole** until
it is inspected. `.ok` and `.err` are readable anywhere; `.value` needs a
guard. Two forms, and they narrow different regions:

```tuck
fn use({path: str}) -> int [io]:
  let r = {path} loadFeed
  if r.ok:
    return r.value.feed.episodes   # legal: inside the guarded block
  0                                # error path: no fabricated values

fn use2({path: str}) -> int [io]:
  let r = {path} loadFeed
  if not r.ok:
    return 0                       # bail out first...
  return r.value.feed.episodes     # ...and the rest of the fn is narrowed
```

`if r.ok:` narrows its own block. `if not r.ok:` narrows **everything after
it**, provided the branch always exits (returns, raises, breaks or
continues) — otherwise control could reach the following code with the value
still absent, and the narrowing would be unsound. The early-return form keeps
the happy path unindented, which is why it is the one the pool and resource
examples use.

Outside a guard the value is still the wrapped type, and returning it where a
bare `T` is expected is a compile error.

There is no propagation operator. Passing the burden upward is simply
returning the whole result — the caller's signature then carries `!T` too,
and the caller unwraps or passes it on. `or` is strictly boolean; it does
not unwrap results. Handling combinators (`ifErr`, defaults) live in the
standard prelude, not in the language.

Fallible functions must be marked `[io]`: errors exist only at I/O and
unknown-input boundaries. The pure core of a Tuck program is total — it
cannot fail. Correctness there comes from decision tables, invariants, and
exhaustive matching, not error returns. Effect markers and error lists are
different systems: `[io]` propagates up the call chain; errors stop at the
first handler.

### 4.9 Global Error Policy

Most codebases handle "an error I haven't dealt with yet" the same way: log
it and move on. Tuck formalizes that shortcut in one visible place — like the
event registry — so every site that relies on it is declared, reported, and
findable.

One `errors` declaration per application selects one of three modes:

```tuck
errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    log.warn "unhandled error {code} at {site}"
```

- `strict` — every error is handled directly at its site (unwrapped under an
  `if r.ok` guard, passed to a handling function, or returned whole to the
  caller) or it is a **compile error**. The compiler lists **all** unhandled
  sites, not just the first.
- `continue` — an unhandled error is passed to the global `unhandled`
  handler, then execution continues past that statement. Only legal where
  the error was in statement position — no value is ever fabricated; a site
  whose payload is actually needed is a compile error in every mode.
- `exit` — the `unhandled` handler runs at the **first** unhandled site,
  then the program exits. The handler is the hook for diagnostics machinery:
  error stats, trace dumps, last-registry-events, and similar.

In `continue` and `exit` modes the compiler prints a `SHORTCUTS (n)` report
on every build — same format as the `pending` report — listing each site
that relies on the global handler, so the shortcuts stay findable and can be
retired one by one. Shipping firmware is expected to build with
`[policy: strict]`.

The same rules cover `?T` absence. `?T` is a true option type: absence is a
first-class state (`ok | absent`), not a reserved error code. At runtime all
three wrappers share one tri-state representation — `ok | err(code) | absent`
— so `!?T` distinguishes failure from absence exactly, and error codes keep
the full 16-bit space.

---

## Part 5: Interfaces, Mixins, and the Catalog Model

### 5.1 The Three Buckets

Every Tuck codebase is organized into exactly three kinds of files:

**Domain Files** — the pure, boring truths of the system. Types, sum types, and
pure data transformations. No state mutation, no IO, no concept of the outside
world:

```tuck
# thermal.tuck
type ThermalState: Critical | Hot | Normal

fn classifyTemp({celsius: f32}) -> {state: ThermalState}:
  ...
```

**Mixin Files** — reusable behaviors that operate on domain data. Standalone
functions tagged with `mixin`, waiting to be snapped onto an object. No state of
their own:

```tuck
# retry.mixins.tuck
mixin withRetry:
  fn attempt({maxTries: int}) -> !{result: Self}: ...
```

**Manager Objects** — the assembly layer. Composes domain data with mixins.
Holds `var` state, wires data-flow pipelines. No complex logic permitted (enforced
by the complexity limit):

```tuck
# PodcastPlayer.tuck
object PodcastPlayer:
  + PodcastState
  + AudioOutput
  + withRetry
  + PersistentCache

  fn play({episode: Episode}) -> void:
    self ..loadEpisode ..startAudio
```

### 5.2 Interfaces

A contract: the set of functions a type promises to provide. The body is the
requirement list — an interface holds nothing else, so there is no `require:`
nesting.

```tuck
interface Storable:
  fn save({dest: Path}) -> !void [io]
  fn load({src: Path}) -> !Self [io]
```

An object declares conformance with a `satisfies` line in its body, alongside
the `+` composition lines it already carries. One object may satisfy several
interfaces:

```tuck
object Document:
  path: Path
  + Timestamped
  satisfies Storable

  fn save({dest: Path}) -> !void [io]:
    ...
  fn load({src: Path}) -> !Self [io]:
    ...
```

Conformance is checked at compile time. The rules:

- **Parameters and return type match exactly** — same names, same types, same
  order. Payload fields bind by name (Part 2), so a parameter's name is part of
  the contract, not decoration.
- **Effects may be a subset.** An implementation may do *less* than the contract
  permits — a pure `save` satisfies an `[io] save` — never more. This is the
  same direction as the caller/callee effect budget (Part 4).
- **`Self` means the implementing type.** In a required signature `-> !Self`
  reads as `-> !Document` for `Document`.

A missing or mismatched member is a compile error naming both signatures.

**Attaching a contract from outside.** A conformance may also be declared at
top level, by a module that owns neither the object nor the interface:

```tuck
satisfies Document: Storable
satisfies Image: Storable, Cacheable      # several at once
```

This is what lets a library's type be used through *your* interface without
editing the library. The rules above are unchanged — the object must still
implement every member, or it is a compile error. Re-stating a contract the
object already declares in its body is a no-op, not an error: a calling module
cannot know what the library already promised.

### 5.3 Interface Dispatch

An interface-typed value is a **copying tagged variant** over every type that
satisfies it, not a pointer to one — the same shape a sealed sum type (§4.4)
takes, generated instead of hand-written. A concrete object entering an
interface slot is *copied* into the variant, tag and all; the variant then
owns its data outright, the same as any other Tuck value (§7.1's Tier 1 rule
"no `ref`" stands unqualified — an interface value introduces no reference or
pointer, user-visible or otherwise).

```tuck
var animals = [dog, cat]      # Dog and Cat both satisfy Animal
for a in animals:
  a.makeNoise
```

At `[dog, cat]` the compiler knows each element's concrete type, so it copies
each one into an `Animal` variant carrying that type's tag. At `a.makeNoise`
it knows `a` is an `Animal`, so the call compiles to a `switch` on the tag,
one arm per satisfying type, each arm a direct (non-virtual) call to that
type's own `makeNoise`. There is no dispatch table, no thunk, and — because
every satisfying type is known at compile time, the set is closed, and a
`match`-style switch over it is exhaustive by construction — no lifetime
question: the copy is why. (An earlier design used a borrowing two-word
`{data, function-table}` pair instead, with escape-scope restrictions to keep
the borrow sound; that representation was dropped in favor of the copying
variant, and the restrictions along with it — see below.)

The variant does carry a tag, so dispatch is not literally "no runtime
information" the way a plain struct's is. What Tuck does not have is *open*
runtime type information: the tag distinguishes only the CLOSED set of types
declared to satisfy this one interface, resolved and validated entirely at
compile time. There is still no general type assertion, no type switch over
an arbitrary type, and no inheritance — those would need a type identity that
means something outside one interface's own closed variant, which nothing in
Tuck produces.

Because the value is copied, not borrowed, there is no escape-scope
restriction left to state: an interface-typed value may be a function
parameter, a local, an element of a collection, an object/actor field, or a
return type — anywhere an ordinary Tuck value may appear.

```tuck
var items = [doc, user, config]     # each satisfies Storable
for item in items:
  item.save {dest: backupPath}
```

Every element of a collection of an interface type is the same shape
regardless of which concrete type it holds (the tagged variant), which is
what makes the collection uniform. Mutating a satisfying type's own field
through a stored `+`-composed member still works exactly as it does anywhere
else in Tuck — it mutates the copy the interface value holds, same as passing
any other Tuck value ever does; there is no separate rule for interfaces.

### 5.4 The `pending` Block — Walking Skeleton

Allows an app to compile with typed holes so top-down design can proceed before
bottom-up implementation is finished:

```tuck
object PodcastApp:
  fn play({episode: Episode}): ...

  pending:
    fn fetchFeed({url: str}) -> !{feed: Feed}
    fn syncLocal({feed: Feed}) -> !void
```

Compiler flags control runtime behavior of `pending` functions: trap (default in
debug), return zero value (release stub), or log and continue.

---

## Part 6: Correctness Features

### 6.1 Decision Tables

Multi-condition dispatch that the compiler verifies for completeness and
non-ambiguity, then compiles to a bitmask lookup:

```tuck
decision classifyPacket({priority: u2, size: u12, encrypted: bool}) -> Action:
  | high  _     true  -> QueueSecure
  | high  _     false -> QueueFast
  | low   small _     -> QueueDefer
  | _     _     _     -> Drop
```

The compiler:
- Packs conditions into a `uint64` bitmask per row
- Verifies no gaps (unhandled input combinations)
- Verifies no overlaps (ambiguous rows)
- Emits a Nim `case` over a packed integer — zero branches at runtime

Large tables can be split into composed functions. One decision table calls another,
the compiler inlines and builds one combined bitmask table underneath:

```tuck
decision classifySize({bytes: u32}) -> SizeClass: ...

decision routePacket({priority: u2, encrypted: bool, bytes: u32}) -> Action:
  | high  true  Small  -> FastSecure
  | _     _     _      -> routePacket.fallback
```

### 6.2 Static Stack Depth Analysis

For non-recursive Tier 1 code, worst-case stack depth is computable statically.
Declare a budget on any function and the compiler verifies it:

```tuck
fn processISR({event: SensorEvent}) -> void [irq_safe, stack: 128]:
  ...
  # compiler verifies: this fn + all callees use ≤ 128 bytes of stack
```

Algorithm: DFS over the call graph in the IR, summing frame sizes. Recursive calls
are flagged — they are banned in Tier 1 anyway (unbounded stack). The result is a
certification-grade guarantee with zero runtime cost.

### 6.3 Complexity Limit — ruled, not yet enforced

The intent: a cyclomatic complexity limit of ≤ 5 and approximately 10–15
executable lines per `fn`, as a compile error rather than a linting
suggestion, so every function reads like pseudocode, fits in your head, and
is auditable for certification. It forces high-level architecture to remain
pure wiring diagrams.

**Status: not implemented.** `tuck check` measures nothing today and rejects
no program for being too complex, at any size. The ceiling is real only for
the *compiler's own Nim source*, where `tools/cc` measures it against a
budget in the test suite — that tool parses Nim, not Tuck, so it cannot be
pointed at user code as-is.

Until it lands, treat the limit as a convention the corpus follows rather
than a guarantee the compiler provides. When it does land it applies to
`fn` declarations; the ceiling for a `decision` table is its row count, which
the table's own exhaustiveness/overlap checking (§6.1) already bounds.

---

## Part 7: Memory

### 7.1 Tier Model

Tuck is one language everywhere, with strict boundaries:

- **Tier 1 (Application):** Stack-only. Named structs, actors, errors as types,
  no raw pointers, no `ref`, no heap. All structs are value types, copied across
  actor boundaries. The allocator problem doesn't exist.
- **Tier 2 (Library):** Same language + `ref`, `owned ref`, custom allocators,
  SIMD, `when` conditionals, bump and arena allocators.
- **Tier 3 (Systems):** Explicitly Nim. C FFI, MMIO, raw pointers, atomics. A
  concrete substrate, not a vague escape hatch.

### 7.2 Static Memory Pool

Fixed-size object pool. Known at compile time, zero fragmentation, O(1) acquire:

A pool is **N slots of an arbitrary type** — not necessarily an array. Byte
buffers are the embedded case; records are the §7.4 case (files, connections).

```tuck
pool UartBuffer  = Array[64, u8] [count: 8]   # 512 bytes, statically allocated
pool Connections = Connection    [count: 16]  # records pool the same way

let buf = UartBuffer.acquire     # ?Array[64, u8] — the pool may be exhausted
if not buf.ok:
  return
# ... use buf.value ...
UartBuffer.release {buf.value}
```

The declaration reuses the `X = <type> [attrs]` shape: the element type is
explicit, `count` fixes the number of slots. There is no `size` knob — the
footprint follows from the element type, and restating it would only drift.

`acquire` yields `?T`: exhaustion is absence, handled like any other optional.
There is no `or return` unwrap — `and`/`or`/`xor` are strictly boolean (a `?T`
in a boolean position reads as "is present", which is a test, not an unwrap).

`release` goes through the **pool**, not the value: `Pool.release {v}`. The
element may be a primitive (`Array[64, u8]` carries no methods), so a
`v.release` method form cannot work in general.

`count` is **required**. A pool without one has no static footprint, which is
the entire point of §7.2 — unlike §7.4's registry, whose `cap` is optional
because an uncapped table may legitimately grow. Exhaustion needs no
`on_full` policy either: it surfaces as absence, and the caller decides what
that means (retry, shed, log). That knowledge lives at the call site, not the
declaration.

`pool` is its own declaration form, like `registry` and `arena` — the name
denotes the *container*, not a value of the element type, so it cannot be a
type attribute (`Buf.acquire` yielding a `Buf` would be circular).

Internally: a bitmask + a static array. `acquire` is a bitmask scan. `release`
is a bit clear. Total footprint is verified against available memory at
compile time.

### 7.3 Arena Allocator

Bump-pointer allocator with a clear "frame" lifetime. Reset the whole arena in one
instruction:

```tuck
arena ScratchSpace [size: 2048]:
  let buf   = ScratchSpace.alloc Array[128, u8]
  let frame = ScratchSpace.alloc EthernetFrame
  # process...
  ScratchSpace.reset   # entire arena freed in one pointer assignment
```

Anything allocated from an arena cannot outlive the arena. The compiler enforces
this via scope analysis. No per-object free, no fragmentation, worst-case
allocation time is a pointer increment.

### 7.4 The Resource Registry

Scope-based RAII is the wrong model for OS resources. A hot loop that opens and
closes a file or socket per iteration thrashes on syscalls; the true mental
model is the one the OS itself uses — a global table of handles (the process fd
table). Tuck makes that table explicit: every acquired OS resource lives in a
global, per-kind registry inside the runtime. Nothing is ever lost, even under
GC; cleanup is policy, not accident.

**Declaration.** Resource *kinds* are user-declared, an open set — a UDP
library declares its own kind the same way a module declares its error enums:

```tuck
resources:
  net  [cap: 10_000, on_full: error, sweep_batch: 100]
  file [cap: 8, on_finish: flush]
  udp                     # no cap: unbounded, seq-backed
```

`cap` is optional. Without it the table grows (the OS ulimit is the real
bound); with it the declared `on_full` policy applies and standalone targets
back the table with a static array — the cap becomes a link-time memory
budget, and on hosted servers the explicit shed-load point (the
`worker_connections` knob, in the language). The cap is also the leak alarm:
a table that fills is a bug surfacing early, not an OOM three days in.

**Handles, not refs.** User code never holds the resource — it holds an opaque
handle: a plain value (slot index + generation counter), copyable, comparable,
Tier 1 safe (§7.1). The actual ref lives in the registry entry, in the runtime
layer, alongside its generation and an `isFinished` flag. A stale handle
(generation mismatch) is a caught runtime error,
never a write to the wrong file — the fd-reuse bug class is closed by
construction. Internally the registry is the pool machinery of §7.2: slot
array, occupancy bitmask, O(1) acquire and release.

**Acquire sites** are marked in the effects bracket, on extern signatures and
plain functions alike, and are declared exactly like effects (§3.7 —
explicit, not inferred; a fn returning a resource it did not finish must
declare the marker itself, same as any other effect):

```tuck
fn open(port: u16) -> UdpSocket! [io, resource: udp]
```

An unknown kind in `[resource: k]` is a compile error, same as an undeclared
error enum.

**`defer` is release intent, not release.** At scope end the defer block marks
the entry `isFinished: true`, runs the kind's `on_finish` action, and bumps the
generation — the handle dies *at mark time*, so use-after-defer is a caught
stale-handle error under every policy, and buggy code behaves identically in
all modes. Whether the OS handle actually closes there is the declared policy
(mirroring the `errors` declaration, §4.9):

- **strict** — close at scope end. Deterministic; the embedded/debug default.
- **lazy** — mark only. Finished entries are reclaimed by a sweep when the
  table passes a watermark (~75% of cap), on memory pressure, or at cap.
- **exit** — close-all only at program end.

**finish vs reclaim.** Marking and closing are split so durability never
depends on sweep timing: `on_finish` (per kind — `file: flush`, net:
shutdown, default: none) runs at mark time, always; reclaiming the fd itself
may be lazy. A write-heavy loop under lazy policy loses no data.

**Sweeping is inline — no thread, no background actor.** The trigger lives in
the defer-release code itself: setting `isFinished` also checks (in lazy mode)
whether the table has reached the watermark, and if so evicts synchronously
right there — all finished entries, or in user-specified batches
(`sweep_batch: 100`). So eviction happens mid-loop, deterministically, inside
the mark: a loop acquiring 10,000 times against a cap in the thousands never
blocks — each iteration's defer marks, and the marks themselves reclaim once
the threshold trips. Amortized, lock-free. An explicit `kind::sweep` call
exists for scheduled cleanup, and a dedicated sweeper actor is a possible
opt-in once actors land — never a requirement. Only finished entries are ever
reclaimed; there is no time-based eviction of live resources. Close-all (exit
or shutdown) runs in LIFO registration order:
files flush before their directories close, TLS shuts down before its socket.

**Static tracking.** The checker verifies scope-locally that every acquire
ends in exactly one of: a defer mark, or an escape into the registry (storing
or returning the handle). Escape is always sound — the registry guarantees
close-at-exit — so no whole-program alias analysis is needed; the global table
is the safety net that makes the local analysis sufficient. There is no
refcount: resources are single-owner, one bool. Debug builds print an
`OPEN RESOURCES (n)` report listing unfinished entries with their acquire
sites, in the same spirit as the PENDING and SHORTCUTS reports.

Both models coexist: `defer` for genuinely scoped lifetimes, the registry as
the safety net underneath everything.

---

## Part 8: Hardware

### 8.1 Register Declarations

Type-safe MMIO. The compiler knows which bits are readable, writable, or
read-with-side-effect:

```tuck
register RCC_CR at 0x40021000:
  HSION:   bit 0     [read, write]
  HSIRDY:  bit 1     [read]           # read-only — writing is a compile error
  HSITRIM: bits 3..7 [read, write]
```

`volatile` is implicit on all register fields. Writing to a read-only field is a
compile error. Reading a write-only field is a compile error.

Register declarations can be generated from vendor-supplied CMSIS-SVD files. One
SVD importer gives type-safe register access for the entire ARM Cortex-M ecosystem.

### 8.2 Compile-Time Size Assertions

```tuck
static_assert sizeof(MqttHeader)      == 2
static_assert alignof(DmaBuffer)      == 4
static_assert offsetof(EtherFrame, ethertype) == 12
```

`offsetof` is included because field-offset bugs in protocol implementations are
common and invisible without it.

### 8.3 `when` Conditionals

Compile-time platform selection. No preprocessor, no `#ifdef` soup: a
non-matching block's declarations do not merely fail to run, they are
dropped from the module before typecheck ever sees them — never checked,
never emitted, as if that block had not been written.

```tuck
when TARGET == "stm32f4":
  fn initClock() -> void: ...
when TARGET == "rp2040":
  fn initClock() -> void: ...
```

`TARGET` is set by `--target:NAME` on the `tuck` CLI (any command); resolved
at module load, before any other pass runs, so it applies uniformly whether
the module came from a fresh parse or the AST cache — the cache itself
stores `when` blocks unresolved, precisely so it stays correct across runs
that pass different `--target:` values rather than serving one run's
resolved tree to a differently-targeted one. With no `--target:` given, every
`when` block is dropped (fails closed, rather than guessing a default
platform). v1 supports exactly the shape shown — `TARGET` compared against
one string literal — not a general compile-time boolean expression; there is
no `elif`/`else` form.

---

## Part 9: Concurrency

**Runtime note, read before either subsection below.** An earlier draft of
this spec targeted *stackless* coroutines — a compiler transform turning each
`[io]` yield point into a state-machine variant, with no per-task stack at
all. That approach was deliberately abandoned: hand-rolled stackless state
machines (and the nim-cps alternative) were tried and dropped in favor of
**stackful coroutines over a single, vendored C library (minicoro)**, shared
identically by both backends, so the two cannot diverge on switch semantics
the way two independent hand-written transforms eventually would. Each task
or actor gets a real coroutine with its own stack; `[io]` calls yield by an
actual stack switch (`mco_yield`/`mco_resume`), not a compiler-synthesized
state enum. Stacks are `mmap`-reserved virtual memory (a large nominal size,
e.g. 1MB) rather than `calloc`'d — physical RAM is only committed for the
pages a coroutine actually touches, so many idle coroutines are cheap even
though each nominally "has" a big stack.

**This makes the concurrency runtime a Tier 3 (§7.1) capability today, not a
Tier 1 one**: `mmap` and the epoll/kqueue-based reactor that drives I/O
readiness both assume a hosted OS. A bare-metal Cortex-M0 target has neither.
Actors and tasks as specified below are real, both-backends-verified, and
run-gated by the test suite — but they currently target Linux/macOS/Windows,
not the bare-metal case Part 1 frames as a primary use case. A stackless,
truly Tier-1-safe concurrency path is not designed; if the embedded story
needs one, it is separate future work, not a mode of what is built today.

### 9.1 Actors

Long-lived isolated state machines, one instance per declared type (a
singleton — there is no separate construction step, no reference to hold).
Each runs on its own coroutine (see the runtime note above) with a static
ring-buffer mailbox:

```tuck
actor UartDriver [queue: 8]:
  txBuf: Array[256, u8]

  on send({data: Seq[u8]}) -> void:
    txBuf.copyFrom {data}
    uart.flush {txBuf} [io]     # [io] → implicit yield, others can run

  on select:
    | timer.1s   -> {}:  self.heartbeat
    | shutdown   -> {}:  return    # only way to exit
```

Only value types (copied) cross actor boundaries. No reference sharing across
boundaries. Queue (mailbox) size is a compile-time constant — the ring buffer
is sized to it exactly, so a full mailbox is a fixed, known capacity, not an
unbounded allocation.

### 9.2 Tasks

Async operations with a defined completion. `[io]`-annotated function calls are
implicit yield points — no `await` keyword, no explicit `yield`. The effect system
IS the yield annotation:

```tuck
task fetchFeed({url: str}) -> !{feed: Feed}:
  let resp = http.get {url}    # [io] → compiler inserts yield here
  resp.body parse              # pure → runs immediately, no yield
```

Calling a task **spawns** it onto its own coroutine (runtime note above) — the
call returns immediately, and the caller does not suspend at the call site
itself; binding the task's result (`let r = {...} fetchFeed`) is what awaits
completion, and only there does the caller yield if the task has not finished.
A task's effects do not propagate to its caller (contrast §3.7's ordinary
call rule) — spawning decouples them, exactly because they now run on a
different coroutine on the caller's behalf rather than inline in its own body.

### 9.3 `on select` — Waiting on Multiple Events

Identical syntax in both actors and tasks. A one-shot branch in tasks, a looping
branch in actors:

```tuck
task handleConn({conn: Connection}) -> !void:
  on select:
    | conn.recv   -> {msg}:  msg.process
    | timeout.5s  -> {}:     conn.keepalive
    | shutdown    -> {}:     return
```

### 9.4 The Scheduler

The entire Tuck scheduler is cooperative. Tasks and actors are items in a ready
queue. Each gets one `resume` call per tick — a coroutine switch onto that
task's or actor's own stack (see the runtime note opening this Part) — runs
until its next `[io]` yield point, then re-enqueues or parks waiting for a
waker. An epoll/kqueue-based reactor drives readiness for parked I/O waits.
No preemption, no kernel context switches. Each task and actor does have its
own coroutine stack (the runtime note above covers why that is cheap in
practice, not absent).

---

## Part 10: The Event Registry

One global per application. The entire event surface of the system is declared in
one place. No dynamic subscriptions, no cascading, no invisible control flow:

```tuck
registry AppEvents:
  | SensorFailure({port: u8, reason: str})
  | LowMemory({remaining: u32})
  | WatchdogWarning
  | UartOverflow({dropped: u16})
```

**Three operations:**

```tuck
# Raise — signal an event from anywhere
AppEvents.raise SensorFailure {port: 1, reason: "timeout"}

# Handle — declare the one handler for an event, in a manager or actor
on AppEvents.SensorFailure({port, reason}):
  log.warn "sensor {port} failed"
  monitors[port].restart

# Query — poll current state
if AppEvents.latest is LowMemory:
  caches.flush
```

**Compiler guarantees:**
- Every event variant must have at least one handler — an unhandled event type is
  a compile error
- Multiple handlers for the same event are permitted and called in declaration
  order, which is deterministic and visible in the source
- A handler may not raise the same event it handles — trivial infinite loop,
  detected as a cycle at compile time
- `raise` only accepts variants declared in the registry — typos are compile errors
- The entire event surface is visible by reading two things: the `registry`
  declaration and the `on AppEvents.X` handlers

At runtime the registry is a small static array of slots, one per variant, holding
the last payload. `raise` writes the slot and calls all registered handlers in
declaration order, synchronously. No queues, no dynamic allocation, no cascading
to other event types. Each handler returns, the raiser continues.

---

## Part 11: Compiler Architecture

*This Part describes the compiler that was actually built, not the one an
earlier draft of this spec planned. The two differ on purpose, not by
drift: npeg, a flat index-based IR, and a Merkle-hashed cache were the
original design; a hand-rolled recursive-descent parser, a tree-shaped AST,
and a simpler build-stamp-and-source-hash cache are what was built instead,
and that outcome is preferred, not a compromise to fix later. This Part was
rewritten 2026-08 to match reality; treat anything below as a description of
the real compiler.*

### 11.1 Pipeline

```
Source File
  → Lexer (hand-rolled) — text to tokens
  → Parser (hand-rolled, recursive descent) — tokens to a tree-shaped AST
  → Rewrite — unconditional, type-free tree normalization (what a
    construct MEANS: e.g. `5.ms` sugar, `elif` as sugar for nested `else`/`if`)
  → Module loading — import closure, msgpack AST cache + signature index,
    `when TARGET` resolution (§8.3)
  → Typecheck — bidirectional (synthesize/check), two passes per module:
    signature collection, then per-declaration body checking; fails fast
  → Semantics — the effect audit (§3.7): every performed effect must be
    declared, checked bottom-up per declaration
  → Mangling — whole-program, once: user names get a backend-collision-proof
    prefix, before any backend-specific work begins
  → Lowering — per backend (each gets its own copy of the checked tree):
    rewrites constructs that are pleasant to WRITE into ones that are easy
    to EMIT (e.g. a registry raise becomes an ordinary call)
  → Emitter — codegen.nim (Nim) / codegen_odin.nim (Odin): walks the tree,
    concatenates target-language source text directly, no separate IR
  → Nim or Odin compiler → Binary
```

### 11.2 The AST

A tree of `ref object` nodes (`compiler/ast.nim`'s `Decl` and `Expr`), not a
flat, index-based structure — pointer-linked, the ordinary shape a
recursive-descent parser naturally builds. Both are Nim `case object`
variants keyed by a kind enum (`DeclKind`, `ExprKind`), so the same
exhaustiveness guarantee an index-based IR would have given still holds:
adding a new kind forces every unhandled `case` in the compiler to become a
compile error, at every later stage — typecheck, semantics, lowering, both
emitters.

```nim
type DeclKind* = enum
  dkType, dkObject, dkRegistry, dkPool, dkFn, dkMixin, dkExtern, dkPending,
  dkActor, dkTask, dkExpr, dkConst, dkRegister, dkStaticAssert, dkErrors,
  dkImport, dkSelect, dkFnSig, dkSatisfies, dkInterface, dkWhen
  # (representative, not exhaustive — the real enum grows as the language does)

type ExprKind* = enum
  exkVar, exkLit, exkStruct, exkCall, exkField, exkChain, exkAssign,
  exkIf, exkMatch, exkFor, exkBinary, exkUnary, exkReturn, exkRaise,
  exkSend, exkSelect
  # (representative, not exhaustive)
```

### 11.3 Signature Collection

One linear scan over each module's top-level declarations (`collectSigs`),
before any function body is checked. Builds the tables later checking reads:

- function/task signatures, keyed by name (and by `module::name` for
  qualified calls)
- type field sets, for subset matching (§2.5)
- sealed-type transition adjacency, for static transition checking (§4.4b)

Return types are explicit on all signatures. This is what seeds the scan
with enough information to resolve mutual recursion without forward
declarations — two mutually recursive functions are both in the signature
table before either body is checked.

### 11.4 Body Checking

For each declaration, in source order:

- Resolve every call: subset/whole-bind matching (§2.5) against the
  signature table built above
- Check `match` exhaustiveness over closed domains (sum types, `bool`,
  error enums)
- Check `..` only on `var` bindings (§2.3)
- Check effect markers: every performed effect must be in the declaring
  function's own declared budget (§3.7 — explicit, not inferred)

For each sealed type: verify every match arm and every tracked reassignment
only produces transition-graph-reachable variants (§4.4b).

For each decision table: build the packed-key table, check coverage and
overlaps (§6.1).

**Error handling: fails fast.** The first error in a declaration stops the
check and is reported with its file:line:col; the compiler does not attempt
to collect every error across the whole file in one run.

### 11.5 The Cache

Two caches, doing different jobs, both under `<dir>/.tuck-cache/`:

1. **The AST cache** (`<name>.bin`) — an entire parsed-and-rewritten `Module`,
   msgpack-serialized. Keyed on (compiler build stamp, source hash): a
   recompiled compiler or an edited source invalidates the entry, which then
   falls back to a fresh parse. Skips lexing and parsing for an unchanged
   import.
2. **The signature index** (`index.bin`) — just the exported signatures a
   module needed the LAST time the whole program checked clean, plus the
   source hash of each dependency at that time. An import is trusted from
   here — no AST load, no re-typechecking its body — only if its own source
   is unchanged AND every dependency it names is *itself* still valid,
   checked recursively; a changed dependency anywhere in the chain falls
   back to loading that import in full. `tuck check` reads this and, when it
   hits, never walks the interior of an imported module at all; `tuck
   build`/`compile` always need real bodies (to emit code for them), so this
   index is `check`'s accelerator specifically, not a build cache.

Both caches are best-effort: a stamp mismatch, a hash mismatch, or a
truncated/unreadable file all fall back to a fresh parse or a full reload
rather than trusting stale data.

### 11.6 The Emitter

Two emitters — `codegen.nim` (Nim) and `codegen_odin.nim` (Odin), sharing
helpers via `codegen_common.nim` — each a `case` statement over the real AST's
kind enums (§11.2) that concatenates target-language source strings directly.
Neither builds a Nim or Odin AST of its own; by the time a tree reaches here,
every hard question (types, effects, names, sealed transitions, decision
coverage) has already been answered by earlier stages, so what is left is
transcription.

A few constructs worth naming because they lower to more than a literal
transcription:
- a decision table → a target-language `case`/`switch` over a packed integer
- an actor → a mailbox struct (a static ring buffer) plus handler procs
  dispatched by message tag; both backends run actors and tasks on their own
  coroutine, over the same vendored C library (minicoro) — see Part 9's
  runtime note for why, and why that currently makes concurrency a Tier 3
  (§7.1) capability rather than a Tier 1 one
- a register declaration → `volatile` field access with inline endian swap
  where `[big_endian]` is declared

### 11.7 Bidirectional Typing

Two functions, mutually recursive:

- `check(expr, expectedType)` — push a known type down into an expression
- `synthesize(expr)` — pull an unknown type up from an expression

Return types on signatures make this tractable. Genuine cycles (where no annotation
exists to seed inference) are compile errors with a clear message asking for an
explicit return type annotation. In practice this is rare — Tuck's explicit
signature style means the annotation is almost always already there.

### 11.8 Performance Targets

- < 100ms single file
- < 500ms full project rebuild (cache cold)
- < 10ms incremental (cache warm, one function changed)
- LSP integration from day one — the checker produces source-span-tagged errors,
  which is all an LSP needs

---

## Part 12: Grammar Sketch

A descriptive sketch of the syntax the parser accepts, in PEG-like notation
(`<-`, `*`, `?`, `+`, alternation) for readability — it does not name or
imply a particular parsing technology. The real parser (Part 11) is a
hand-rolled recursive descent, not a grammar compiled by a parser-generator
library; this section describes the LANGUAGE it accepts, not how that parser
is implemented.

Key rules:

```nim
# Indentation — INDENT/DEDENT tokens emitted by the hand-rolled tokenizer
# Tabs banned at the tokenizer level — hard error

# Identifiers
loIdent <- >(Alpha | '_') * *(Alnum | '_')   # foo_bar
upIdent <- >Upper * *(Alnum | '_')            # FooBar

# Type expressions
baseType  <- ("!?" * typeExpr) | ("!" * typeExpr) | ("?" * typeExpr)
           | upIdent | structType
typeExpr  <- baseType * *("+" * baseType)    # T + U + V
typeAttrs <- "[" * attrList * "]"            # [packed, align: 4]

# Struct literals
structLit <- "{" * *((loIdent * ":" * expr | loIdent) * ?",") * "}"

# Expressions — infix only inside function bodies
primary   <- literal | structLit | "(" * expr * ")" | loIdent | upIdent
postfixOp <- (".." * loIdent * ?structLit)   # mutation
           | ("."  * loIdent)                    # field access
           | ("[" * expr * "]")              # index
           | ("?" | "!" | "?!")                 # postfix type wrappers (type position)
           | ("::" * loIdent)                   # function ref
postfix   <- primary * *postfixOp
app       <- postfix +                        # implicit whitespace invocation
expr      <- app * *(infixOp * app)           # infix in bodies

# Function signatures — return type always required
fnSig   <- "fn" * >loIdent * "(" * *param * ")" * "->" * >typeExpr
         * ?("[" * >effectList * "]")

# Sum types with optional transitions
typeDecl <- "type" * >upIdent * ?typeAttrs * ":" * nl
          * +sumVariant * ?transitions

# Sealed transitions
transitions  <- "transitions" * ":" * nl * +transitionRow
transitionRow <- >upIdent * "->" * >upIdent * nl

# Decision tables
decisionDecl <- "decision" * >loIdent * "(" * structType * ")" * "->" * typeExpr
              * ":" * nl * +decisionRow
decisionRow  <- "|" * +(expr) * "->" * expr * nl

# Actors and tasks — same on/select syntax
actor  <- "actor" * >upIdent * ?typeAttrs * ":" * nl * +(varDecl | onHandler)
task   <- "task"  * >loIdent * "(" * *param * ")" * "->" * typeExpr * ":" * block
onHandler <- "on" * (loIdent * ?structType * ?("->" * typeExpr) * ":" * block
           | "select" * ":" * nl * +selectArm)
selectArm <- "|" * expr * "->" * structLit * ":" * stmt * nl

# Event registry
registry <- "registry" * >upIdent * ":" * nl * +sumVariant

# Interfaces (§5.2) — the body IS the requirement list; sigs carry no body.
# `satisfies` is an object-body line, like the `+` composition lines.
ifaceDecl <- "interface" * >upIdent * ":" * nl * indent * +fnSig * dedent
satisfies <- "satisfies" * >upIdent * nl

# ...and a top-level form, for attaching an object you did not declare to a
# contract you did not declare. Keyword first, like every other declaration.
satisfiesDecl <- "satisfies" * >upIdent * ":" * >upIdent * *("," * >upIdent) * nl

# Compile-time platform selection (§8.3) — v1 supports exactly this one
# condition shape, not a general compile-time boolean expression.
whenDecl <- "when" * "TARGET" * "==" * stringLit * ":" * nl * indent
          * +topDecl * dedent

# Top level — DECLARATIONS ONLY (§2.3b). No let/var/bare-expression
# statement ever appears here; the runnable program is `fn main`.
topDecl <- fnDecl | typeDecl | objDecl | mixinDecl | ifaceDecl
         | actorDecl | taskDecl | registryDecl | decisionDecl
         | satisfiesDecl | whenDecl
```

---

## Appendix A: Open Questions

Items deferred, not forgotten:

1. **Generics / parametric types** — v1 implemented (2026-07-11): simple
   substitution, Nim/C# style — no variance, no HKTs, no constraints.
   `fn identity[T]({x: T}) -> T`, `type Box[T] = {value: T}`; type params are
   Uppercase idents, inferred at call sites from the payload (no explicit
   call-site type args), lowered verbatim to Nim generics (Nim monomorphizes).
   Remaining: direct construction of generic records (`{value: 5} Box` —
   checker error v1), constraints, explicit instantiation syntax.
2. **Module system** — how files import each other, visibility rules.
3. **SVD importer** — tooling to generate register declarations from vendor XML.
4. **Deferred logging** (`defmt`-style) — format-string-ID protocol. Specified as
   a standard library mixin, not a language feature.
5. **Protocol state machines on message sequences** — valid ordering of messages,
   not just valid message shapes. Post-v1.
6. **LSP protocol** — error format, incremental re-check triggers.
7. **Resource registry details (§7.4)** — handle sharing across actors
   (likely ownership transfer, not refcount — deferred to actor design);
   sweep scheduling beyond acquire-time watermark + explicit `kind::sweep`.
8. **Explicit numeric-conversion sigils** — ruled (not yet implemented):
   `~T` marks a conversion that may lose precision, range, or meaning
   (narrowing, signed↔unsigned at any width, float↔int); `^T` marks one that
   provably cannot. A lossy conversion without `~` would be a compile error,
   not a warning — today `compatible()` still lets any numeric type match any
   other, which is the gap this closes. Declared types never auto-widen
   either way (`u8 + u8` stays `u8`); this is additive to, not a
   replacement for, the overflow-mode attributes in §4.1.

---

## Appendix B: What Tuck Does Not Have

These are deliberate omissions, not oversights:

- Null / nil
- Exceptions
- Inheritance
- Vtables (dispatch is a compile-time switch over a closed tagged variant —
  §5.3 — not an indirect call through a table)
- *Open* runtime type information — an interface value's tag distinguishes
  only the closed set of types satisfying that one interface, resolved at
  compile time; nothing can ask an arbitrary "what is this really?"
- Type assertions / general type switches (they would need the above)
- Interface default methods (an interface is requirements only)
- `self` keyword
- Forward declarations
- Preprocessor / macros
- Implicit conversions
- Global mutable state (except the one declared `registry`)
- Heap allocation in Tier 1
- Recursion in Tier 1
- Preemptive scheduling

---

*End of specification.*
