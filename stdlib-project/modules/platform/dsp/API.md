# platform.dsp

## Purpose
Standardized, allocator-free signal-processing primitives — FIR/IIR filters, FFT, basic matrix math — so common numeric processing on sensor data isn't reimplemented (and re-bugged) per silicon vendor.

## Design lineage
Modeled directly on CMSIS-DSP, named in the report as "a genuinely mature, hand-optimized reference implementation" and the only entry in the entire survey (Part II, §2.1's category matrix) with a real answer in the DSP/signal-processing row for the embedded space — no general-purpose language stdlib surveyed ships anything comparable. The design goal here is API compatibility of *shape* (fixed-size buffers, explicit instance/state structs, no allocation) with CMSIS-DSP's `arm_fir_instance_f32`-style conventions, not a from-scratch reinvention.

## Proposed API
```
struct FirState<const N_TAPS: usize, const BLOCK: usize> {
    coeffs: [f32; N_TAPS],
    state: [f32; N_TAPS_PLUS_BLOCK_MINUS_1],   // caller-owned, no heap
}
impl<const N: usize, const B: usize> FirState<N, B> {
    fn new(coeffs: [f32; N]) -> Self;
    fn process(&mut self, input: &[f32; B], output: &mut [f32; B]);
}

struct MovingAverage<const WINDOW: usize> {
    buf: [f32; WINDOW],
    idx: usize,
    sum: f32,
    filled: bool,
}
impl<const WINDOW: usize> MovingAverage<WINDOW> {
    fn new() -> Self;
    fn push(&mut self, sample: f32) -> f32;   // returns current average, O(1)
}

struct BiquadState {
    b: [f32; 3], a: [f32; 2],
    z: [f32; 2],   // Direct Form II transposed state
}
impl BiquadState {
    fn process_sample(&mut self, x: f32) -> f32;
}

fn fft_radix2<const N: usize>(buf: &mut [Complex32; N]) -> Result<(), DspError>;
// N must be a power of two, checked at compile time via a const-generic bound
// where the language allows it, else a runtime DspError::InvalidSize.

fn mat_mul<const R1: usize, const C1: usize, const C2: usize>(
    a: &[[f32; C1]; R1], b: &[[f32; C2]; C1], out: &mut [[f32; C2]; R1]);
```

## Key design decisions
- **Every type is a caller-owned, fixed-size struct with no internal allocation** (`FirState<N_TAPS, BLOCK>`'s `state` array is sized by const generics, not a `Vec`) — this is the least negotiable design constraint of the whole tier per Principle 2, and it is why `platform.dsp` cannot simply re-export a numerics library from `std.math`; `std.math` is permitted to allocate, `platform.dsp` is not, even though the underlying math is identical.
- **`MovingAverage<WINDOW>` is a dedicated, minimal type distinct from the general `FirState`**, even though a moving average *is* a FIR filter with all-equal coefficients — included deliberately as the deliberately trivial case the assignment calls out, to check whether the module is over-built. It is not: a general `FirState<WINDOW, 1>` would spend a multiply-accumulate per tap per sample, while `MovingAverage` maintains a running sum and updates it in O(1) by subtracting the outgoing sample and adding the incoming one, which matters at the sensor node's power budget (every extra cycle running is battery). The two coexist because "technically a special case of FIR" is not sufficient justification to force a slower, more general implementation on a resource-constrained caller.
- **`fft_radix2` reports `DspError::InvalidSize` for non-power-of-two `N`** rather than silently zero-padding or truncating — consistent with `core.error`'s single carrier convention (Principle 4) and this tier's "nothing hidden" stance: a silently altered result size on an FFT is a correctness bug that is extremely hard to notice downstream, so it is surfaced as an explicit, typed failure instead.
- **No hand-optimization (SIMD/DSP-instruction dispatch) is mandated by the trait signatures** — `platform.dsp`'s public API is deliberately architecture-neutral (unlike CMSIS-DSP itself, which ships separate `_f32`/`_q15`/`_q31` fixed-point variants and Cortex-M4/M7 SIMD-optimized code paths internally). A vendor implementation is free to dispatch to hand-tuned assembly behind the same signature; the fixed-point (`q15`/`q31`) variants are treated as a follow-up, not included in this first draft, since the sensor node's moving-average filter needs only `f32`.

## Validated by applications
The embedded-sensor-node's moving-average filter is deliberately, per the app's own design note, "a trivial case to check the module isn't over-built for it" — and it is a useful stress test precisely because it is small: the app only needs `MovingAverage<WINDOW>::push`, never `FirState`, `BiquadState`, `fft_radix2`, or `mat_mul`, which confirms the module's layering is sound only if the trivial case doesn't *require* linking or understanding the heavier machinery. A naive design that expressed "moving average" purely as a special-cased call into the general `FirState` (arguing "one type, less API surface") would have failed this specific check by forcing a Cortex-M0 build to pull in generic FIR convolution logic and pay its per-sample multiply-accumulate cost for what should be two additions and a subtraction — the dedicated `MovingAverage` type is a direct, load-bearing response to this app's stress point, not a hypothetical concern. Because the app exercises only the smallest corner of this module, it does not validate `fft_radix2` or `mat_mul` at all — those remain unvalidated by any application in this project, which is itself worth flagging honestly rather than claiming coverage the app doesn't provide.

## Open questions / risks
`fft_radix2`, `BiquadState`, and `mat_mul` are speculative relative to this project's evidence base — no app here exercises FFT or matrix math, so their signatures are modeled on CMSIS-DSP's shape but unvalidated against any real scenario in this report, unlike `MovingAverage`, which the sensor-node app directly confirms. Fixed-point (`q15`/`q31`) support, which CMSIS-DSP treats as first-class (many Cortex-M0/M0+ parts have no hardware FPU and float ops are markedly more expensive), is deferred entirely — a genuine gap for the "runs on a Cortex-M0" target this whole tier claims to serve.
