# platform.dsp — Tuck translation

## Shape decision
Freeform `pending:` over fixed-size value records. **Compiler-verified**,
`./tuck ch`: `OK`.

```tuck
type Biquad = {b0: f32, b1: f32, b2: f32, a1: f32, a2: f32, z1: f32, z2: f32}

pending:
  fn biquadStep({f: Biquad, x: f32}) -> {f: Biquad, y: f32}
  fn movingAverage({samples: Seq[f32], window: int}) -> Seq[f32]
  fn rmsOf({samples: Seq[f32]}) -> f32
```

## Notes
- **`biquadStep` returning `{f, y}` is the value-semantics tax again** — a
  filter carries state (`z1`/`z2`), so each step hands back the updated
  filter alongside the output sample. Per-sample, in an audio or sensor
  loop, that is the hottest path in the corpus for this pattern. The
  `object` + `self ..field` alternative (see `std.random`) matters more
  here than anywhere else.
- **`Array[N, f32]` rather than `Seq[f32]` is probably right for the
  freestanding target** — a fixed-size buffer allocates nothing and its
  length is in the type. Written with `Seq` above for consistency with the
  rest of the corpus; flagged as likely wrong for this tier specifically.
- **FFT and matrix math are deliberately not sketched.** `INDEX.md` flagged
  them as **unvalidated** — embedded-sensor-node only exercises a trivial
  moving average, so "the harder, more failure-prone parts of a CMSIS-DSP
  style API were never actually stress-tested." Translating them would add
  surface without evidence; that gap is unchanged and worth preserving as a
  gap.
