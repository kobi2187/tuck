# core.cmp — Tuck translation

## Shape decision
`interface Sortable` (Tuck's real contract mechanism) plus freeform
`pending:` verbs. **Compiler-verified**, `./tuck ch`: `OK`.

## The API

```tuck
type Order:
  | Before
  | Same
  | After

interface Sortable:
  fn compare({self: Self, other: Self}) -> Order

pending:
  fn flipped({o: Order}) -> Order
  fn breakTiesWith({o: Order, next: Order}) -> Order
  fn smaller[T]({a: T, b: T}) -> T
  fn larger[T]({a: T, b: T}) -> T
  fn clamped[T]({x: T, low: T, high: T}) -> T
```

## Notes on the translation
- **Nim `concept` → Tuck `interface`**, the direct counterpart and this
  language's most thoroughly specified feature. Conformance is explicit
  (`satisfies`), never structural — but that costs the stdlib nothing,
  because **`satisfies` also works as a top-level declaration**:
  `satisfies Dog: Speaker, Mover` attaches a type to a contract *from the
  calling module*, without editing the type's own declaration
  (`tests/suites/interfaces.nim:247`, run-verified 42). So `core.cmp` can
  attach `Sortable` to primitives and to types it doesn't own —
  retroactive conformance, the same capability Rust gets from trait impls
  — and re-stating a contract the object already declares is a documented
  no-op rather than an error. Explicit conformance is therefore stricter
  than Nim's structural concepts *and* no less reusable.
- **The `Equatable`/`Comparable`/`Sortable` three-way split collapses to
  one.** `Equatable` is unnecessary — Tuck records already compare with
  `==` by field (verified in `cli_smoke`, exit 17). `Comparable`
  (partial ordering, returning `Option[Order]` for NaN) folded away too:
  it existed so floats couldn't be silently sorted, but a `tryCompare`
  returning `Order?` is expressible if that guarantee is wanted — flagged
  below rather than dropped silently.
- **`by(extract)` becomes a baked record**, which is Tuck's own idiom for
  what Nim did with a returned closure. A `fnsig` names the extractor's
  shape, a **declared record type** gives that slot its type, `bake` fills
  it at compile time, and `invoke` runs it — no capture, no allocation, and
  the slot emits as a generic param so the call is direct:

  ```tuck
  fnsig KeyOf = {x: Task} -> int
  type SortBy = {items: Seq[Task], key: KeyOf}

  let byPriority = {items: tasks} SortBy bake {key: :priority}
  ```

  **The declared type is load-bearing, not decoration.** `bake` fills a
  slot whose type comes from the record's declaration — that `SortBy`
  annotation is what says `key` must match `KeyOf`. Baking onto a bare
  untyped literal (`{items: tasks} bake {key: :anything}`) has no slot
  type to match against; see `TUCK-TRANSLATION.md`'s note on what the
  checker does and doesn't enforce there today.

  The function reads the *record's* other fields, never the enclosing
  function's locals — everything it uses is placed into the record
  explicitly. See `examples/03-functions-bake.tuck` (run-gated 42).
- **`isSortable(T)` (compile-time predicate) is dropped** — Tuck has no
  `typedesc`/compile-time-reflection equivalent verified in this pass.

## Open question
Dropping `Comparable` means nothing stops a float from satisfying
`Sortable` and sorting with NaN's undefined behaviour — the exact thing
the Nim design's split existed to prevent. Restoring it means a second
interface (`fn tryCompare(...) -> Order?`) and a rule about which one
sorting requires. Worth deciding; not decided here.
