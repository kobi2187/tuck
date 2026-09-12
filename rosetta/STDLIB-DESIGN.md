# STDLIB-DESIGN — a .NET-BCL-grade standard library for Tuck (batch F)

Written after batches A–F: 130 example programs (100 from A–E's algorithmic
sweep, 30 from F's application-shaped sweep — `f01`–`f30`, covering
dictionary lookup, LINQ-everyday shapes, string building, dates, TryParse,
file/config access, retry flows, CSV parsing, and repository patterns). This
document is batch F's module design; `rosetta/STDLIB-PROPOSAL.md` is the
cross-batch synthesis that merges this with A–E's proposals and owns the
canonical priority list — read that one first if choosing what to build
next. This file goes deeper on module boundaries and full signatures.

Current stdlib (`std/*.tuck`) is 6 files: `io` (print/printLine/readLine),
`fs` (readFile/writeFile/appendFile/fileExists/removeFile), `seq` (at/setAt
only — no len, no push), `str` (toStr only), `sys` (argCount/argAt/getEnv/
exit), `time` (nowMs/sleepMs + duration units). Everything below is new
surface.

**Naming stance:** per the user's ruling (2026-07-25), the emitter will
mangle/prefix emitted Tuck fn names so they can never be captured by Nim's
`system` module. Every signature below uses the RIGHT .NET-familiar name
(`min`, `max`, `count`, `sum`, `find`, `join`, `split`, `contains`,
`reverse`, `add`) without collision-avoidance contortion. Until mangling
ships, treat any example below that "builds and runs" using one of those
names as suspect — verify the `TUCK PENDING: <name> invoked` stderr line
actually fired before trusting the output (see DISCOVERIES.md #11).

## 1. Module layout

| module | charter | why its own module |
|---|---|---|
| `std/seq` | growable sequence: build, index, iterate, resize | already exists for `at`/`setAt`; growth is the #1 demanded addition |
| `std/list` | read-only higher-order ops over `Seq[T]`: filter/map/fold/sort/take/find/any/all/where/groupBy/join | separated from `std/seq` because it's *generic algorithm* surface, not *storage* surface — a `Seq[T]` is a container, `list` is what LINQ calls `Enumerable`. A future non-`Seq` container (fixed array, ring buffer) can reuse `std/list`'s algorithms without inheriting `seq`'s growth/mutation API. |
| `std/map` | key→value dictionary: get/set/remove/containsKey/keys/values | .NET splits `Dictionary<K,V>` from `List<T>`; Tuck should too — different big-O contract, different failure modes (`get` on a missing key is a *result*, not a crash) |
| `std/set` | unique-element collection: union/intersect/except/contains | small but earns its own module — set algebra reads badly bolted onto `list` (`{a, b} union` should not be ambiguous with list-concatenation) |
| `std/str` | text operations: case, trim, split/join, search, format | the single biggest gap surfaced by batch E; large enough alone to justify a dedicated module, exactly as .NET gives `string` a huge surface separate from collections |
| `std/char` | byte/char-level ops backing `std/str`: charAt, isDigit, isAlpha, isSpace | kept separate from `str` because it's the ASCII-byte-level escape hatch, not the everyday API; most callers never touch it directly (see §4.4 on why this needs a language-level type first) |
| `std/fmt` | display formatting: number-to-string with precision, padding/alignment | distinct from `str` because it's about *presentation* (culture-free, deterministic) not text *manipulation*; .NET's `String.Format`/`ToString("F2")` is the model |
| `std/math` | numeric functions: sqrt, pow, abs, min, max, gcd, lcm, floor/ceil/round, clamp | pure numeric-domain library code, no relationship to any language feature — the cleanest possible "just a module" case |
| `std/time` | already exists (clocks, durations) — extend with `Date`/calendar arithmetic and `today()` | keep folded into `time` rather than a new `std/date`: a `Date` is a coarser view of the same "point in time" concept `nowMs` already returns |
| `std/io` | already exists (print/printLine/readLine) — no change needed | console is a narrow, stable surface; batch E confirmed no gap here beyond a codegen bug |
| `std/fs` | already exists — extend with `readLines`, `joinPath` | batch F's `f27` reached for both immediately once file work got realistic; everything else (`readFile`/`writeFile`/`fileExists`) is already sufficient |
| `std/sys` | already exists (argCount/argAt/getEnv/exit) — no change needed | small and sufficient per batch F (`f20`) |
| `std/random` | random number generation: randomInt, randomFloat, randomBool | isolated because determinism matters: a `[io]`-effect-tagged module makes "this function's output is not reproducible" visible at the type/effect level, which .NET's `System.Random` does not — a place Tuck's effect system can do strictly better |
| `std/opt` | helpers over `?T`: unwrapOr, map, isSome, isNone | tightly coupled to the `?T` language feature — same reasoning as `seq::at`/`setAt` backing `xs[i]` sugar |
| `std/result` | helpers over `!T`: unwrapOr, mapErr, isOk | same coupling argument as `opt`, but blocked until §4.3's unwrap gap is fixed |

### What does NOT get its own module, and why

- **No `std/linq` / no lazy `IEnumerable`.** See §6 — Tuck has no
  closures-over-mutable-state story and no `yield`/generator construct;
  `std/list` ships eager, `Seq`-in/`Seq`-out functions instead of a lazy
  pipeline type. Batch F's `f21` (`where`/`project`/`orderBy`/`sum`/`any`
  chained by hand) shows the eager postfix style reads fine without laziness.
- **No `std/collections.generic`-style umbrella.** `seq`, `list`, `map`,
  `set` are peers, not children of one grab-bag module.
- **No `std/convert`.** `toStr` stays with `str` (or becomes
  compiler-derived, §4.6); `parseInt`/`parseFloat`/`tryParseInt` join `str`
  as the natural dual of `toStr`. A dedicated conversion module would just
  be an alphabetized function dump.
- **No `std/regex`.** Zero demand across 130 examples.
- **No separate module for `groupBy`/`joinOn`/`where`/`project`/`orderBy`.**
  They're `Seq[T]`-in, `Seq[T]`-out higher-order functions exactly like
  `filter`/`sortBy` — LINQ's own split from `System.Collections.Generic` was
  a shipping-order accident (LINQ came later), not a boundary Tuck should
  copy.
- **No `std/env` separate from `sys`.** `sys::getEnv` already lives there;
  .NET keeps `Environment.GetEnvironmentVariable` on one static class too.

## 2. Full signatures, by module and tier

Tier 1 = can't write ordinary .NET-familiar programs without it. Tier 2 =
expected by any developer. Tier 3 = nice to have. Signatures use real Tuck
syntax; `fn` values are passed the `:name` way per SYNTAX.md.

### std/seq — Tier 1

```tuck
fn push[T]({items: Seq[T], value: T}) -> Seq[T]        # grow by one
fn pop[T]({items: Seq[T]}) -> {items: Seq[T], value: ?T}
fn len[T]({items: Seq[T]}) -> int                       # fn form of `.len`, for generic/pending-free contexts
fn at[T]({items: Seq[T], index: int}) -> T              # EXISTS
fn setAt[T]({items: Seq[T], index: int, value: T}) -> void   # EXISTS
fn empty[T]({}) -> Seq[T]                                # construct a growable seq with no literal
fn withCapacity[T]({capacity: int}) -> Seq[T]            # pre-size, avoid reallocation in a hot loop
```

`push`/`pop`/`empty` are the single highest-value addition in the whole
document — see §4.1. Everything else stands on top of it.

### std/list — Tier 1 (filter/where/project/find/sortBy/sum/count/any/all), Tier 2 (rest)

```tuck
# Tier 1 — the everyday LINQ-shaped surface (batch F f21, f15)
fn where[T]({items: Seq[T], pred: fn}) -> Seq[T]           # LINQ's Where; kept distinct from `filter` below only in naming taste (see note)
fn filter[T]({items: Seq[T], pred: fn}) -> Seq[T]          # same operation as `where` — Tuck should ship ONE name, see note
fn project[T, U]({items: Seq[T], transform: fn}) -> Seq[U] # LINQ's Select; NOT named `select` — `select` is a reserved word (verified, f21), and `map` is the name Tuck's own vocabulary already reaches for (batch D)
fn find[T]({items: Seq[T], pred: fn}) -> ?T                # LINQ's First/FirstOrDefault
fn sortBy[T]({items: Seq[T], compare: fn}) -> Seq[T]       # compare: {a: T, b: T} -> bool, "a before b"
fn sum({items: Seq[int]}) -> int
fn count[T]({items: Seq[T], pred: fn}) -> int
fn any[T]({items: Seq[T], pred: fn}) -> bool
fn all[T]({items: Seq[T], pred: fn}) -> bool
fn contains[T]({items: Seq[T], value: T}) -> bool

# Tier 2
fn fold[T, Acc]({items: Seq[T], init: Acc, step: fn}) -> Acc   # step: {acc: Acc, item: T} -> Acc
fn indexOf[T]({items: Seq[T], value: T}) -> int          # -1 on miss, matches batch D's hand-written convention
fn reverse[T]({items: Seq[T]}) -> Seq[T]
fn take[T]({items: Seq[T], count: int}) -> Seq[T]
fn skip[T]({items: Seq[T], count: int}) -> Seq[T]
fn min({items: Seq[int]}) -> int
fn max({items: Seq[int]}) -> int
fn average({items: Seq[int]}) -> float
fn groupBy[T]({items: Seq[T], keyOf: fn}) -> Map[str, Seq[T]]
fn sortByField[T]({items: Seq[T], field: fn}) -> Seq[T]  # field: {item: T} -> Ord-comparable; convenience wrapper over sortBy for "sort records by a projection", the single most common real-world sort (batch F f03, f16)
fn distinctValues[T]({items: Seq[T]}) -> Seq[T]          # order-preserving dedup
fn joinOn[L, R, Out]({left: Seq[L], right: Seq[R], leftKey: fn, rightKey: fn, combine: fn}) -> Seq[Out]   # inner join, LINQ's Join

# Tier 3
fn zip[A, B]({a: Seq[A], b: Seq[B]}) -> Seq[{first: A, second: B}]
fn flatten[T]({items: Seq[Seq[T]]}) -> Seq[T]
fn chunk[T]({items: Seq[T], size: int}) -> Seq[Seq[T]]
```

**Naming note on `where`/`filter`, `project`/`map`/`select`:** batch F
independently invented `where`+`project` (`f21`, chasing LINQ vocabulary
directly) and `filter`+`map` (`f05`, `f15`, chasing Tuck's own "postfix
struct payload" idiom, which reads more naturally as `{items, pred} filter`
than `{items, pred} where`). Recommend shipping **`filter`/`map`/`find`**
as the real names — they're shorter, unambiguous, and match what
batch D independently converged on with zero LINQ priming — and treat
`where`/`project`/`select` as C#-muscle-memory synonyms that a porting
guide can call out, not separate stdlib entries. Two names for one
operation is worse than either name alone.

### std/map — Tier 1

```tuck
fn empty[K, V]({}) -> Map[K, V]
fn set[K, V]({table: Map[K, V], key: K, value: V}) -> Map[K, V]
fn get[K, V]({table: Map[K, V], key: K}) -> ?V             # note: no throwing variant — see §6, no exceptions in Tuck
fn containsKey[K, V]({table: Map[K, V], key: K}) -> bool
fn remove[K, V]({table: Map[K, V], key: K}) -> Map[K, V]
fn len[K, V]({table: Map[K, V]}) -> int
fn keys[K, V]({table: Map[K, V]}) -> Seq[K]
fn values[K, V]({table: Map[K, V]}) -> Seq[V]
```

**On `get` vs `tryGet`:** batch F's `f01` reached for `get`, `f22` reached
for `tryGet` — same signature, same semantics, different name, because
`f22` was deliberately written to probe the .NET `TryGetValue` idiom. In
.NET, `TryGetValue` exists because `dict[key]` THROWS on a miss and
`TryGetValue` is the non-throwing escape hatch — two different behaviors
need two different names. In Tuck, `get` already returns `?V` — there is no
throwing indexer to escape from, so the `Try`-prefix carries no actual
distinction. **Recommend shipping `get` only; do not ship `tryGet`.** The
"Try" naming convention is a .NET-specific artifact of exceptions-as-default,
not a pattern Tuck should reproduce (see §6).

`Map[K, V]` itself is a language-level generic container type that does not
exist today (`f01`/`f04`/`f22` all hit `undeclared identifier: 'Map'` at
the Nim stage) — see §4.2.

### std/set — Tier 2

```tuck
fn empty[T]({}) -> Set[T]
fn add[T]({set: Set[T], value: T}) -> Set[T]
fn contains[T]({set: Set[T], value: T}) -> bool
fn union[T]({a: Set[T], b: Set[T]}) -> Set[T]
fn intersect[T]({a: Set[T], b: Set[T]}) -> Set[T]
fn except[T]({a: Set[T], b: Set[T]}) -> Set[T]           # a minus b
fn toSeq[T]({set: Set[T]}) -> Seq[T]
fn fromSeq[T]({items: Seq[T]}) -> Set[T]
```

Same `Map`-style new-type dependency as above. Ranked Tier 2 not Tier 1
because `f02` was the only example across 130 that reached for set algebra.

### std/str — Tier 1

```tuck
fn len({text: str}) -> int                # EXISTS as `.len` sugar; fn form for parity
fn upper({text: str}) -> str
fn lower({text: str}) -> str
fn trim({text: str}) -> str
fn split({text: str, sep: str}) -> Seq[str]
fn join({items: Seq[str], sep: str}) -> str
fn contains({text: str, needle: str}) -> bool
fn startsWith({text: str, prefix: str}) -> bool
fn endsWith({text: str, suffix: str}) -> bool
fn parseInt({text: str}) -> !int [io, error: str]        # throws-shaped: caller wants the value or a hard failure
fn tryParseInt({text: str}) -> ?int                       # TryParse-shaped: caller wants a value or nothing, no error detail
fn parseFloat({text: str}) -> !float [io, error: str]
```

**`parseInt` vs `tryParseInt` — unlike `get`/`tryGet` above, THIS pair earns
two names.** Batch F wrote both independently (`f11`/`f29`-style `!T`
signatures wanting a reason for failure vs. `f26`'s `?int` wanting only
"did it work"). Unlike the map case, `!T` and `?T` are genuinely different
return shapes carrying different information (an error value vs. nothing) —
`!int` is for a caller that will report *why* parsing failed (user-facing
validation message), `?int` is for a caller that only branches on
success/failure and doesn't care why. Both are real, distinct call sites in
this batch. Keep both.

### std/str — Tier 2

```tuck
fn replace({text: str, target: str, replacement: str}) -> str
fn substring({text: str, start: int, length: int}) -> str
fn repeat({text: str, times: int}) -> str
fn indexOf({text: str, needle: str}) -> int              # -1 on miss
fn countOccurrences({text: str, needle: str}) -> int
fn lessThan({a: str, b: str}) -> bool                     # lexicographic; str only has `==` today
fn isEmpty({text: str}) -> bool
```

### std/char — Tier 2 (blocked on a language-level type, see §4.4)

```tuck
fn charAt({text: str, index: int}) -> str      # length-1 str, byte-sliced, documented as ASCII-scoped
fn isDigit({ch: str}) -> bool
fn isAlpha({ch: str}) -> bool
fn isSpace({ch: str}) -> bool
fn toUpper({ch: str}) -> str
fn toLower({ch: str}) -> str
```

### std/fmt — Tier 1

```tuck
fn toFixed({value: float, decimals: int}) -> str
fn padLeft({text: str, width: int}) -> str
fn padRight({text: str, width: int}) -> str
fn padLeftWith({text: str, width: int, fillChar: str}) -> str    # Tier 2
fn padRightWith({text: str, width: int, fillChar: str}) -> str   # Tier 2
```

No `format({template, args})` sprintf-style function — batch F's `f07`
built a formatted report line with plain `+` concatenation and it read
fine; see §6.

### std/math — Tier 1 (sqrt, pow, abs, min, max), Tier 2 (rest)

```tuck
# Tier 1
fn sqrt({value: float}) -> float
fn pow({base: int, exp: int}) -> int
fn abs({value: int}) -> int
fn min({a: int, b: int}) -> int
fn max({a: int, b: int}) -> int

# Tier 2
fn gcd({a: int, b: int}) -> int
fn lcm({a: int, b: int}) -> int
fn floor({value: float}) -> int
fn ceil({value: float}) -> int
fn round({value: float}) -> int
fn clamp({value: int, low: int, high: int}) -> int
```

`min`/`max`/`abs`/`clamp` are exactly the names DISCOVERIES.md #11 verified
get silently shadowed by Nim's `system` today. Ship the real names anyway
per the mangling ruling (§0) — but implementers must confirm mangling has
actually landed before trusting any test of these four names that "just
works" (see DISCOVERIES.md #11's minimal repro for the check).

### std/time — extend with dates, Tier 2

```tuck
# EXISTS: nowMs, sleepMs, ms/us/s duration constructors
type Date:
  year: int
  month: int
  day: int

fn today() -> Date [io]                         # DateTime.Now-shaped (batch F f25)
fn addDays({date: Date, days: int}) -> Date
fn addHours({at: Date, hours: int}) -> Date     # f25 — hour-granularity arithmetic on the same Date value; argues Date may need an hour/minute field or a separate DateTime-shaped type, see note
fn daysBetween({a: Date, b: Date}) -> int
fn isBefore({a: Date, b: Date}) -> bool
fn formatDate({date: Date}) -> str              # "YYYY-MM-DD", the one unambiguous default
```

**Open question surfaced by `f25`:** `addHours` on a day-granularity `Date`
is a type mismatch waiting to happen — .NET solves this by giving
`DateTime` full second-or-finer precision from the start rather than
splitting `Date`/`DateTime`. Recommend Tuck's `Date` carry an optional
time-of-day component (or rename it `DateTime` and accept day-only usage
just zeroes the time fields) rather than shipping a real `Date`/`DateTime`
split — batch F never had two examples that needed date-only vs.
datetime-only precision to be distinguished at the type level, so the
split would be speculative complexity with zero demand behind it.

### std/fs — extend, Tier 2

```tuck
# EXISTS: readFile, writeFile, appendFile, fileExists, removeFile
fn readLines({path: str}) -> !Seq[str] [io, error: FsError]   # f27 — line-oriented is the common case, not whole-file-as-one-string
fn joinPath({dir: str, file: str}) -> str                      # f27 — Path.Combine-shaped; portable separator handling belongs in the runtime, not caller string-concat
```

### std/random — Tier 2, all `[io]`

```tuck
fn randomInt({low: int, high: int}) -> int [io]     # inclusive low, exclusive high — .NET's Random.Next convention
fn randomFloat({}) -> float [io]                     # [0.0, 1.0)
fn randomBool({}) -> bool [io]
fn seeded({seed: int}) -> void [io]                  # sets the process-global generator's seed, for reproducible tests
```

### std/opt — Tier 1

```tuck
fn unwrapOr[T]({self: ?T, fallback: T}) -> T
fn isSome[T]({self: ?T}) -> bool
fn isNone[T]({self: ?T}) -> bool
fn map[T, U]({self: ?T, transform: fn}) -> ?U
```

This is the single most load-bearing Tier-1 entry in the whole document by
frequency: `unwrapOr` was reached for by c09 and, independently and without
prompting, by f01, f15, f18, f22, f26, f30 — six of batch F's thirty files
alone. It is invented constantly and implemented nowhere — see §5.

Note `f22` also reached for `.isSome` as a field-style check
(`found.isSome`) before falling back to `unwrapOr` — direct field access on
`?T` is currently a type error (`unhandled ?int`), matching `!T`'s
`.ok`-narrowing precedent. Whatever unwrap story ships for `?T` should
support both an `unwrapOr`-with-default call AND a narrowing check, since
both were independently reached for in this batch alone.

### std/result — blocked, see §4.3

```tuck
fn unwrapOr[T, E]({self: !T, fallback: T}) -> T
fn isOk[T, E]({self: !T}) -> bool
fn mapErr[T, E, E2]({self: !T, transform: fn}) -> !T
```

Signatures given for completeness; do not implement until the language
decides how `!T` gets unwrapped at all (§4.3).

## 3. Demand evidence — cross-referenced against all 130 examples

| function | batches that reached for it, unprompted | count |
|---|---|---|
| `unwrapOr` (opt) | C (c09), F (f01, f15, f18, f22, f26, f30) | 7 |
| `sum`/`average` (list) | A (a08), D (d01, d02), F (f05, f21) | 5 |
| `min`/`max` | A (a16, a17-adjacent), D (d03, d20) | 3 |
| `filter`/`where` | D (d05), F (f15 as `findFirst`, f21 as `where`) | 3 |
| `split`/`join` (str) | E (e10, e11, e15), F (f29 as `splitFields`) | 4 |
| `parseInt`/variants | A (implicit), B (b22), E (e17), F (f11 as `parsePoint`, f26 as `tryParseInt`, f29) | 6 |
| `Map`/dictionary | F (f01, f04, f22) | 3 — all new in batch F |
| `sortBy`/comparer sort | F (f03, f16, f21 as `orderBy`) | 3 |
| `groupBy` | F (f04) | 1 |
| `push`/growable seq | D (d20), flagged independently by DISCOVERIES.md as top structural gap | 1 explicit + universal implicit demand |
| `reverse` (str) | E (e05, e06) | 2 |
| `upper`/`lower` | E (e07), F (f24 via case-insensitive compare) | 2 |
| `trim` | E (e12) | 1 |
| `sqrt` | C (c01) | 1, "first wall hit" per batch C |
| `pow`, `gcd` | A (a13, a05) | 2 |
| `Set`/set algebra | F (f02) | 1 |
| `toFixed`/decimal formatting | F (f06) | 1 |
| `padLeft`/`padRight` | F (f08) | 1 (2 fns) |
| date arithmetic/formatting | F (f09, f10, f25) | 3 |
| `sortByField` | F (f03, f16) | 2 |
| `joinOn` (collection join) | F (f17) | 1 |
| repository add/find/update/remove | F (f18, f30) | 2 files, 6 fns total |
| `randomInt`/`randomBool` | B (b24), F (f19) | 2 |
| `readLines`/`joinPath` (fs) | F (f27) | 1 (2 fns) |
| retry-around-fallible-call | F (f28) | 1 |
| enumerate-with-index | F (f13) — this is a **language feature** (`for idx, item in xs:`) that already works, no stdlib fn needed | 0 stdlib demand |
| string accumulation (`+=`-style build) | F (f23) — also a language feature, plain `+` on a `var str`, already works | 0 stdlib demand |

**Where demand outranks my taste:** `Map[K, V]` as a new container *type*
was not something I'd have front-loaded on first principles — a
systems-flavored language can go a long way on `Seq` alone. But three
separate batch-F files (`f01`, `f04`, `f22`) hit `undeclared identifier:
'Map'` the moment example authors wrote *any* realistic lookup-by-key
program. That's a stronger signal than the raw 3/130 count suggests:
frequency undercounts it because batches A–E's tasks were algorithmic by
construction and never had a reason to want a dictionary. Trust the
qualitative signal (first wall an app-shaped program hits) over the count.

**Where I overrode my own first draft:** the earlier 20-example version of
this document proposed both `filter` and a hypothetical `where` as if they
might coexist; having now written `f21` (LINQ-styled) alongside `f05`/`f15`
(Tuck-idiom-styled) in the same batch, the evidence is that these are the
SAME operation invented twice under different naming pressure, not two
real needs. See the naming note under `std/list` above — recommend one
name, not two.

**Where demand is thin, deliberately not promoted:** `std/set` (1/130),
`joinOn` (1/130), full repository update/remove (2/130) — real, Tier 2/3,
not Tier 1. `f22`'s `tryGet` is 1/130 by itself and, per the analysis
above, shouldn't ship as a second name at all.

## 4. Language-level prerequisites — cannot be written as ordinary Tuck today

### 4.1 Growable sequences (blocks nearly everything above)

`Seq[T]` has no `push`/`append`/growth today. Confirmed again from a new
angle in batch F: `f13`'s `for idx, item in xs:` with string concat inside
the loop body hit a distinct-but-related int8-arithmetic Nim codegen error,
suggesting the growth/arithmetic-widening codegen path is fragile beyond
just the documented `acc = acc + [x]` case. Every function in `std/list`
that returns a `Seq[T]` of unknown-in-advance length is unimplementable as
ordinary Tuck without this. **Rank #1** (also DISCOVERIES.md's ranking).

### 4.2 Generic container types beyond `Seq[T]` (blocks `std/map`, `std/set`)

There is no `Map[K, V]` or `Set[T]` type in the language — confirmed three
separate times in batch F alone (`f01`, `f04`, `f22`), all with the same
`undeclared identifier: 'Map'` failure at the Nim stage. Unlike `push` this
can't be worked around with a fixed-size-array trick; some new type-level
primitive (compiler built-in like `Seq`, or a compiler-recognized generic
struct with an opaque runtime handle) is required before `std/map`/
`std/set` can exist for real. **Rank #2.**

### 4.3 No working `!T`/`?T` → `T` unwrap idiom (blocks every fallible fn)

Confirmed across batches C, E, and F: `expr?` propagation does not exist in
the parser; the only working pattern is narrowing on `.ok` for `!T`
(batch F's `f11`/`f12`/`f28` all used it successfully) — but that only
tells you *whether* the call succeeded, not how to extract the payload in
a checked way. `f22` independently discovered the same gap on the `?T`
side: `found.isSome` is a type error (`unhandled ?int`) even though the
`.ok` narrowing works for `!T`, so the two optional/result types don't even
share a consistent partial workaround today. Every fallible fn in this
document (`parseInt`, `tryParseInt`, `readLines`, `fetchStatus`,
`std/result::unwrapOr`) is honest-on-paper but nearly useless in practice
until this has an end-to-end story. **Rank #3.**

### 4.4 No char type, no string indexing

`s[0]` on a `str` is a type error; there is no `char`/byte-element type.
Ranked below §4.1–4.3 because batch F's application-shaped examples never
actually needed character-level access (unlike batch E's more algorithmic
ones) — matters less for "everyday app code" than for text-processing
puzzles.

### 4.5 Generics/constraints for comparers

`sortBy`'s `compare: fn` and `std/list`'s `pred`/`transform`/`keyOf`
parameters rely on first-class function values as struct fields, which
already has *some* runtime story (batch F's `f03`, `f16`, `f21` all check
clean using `:name` fn-ref syntax). What's still open: no `Ord`/`Eq`-style
constraint syntax to say "T must be comparable" at the generic-parameter
level — a caller who passes the wrong shape of comparer gets a Nim-stage
error, not a Tuck one. Lower priority than 4.1–4.4.

### 4.6 Should record equality/comparison/formatting be compiler-derived?

Structural `==` on records already works (batch C, c17) — no stdlib fn
needed, do nothing. Recommend **formatting** be compiler-derived (a
default `{self: T} toStr -> str`) rather than hand-written per type — every
batch-C/F example that wanted to print a record fell back to picking
fields by hand for lack of this. Recommend **ordering** be opt-in derived
(`derive Ord`), not blanket-default, since not every struct has a sensible
total order.

### 4.7 Contextual keywords block ordinary field names

Verified twice more in batch F, beyond the earlier `fn`/`task`/`select`
findings: any lexer keyword is unusable as a struct field name even where
it's the obviously correct name for the data (`f21` had to rename a field
away from `select` to write `project`). For a language whose entire calling
convention is named struct fields, this taxes ordinary data modelling more
than a keyword collision usually would in other languages. Fix direction:
an identifier immediately after `{` or `.` should parse as a field name,
not be captured as a keyword.

## 5. Recommended build order

See `rosetta/STDLIB-PROPOSAL.md` §6 for the authoritative cross-batch
order (name mangling and the pending-stub arity fix both come first, in
that relative order, ahead of any stdlib module work). This section adds
batch-F-specific sequencing within "stdlib modules," assuming those two
compiler fixes and growable `Seq[T]` are already in place:

1. **`std/opt::unwrapOr`+friends.** Cheap (no new language feature — `?T`
   already exists), and the single most independently-reinvented fn across
   all 130 examples (7 separate files). Highest demand-to-effort ratio.
2. **`std/math`: sqrt, pow, abs, min/max, gcd, clamp.** Small,
   self-contained, unblocks every numeric example that hit a wall in
   batch A/C. Verify the min/max/abs/clamp shadowing bug (DISCOVERIES.md
   #11) is actually gone before calling this done.
3. **`std/str`: split/join/upper/lower/trim/startsWith/endsWith.** Batch
   E's single biggest gap category, confirmed again by `f24`/`f29`.
4. **`Map[K, V]`** as a language-level type, then `std/map`'s Tier-1
   surface (`empty`/`set`/`get`/`containsKey`/`remove`) — no `tryGet`, per
   §2's naming analysis. Ranked after the above despite being a genuinely
   new type-system primitive (§4.2) because it's more expensive than
   anything above it, but ahead of `std/set`/`std/fmt`/dates because three
   separate batch-F files hit this wall first.
5. **`std/list`: filter/map/find/sortBy/sum/count/any/all.** The everyday
   LINQ-shaped surface once `Seq` growth and `Map` both exist (`groupBy`
   needs `Map`).
6. **`std/fmt`: toFixed, padLeft, padRight.** Cheap, no new types, wanted
   the moment programs produce user-facing text.
7. **The `!T`/`?T` unwrap story (§4.3).** Deliberately not #1 despite being
   the single biggest *design* gap across three batch reports — this is a
   language-semantics decision, not stdlib-shaped work, and rushing it
   risks locking in the wrong shape. Recommend a short, separate design
   pass once items 1–6 have freed up cycles.
8. **Everything else** (`std/set`, `std/fs::readLines/joinPath`, date
   arithmetic, `joinOn`, `randomInt`, repository-pattern helpers) — real,
   each backed by 1–3 examples out of 130. Build on request once 1–7 are
   in place.

## 6. Where .NET's design would be wrong for Tuck

- **No lazy `IEnumerable<T>` / LINQ-style pipeline.** `std/list` ships
  eager, `Seq[T]`-in/`Seq[T]`-out — Tuck has no closures-over-captured-state
  or generator mechanism to build laziness on. Batch F's `f21` shows the
  eager postfix chain (`{items, pred} filter` then `{items, transform}
  map`) reads fine without it.
- **No exceptions-as-control-flow anywhere in the design.** Every fallible
  signature returns `?T` (missing-is-normal) or `!T`
  (failure-is-exceptional-but-not-a-crash) instead of throwing. This
  directly kills the .NET `Try*` naming convention (§2's `get`/`tryGet`
  analysis) — Tuck has no throwing indexer for a `Try`-prefixed method to
  be an alternative to, so shipping both names would just be copying a
  .NET naming artifact with no underlying reason in Tuck.
- **No culture/locale system.** `std/fmt::toFixed` is deliberately
  culture-invariant. 0/130 examples wanted locale-aware formatting.
- **No `sprintf`-style format-string mini-language.** `f07`, `f21`'s report
  lines, and `f23`'s accumulate-a-report pattern all read fine with plain
  `+` concatenation on a `var str` — a template-string engine would be new
  surface for a problem string concatenation already solves at Tuck's
  scale.
- **Effects make `std/random` stricter than `System.Random`, deliberately.**
  Every `std/random` signature is tagged `[io]` — a type-level fact that
  "this result is not reproducible," strictly more honest than .NET's
  untagged `Random` class.
- **No `TryGetValue`-style double-naming for non-throwing lookups.** Once
  every lookup already returns `?T` by default (because there's no
  exception to escape from), a `Try`-prefixed synonym adds a second name
  for the same operation with no distinction behind it. `std/map::get`
  alone covers what .NET needs two names for.

## 7. Summary

**Module list:** `seq`, `list`, `map`, `set`, `str`, `char`, `fmt`, `math`,
`time` (extended), `io`/`sys` (unchanged), `fs` (extended), `random`,
`opt`, `result` (blocked).

**Tier 1 set:** `seq::push/pop/empty`, `list::filter/map/find/sortBy/sum/
count/any/all/contains`, `map::empty/set/get/containsKey/remove` (no
`tryGet`), `str::upper/lower/trim/split/join/contains/startsWith/endsWith/
parseInt/tryParseInt`, `fmt::toFixed/padLeft/padRight`,
`math::sqrt/pow/abs/min/max`, `opt::unwrapOr/isSome/isNone/map`.

**Top 3 language-level prerequisites**, in priority order:
1. **Growable `Seq[T]`** — the one structural gap every other collection
   function stands on top of.
2. **A `Map[K, V]`/`Set[T]` container primitive** — confirmed three times
   independently in this batch alone to be the first wall an
   application-shaped program hits, ahead of formatting or dates.
3. **A working `?T`/`!T` → `T` unwrap idiom** — flagged independently
   across three of the six batches now on record; blocks every fallible
   stdlib fn from being genuinely usable even once implemented, and the
   `?T` and `!T` sides don't even share a consistent partial workaround
   today (`.ok` works on `!T`, `.isSome` does not work on `?T`).

Per `rosetta/STDLIB-PROPOSAL.md`, name mangling and the pending-stub arity
fix are both compiler prerequisites that must land before any of the above,
in that relative order — pure compiler work, not design questions, and
currently the largest reason correctly-designed stdlib functions would
still fail to build.
