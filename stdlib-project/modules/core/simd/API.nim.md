# core.simd — Nim API

## Purpose
Do the same arithmetic to a small pack of numbers at once. Write it once and it becomes AVX on a laptop, NEON on a phone, and a plain unrolled loop on a microcontroller with no vector unit at all.

## Protocols implemented
**None — this is a primitive/domain module.** A `Pack` is one value that happens to hold several numbers, not a collection you insert into or take things out of.

## The API

```nim
type
  Packable* = int8 | int16 | int32 | int64 | uint8 | uint16 | uint32 | uint64 |
              float32 | float64

  Pack*[N: static int; T: Packable] = object
    ## N numbers handled together. N is fixed at compile time so the compiler can
    ## pick the best instruction; it is the same `static int` mechanism
    ## `core.array` uses, not a second one.
    lanes: array[N, T]

  LaneMask*[N: static int] = object
    ## One yes/no per lane. What comparisons produce and `pick` consumes.
    bits: array[N, bool]

func filled*[N: static int, T](_: typedesc[Pack[N, T]], value: T): Pack[N, T]
  ## Every lane the same. Same word `core.array.filled` uses.
func load*[N: static int, T](source: View[T]): Pack[N, T]
  ## Raises `Failure` if the view is shorter than N lanes.
func tryLoad*[N: static int, T](source: View[T]): Option[Pack[N, T]]
proc store*[N: static int, T](p: Pack[N, T], dest: var View[T])
func toArray*[N: static int, T](p: Pack[N, T]): array[N, T]

func `+`*, `-`*, `*`*[N, T](a, b: Pack[N, T]): Pack[N, T]
  ## Lane by lane. Operators, because that's what this is for.
func addClamped*[N, T](a, b: Pack[N, T]): Pack[N, T]
  ## Pins to the type's min/max instead of wrapping — same name and behaviour as
  ## `core.num.addClamped`, so scalar and packed code read identically.
func smaller*, larger*[N, T](a, b: Pack[N, T]): Pack[N, T]   ## lane-wise, as core.cmp

func below*, above*, sameAs*[N, T](a, b: Pack[N, T]): LaneMask[N]
func pick*[N, T](a, b: Pack[N, T], where: LaneMask[N]): Pack[N, T]
  ## `a`'s lane where the mask says yes, `b`'s where it says no.

func total*[N, T](p: Pack[N, T]): T       ## add every lane together
func largest*[N, T](p: Pack[N, T]): T
func anyLane*[N](m: LaneMask[N]): bool
func allLanes*[N](m: LaneMask[N]): bool

func lanesFor*(T: typedesc[Packable]): int {.compileTime.}
  ## How many lanes this target does natively. Pick N from this, or don't — a
  ## mismatch degrades to a straight unrolled loop, never to a compile error.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Simd<T, N>` | `Pack[N, T]` | "SIMD" is an acronym you have to be told. "A pack of four floats" explains itself, and `Vec`/`Vector` were both already taken (`alloc.vec`, and maths). |
| `splat(v)` | `filled(T, v)` | Graphics-shader slang replaced with the word `core.array` already uses for the identical idea. |
| `from_slice` / `to_array` | `load` / `store` / `toArray` | `load`/`store` are the two words this operation has had since the 1970s and they're honest about the cost. `load` raises, `tryLoad` doesn't — the standard pair. |
| `lt` / `gt` / `eq` | `below` / `above` / `sameAs` | Abbreviations replaced with words. They return a mask, so reading them as a question ("which lanes are below?") is exactly right. |
| `select(mask, a, b)` | `pick(a, b, where = mask)` | Target values first, the option last and named — the fixed argument order, applied. And `where =` at the call site says what the mask is for. |
| `reduce_sum` / `reduce_max` | `total` / `largest` | "Reduce" is jargon; nobody needs it to understand adding up four numbers. |
| `Mask<N>` | `LaneMask[N]` | Disambiguated from bit masks in `core.num`, which are a different thing. |
| `saturating_add` | `addClamped` | Identical to the scalar name in `core.num`, on purpose. |

## In use

```nim
# mp3-player: scale a buffer of samples by volume, four at a time, no clipping
const lanes = lanesFor(int16)
let gain = filled(Pack[lanes, int16], volumeQ15)

var i = 0
while i + lanes <= samples.count:
  var window = samples.slice(i ..< i + lanes)
  load[lanes, int16](window).addClamped(gain).store(window)
  i += lanes
for j in i ..< samples.count:              # the tail, scalar, same names
  samples[j] = samples[j].addClamped(volumeQ15)
```

## Vocabulary exceptions
`load`, `store`, `pick`, `total`, `largest` and the comparison words are domain verbs. `load`/`store` are deliberately *not* `read`/`write`: in this library those two mean streaming through a handle (`core.fmt`, `core.ptr`, `sys.io`), and a pack load is a single fixed-width move with no handle and no position. Keeping the words distinct preserves the meaning of both.
