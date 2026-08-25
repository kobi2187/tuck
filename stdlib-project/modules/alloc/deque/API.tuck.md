# alloc.deque — Tuck translation

## Shape decision
A real new type (`Ring[T]`), the Nim pass's own name for it — "a queue you
can add to and take from at either end, cheaply." **Compiler-verified**,
`./tuck ch`: `OK`.

## The API

```tuck
type Ring[T] = {items: Seq[T]}

pending:
  fn newRing[T]() -> Ring[T]
  fn pushBack[T]({r: Ring[T], value: T}) -> Ring[T]
  fn pushFront[T]({r: Ring[T], value: T}) -> Ring[T]
  fn popBack[T]({r: Ring[T]}) -> {rest: Ring[T], value: T}?
  fn popFront[T]({r: Ring[T]}) -> {rest: Ring[T], value: T}?
  fn first[T]({r: Ring[T]}) -> T?
  fn last[T]({r: Ring[T]}) -> T?
  fn count[T]({r: Ring[T]}) -> int
  fn isEmpty[T]({r: Ring[T]}) -> bool
```

## Notes
- **`Ring[T]` name kept** from the Nim pass, which chose it over `Deque`
  because it says what it is rather than abbreviating "double-ended queue."
  Still right, and it doesn't collide with anything in Tuck.
- **`first`/`last` rather than `front`/`back`** — the Nim pass's rename,
  matching the same words used across every other collection here.
- **This is the module most likely to want a `pool` backing.** Its stated
  use cases (work queues, sliding windows, fixed-size histories) are
  exactly the "at most N of these exist at once" shape that
  `examples/25-pools.tuck` argues a `pool` should express — a
  `Ring` over `pool`-allocated slots would get bounded memory *and* an
  honest backpressure story (`acquire` returning `?T`) for free. Worth
  designing deliberately rather than defaulting to an unbounded `Seq`.
- Same open `..`-mutation performance question as the rest of the tier.
