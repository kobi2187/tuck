# core.convert — Nim API

## Purpose
One way to turn one type into another, everywhere in the library: `to` when you want a new value, `view` when you just want to look at the same bytes differently, and `tryTo` when the conversion might not work out.

## Protocols implemented
**None of the nine** — but this module owns the `to<Format>` verb family the vocabulary names (`toBytes`, `toText`, `toJson`), and defines what "options as named arguments" means for a conversion.

## The API

```nim
type
  ConvertsTo*[U] = concept x
    ## Infallible: this always produces a `U`.
    to(x, U) is U
  MayConvertTo*[U] = concept x
    ## Fallible: `to` raises `Failure`, `tryTo` hands back `none` instead.
    tryTo(x, U) is Option[U]
  ViewableAs*[U] = concept x
    ## O(1), borrows, never copies, never fails. The promise is the cost, not the shape.
    view(x, U) is U

func to*[T, U](x: T, _: typedesc[U]): U
  ## `reading.to(Celsius)`. Raises `Failure` if this pair's conversion can fail.
func tryTo*[T, U](x: T, _: typedesc[U]): Option[U]
  ## Same conversion, non-raising. Absent means "these bytes aren't a valid U".
func view*[T, U](x: T, _: typedesc[U]): U
  ## Cheap reinterpretation — `array[32, byte].view(View[byte])`.

func canConvert*(From, To: typedesc): bool {.compileTime.}
  ## For generic code that wants to pick a path at compile time.

# Numeric conversions, where losing information is the interesting part:
func toNarrower*[W, N](x: W, _: typedesc[N]): N
  ## Raises if `x` doesn't fit. The default posture for untrusted input.
func tryToNarrower*[W, N](x: W, _: typedesc[N]): Option[N]
func toNarrowerClamped*[W, N](x: W, _: typedesc[N]): N
  ## Pins to the target's min/max instead of failing. Same `Clamped` suffix core.num uses.
func toApproximate*[W, N](x: W, _: typedesc[N]): N
  ## Always succeeds, may lose precision (`float64` -> `float32`). Named so you can't
  ## claim you didn't know.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `From<T>` / `Into<T>` | one `to(x, U)` | Rust needed two traits because of impl-coherence rules. Nim's UFCS means `x.to(U)` reads at the call site regardless, so there's one verb, one implementation site, and no blanket-impl story to explain. |
| `TryFrom` / `TryInto` | `tryTo(x, U)` | Fallibility becomes the `try` prefix everybody already knows from `tryOpen`/`tryRead`, rather than a second pair of traits. |
| `AsRef<T>` | `view(x, U)` | Same word `core.slice` and `core.array` use for a borrow. One idea, one name. |
| `Error` associated type | *(gone)* | Failure raises a `Failure`; there's no per-conversion error type to declare. |
| *(the unresolved third tier)* | `toApproximate` | The Rust file left "lossy but always succeeds" unresolved between this module and `core.num`. Resolved here: it's a conversion, so it lives with conversions, and its name carries the warning. |
| `saturating` narrowing | `toNarrowerClamped` | Shares `core.num`'s `Clamped` suffix so one word means one behaviour library-wide. |

## In use

```nim
# embedded-sensor-node: six raw I2C bytes -> a typed reading, rejecting bus garbage
proc tryTo*(raw: array[6, byte], _: typedesc[Reading]): Option[Reading] =
  let rawC = fromBytes(uint16, raw.view().slice(0 .. 1), order = Big)
  if rawC > maxPlausible: none(Reading)
  else: some(Reading(milliC: rawC.to(int32) * 10))

bus.read(sensorAddr, 6).tryTo(Reading).ifSome(r):
  filter.push(r)                        # bad bytes never reach the filter

# archive-cli: an untrusted 64-bit header field down to a real length
let size = header.declaredSize.tryToNarrower(int32).orRaise("entry too large")
```

## Vocabulary exceptions
None. `to` and `view` are both in the table's spirit (`to<Format>` derives a new representation; `view` is this library's established word for a borrow), and `tryTo` is the standard `try` prefix. `toNarrower`/`toApproximate` are `to`-family verbs with the qualifier in the name rather than in a flag argument, matching how `toBytes(order = Big)` puts the *choice* in a named argument but the *kind* of conversion in the verb.
