# PARITY-RUST — Rust std as the parity reference for Tuck stdlib

Source: Rust `std`/`core` (`Option`, `Result`, `Vec`, slices, `str`/`String`,
`HashMap`/`HashSet`, `Iterator`, `std::fmt`, `std::fs`, `std::time`). Cross-
referenced against `rosetta/STDLIB-PROPOSAL.md` (empirical, 6-batch merge) and
`rosetta/DISCOVERIES.md` (verified compiler behavior). Where the two disagree
on a signature, STDLIB-PROPOSAL wins — it's demand-driven; this file adds the
Rust analogue and fills gaps STDLIB-PROPOSAL didn't need to cover (Option/
Result combinators, HashMap/HashSet, iterator adaptors).

Every entry is a **real Tuck signature** in the language's actual syntax:
struct-payload params, postfix calls, `!T`/`?T`, `[effects]`. Tier follows
STDLIB-PROPOSAL's scheme (1 = can't write ordinary programs without it, 2 =
any developer expects it, 3 = nice to have).

---

## 0. The headline design question — `opt`/`result` combinators

**Tuck has `!T` and `?T` today but zero unwrap idiom.** Verified
(DISCOVERIES #9): `expr?` is not in the parser at all — `tkQuestion` only
appears in type position. The *only* working route is `if r.ok` narrowing
(TOUR.md). This is the biggest hole relative to Rust, because Rust's whole
`Option`/`Result` ergonomy is built on `?` plus a combinator library, and Tuck
currently has neither the operator nor the library.

This section proposes the full `std/opt` and `std/result` surface. Every
entry below is flagged:
- **[fn]** — an ordinary function, needs nothing new from the compiler beyond
  `?T`/`!T` being real generic-ish types the checker can pattern-match on.
- **[lang]** — needs compiler/parser support first; the fn surface is a thin
  wrapper once the feature lands.

### std/opt (`?T`, modeled on `Option<T>`)

```tuck
fn isSome[T]({self: ?T}) -> bool                              # [fn]  Option::is_some
fn isNone[T]({self: ?T}) -> bool                               # [fn]  Option::is_none
fn unwrapOr[T]({self: ?T, default: T}) -> T                    # [fn]  Option::unwrap_or  (VERIFIED — see #13)
fn unwrapOrElse[T]({self: ?T, fallback: fnsig}) -> T           # [fn]  Option::unwrap_or_else
fn expect[T]({self: ?T, message: str}) -> T                    # [fn]  Option::expect — panics with message
fn map[T, U]({self: ?T, transform: fnsig}) -> ?U               # [fn]  Option::map
fn andThen[T, U]({self: ?T, next: fnsig}) -> ?U                # [fn]  Option::and_then (flatMap)
fn filter[T]({self: ?T, pred: fnsig}) -> ?T                    # [fn]  Option::filter
fn okOr[T, E]({self: ?T, err: E}) -> !T                        # [fn]  Option::ok_or — bridges opt -> result
fn orElse[T]({self: ?T, fallback: ?T}) -> ?T                   # [fn]  Option::or
```

### std/result (`!T`, modeled on `Result<T, E>`)

```tuck
fn isOk[T]({self: !T}) -> bool                                 # [fn]  Result::is_ok
fn isErr[T]({self: !T}) -> bool                                # [fn]  Result::is_err
fn unwrapOr[T]({self: !T, default: T}) -> T                    # [fn]  Result::unwrap_or
fn unwrapOrElse[T]({self: !T, fallback: fnsig}) -> T           # [fn]  Result::unwrap_or_else
fn expect[T]({self: !T, message: str}) -> T                    # [fn]  Result::expect — panics with message
fn map[T, U]({self: !T, transform: fnsig}) -> !U               # [fn]  Result::map
fn mapErr[T]({self: !T, transform: fnsig}) -> !T               # [fn]  Result::map_err
fn andThen[T, U]({self: !T, next: fnsig}) -> !U                # [fn]  Result::and_then
fn ok[T]({self: !T}) -> ?T                                     # [fn]  Result::ok — bridges result -> opt
```

### The `?`-propagation operator itself — **[lang]**, not stdlib

Rust's `?` desugars to an early-return on `Err`/`None`. Tuck's `if r.ok`
narrowing is the only working substitute today, and it does not compose
across call chains the way Rust's `?` does — every fallible call needs its
own `if`, which is exactly the boilerplate `?` exists to remove. Two options
for the user to rule on, concrete enough to pick between:

1. **Add `expr?` to the expression parser**, desugaring to "if `!T`/`?T` is
   error/none, `return` it from the enclosing fn (which must itself return
   `!T`/`?T` with a compatible error type); else bind the payload." This is
   the direct Rust transplant and reads naturally after Tuck's postfix style:
   `{path} readFile? .content upper`.
2. **Do nothing at the parser level; lean on `match`.** Ship the `[fn]`
   combinators above and let `match r: Ok(v): ... Err(e): ...` (once sum-type
   match is fixed — DISCOVERIES bug cluster) be the idiom. Cheaper, but every
   multi-step fallible pipeline stays visually noisy compared to Rust.

Recommendation: ship the `[fn]` combinator library now (it needs nothing new
and unblocks `unwrapOr`-style chains immediately — DISCOVERIES #13 shows
`unwrapOr` already partially exists and has a call-emission bug to fix
regardless). Treat `expr?` (option 1) as a separate, later language ruling —
don't block the stdlib catalogue on it.

---

## 1. Tier 1 — direct extensions of the existing STDLIB-PROPOSAL Tier 1

These are Rust analogues of fns STDLIB-PROPOSAL already tiered; listed here
for traceability, not re-litigated.

```tuck
# std/seq  (Rust: Vec<T> / slice)
fn push[T]({items: Seq[T], value: T}) -> Seq[T]        # Vec::push
fn sum({items: Seq[int]}) -> int                        # Iterator::sum
fn min({items: Seq[int]}) -> int                        # Iterator::min
fn max({items: Seq[int]}) -> int                        # Iterator::max
fn contains[T]({items: Seq[T], value: T}) -> bool       # slice::contains
fn indexOf[T]({items: Seq[T], value: T}) -> int         # Iterator::position (Rust returns Option<usize>; Tuck: -1 on miss per STDLIB-PROPOSAL)
fn filter[T]({items: Seq[T], pred: fnsig}) -> Seq[T]    # Iterator::filter
fn map[T, U]({items: Seq[T], transform: fnsig}) -> Seq[U]  # Iterator::map

# std/str  (Rust: str / String)
fn split({text: str, sep: str}) -> Seq[str]             # str::split
fn join({items: Seq[str], sep: str}) -> str             # slice::join
fn reverse({text: str}) -> str                          # str::chars().rev()
fn upper({text: str}) -> str                            # str::to_uppercase
fn lower({text: str}) -> str                            # str::to_lowercase
fn trim({text: str}) -> str                             # str::trim
fn parseInt({text: str}) -> !int                        # str::parse::<i64>()
```

## 2. Tier 1 additions this batch contributes — Map/Set (Rust: HashMap/HashSet)

STDLIB-PROPOSAL already flags `Map[K,V]` absence as prereq 6b. Full surface,
Rust-modeled:

```tuck
type Map[K, V]                                          # opaque; HashMap<K, V>

fn insert[K, V]({self: Map[K, V], key: K, value: V}) -> Map[K, V]   # HashMap::insert
fn get[K, V]({self: Map[K, V], key: K}) -> ?V                        # HashMap::get (borrow-checked in Rust; here just returns by value)
fn containsKey[K, V]({self: Map[K, V], key: K}) -> bool               # HashMap::contains_key
fn remove[K, V]({self: Map[K, V], key: K}) -> Map[K, V]               # HashMap::remove
fn len[K, V]({self: Map[K, V]}) -> int                                 # HashMap::len
fn keys[K, V]({self: Map[K, V]}) -> Seq[K]                             # HashMap::keys
fn values[K, V]({self: Map[K, V]}) -> Seq[V]                           # HashMap::values

type Set[T]                                              # opaque; HashSet<T>

fn add[T]({self: Set[T], value: T}) -> Set[T]            # HashSet::insert
fn hasValue[T]({self: Set[T], value: T}) -> bool         # HashSet::contains — NOT `contains`, avoid clash w/ std/seq contains overload confusion across modules
```

**Rejected from Rust's design**: no `entry()` API (`Entry<'a, K, V>` needs
borrow lifetimes Tuck doesn't have — see §4). `insert`/`remove`/`add` return
the updated collection (value semantics + reassignment, e.g.
`m = m.insert(...)` in Tuck spelling `{self: m, key: k, value: v} insert`)
rather than Rust's in-place `&mut self` mutation, because Tuck has no
`&mut`/borrow story either. This is the same shape STDLIB-PROPOSAL already
uses for `push` returning `Seq[T]`.

## 3. Tier 2

```tuck
# std/num (Rust: core::cmp, i64 methods)
fn pow({base: int, exp: int}) -> int                     # i64::pow
fn sqrt({value: int}) -> int                              # f64::sqrt, truncated
fn gcd({a: int, b: int}) -> int                            # not in std, but ubiquitous; Euclidean
fn clamp({value: int, low: int, high: int}) -> int         # Ord::clamp

# std/seq (Rust: slice methods)
fn first[T]({items: Seq[T]}) -> ?T                        # slice::first
fn last[T]({items: Seq[T]}) -> ?T                          # slice::last
fn windows[T]({items: Seq[T], size: int}) -> Seq[Seq[T]]  # slice::windows
fn chunks[T]({items: Seq[T], size: int}) -> Seq[Seq[T]]   # slice::chunks
fn splitAt[T]({items: Seq[T], index: int}) -> {left: Seq[T], right: Seq[T]}  # slice::split_at
fn sortBy[T]({items: Seq[T], key: fnsig}) -> Seq[T]       # slice::sort_by_key
fn binarySearch({items: Seq[int], target: int}) -> ?int   # slice::binary_search -> index

# std/str (Rust: str methods)
fn find({text: str, needle: str}) -> ?int                 # str::find -> byte index
fn replace({text: str, from: str, to: str}) -> str        # str::replace
fn startsWith({text: str, prefix: str}) -> bool           # str::starts_with
fn endsWith({text: str, suffix: str}) -> bool             # str::ends_with

# std/fmt (Rust: std::fmt)
fn padLeft({text: str, width: int, fill: str}) -> str     # width/fill formatting
fn toFixed({value: float, places: int}) -> str            # {:.N} precision
```

## 4. Where Rust's design must NOT be copied — specifics

Tuck has no traits, no closures (only named `fnsig`/`bake`/`:name` fn refs —
no capturing anonymous lambdas), no lifetimes, and no borrow checker today.
Concretely, this breaks:

1. **Iterator adaptor *chains* (`impl Iterator<Item=T>`, lazy evaluation).**
   Rust's `.iter().filter(...).map(...).take(5).collect()` is lazy and
   monomorphized per-chain via `impl Trait`. Tuck has neither trait objects
   nor generic closures to type a `Filter<Map<...>>` chain, and STDLIB-
   PROPOSAL already rejected `std/linq`-style laziness for the same reason
   (no closures/generators to back it). Tuck's `filter`/`map` above are
   **eager**, each materializing a full `Seq[T]` — call it `std/list`, per
   STDLIB-PROPOSAL's `seq` (storage) vs `list` (algorithms) split. A 3-stage
   pipeline in Tuck allocates 3 intermediate seqs where Rust allocates one
   output. Acceptable now; revisit only if `bake`/generics grow enough to
   express a real iterator trait.
2. **`impl Trait` / generic trait bounds (`T: Ord`, `T: Clone`).** Rust's
   `min`/`max`/`sort_by_key` are generic over any `Ord`. Tuck has no trait
   constraint syntax, so per STDLIB-PROPOSAL prereq 6 the honest MVP is
   **int-only** monomorphic signatures (`min({items: Seq[int]}) -> int`),
   not a generic `[T]` with an implied bound the checker can't express or
   enforce. Don't write `fn min[T]({items: Seq[T]}) -> T` — it would typecheck
   against anything, including un-comparable structs, with no error.
3. **By-reference slicing / `&[T]`, `&mut Vec<T>`, `&str`.** Rust's
   `first()`/`last()`/`get()` return borrowed references (`Option<&T>`), and
   mutation methods take `&mut self`. Tuck has no reference type in this
   syntax at all — every payload is passed and returned by value (see how
   `std/seq::at`/`setAt` already work: `at` returns `T` by value, `setAt`
   takes the new value and returns `void`, mutating via the `var` binding
   sugar rather than a reference param). So `first[T]({items: Seq[T]}) -> ?T`
   above returns an owned copy, not `Option<&T>` — cheap for `int`, a real
   cost for large structs, but there's no alternative without borrows.
   `entry()` (Map, above) is rejected outright for the same reason: it
   returns a live mutable handle into the map, which requires exactly the
   lifetime Tuck doesn't have.

---

## 5. Summary for the user

- **Key deliverable**: `std/opt` + `std/result` combinator surface above
  (§0) — 10 opt fns, 9 result fns, all **[fn]**, buildable today modulo the
  existing arity/mangling prereqs. The `?`-propagation operator is a
  separate **[lang]** decision, deliberately not blocking this catalogue.
- **Tier 1 additions this batch**: `Map[K,V]`/`Set[T]` full CRUD surface
  (§2), filling STDLIB-PROPOSAL prereq 6b.
- **Reject-from-Rust list** (§4): (1) lazy iterator adaptor chains — ship
  eager `std/list` instead; (2) generic `Ord`-bounded `min`/`max`/`sortBy` —
  ship int-only monomorphic versions; (3) reference-returning slice/map
  accessors (`&T`, `entry()`) — everything returns owned values instead.
