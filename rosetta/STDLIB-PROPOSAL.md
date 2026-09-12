# Tuck standard library — merged proposal

Synthesis of 6 batches / ~155 example programs written in the most natural
Tuck their authors could manage. Demand figures are empirical: how many
examples reached for the fn while solving an ordinary task.

STATUS: all 6 batches merged (~145 examples). Batch F's fuller module design
lives in rosetta/STDLIB-DESIGN.md; this file is the cross-batch synthesis and
the decision list.

---

## 1. Language prerequisites — these gate the stdlib

Ordered by how much stdlib surface each unblocks. Nothing in Tier 1 of §2 is
safely implementable until items 1–3 are settled.

1. **Name mangling on emitted fns.** RULED by the user 2026-07-25: the emitter
   mangles/prefixes Tuck fn names so Nim's `system` can never capture them.
   Without it, `abs`/`min`/`max`/`clamp` (verified) silently run Nim's version
   — builds, runs, plausible output, Tuck stub dead, no diagnostic.
   **Must land BEFORE or WITH the pending-stub arity fix** — that bug's loud
   build failure is currently what protects most colliding names.
   Unblocks: the entire .NET-shaped naming set (count/sum/find/join/split/...).

2. **Growable sequences.** No `push`/`append` exists; `acc = acc + [x]`
   typechecks then emits invalid Nim. Every Seq-returning fn below
   (`filter`, `map`, `dedup`, `split`, `take`, `skip`) is really asking for
   this underneath. **The single biggest structural gap.**

3. **Integer division.** `let q = 7 / 2` prints `3.5`. Blocks `average`,
   midpoints, binary search, digit extraction, base conversion.
   STANDING PROPOSAL (batch A, endorsed): type-directed `/` — `int/int -> int`,
   any float operand -> float; `%` int-only; mixed `+ - *` follow the same rule.
   AWAITING USER RULING.

4. **`!T` unwrap idiom.** There is none. `expr?` does not exist in the parser
   (my SYNTAX.md wrongly documented it). Only the `if r.ok` narrowing works.
   This undermines EVERY fallible fn — `parseInt`, `readFile`, `readLine` —
   even after they are implemented. Needs a language ruling, not a stdlib fn.

5. **Char / text-element story.** No char type, no string indexing.
   RECOMMENDATION (batch E): ship `str::charAt({text, index}) -> str`
   (length-1 str, **byte semantics, documented as such**) to unblock now;
   defer codepoint/grapheme correctness as a separate design question.
   Risk on the record: byte-slicing "café" at index 3 silently returns half a
   codepoint, with no type-level signal. Retrofitting means an O(n) scan per
   call or a breaking signature change.

6. **Generics / constraints for comparers.** `min`/`max`/`sortBy` over
   `Seq[T]` want an ordering constraint. Int-only is the honest MVP today.

6b. **`Map[K,V]` / `Set[T]` as real types.** VERIFIED ABSENT: `{} Map[str,int]`
   → "indexing takes exactly one index, got 2". No dictionary type exists.
   Batch F promoted this to Tier 1 on qualitative grounds over raw frequency
   (2/145 calls) with the right argument: it is the FIRST wall an
   application-shaped program hits — lookup tables, grouping, counting by key.
   Algorithm-flavored batches never reached it because puzzles rarely need it.

6c. **Contextual keywords.** Every one of the ~40 lexer keywords is unusable
   as a struct field name (`task`, `select`, `fn` all verified). For a
   language whose calling convention is named struct fields, this taxes
   ordinary data modelling. Fix: an identifier after `{` or `.` is a field
   name, not a keyword.

7. **Compiler-derived, NOT stdlib** (batch C ruling, endorsed):
   - structural equality — **already works**, verified. Add nothing.
   - record formatting/printing — should be auto-derived. Six batch-C examples
     degenerated into printing fields one at a time.
   - ordering for sorting — opt-in derived (`derive Ord`), since not every sum
     type has a sensible order.

---

## 2. Module layout

Batch F argues for a finer split than the table below, and the reasoning is
sound where it differs — adopt it as the target shape:
- **`seq` vs `list`**: `seq` = growable storage primitive; `list` = eager
  higher-order algorithms over it. Keeps the storage type small.
- **`str` vs `fmt`**: text manipulation vs presentation. `fmt` owns
  fixed-decimals, padding, date display.
- **`char`** deferred — blocked on the language type (prereq 5).
- **`result`** signatures written but not buildable (prereq 4).
- **`random` tagged `[io]` throughout** — deliberately stricter than
  System.Random. Good call: nondeterminism is an effect.
- Explicitly rejected, with reasons: no `std/linq` / lazy IEnumerable (no
  closures or generators to back it), no exceptions-as-control-flow (`?T`/`!T`
  is the Tuck-native choice, not a downgrade), no locale system, no
  sprintf-style format mini-language (postfix `+` concat already covers it).

| module | charter |
|---|---|
| `std/seq` | sequences: access, growth, query, transform |
| `std/str` | text: build, slice, search, case, split/join |
| `std/num` | scalar math: abs, min/max, pow, gcd, sign, clamp |
| `std/fmt` | number/date formatting for display |
| `std/opt` | `?T` helpers — unwrapOr and friends |
| `std/io` | console (exists) |
| `std/fs` | files (exists) |
| `std/time` | clock + duration units (exists) |
| `std/sys` | process/exit (exists) |
| *(batch F)* | map/set/env/random — slots in when F lands |

Not separate modules: no `std/math` distinct from `std/num` (one scalar-math
home); no `std/linq` (query fns belong on `std/seq`).

---

## 3. Tier 1 — cannot write ordinary programs without these

### std/seq
```tuck
fn push[T]({items: Seq[T], value: T}) -> Seq[T]   # gated on prereq 2
fn sum({items: Seq[int]}) -> int                  # D: 2 examples, top ask
fn min({items: Seq[int]}) -> int
fn max({items: Seq[int]}) -> int                  # D: d03, d20
fn contains[T]({items: Seq[T], value: T}) -> bool
fn indexOf[T]({items: Seq[T], value: T}) -> int   # -1 on miss
fn filter[T]({items: Seq[T], pred: fn}) -> Seq[T]
fn map[T, U]({items: Seq[T], transform: fn}) -> Seq[U]  # NOT `fn:` — reserved
fn count[T]({items: Seq[T], pred: fn}) -> int
```

### std/str  (the biggest gap by far — batch E)
```tuck
fn split({text: str, sep: str}) -> Seq[str]   # highest-value single addition
fn join({items: Seq[str], sep: str}) -> str   # the pair that unlocks parsing
fn reverse({text: str}) -> str
fn upper({text: str}) -> str
fn lower({text: str}) -> str
fn trim({text: str}) -> str
fn parseInt({text: str}) -> !int              # gated on prereq 4
fn charAt({text: str, index: int}) -> str     # gated on prereq 5
```

### std/num
```tuck
fn abs({value: int}) -> int       # A, B — every sign-handling task
fn min({a: int, b: int}) -> int
fn max({a: int, b: int}) -> int   # most-reached-for pair in the corpus
```

## 4. Tier 2 — any developer expects these
```tuck
# std/num
fn pow({base: int, exp: int}) -> int
fn sqrt({value: int}) -> int      # C ranked #1: first wall in geometry code
fn gcd({a: int, b: int}) -> int   # true primitive; lcm composes from it
fn clamp({value: int, low: int, high: int}) -> int
fn sign({n: int}) -> int
fn average({items: Seq[int]}) -> float   # gated on prereq 3

# std/seq
fn dedup[T]({items: Seq[T]}) -> Seq[T]   # preserves first-seen order
fn sortBy[T]({items: Seq[T], key: fn}) -> Seq[T]   # gated on prereq 6

# std/str
fn startsWith / endsWith / replace / substring / repeat / countOccurrences

# std/opt
fn unwrapOr[T]({self: ?T, fallback: T}) -> T   # first thing anyone does to ?T
```

## 5. Tier 3 — nice to have
`sumProperDivisors` (better: `divisors -> Seq[int]` and compose),
`randomBool`/`randomInt`, `padLeft`/`padRight`, `toFixed`.

---

## 6. Recommended build order

Batch F ranked the arity fix first (it unblocks the most examples); I rank
mangling first (it must not come after). Both hold — they are adjacent and
the constraint is ORDER, not priority: mangling before-or-with arity, because
fixing arity first widens the set of calls Nim can silently capture.

1. **Name mangling** (prereq 1) — unblocks all naming, and must precede the
   arity fix. Cheap.
2. **Pending-stub arity fix** (bug #7) — restores the invent-a-fn workflow at
   build time, which every later stdlib design pass depends on. Batch F: this
   single bug blocks more examples than anything else on the list.
3. **Integer division ruling + lowering** (prereq 3) — unblocks averages,
   midpoints, binary search. One-time semantic decision.
4. **Growable sequences** (prereq 2) — the gate on half of Tier 1.
5. **std/num Tier 1** — trivial once 1 and 3 land.
6. **std/str split/join/reverse/case/trim** — biggest single unlock for
   everyday programs.
7. **`!T` unwrap ruling** (prereq 4) — before parseInt/readFile matter.
8. **std/seq query fns** — filter/map/count/contains, after growth exists.

## 7. Sum-type bug cluster (blocks Tier-anything using sum types)
Not stdlib, but gating: `match` on a payload sum type emits `case s` instead
of `case s.kind`; payload-less variant construction emits `Color.Red()`;
`_` catch-all lowers to Nim's `_` discard; match-on-bool fails exhaustiveness
with both arms present. Batch C established #1 and #2 are independent
(different code paths, different representations). Fix `case s.kind` first —
it is one token and unblocks every payload-bearing sum type.
