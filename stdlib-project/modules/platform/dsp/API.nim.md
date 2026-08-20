# platform.dsp — Nim API

## Purpose
Filters and small numeric routines for sensor data, every one of them a fixed-size value you own outright. Nothing here allocates, and nothing here can allocate.

## Protocols implemented
**None of the nine, and that is the honest answer.** A filter is not a collection, a resource, or something you wait on — you push samples through it. See the exceptions section; this module is domain verbs almost end to end.

## The API

```nim
{.push checks: off, fp: fast.}

type MovingAverage*[Window: static int] = object
  ## The trivial case, given its own type on purpose. A general FIR with equal
  ## coefficients costs a multiply-accumulate per tap per sample; this costs one
  ## add and one subtract per sample, forever, whatever the window.
  buf: array[Window, float32]
  at: int
  running: float32
  full: bool

proc feed*[W](m: var MovingAverage[W], sample: float32): float32
  ## Hands back the current average. O(1).
proc get*[W](m: MovingAverage[W]): float32     ## the average without feeding anything
proc clear*[W](m: var MovingAverage[W])        ## the structural verb, ordinary meaning

type Fir*[Taps, Block: static int] = object
  coeffs: array[Taps, float32]
  state: array[Taps + Block - 1, float32]      ## sized by the compiler, owned by you
proc newFir*[T, B](coeffs: array[T, float32]): Fir[T, B]
proc feed*[T, B](f: var Fir[T, B], input: array[B, float32],
                 into: var array[B, float32])
  ## A whole block at a time — the shape hand-tuned assembly wants underneath.

type Biquad* = object
  b: array[3, float32]
  a: array[2, float32]
  z: array[2, float32]                          ## direct form II transposed
proc feed*(f: var Biquad, sample: float32): float32
proc clear*(f: var Biquad)

proc fft*[N: static int](buf: var array[N, Complex32])
  ## In place, radix-2. `N` must be a power of two — checked **at compile time**,
  ## so there is no runtime size error to handle and no code emitted to check it.
proc fft*(buf: var View[Complex32])
  ## The runtime-length door, for buffers whose size is only known at run time.
  ## Raises on a non-power-of-two length; `tryFft` returns `false` instead.

proc mul*[R, C, K: static int](a: array[R, array[C, float32]],
                               b: array[C, array[K, float32]],
                               into: var array[R, array[K, float32]])
  ## Dimensions have to agree, so the compiler checks them rather than the caller.
{.pop.}
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `MovingAverage::push(x) -> f32` | `feed(m, x)` | `push` is `alloc.vec`'s word for adding to a collection, and a filter is not one. `feed` is the same verb for every filter here, so learning one teaches all three. |
| `FirState` / `BiquadState` | `Fir` / `Biquad` | The `-State` suffix said "this struct holds mutable state", which is true of nearly every object in the library. |
| `FirState::process(in, out)` | `feed(f, input, into)` | Same verb as the scalar case, and `into` names the output parameter the way it is named everywhere else in this library. |
| `fft_radix2(buf)` | `fft(buf)` | Radix-2 is how it works, not what it does. Two overloads instead of two names. |
| `DspError::InvalidSize` | *(gone, at compile time)* | On the `static int` overload the bad size cannot reach a running program — see below. |
| `mat_mul(a, b, out)` | `mul(a, b, into)` | The types already say these are matrices; `mat_` was a prefix apologising for weak typing. |
| `Complex32` | `Complex32` | Kept — unambiguous and already the word everyone uses. |

## In use — embedded-sensor-node

```nim
var smooth: MovingAverage[8]              # 32 bytes of state, all of it visible

while true:
  sensor.sample(timeout = 10.ms).ifSome(raw):
    let degrees = smooth.feed(raw.toCelsius())
    if degrees > alarmThreshold: led.set(High)
    flashRing.append(degrees)
  discard power.enterSleep(Deep, [wakeOn(30.seconds)])
```

That is the module's whole footprint for this device: one type, one verb, no linking of FIR convolution or FFT machinery — which was the point of giving the trivial case its own type.

## Vocabulary exceptions
**This module is mostly domain verbs, as PROTOCOLS predicted for `std.crypto`, and for the same reason.** `feed`, `fft` and `mul` describe transformations of numbers, and the structural table describes operations on containers; forcing a filter into `add`/`get` would suggest you could enumerate or remove samples, which you cannot — they are gone into a running sum. Two structural verbs do fit honestly and are used unchanged: `clear` (empty it, exactly the table's meaning) and `get(m)` for reading the current average without disturbing anything, keyless in the same way `platform.hal`'s pin is. One domain verb, `feed`, covering every filter is the discipline that keeps this from becoming fifteen novel words.

## Honest limits
- **`fft`, `Biquad` and `mul` are unvalidated by any application in this project.** Only `MovingAverage` has a real caller. Their shapes follow CMSIS-DSP, which is a good precedent and not evidence.
- **Fixed-point (`q15`/`q31`) is missing entirely**, and that is a genuine gap for the Cortex-M0 this tier claims to serve: those parts have no FPU, so every `float32` above is a software routine costing tens of cycles. The `feed` verb and the fixed-size shape carry over unchanged to a `Fixed16` variant; the work simply has not been done.
- No SIMD or DSP-instruction dispatch is mandated by these signatures. A vendor may hand-tune behind them; the API stays architecture-neutral.

**Nim-specific:** `Taps`, `Block`, `Window` and `N` are `static int` generic parameters, so every buffer above is a compile-time-sized `array` living in the caller's frame or in `.bss` — no `seq`, no allocator, no hidden indirection. That also removes a runtime error the Rust design had to keep: `fft`'s power-of-two requirement is a `static: doAssert` inside the `static int` overload, so a bad size is a compile error and no `InvalidSize` branch is emitted at all. The runtime-length overload exists for callers who genuinely do not know `N` until run time, and it is the only one that can raise.
