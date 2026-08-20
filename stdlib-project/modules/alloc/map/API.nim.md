# alloc.map — Nim API

**Purpose**
`Table[K, V]` — look a value up by a key, fast. The workhorse of the tier, and the one collection almost every program touches.

**Protocols implemented**
`Gettable[K, V]`, `Settable[K, V]`, `Collection[(K, V)]`, per PROTOCOLS' assignment table.

## The API

```nim
type Table*[K, V] = object   ## hashed, unordered, average O(1). DoS-resistant hashing by default.

proc newTable*[K, V](memory = defaultMemory()): Table[K, V]
proc newTable*[K, V](capacity: int; memory = defaultMemory()): Table[K, V]
proc newTable*[K, V](hasher: Hasher; memory = defaultMemory()): Table[K, V]
  ## Swap in core.hash's FNV when keys are yours, not a stranger's. Default is SipHash for a reason.

proc get*[K, V](t: Table[K, V]; key: K): Option[V]      ## never raises; absence is ordinary
proc set*[K, V](t: var Table[K, V]; key: K; value: V)   ## raises OutOfMemory if it must grow and can't
proc trySet*[K, V](t: var Table[K, V]; key: K; value: V): bool
proc has*[K, V](t: Table[K, V]; key: K): bool
proc remove*[K, V](t: var Table[K, V]; key: K): Option[V]  ## hands back what was there
proc `[]`*[K, V](t: var Table[K, V]; key: K): var V         ## raises KeyMissing — for keys you know exist
proc getOrSet*[K, V](t: var Table[K, V]; key: K; fallback: V): var V
  ## Read it, or put `fallback` there and read that. One hash, not two.
proc getOrSet*[K, V](t: var Table[K, V]; key: K; build: proc (): V): var V
  ## Same, but only builds the fallback if it's actually needed.
proc adjust*[K, V](t: var Table[K, V]; key: K; delta: V)
  ## Relative change, creating the entry at zero if absent — kv-store-server's INCR in one call.
proc count*[K, V](t: Table[K, V]): int
proc clear*[K, V](t: var Table[K, V])
proc keepIf*[K, V](t: var Table[K, V]; pred: proc (key: K; value: var V): bool)
  ## Bulk conditional eviction in a single pass, no temporary allocation, no iterator-invalidation trap.
iterator list*[K, V](t: Table[K, V]): (K, V)   ## the sole Collection primitive; order is unspecified
iterator keys*[K, V](t: Table[K, V]): K
iterator values*[K, V](t: Table[K, V]): var V
proc memory*[K, V](t: Table[K, V]): Memory
```

`isEmpty`, `first`, `toSeq`, `each` all arrive from `Collection`. `Adjustable[V]` falls out of `adjust`.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `HashMap<K, V>` | `Table[K, V]` | PROTOCOLS' table, and Nim's own stdlib word. Zero new vocabulary for a Nim reader |
| `insert` | `set` | the structural verb. `insert` also wrongly hints "fails if present" |
| `contains_key` | `has` | one syllable, same word as every other module's membership test |
| `entry(k).or_insert(v)` | `getOrSet(t, k, v)` | one call instead of a two-step type dance, and it says exactly what it does |
| `get_mut` | `values` iterator / `[]` | Nim's `var V` return covers mutation without a second method name |
| `retain(f)` | `keepIf(pred)` | matches `alloc.vec` exactly; "keep if" tells you which half survives |
| `with_hasher_in(h, a)` | `newTable(hasher, memory =)` | four Rust constructors collapse to one with named arguments |
| *(none)* | `adjust` | new: PROTOCOLS has a verb for relative change, so INCR stops being hand-rolled read-modify-write |

## In use — kv-store-server's TTL sweep

```nim
var store = newTable[Text, Value](capacity = 65536)

store.set("visits", Value(kind: Counter, n: 0))
store.adjust("visits", 1)                            # INCR, one hash, no read-modify-write dance

let hits = store.getOrSet("session:" & id) do -> Value: newSession()

proc sweepExpired(now: Instant) =
  store.keepIf do (key: Text; v: var Value) -> bool:
    v.expiresAt.isNone or v.expiresAt.get() > now    # one pass, under one lock, zero allocation
```

And todo-cli, where the whole thing stays boring:

```nim
var byId = newTable[Uuid, Task]()
byId.set(task.id, task)
if byId.has(id): echo byId.get(id).get().title
```

## Vocabulary exceptions

- **`getOrSet` is a compound of two vocabulary verbs, not a new one.** It exists because the double-hash it avoids is real (chat-server's nickname registration under lock), and because Rust's `Entry` type is exactly the kind of machinery a casual coder should never have to meet. Reading it as "get, or set then get" is correct.
- **`[]` raises `KeyMissing` while `get` returns `Option`.** This looks like mixing failure modes but isn't: `get` is the vocabulary verb and obeys the rule absolutely. `[]` is Nim's indexing operator, and Nim programmers already expect indexing to raise. Anyone unsure reaches for `get` and is right.
- **`set` raises rather than returning the previous value.** Rust's `insert` returned `Option<V>`; splitting that off means `set` matches its signature everywhere else in the library. If you want the old value, `remove` then `set` — and you almost never want it.
- **Iteration order is unspecified, on purpose.** Sort explicitly through `core.cmp` when you need a stable listing.
