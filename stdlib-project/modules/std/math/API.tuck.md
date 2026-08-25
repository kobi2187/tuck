# std.math — Tuck translation

## Shape decision
Freeform `pending:` over plain records. **Compiler-verified**, `./tuck ch`:
`OK`.

## The API

```tuck
type Decimal = {units: i64, scale: u8}
type Rounding:
  | HalfUp
  | HalfEven
  | Down
  | Up

type Stats = {count: int, mean: float, variance: float, stddev: float, min: float, max: float}

pending:
  fn decimal({units: i64, scale: u8}) -> Decimal
  fn parseDecimal({t: str}) -> Decimal?
  fn addDec({a: Decimal, b: Decimal}) -> Decimal
  fn subDec({a: Decimal, b: Decimal}) -> Decimal
  fn mulDec({a: Decimal, b: Decimal}) -> Decimal
  fn divDec({a: Decimal, b: Decimal, scale: u8, mode: Rounding}) -> Decimal?
  fn decToStr({d: Decimal}) -> str

  fn describe({samples: Seq[float]}) -> Stats
  fn percentile({samples: Seq[float], p: float}) -> float?
  fn sqrtOf({x: float}) -> float
  fn powOf({base: float, exp: float}) -> float
  fn lnOf({x: float}) -> float?
  fn sinOf({x: float}) -> float
  fn cosOf({x: float}) -> float
```

## Notes
- **`Decimal` stays a record, not a `distinct`** — it carries two fields
  (units + scale), so there's nothing to make distinct *from*. Exact money
  math was `math-toolkit-cli`'s driving requirement and the design is
  unchanged.
- **`divDec` keeps its explicit `(scale, mode)`**, which was round-1's
  finding: division is the one operation that can be non-terminating, so
  the caller must say where to stop. Returns `?` for divide-by-zero.
- **`describe` (Welford, single pass) is the right call and gets *more*
  right here.** Round-1 reshaped the stats API around one `describe()`
  because per-function `mean()`/`variance()`/`stddev()` each consumed the
  iterator separately — a real bug for a streaming source. Under Tuck's
  value semantics that argument is stronger still: three passes over a
  `Seq` is three traversals of a copied value.
- **`TDigest` (online quantile estimation) is not translated.** It's a
  stateful accumulator — every `add` returns a new digest under value
  semantics — and it has the same "should this be an `object` with `self`
  mutation" question as `std.random`'s `Dice`. Deferred with that one so
  both get the same answer. `load-tester` needs it.
- **Trig/log names take an `Of` suffix** (`sqrtOf`, `lnOf`, `sinOf`)
  because free functions can't overload and bare `sin`/`cos` risk
  colliding with user code in a flat namespace. Not ideal — worth
  revisiting if module-qualified calls (`math::sin`) are the expected
  spelling, in which case the plain names are fine.
- **`lnOf` returns `?float`** — `ln(0)` and `ln(negative)` have no answer,
  and absence says so better than NaN.
- **No bigint**, consistent with `COMPARISON.md`'s finding that it's a
  softer gap (Java/.NET ship one, Python's is language-level, Tuck's
  target domain rarely needs it).
