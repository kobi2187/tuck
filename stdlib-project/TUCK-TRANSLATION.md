# Translating the design corpus into real Tuck

Every `API.md`/`API.nim.md` pair in this project was brainstormed by someone
who hadn't seen Tuck yet, scoped to *functionality*, not idiom (per direct
guidance). This file records what actually happened translating a first
slice of it into real, compiler-verified Tuck — read this before adding
another `API.tuck.md`, so the same ground isn't re-derived per module.

**Method.** Read `LANGUAGE-OVERVIEW.md` in full (especially §0, "what will
surprise you"), the relevant `tuck-spec.md` sections, every real module
under `std/` (the actual, if sparse, implemented stdlib — treated as a style
sample, not authoritative, per direct guidance: it's slices/spikes, not the
target), and the run-verified `examples/*.tuck`. Every claim below was
checked against the real compiler (`./tuck ch`) in the scratchpad, not
assumed from the docs alone.

**See also `FRICTIONS.md`** — the compiler-facing findings from this pass
(parse gaps, unchecked cases, and error messages that describe the
parser's problem rather than the author's), collected in one place with
verbatim error text and reproductions.

## `pending` is the mechanism for this whole corpus

`pending:` — "declared, but not yet implemented; the compiler prints a TODO
list and runs a stub" (spec §5.4, `examples/01-data-flow.tuck`) — is
functionally what every signature-only `API.nim.md` file already is. It
works at top level and inside `object` (both verified). **It does not yet
work inside `actor`** — the parser rejects `pending:` there
(`Expected 'Fn' here, found 'on'`) — per direct guidance, that's a planned
gap, not a blocker: actor-shaped modules below use real `on` handlers with
placeholder bodies instead.

## No operator overloading

Nothing in the spec, tests, or examples defines a custom `+`/`-`/`*` for a
user type — `5.ms` is an ordinary postfix call, not operator sugar (spec
explicitly: "no unit magic in the compiler"). Every Nim design that used
`func \`+\`*(a, b: Vec2): Vec2` becomes a named verb (`vAdd`) called through
the normal postfix/dot convention. This is not a workaround; it matches
Tuck's own stated idiom.

## Callbacks: a "closure" is a baked record, and it beats the Nim design

Tuck has no captured environment, and doesn't need one. `fnsig` names a
signature; a **declared record type** gives a field that signature as its
type; `bake` fills slots at compile time — fn references *and* argument
values, progressively (`x bake {op: :plus}` then `bake {b: 2}`); `invoke`
runs it. The function body reads the **record's own fields** — never the
enclosing function's locals — so everything it uses was put there
explicitly. Slots emit as generic params, so a call through a baked slot is
direct: no boxing, no runtime dispatch, no allocation
(`examples/03-functions-bake.tuck`, run-gated 42).

**`bake` is not mandatory — the ordinary call site just passes `:fnRef`.**
The parameter is already typed by the receiving function's own signature,
so no wrapper record is needed:

```tuck
fn keep({items: Seq[int], test: Predicate}) -> Seq[int]

let live = readings.keep {test: :isPositive}          # postfix
let live2 = {items: readings, test: :isPositive} keep  # payload-prefix, same call
```

**Reach for `bake` when the context is reused** — pre-fill the operation
once and call it repeatedly, or pass the filled record around. Then the
record needs a declared type, because **`bake` matches the signature
declared on that record's slot** rather than accepting any fn reference:

```tuck
fnsig Predicate = {x: int} -> bool
type Query = {items: Seq[int], test: Predicate}

let q = {items: readings} Query bake {test: :isPositive}   # slot typed by Query
```

⚠️ **The checker does not enforce this yet — verified, and it is a gap, not
a subtlety.** Storing a plainly wrong fn into a typed slot is accepted
today: with `type Query = {items: Seq[int], test: Predicate}` and
`fn wrongShape({a: str}) -> str`, both
`{items: [1,2,3], test: :wrongShape} Query` and
`{items: [1,2,3]} bake {test: :wrongShape}` typecheck `OK`.
`tests/suites/typecheck.nim:1805` tests that *calling through* a fnsig slot
checks arity, but nothing tests that *storing into* one checks the
signature. Write the declared-type form above regardless — it is the
intended semantics; the checker will catch up.

**This reverses the Nim pass's single biggest structural concession.** That
pass recorded closure iterators as *"the single biggest structural
divergence from the Rust original"* — adapters had to become inline
iterators that couldn't be stored in a variable or returned. A baked Tuck
adapter is an ordinary record: storable, passable, returnable, holdable in
a field, and still free at runtime. Tuck lands closer to the original Rust
design than the Nim pilot could.

Applies to every callback-shaped API in the corpus: `core.iter`'s adapters,
`core.cmp::by`, `core.array::built`/`mapped`, `alloc.map::retain`,
`std.testing`'s predicates, `sys.fs`'s walk filters.

**Known gap, assume it will be fixed:** a *generic* `fnsig`
(`fnsig Mapper[T, U] = {x: T} -> U`) does not parse yet — `fnsig` has no
type-parameter slot. Filed in `LANGUAGE-OVERVIEW.md` §13. Modules are
written with the generic spelling as intended, with the concrete-type
version compiled as proof of shape. Do **not** work around it by writing
bare unbound `T`/`U` in a non-generic `fnsig`: that appears to typecheck
only because gradual typing reads them as `Unknown`, which is the §0 trap
where sketch code and a destroyed tree look identical.

## The `core` tier shrinks by about a third, and the reason is structural

Five of seventeen `core` modules turned out not to translate at all:
`slice`, `ptr`, `atomic`, `sync-cell`, and most of `mem`. Not for five
separate reasons — for one:

**Rust's and Nim's `core` tiers are substantially about handling references
safely. Tuck's Tier 1 deletes references.** No `ref`, no stored pointers
(196-line negative suite), messages copied across actor boundaries, no
borrow checker — *"not because those problems were solved, but because they
were never expressible."* A borrowed view (`slice`), a raw address (`ptr`),
a shared mutable cell (`sync-cell`), and a tear-free shared counter
(`atomic`) are all vocabulary for the sentence Tuck refuses to let you say.

Three more dissolved into language features rather than being deleted:

- `types::Option[T]` → built-in `?T`
- `mem::Unfilled[T]` → the `<uninit>` checker marker (its own test suite)
- `num`'s `Clamped`/`Wrapped` families → `[saturating]`/`[wrapping]` type
  attributes

**So the tier that was hardest to design in Rust/Nim is the one Tuck mostly
supplies itself.** What remains in `core` is the genuinely computational
part: `str`, `iter`, `cmp`, `fmt`, `hash`, `num`'s bitset half, `geom`,
`array`, and `convert`'s parsing.

Two real gaps survive the shrink and are *not* absorbed anywhere — worth
tracking rather than celebrating the deletions:

1. **Secret scrubbing** (`mem::Scrubbed[T]`, zero-on-drop with an
   optimizer barrier) has no Tuck answer — no destructor hook, no scope-exit
   action. Interacts with `alloc.allocator`'s `Secret[T]`.
2. **ISR ↔ main-loop shared state** (`atomic`'s embedded half). Hardware
   preempts regardless of what the cooperative scheduler or the type system
   can express, so "no `ref` in Tier 1" does not cover it. Belongs to
   `platform.interrupt`.

## The `alloc` tier: half dissolves, and the survivors are the real work

Same pattern as `core`, sharper. Of ten modules:

**Dissolved into language features (4):** `allocator` (→ `pool`/`arena`
declarations), `vec` (→ built-in `Seq[T]`), `string` (→ built-in `str`),
`fmt` (→ `core.fmt`, since the owned/borrowed text split doesn't exist).

**Dissolved because Tier 1 has no references (3):** `box` (`Owned[T]`),
`rc` (`Shared[T]`/`Watcher[T]`), `list` (`Chain[T]` — already rejected in
the Nim design, and now unwritable).

**Genuinely new surface Tuck lacks entirely (3):** `map`, `set`, `deque`.
These are the tier's real content — Tuck has **no map, no set, no deque**,
confirmed by grep across the spec and every real `std/*.tuck`.

Three findings worth carrying:

1. **Hashing primitives is a confirmed blocker for `map`/`set`.** Top-level
   `satisfies` attaches *declared objects* to contracts, not built-ins:
   `satisfies int: Hashable` → *"names 'int', which is not a declared
   object in scope"*. `Table[str, V]` is the most common map there is, so
   this needs a decision (built-in conformance, extend `satisfies`, or a
   `fnsig` hash slot) before either module is implemented.
2. **Recursive types have no expression in Tuck**, surfaced by `box` and
   `list`. Bigger than containers: JSON documents, schema trees, ASTs and
   filesystem hierarchies are all recursive. The corpus's own workaround is
   indexing into a flat `Seq`, which is idiomatic in an arena world and
   often faster — but it's currently forced rather than chosen. Needs a
   ruling, and it lands on `std.encoding` and `std.reflect` next.
3. **`pool` deserves to back `deque`.** `examples/25`'s argument (a count is
   a real-world fact; exhaustion is backpressure, not an error) fits work
   queues and sliding windows exactly, and `acquire` returning `?T` gives
   an honest bounded-queue story for free.

## The `sys` tier: the handle convention, and two modules with real code

Of thirteen modules, **six translate cleanly**, **five dissolve**, and
**two already exist as working code**.

**The convention that emerged:** every OS resource is a plain `fd: int` /
`pid: int` handle, not an object. Set by the real `std/net.tuck`
(`{fd: sock, max: 4096} recv`), matched by `sys.fs` and `sys.process`. It
also sidesteps the opaque-handle storage rule, since an integer descriptor
is an ordinary value.

**Already real, so these are diffs not translations:** `sys.time`
(`std/time.tuck` — has the distinct duration units and `5.ms`; missing the
`Instant`/`Timestamp` split, which matters and is cheap to add) and
`sys.net` (`std/net.tuck` — has TCP over the reactor; missing UDP, Unix
sockets, half-close, and `recv` returns `str` where binary protocols want
`Seq[u8]`).

**Dissolved (5):**
- `ffi` → the `extern` block, in four flavours. The cleanest such case in
  the corpus: nothing lost, and Tuck's version is more capable than Nim's.
- `thread`, `sync` → `task`/`actor`/scheduler. No user-facing OS threads
  exist ("no preemption, no OS threads in the scheduler"); the one other
  thread is an internal offload worker for blocking externs.
- `mmap`, `dynload` → blocked on the pointer rules rather than absent.

**Three capability regressions worth naming, not burying:**

1. **No CPU parallelism.** One cooperative scheduler on one thread means
   compute-bound work cannot use more than one core. I/O concurrency is
   fully served (reactor + offload, measured: 32 connections in 108ms);
   CPU parallelism is not served at all, and `std.async`'s round-3
   executor decision ("bounded M:N work-stealing pool, N OS workers") has
   to be revisited against this.
2. **No zero-copy file scanning.** `sys.mmap`'s entire product was
   returning a borrowed `View[byte]`; without views it returns a copy, and
   `log-grep`/`mp3-player` lose what they came for. This is where the
   no-borrowed-views choice costs the most.
3. **No runtime symbol loading.** `dlopen` is fine (opaque handle), but
   `dlsym` can't produce anything callable — `fnsig` slots are filled by
   compile-time `:name` references and mangled whole-program. Plugin
   architectures need a different mechanism entirely.

## Container mutators: use `..` at the call site

Value semantics means a container "mutator" returns the new container. The
call site should **not** rebind by hand — Tuck's `..` operator is exactly
this, and it is the idiomatic spelling (`server ..withDefaults ..port {8080}`
is the same pattern):

```tuck
var xs = [1, 2, 3]
xs ..push {value: 4}          # not: xs = {items: xs, value: 4} push
```

Verified: it typechecks and lowers to `xs = tuck_push(xs, 4)`.

⚠️ **Open codegen question affecting every `alloc` container module.**
`Seq` currently emits as a plain Nim value parameter and return
(`proc tuck_addOne*(items: seq[int], value: int): seq[int]` — no `var`, no
`sink`), so today an append loop copies and is O(n²). That would hit
`alloc.vec`, `alloc.string`, `alloc.deque`, `alloc.map` and `alloc.set`
alike.

**How `Seq` crosses a call boundary is Tuck's own decision** — the emitted
shape today is not a settled semantic, and the Nim/Rust stdlib vision's
answer doesn't carry over. The fix, if wanted, is in lowering (emit an
in-place mutation for `..` on an owned `var`, or pass/return by move), not
in the API: the `..` spelling above is already right either way. Worth
benchmarking before the tier is committed — `benches/` exists for this.

## Naming: Ruby, not Haskell

`bake` and `:fnRef` make functional idioms cheap in Tuck — which makes it
worth stating what the library deliberately does *not* do with them. The
target feeling is **Ruby**: plain verbs a person says out loud. Explicitly
not OCaml/F#/Haskell.

**Use:** `map`, `filter`, `reject`, `find`, `each`, `count`, `sum`,
`first`/`last`, `has`, `sortBy`, `groupBy`.

**Factor supplies the short-word half of the vocabulary**, which fits: this
project already studied concatenative style (`PROTOCOLS.md`) and
`examples/03` calls `bake` "Factor-style fry." What's worth taking is
Factor's *word choice* — short, concrete, naming the result rather than the
algebra — not its stack mechanics. All verified to parse as Tuck
identifiers:

| Instead of | Use | Why |
|---|---|---|
| `flatten` / `flatMap` | `concat` | Factor's word; shorter, and `flatMap` is on the banned list anyway |
| `followedBy` | `append` / `prepend` | the Nim pass's compound name says less than the plain verb |
| `firstN` / `skipN` | `take` / `skip` | the `N` was noise |
| `anyOf` / `allOf` | `any` / `all` | both parse bare; Factor spells these `any?`/`all?`, but `?` is Tuck's optional marker so the suffix is dropped |
| `countOf` | `count` | same |
| `forEach` | `each` | Factor and Ruby agree |

Deliberately **not** taken: `dip`, `keep`, `bi`, `tri` and the rest of the
stack shufflers — those are the part `PROTOCOLS.md` already rejected ("the
stack is merely how Forth obtains them, and is the one part that taxes the
reader").

**The general rule this gives:** prefer the shortest concrete word that
names the result. It also cuts against several long compound names the Nim
pass produced — `orCompute`, `breakTiesWith`, `pairedWith`,
`tryToNarrower` — which should shorten on the same principle as they're
translated.

**Avoid:** `foldl`/`foldr` (say `reduce`), `bind`/`flatMap`, `lift`/`pure`/
`unit`, `compose`/`pipe` as named combinators, and `Functor`/`Monoid`/
`Traversable`-style interface names. Point-free style is not an idiom here.
Custom operators don't exist in Tuck anyway, so operator soup was never
available.

**This overrides one Nim-pass rename.** That pass changed `filter` → `keep`
library-wide ("one word means one thing"). Ruled: `map` and `filter` are
too widely understood to rename — Nim, Factor and Ruby all use them — so
they come back, with `reject` as `filter`'s negation (Ruby's own pairing).
Where `keep` still appears in an `API.nim.md`, `filter` is the Tuck
spelling.

**The subtler version of the same rule:** don't build a lazy pipeline type
just because `bake` makes it affordable. `readings.filter {test: :isPositive}`
returning a plain `Seq` is the human shape; a chained lazy-adapter that
must be forced with `.collect` is the Haskell shape. The Nim pass needed
fused iterators out of necessity (its closures allocated); Tuck doesn't, so
the eager version wins — with allocation visible in the return type, per
the "no *hidden* allocation" ruling.

## Interface conformance is explicit — and retroactive

`satisfies` works as a **top-level declaration**, not only inside the
object body: `satisfies Dog: Speaker, Mover` attaches a type to a contract
from the *calling* module, without editing the type
(`tests/suites/interfaces.nim:247`, run-verified 42). Re-stating a contract
the object already declares is a documented no-op, not an error.

So explicit conformance costs the stdlib nothing in reusability: a library
type can be attached to a contract it never heard of — the capability Rust
gets from trait impls — while still refusing *accidental* structural
conformance the way Nim concepts cannot.

## Value semantics forces "return the new value," not "mutate in place"

A callee cannot write through a parameter (`TK-TY15`). Every Nim design with
an in-place mutator (`proc adjust(c: var Counter, delta: int)`) becomes
"takes the old value, returns the new one" (`c = {c, delta: 1} adjust`, not
`c.adjust(1)`). This is the concrete shape of the "these will likely be
proxied into manager objects later" point from direct guidance: a single
shared piece of state (a process-wide counter, a registry) needs *something*
holding the current value between calls once more than one call site touches
it — a `var` at the call site today, a manager object or actor later, once
a real app forces the actual shape rather than a guess.

## Actors are the right shape for services — and the reply pattern is now resolved

Direct guidance: window, audio, and the other genuinely stateful,
long-lived, OS-resource-owning modules (`std.db`, `std.queue`,
`platform.watchdog`) get `actor` shape — one singleton per declared type, no
construction, matching what these actually are (one window, one audio
device, one database connection, one durable queue, one watchdog timer).

**Checked against every run-verified actor example
(`examples/08/16/26/27`): `send` is fire-and-forget. Nothing in this
project's compiler examples shows a caller getting a typed reply back
inline** — the shown pattern is `send`, then poll a public field via
`scheduler::waitUntil`. That's a real mismatch for `std.db::query`,
`sys.window::poll`, and anything else where the caller needs the return
value at the call site.

**The resolution, worked through directly and verified against the
compiler at each step, not guessed:**

1. **`send` stays a pure fire-and-forget statement.** No language change —
   this was an explicit requirement, and confirmed `send` has no return
   value in any test or example either way.
2. **Correlation is a caller-supplied token, not a compiler-generated
   one.** A generated-token design would need `send` to become an
   expression (a real language change); a caller-chosen token (an
   incrementing counter it already keeps, say) needs nothing new, and
   works identically from `main` (a plain `fn`, which can't await anything
   regardless — only a task's bound result awaits), an actor, or a task.
3. **The actor's own state is the correlation table.** A small, bounded
   `Seq[Entry]` public field holds results keyed by that token (`Table[K,V]`
   doesn't exist in Tuck yet — confirmed by grep across the spec and every
   real `std/*` module, only `Seq[T]` does); an explicit `deleteToken`/`ack`
   message (still fire-and-forget) frees entries once the caller has read
   them. This is exactly `std.queue`'s own `push`/`pending`/`ack` shape,
   generalized to every service actor rather than being one module's
   private trick.
4. **The actor-boundary copy is deliberate, not incidental.** Spec:
   *"messages are copied into a fixed-size mailbox... so nothing crosses an
   actor boundary by reference and 'two actors sharing state' is likewise
   unsayable"* — the same class of argument as Tuck's "no `ref` in Tier 1"
   reasoning. So the answer to "this reply would be large" is never to make
   the boundary cheaper — it's to keep every individual message small on
   purpose. Concretely:
   - **`std.db`**: turn one big reply into many small ones. `query`
     returns a cursor token; `fetchNext {token}` returns exactly one row
     per call, appended to a small `fetched: Seq[FetchResult]` field.
   - **`sys.window`**: split into a cheap default (`state`: current
     mouse/keys snapshot, a few bytes, no token needed at all — it's one
     ordered stream, not many concurrent requests) plus an opt-in
     `events: Seq[InputEvent]` for a caller that needs discrete, lossless
     input, freed via `ackEvents {upTo}` keyed by an *actor-assigned*
     sequence number (not a caller token — the distinction from `std.db`
     matters: `std.db` has many concurrent callers each wanting their own
     answer, `sys.window` has one ordered stream everyone reads the same
     way). Recommended default overflow policy: drop-oldest — a stale
     keystroke matters less than a recent one, unlike DB rows or queue
     entries where dropping data would be a correctness bug.
   - **`sys.audio`/`platform.watchdog`**: already correct as originally
     designed — status/count-sized replies fit the small-message model
     natively, no redesign needed.
5. **Genuinely large, opaque blobs** (a whole texture, a captured audio
   buffer) are the one case that needs an actual escape hatch — an arena or
   other dedicated memory region (`alloc.allocator`'s existing strategies),
   not mmap specifically. It must be visibly marked as opting back into
   cross-actor reference sharing — the exact thing the copy-on-mailbox
   design exists to make unsayable — the same weight `[unsafe]` already
   carries for constructing a sealed variant out of sequence, not a silent
   alternative sitting next to the safe path.

### `TokenIssuer` — a reusable helper, so callers stop hand-rolling counters

Point 2 above needs the caller to supply a token, but "invent your own
counter" shouldn't mean every call site copy-pastes the same three lines.
`TokenIssuer` is a small `object` (not an actor — it's purely local to one
caller, never shared, so it needs none of the actor machinery) with three
named construction strategies:

```tuck
type IssuerKind:
  | tikIncremental
  | tikMonotonic
  | tikUuid4

type Uuid = {hi: u64, lo: u64}

object TokenIssuer:
  kind: IssuerKind
  counter: i64
  seed: u64

  fn next({self: TokenIssuer}) -> i64:
    self ..counter {self.counter + 1}
    return self.counter

  pending:
    fn nextMonotonic({self: TokenIssuer, nowNs: u64}) -> i64
    fn nextUuid({self: TokenIssuer}) -> Uuid

fn newIncremental() -> TokenIssuer
fn newMonotonic({seed: u64}) -> TokenIssuer
fn newUuid4({seed: u64}) -> TokenIssuer
```

**Compiler-verified beyond a typecheck — actually run.** `next`'s
`self ..counter {...}` is the one case in this whole pass that needed more
than `./tuck ch`: object methods are the one place `self` mutation is
legal (rule #11), and it was worth confirming the mutation is *real* at
the call site, not silently operating on a fresh copy each call. Built and
ran it: two successive `{self: issuer} next` calls on the same `var issuer`
returned 1 then 2 — exit code 2 confirms the counter genuinely persists
across calls, not resetting.

- **`Incremental`** — the concrete method above; simplest, correct within
  one process, resets on restart.
- **`Monotonic`** — declared `pending`, deliberately: real behavior needs a
  clock reading. Kept pure by taking `nowNs` as an explicit argument
  (caller supplies it from `sys.time`) rather than making the method itself
  `[io]` — same "explicit seed over hidden effect" choice `std.random::Dice`
  already makes with its own seeded-vs-OS-seeded constructor pair.
- **`Uuid4`** — also `pending`, same reasoning: needs real entropy, which
  this type accepts as a caller-supplied `seed` rather than reaching for
  `[io]` itself. A caller that wants OS-seeded randomness gets it from
  `std.random::newDice()` once, then hands the resulting bits to
  `newUuid4(seed)` — the effect happens once, at the boundary, not inside
  this type.

`std.db`'s tokens and `sys.window`'s caller-side bookkeeping (not its
actor-assigned `events` sequence numbers, which are a different thing —
see above) are both meant to use this rather than a hand-rolled counter at
each call site.

Both `std.db`'s cursor design and `sys.window`'s dual state/events design
are compiler-verified (`./tuck ch`: `OK`) in their own `.tuck.md` files.

## Syntax gotchas hit along the way, for the next translation pass

- A nullary call is the bare name, never `name()` — `newStopwatch`, not
  `newStopwatch()` (spec §2, confirmed: `()` is a parse error: "Function
  calls are postfix in Tuck").
- A record-type literal's field list cannot wrap across lines — same
  "structure lives in indentation, not brackets" ceiling that already
  applies to list literals (§0 rule #13); keep every `type X = {...}` on
  one line.
- A pure fn cannot return `!T` — fallible returns require `[io]` (spec §4).
  A precondition-style failure (bad input, not an environment failure) stays
  a plain return or `?T`, following `std/seq.tuck::at[T]`'s own precedent
  ("a program error reported at the call site, not a result the caller
  matches on").
- **`pending` is a reserved word — it cannot be a field name.** A field
  literally named `pending` (e.g. `pending: Seq[FetchResult] = []`) fails
  to parse (`Expected the end of the line here, found 'Seq'`), because the
  parser reads `pending:` as the start of a pending-block. Hit this
  translating `std.db`'s cursor design; renamed the field to `fetched`.
