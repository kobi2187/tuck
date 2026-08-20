# core.simd

## Purpose
Portable, fixed-width SIMD vector types (`Simd<T, N>`) and lane-wise operations (arithmetic, comparison, shuffle, reduce) that compile down to the target's native vector instructions where available and fall back to a scalar loop where not — without the caller writing target-specific intrinsics.

## Design lineage
Modeled on Rust's `core::simd` (portable_simd: a single `Simd<T, N>` type generic over element type and lane count, with the compiler responsible for lowering to AVX/NEON/etc., or scalarizing) and Zig's `@Vector(N, T)` builtin (vector types as ordinary values with operator support, no separate intrinsic-call API). Both were chosen over exposing target-specific intrinsic modules directly (the traditional C/C++ approach) because the report's Part II identifies "one portable API, multiple backends" as the pattern that keeps numerically-intensive code from needing per-architecture rewrites — the same principle CMSIS-DSP applies at the embedded toolkit layer, cited approvingly in Part II's "ideas worth stealing."

## Proposed API
```
struct Simd<T, const N: usize> { /* opaque: N lanes of T, alignment matching native vector width */ }

impl<T: SimdElement, const N: usize> Simd<T, N> {
    fn splat(value: T) -> Self;                          // all lanes set to one value
    fn from_slice(src: slice::Slice<T>) -> Self;          // panics/traps if src.len() < N
    fn to_array(self) -> array::Array<T, N>;

    fn add(self, other: Self) -> Self;
    fn sub(self, other: Self) -> Self;
    fn mul(self, other: Self) -> Self;
    fn min(self, other: Self) -> Self;
    fn max(self, other: Self) -> Self;

    fn lt(self, other: Self) -> Mask<N>;                  // lane-wise compare -> mask
    fn select(mask: Mask<N>, a: Self, b: Self) -> Self;   // blend by mask

    fn reduce_sum(self) -> T;
    fn reduce_max(self) -> T;

    fn saturating_add(self, other: Self) -> Self where T: num::SaturatingArith;
}

struct Mask<const N: usize> { /* opaque: N lanes of bool, one bit or byte per lane */ }
```

## Key design decisions
- Lane count `N` is a const generic, not a runtime parameter, so the compiler can pick the best native mapping (e.g. a 4-lane `f32` vector maps directly to SSE/NEON) at compile time rather than dispatching at runtime — consistent with `core.array`'s const-generic sizing and flagged there as needing one unified const-generic mechanism shared by both modules.
- Scalar fallback (on targets/lane-widths without a matching native instruction) is a silent, correctness-preserving degrade, not a compile error — this is what lets the *same* `core.simd` code target both a server CPU with AVX2 and a Cortex-M0 with no vector unit at all, honoring Principle 1's "runs on the weakest environment it targets" even for a performance-oriented module.
- `saturating_add` (and other checked/wrapping/saturating variants) are expressed via a bound on `core.num`'s arithmetic traits rather than `core.simd` duplicating that logic, keeping "one coherent idiom" for overflow behavior shared between scalar and vector code (Principle 4).

## Validated by applications
- **mp3-player**: the one app in the set with `core.simd` named directly in its module table, for "volume scaling / sample format conversion across a buffer." This is concrete, not hypothetical: scaling every sample in a buffer by a volume factor, and converting between sample formats (e.g. 16-bit PCM to float and back), are lane-wise multiply/clamp operations over exactly the shape `Simd<T, N>` targets. This app's real-time constraint (no glitches, bounded per-callback work) is what confirmed `reduce_sum`/lane ops need to compile to genuinely branch-free code — a naive design that fell back to a masked-select-per-lane loop even in the "no native vector support" case would have reintroduced the branching this app's audio thread cannot tolerate; the resolution is that scalar fallback must be a straight unrolled loop, not a masked emulation.
- **secrets-vault** and **archive-cli**: both are indirect, substrate-level validations rather than direct callers — `std.crypto`'s AEAD ciphers (secrets-vault) and `std.compress`'s deflate/zstd codecs (archive-cli) are exactly the kind of numerically-intensive, per-byte-or-per-block inner loops that benefit from `core.simd` internally, the same way CMSIS-DSP standardizes vectorized filter kernels for embedded targets without every consumer of CMSIS-DSP writing SIMD code themselves. Neither app calls `core.simd` directly, and that absence is itself informative: it confirms the module's primary audience is other stdlib modules' internals (crypto, compression) plus a handful of directly numeric apps like mp3-player, not typical application code.
- **image-thumbnailer**: a third instance of the same pattern, and the app's own profile calls this out explicitly — a bilinear/box resize filter's per-pixel weighted-sum math is exactly `Simd<T, N>`-shaped lane-wise multiply-accumulate work *if* implemented in-language, but this app's validated answer (see its `APP.md`) is to delegate JPEG/PNG/WebP decode and resize to system libraries via `sys.ffi`/`sys.process` rather than reimplementing codec-adjacent pixel math in the stdlib. `core.simd` is therefore exercised here only as a hypothetical, not an actual call site — a non-event that reinforces, rather than changes, the existing reading that this module's direct audience is narrow (mp3-player, stdlib internals) and that image/codec work is correctly kept out of scope entirely (see `image-thumbnailer`'s own validation note and the report's `std.gui` precedent).

## Open questions / risks
Whether `core.simd` should expose masked (non-power-of-two, or partial-tail) loads/stores as first-class operations, or push "handle the remainder scalar-fallback loop yourself" to the caller, is unresolved; mp3-player's arbitrary-length sample buffers make this a real, not theoretical, gap.
