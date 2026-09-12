# alloc.map — Tuck translation

## Shape decision
A real new type. **Tuck has no map/dictionary at all** — confirmed by grep
across the spec, `LANGUAGE-OVERVIEW.md` and every real `std/*.tuck` module:
only `Seq[T]` and `Array[N, T]` exist. So unlike `alloc.vec` (which wraps
built-in `Seq`) this module is genuinely new surface, and it's the highest-
value single module in the `alloc` tier.

**Compiler-verified**, `./tuck ch`: `OK`, 11/11 `PENDING`.

## The API

```tuck
type Entry[K, V] = {key: K, value: V}
type Table[K, V] = {entries: Seq[Entry[K, V]]}

pending:
  fn newTable[K, V]() -> Table[K, V]
  fn get[K, V]({t: Table[K, V], key: K}) -> V?
  fn set[K, V]({t: Table[K, V], key: K, value: V}) -> Table[K, V]
  fn getOrSet[K, V]({t: Table[K, V], key: K, value: V}) -> Table[K, V]
  fn remove[K, V]({t: Table[K, V], key: K}) -> Table[K, V]
  fn has[K, V]({t: Table[K, V], key: K}) -> bool
  fn count[K, V]({t: Table[K, V]}) -> int
  fn keys[K, V]({t: Table[K, V]}) -> Seq[K]
  fn values[K, V]({t: Table[K, V]}) -> Seq[V]
  fn pairs[K, V]({t: Table[K, V]}) -> Seq[Entry[K, V]]
  fn clear[K, V]({t: Table[K, V]}) -> Table[K, V]
```

`..` is rejected here, same reason as `alloc.vec`/`alloc.set`: `set` returns
a new `Table`, nothing to mutate through. Call-site spelling is plain
reassignment:

```tuck
var rooms: Table[str, Room] = {entries: []} Table
rooms = {t: rooms, key: "lobby", value: room} set
```

## Notes on the translation
- **`Table` is the right name** — it's what Nim calls it, the Nim pass
  already chose it, and Tuck's own `decision` tables are a different
  construct that never appears in a type position. (`std.cli` has a
  deliberate `Table` collision for terminal output; that was already
  flagged in the Nim design and is resolved by qualified import.)
- **`getOrSet` is kept from the Nim pass**, which collapsed Rust's
  `entry(k).or_insert(v)` dance into one verb. Still the right call.
- **The `entries: Seq[Entry]` representation shown is illustrative, not
  prescriptive.** A real implementation wants open addressing over two
  parallel `Seq`s, or a `pool`-backed bucket array for the fixed-capacity
  case. The type is opaque to callers either way; what matters here is the
  verb set.
- **`retain(f)` (round-1's addition for `kv-store-server`'s TTL sweep) is
  not shown** — it takes a predicate, so it's a `fnsig`+`bake` API like
  `core.iter`'s, and it needs generic `fnsig` (recorded gap) to spell
  properly. Should be added once that lands: `fn retain[K, V]({t: Table[K, V],
  test: EntryPred[K, V]}) -> Table[K, V]`.

## Two things this module needs that Tuck doesn't have yet

1. **Hashing primitive keys — unblocked by `group`, not decided.**
   `satisfies` can't attach a primitive to an interface (`satisfies int:
   Hashable` → *"names 'int', which is not a declared object in scope"*),
   which is what blocked this. `group Hashable` doesn't have that problem —
   it's structural, no attach statement — so `Table[str, V]`'s key hashing
   is unblocked once core.hash gives `int`/`str` a `hashOf` overload
   (TASKS.md T-08). Still undecided: `FastHash` vs `SafeHash` (below) is a
   choice a bare `group Hashable` bound can't express — that part still
   wants a `fnsig` slot or a constructor pair, on top of the bound.
2. **A DoS-resistant default.** `INDEX.md`'s round-0 finding #8 was that
   `alloc.map` should default to SipHash with FNV as opt-out, because
   `chat-server`'s keys are attacker-chosen nicknames. That reasoning is
   unchanged by Tuck, and the `FastHash`/`SafeHash` split in `core.hash`
   already exists to serve it — but a `Table` with no allocator or hasher
   parameter has nowhere to say which one it uses. Needs a decision:
   a `newTableSafe` constructor pair, or a field on the type.
