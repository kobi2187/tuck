# PARITY — Elixir & Ruby stdlib mining for Tuck

Source batch. Mines Elixir's `Enum`/`String`/`Map`/`Keyword` and Ruby's
`Enumerable`/`String`/`Array`/`Hash` for stdlib parity, plus 15 parser-stress
examples. Builds on the merged synthesis in STDLIB-PROPOSAL.md and the fuller
module design in STDLIB-DESIGN.md — this batch does not re-litigate module
boundaries already settled there (`seq` vs `list`, `str` vs `fmt`, Map/Set as
Tier 1 prereqs). It adds the Elixir/Ruby analogues and a naming-convention
ruling those batches didn't have the mandate to make.

## 0. Why Elixir specifically

Tuck's call rule is `{payload} fnName` — the payload is offered whole to
param 1, or spread by field. Elixir's pipe is `payload |> fn_name(args)` —
the piped value is ALWAYS the first argument. These are the same discipline
wearing different syntax:

```elixir
list |> Enum.filter(&is_even/1) |> Enum.map(&(&1 * 2)) |> Enum.sum()
```

```tuck
let evens = {items: xs, pred: :isEven} filter
let doubled = {items: evens, transform: :double} map
let total = {items: doubled} sum
```

Every `Enum` function takes the collection first *by convention*, not by
accident — Elixir's core team calls this "data-first" and it exists
specifically so pipe chains read left to right without positional gymnastics.
Tuck's payload-first postfix call has the identical requirement: the struct's
"primary" field is what the previous stage's output gets threaded into. .NET
extension methods (`xs.Where(...)`) get this for free from the receiver
syntax; Tuck has to get it from **field-naming discipline inside the payload
struct**, because there's no receiver — just a struct being pattern-matched
into params. That's the gap this batch closes.

## 1. THE naming/argument-order convention (key deliverable)

### The problem, concretely

`{items: Seq[T], pred: fn}` vs `{list: Seq[T], predicate: fn}` vs
`{self: Seq[T], pred: fn}` — nothing in Tuck's grammar forces a choice. But
the payload-first call rule means the FIRST/PRIMARY field name is load-bearing
for chaining: `xs filter {pred: :isEven}` only reads naturally if `filter`'s
struct has a field that `xs` alone can fill by *positional-whole-payload*
match, and every downstream `{items: ...} nextFn` needs the same field name
if the pipeline is going to `merge`/`alias` cleanly between stages.

### Recommendation: name the primary field by TYPE SHAPE, not by module

Reject "always `self`" (that's OO-receiver thinking bolted onto a struct
language — it also collides with the `self` convention this corpus already
uses for record-method-style payloads like `bump({self: Counter})` in
c04-struct-field-update.tuck; overloading `self` for both "the record I'm a
method of" and "the collection I'm iterating" is exactly the kind of
concept-collapse the user's own explicit-identity rule warns against). Reject
per-module bespoke names (`list`/`text`/`table`) too — that makes `merge`ing
two pipeline stages from different modules require a rename (`alias`) at
every boundary, which defeats the postfix-chain ergonomics that are the
entire point of copying Elixir's model.

**Rule: one primary-field name per payload SHAPE, fixed stdlib-wide:**

| shape | field name | rationale |
|---|---|---|
| `Seq[T]` (any element type) | `items` | already the incumbent — used by every batch A–F signature (`{items: Seq[int]} sum`) and by this batch's own `pending:` blocks; Elixir's `Enum` docs use "enumerable" generically for the same reason: the name should say "a sequence of things," not name the domain |
| `str` | `text` | incumbent in `std/str` proposals (`{text: str} split`) and STDLIB-PROPOSAL.md §3; matches `printLine`'s existing `{text: str}` in `std/io.tuck` — this one is not even a proposal, it's already load-bearing production code |
| `Map[K,V]` | `entries` | new (Map doesn't exist yet — prereq 6b). NOT `map`, because `map` is also a verb (`Enum.map`) and Tuck fn names and field names share one identifier namespace inside a struct literal — `{map: m} map` parses but reads like a typo forever. `entries` is what `Map.to_list`/`Enum.into` call the K/V pairs in both Elixir and Ruby's `Hash#each`. |
| single scalar being transformed (`int`/`float`) | `value` | incumbent — `std/num` Tier 1 (`{value: n} abs`), already the payload shape `toStr` uses |
| a record/struct being transformed in place (`..mutate` chains) | `self` | KEEP for this one shape only — it's the shape c04 already uses, and it's the one case where "the record this fn is conceptually a method of" is the right mental model, because there's no sequence/text/scalar semantics to name instead |

The test for whether a name belongs in this table: **does the SAME name
appear as the primary field across unrelated modules for the same shape?**
`items` must mean `Seq[T]` whether it's `std/seq`, `std/list`, or a future
`std/set`'s `toSeq`. If two modules pick different names for the same shape,
`merge`ing a `list`-stage struct into a `str`-stage struct silently produces
two dead fields instead of one filled parameter — a bug the type checker
won't catch because struct literals allow extra fields (SYNTAX.md: "subset
matching; extra fields are fine").

Secondary fields (the non-primary arguments) should read as what Elixir
calls them when there's a direct analogue — `sep` (not `separator` — Elixir's
`String.split/2` uses `sep\_arg` internally, but Ruby's `split(pattern)` and
common usage favor the short form; Tuck's own e10/e11 pending blocks already
wrote `sep`), `pred` (not `predicate`, not `fun` — Elixir uses `fun` but
Tuck's `fn` is a reserved word so a field literally named `fn` is illegal;
`pred` sidesteps the collision and is self-documenting), `default` (matches
`Map.get(map, key, default)` exactly), `count` for a take/drop/repeat
quantity (Ruby's `Array#take(n)`/`#drop(n)` name the param `n`; `count` is
more legible and doesn't collide with the stdlib fn also named `count`
appearing as a value in the same scope).

### The `?` predicate problem

Elixir names predicates `empty?`, `any?`, `has_key?` — trailing `?` is part
of the identifier. Ruby does the same (`empty?`, `include?`). Tuck's lexer
reserves `?` for `?T`/`!T` type syntax; `tkQuestion` never appears in the
identifier grammar (confirmed in SYNTAX.md and DISCOVERIES.md #9). So Tuck
needs a different predicate marker.

**Recommendation: `is`/`has`/`can` verb prefixes, not a suffix — camelCase
compound, no punctuation:**

- `isEmpty`, `isSome`, `isOk` — state predicates (Elixir `empty?`, `is_nil?`)
- `hasKey`, `hasValue`, `contains` — containment predicates (Elixir
  `has_key?`; note `contains` itself needs no prefix — it's already a verb,
  matching batch D's incumbent `{items, value} contains`)
- `startsWith`, `endsWith` — already verb-shaped by convention (batch E
  incumbent), no prefix needed, same reasoning as `contains`
- `any`/`all` — KEEP bare, no prefix (batch F/STDLIB-DESIGN.md incumbent
  `{items, pred} any` / `all`). These read as verbs applied to a predicate
  already (English "any match" not "is any"), and prefixing to `isAny` reads
  worse, not better. The rule is "predicates need SOME verb-shape," not
  "predicates need a prefix" — `is`/`has` fill the gap only where the bare
  name would otherwise read as a noun (`empty` the adjective vs `isEmpty`
  the check).

Rejected alternative: trailing `Q` or `P` (`emptyQ`, `emptyP` mimicking
Lisp's `-p`) — no precedent anywhere in the existing corpus, purely invented,
fails the "reads like Tuck" bar SYNTAX.md sets. Rejected: `check`/`test`
prefix (`checkEmpty`) — reads like a testing framework, not a predicate.

## 2. Module catalogue — Elixir/Ruby analogues

Grouped by the modules STDLIB-PROPOSAL.md/STDLIB-DESIGN.md already
established (`seq`, `list`, `str`, `num`, `map`, `opt`). Each entry: real
Tuck signature, tier, Elixir/Ruby analogue. Entries already Tier-1-ruled by
earlier batches are marked EXISTING PROPOSAL and not re-argued; this batch's
NEW entries are marked NEW.

### std/list (Enum/Enumerable-derived; all `Seq[T]`-in shaped, `items` primary field)

```tuck
# Tier 1 — EXISTING PROPOSAL, restated with the `items` convention locked
fn filter[T]({items: Seq[T], pred: fn}) -> Seq[T]          # Enum.filter / Array#select
fn map[T, U]({items: Seq[T], transform: fn}) -> Seq[U]     # Enum.map / Array#map
fn sum({items: Seq[int]}) -> int                            # Enum.sum / Array#sum
fn count[T]({items: Seq[T], pred: fn}) -> int                # Enum.count/2 / Array#count{}

# Tier 1 — NEW from this mining pass
fn reduce[T, Acc]({items: Seq[T], init: Acc, step: fn}) -> Acc   # Enum.reduce/3 / Ruby #inject
  # named `reduce` not `fold` — Elixir's fn IS called reduce; Ruby's `inject` is the
  # outlier even in its own stdlib (aliased to `reduce` there too). STDLIB-DESIGN.md
  # proposed `fold`; this batch recommends renaming to `reduce` for cross-reference
  # recognizability — no semantic difference, pure naming, flag for the merge pass.
fn any[T]({items: Seq[T], pred: fn}) -> bool                 # Enum.any?/2 / Array#any?
fn all[T]({items: Seq[T], pred: fn}) -> bool                 # Enum.all?/2 / Array#all?
fn find[T]({items: Seq[T], pred: fn}) -> ?T                  # Enum.find/2 / Array#find

# Tier 2 — NEW
fn sortBy[T, K]({items: Seq[T], key: fn}) -> Seq[T]          # Enum.sort_by/2 / Array#sort_by
  # Elixir's data-first + a `key` projection fn, not a full comparator — cheaper to
  # write and read than STDLIB-DESIGN.md's `sortBy(..., compare: fn)` for the common
  # case ("sort by this field"); keep `sortBy` for the projection form, add a distinct
  # `sortWith({items, compare: fn})` only if a real example needs custom ordering
fn groupBy[T]({items: Seq[T], key: fn}) -> Map[str, Seq[T]]  # Enum.group_by/2 / Array#group_by — Tier 1 blocked, Map is prereq 6b
fn uniq[T]({items: Seq[T]}) -> Seq[T]                        # Enum.uniq/1 / Array#uniq — rename of STDLIB-DESIGN's `distinctValues`; `uniq` is shorter and is what BOTH source languages call it (rare cross-language agreement, worth taking)
fn zip[A, B]({a: Seq[A], b: Seq[B]}) -> Seq[{first: A, second: B}]   # Enum.zip/2 / Array#zip
fn frequencies[T]({items: Seq[T]}) -> Map[T, int]            # Elixir Enum.frequencies/1 — no Ruby stdlib equiv (Ruby: `tally`, same idea). High value: turns "count occurrences" (batch E's countOccurrences, D's count-matching) into one call instead of a hand-rolled loop. Blocked on Map (prereq 6b).
fn minBy[T, K]({items: Seq[T], key: fn}) -> T                # Enum.min_by/2 / Array#min_by
fn maxBy[T, K]({items: Seq[T], key: fn}) -> T                # Enum.max_by/2 / Array#max_by
fn chunkEvery[T]({items: Seq[T], size: int}) -> Seq[Seq[T]]  # Enum.chunk_every/2 — rename of STDLIB-DESIGN's `chunk` for the exact Elixir arity/name; Ruby's analogue is `each_slice`
fn partition[T]({items: Seq[T], pred: fn}) -> {yes: Seq[T], no: Seq[T]}  # Ruby Array#partition (Elixir has it too, same name). NEW, not in earlier batches — splits one traversal into two results, common enough (odd/even, pass/fail) to earn a name instead of two `filter` calls with an inverted predicate.
fn eachWithIndex[T]({items: Seq[T], step: fn}) -> void       # Ruby Array#each_with_index. Tuck already HAS `for idx, item in items:` as syntax (SYNTAX.md) so this is lower-value than in Ruby — include only if a callback-style (not loop-style) traversal is wanted; likely SKIP, syntax already covers it. Marked NEW but flagged low-priority/possibly-redundant.

# Tier 3
fn take[T]({items: Seq[T], count: int}) -> Seq[T]            # Enum.take/2 / Array#take — EXISTING PROPOSAL
fn drop[T]({items: Seq[T], count: int}) -> Seq[T]             # Enum.drop/2 / Array#drop — rename of STDLIB-DESIGN's `skip` to match both source names exactly
fn flatMap[T, U]({items: Seq[T], transform: fn}) -> Seq[U]   # Enum.flat_map/2 / Array#flat_map
fn sample[T]({items: Seq[T]}) -> T [io]                       # Ruby Array#sample — random pick, effect-tagged per this corpus's random/io ruling
fn rotate[T]({items: Seq[T], count: int}) -> Seq[T]            # Ruby Array#rotate
```

### std/str (String-derived; `text` primary field, all incumbent-compatible)

```tuck
# Tier 1 — EXISTING PROPOSAL (split/join/reverse/upper/lower/trim/parseInt/charAt)
# unchanged; Elixir/Ruby analogues: String.split//join via Enum.join, String.reverse,
# String.upcase/downcase, String.trim, String.to_integer, String.at/graphemes

# Tier 2 — NEW
fn containsText({text: str, needle: str}) -> bool             # Elixir String.contains?/2 / Ruby String#include? — named containsText not `contains` to avoid a same-name-different-payload-shape clash with std/list's `contains` (Seq vs str primary field would both compile under structural typing but confuse readers scanning for "which contains is this")
fn padLeading({text: str, width: int, pad: str}) -> str        # Elixir String.pad_leading/3 — rename of STDLIB-PROPOSAL's `padLeft` to the Elixir spelling since this batch is specifically arguing for Elixir alignment; Ruby's rjust is the same idea, different name — Elixir spelling wins per this batch's mandate
fn padTrailing({text: str, width: int, pad: str}) -> str       # Elixir String.pad_trailing/3 (Ruby ljust)
fn graphemes({text: str}) -> Seq[str]                            # Elixir String.graphemes/1 / Ruby String#chars — explicitly a Tier-3-until-char-type-lands item; see §3 rejections, codepoint correctness is a real trap here
fn slice({text: str, start: int, to: int}) -> str                # Elixir String.slice/2, Ruby String#[range] — byte-semantics caveat inherited from charAt's existing prereq-5 note
fn squeeze({text: str}) -> str                                   # Ruby String#squeeze — collapse runs of repeated chars; Tier 3, no Elixir equivalent, include only if demand shows up
```

### std/map (NEW module — Map/Keyword-derived; `entries` primary field; entirely blocked on prereq 6b)

```tuck
# Tier 1 — blocked on Map[K,V] existing as a type at all (DISCOVERIES.md #18)
fn get[K, V]({entries: Map[K, V], key: K, fallback: V}) -> V     # Map.get/3 with EXPLICIT default param, not Ruby's Hash.new(default) constructor-time default — Elixir's call-site default is the better fit for a language with no object construction ceremony; matches this batch's std/opt default-value pattern (`unwrapOr`) for consistency
fn put[K, V]({entries: Map[K, V], key: K, value: V}) -> Map[K, V]   # Map.put/3 / Hash#[]=, but returns a NEW map — Tuck has no mutable-in-place collection story yet beyond the `xs[i]=v` array sugar, so treat Map as value-semantic like everything else here until proven otherwise
fn hasKey[K, V]({entries: Map[K, V], key: K}) -> bool             # Map.has_key?/2 / Hash#key? — predicate-prefix convention from §1
fn keys[K, V]({entries: Map[K, V]}) -> Seq[K]                     # Map.keys/1 / Hash#keys
fn values[K, V]({entries: Map[K, V]}) -> Seq[V]                   # Map.values/1 / Hash#values

# Tier 2
fn delete[K, V]({entries: Map[K, V], key: K}) -> Map[K, V]       # Map.delete/2 / Hash#delete
fn merge[K, V]({a: Map[K, V], b: Map[K, V]}) -> Map[K, V]         # Map.merge/2 / Hash#merge — NOTE: collides in spirit with the struct `merge` already in SYNTAX.md (`{episode, prefs} merge`), which flattens STRUCTS not Maps. Same verb, different shape — acceptable in Tuck's structural-typing world (payload shape disambiguates) but flag for the merge pass since it's exactly the kind of same-name/different-shape situation §1 warns readers about elsewhere.
fn getAndUpdate[K, V]({entries: Map[K, V], key: K, update: fn}) -> {entries: Map[K, V], old: ?V}   # Elixir Map.get_and_update/3 — Tier 3 realistically, included because Elixir treats it as core enough to name; needs closures over the update fn to be genuinely useful, which this corpus hasn't proven exist yet (see §3)
```

### std/opt (existing module; `Keyword`/`{:ok,_}` comparison)

```tuck
fn unwrapOr[T]({self: ?T, fallback: T}) -> T    # EXISTING PROPOSAL, unchanged
```

Elixir's `{:ok, value}` / `{:error, reason}` tuple convention plus `with`
chaining is the closest analogue to Tuck's `!T`, and it's worth being
explicit about where they diverge: Elixir's tagged tuples are a *library*
convention (any 2-tuple can masquerade as one, nothing stops a mismatched
`{:ok, x, y}`), while Tuck's `!T` is a *language* result type with a real
`error:` payload in the signature (`!void [io, error: FsError]` — see
`std/fs.tuck`). That's strictly better-typed than Elixir's convention, and
Tuck should keep leaning on it rather than importing Elixir's untyped tuple
idiom. The `with` special form (Elixir's short-circuiting `{:ok, x} <- foo()`
chain) has no Tuck analogue and shouldn't get one via stdlib fns — it needs
either the still-missing `!T`→`T` unwrap operator (prereq 4, DISCOVERIES.md
#9) or nothing; a `withChain` stdlib fn faking control flow would be the
kind of macro-shaped workaround §3 explicitly rejects.

## 3. Where Elixir/Ruby should NOT be copied

1. **No immutable-persistent-data-structure assumptions carried over
   uncritically.** Elixir's `Map`/`List` share structure across "updates"
   (HAMT tries, cons cells) so `Map.put` being O(log n) and non-mutating is
   free performance-wise. Tuck has no such backing structure specified
   anywhere in the compiler source reviewed for SYNTAX.md — a naive `Map.put`
   modeled on Elixir's semantics but implemented as copy-on-write over a
   flat structure would be O(n) per update and silently quadratic in a loop
   that "looks like" idiomatic Elixir. STDLIB-DESIGN.md already flags this
   general risk for `Seq`; it applies doubly to `Map` because Elixir code
   leans on cheap immutable updates far more heavily than Elixir code leans
   on cheap immutable list-growth, and this batch's mining surfaced several
   `Map.put` chains from real Elixir modules that would be a performance
   trap if ported as literal patterns.

2. **No metaprogramming, blocks, or `&`-capture sugar.** Every Elixir
   example above passes `&is_even/1` or `&(&1 * 2)` — anonymous function
   capture syntax Tuck has no equivalent for. Tuck's `:name` fn-reference
   (SYNTAX.md's `bake {op: :plus}`, this batch's `:isEven`/`:plus` usage)
   only reaches NAMED top-level fns, not inline lambdas. Every signature
   above that takes a `pred`/`transform`/`key` fn argument is written
   assuming Tuck callers pass `:someTopLevelFn`, never an inline closure —
   because Tuck has no closure literal syntax in anything reviewed here.
   Don't let the stdlib design imply otherwise by copying Ruby's
   block-heavy idiom (`each { |x| ... }`) into doc examples.

3. **No dynamic-typing conveniences.** Elixir/Ruby happily let
   `Enum.sum([1, 2.5, "3"])` fail at runtime or coerce; Tuck is statically,
   structurally typed. Every signature above is monomorphic-per-call
   (`Seq[int]` for `sum`, not "any enumerable of anything summable"). No
   Ruby-style duck-typed `to_s`/`to_i` coercion-on-call — Tuck already has
   `toStr` as an explicit, typed conversion and that's the right shape to
   keep, not loosen.

4. **No Ruby monkey-patching / reopening classes.** Ruby's `Comparable`
   mixin and reopening `Integer`/`String` to add methods has zero Tuck
   analogue and shouldn't get one — Tuck has no class/object system to
   patch. Where Ruby ships a fn as `Integer#gcd`, Tuck ships it as a free
   fn in `std/num` taking the int as its payload's primary field; that's
   the whole translation, no mixin story needed or wanted.

5. **No Elixir process/actor model borrowed into these modules.** Elixir's
   `Enum`/`String`/`Map` are pure-data modules with no relationship to its
   `GenServer`/process primitives, and the team lead's brief is explicit
   that Tuck's actor model is covered separately — nothing in this document
   references `spawn`/`send`/mailboxes, correctly, because none of the
   mined modules touch them either. Noted only to close the loop: parity
   was checked and there was nothing to reject here, the two areas just
   don't overlap.

## 4. Tier 1 summary (this batch's contribution)

New-to-this-batch Tier 1/2 items, on top of what STDLIB-PROPOSAL.md already
locked in: `reduce`, `any`, `all`, `find` (list); `containsText` (str, once
Tier 1 str lands); `get`/`put`/`hasKey`/`keys`/`values` (map, blocked on
prereq 6b same as the rest of that module). Everything else above is Tier 2/3
— genuinely useful, not blocking ordinary programs the way the Tier 1 list
in STDLIB-PROPOSAL.md §3 is.
