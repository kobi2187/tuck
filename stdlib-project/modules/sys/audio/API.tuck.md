# sys.audio — Tuck translation

## Shape decision
`actor` for device *lifecycle* (open/start/stop/close) — one default audio
output device is the shape every domain persona needed. Per direct
guidance.

**Compiler-verified**, `./tuck ch`: `OK`.

**A real tension beyond the shared reply question:** the Nim design's
`WriteCallback` — the per-buffer PCM fill routine — runs on a dedicated
real-time thread specifically because `sys.sync::SpscRing`'s own design note
says a scheduled/mailbox path is exactly the latency an audio callback
cannot tolerate. An `actor`'s handlers run through the cooperative
scheduler, which is precisely that kind of latency. So the fill callback
itself cannot be an actor handler at all, actor-shaped or otherwise — it has
to stay a `sys.thread`-owned real-time loop reading from a
`sys.sync::Handoff`, with the `AudioDevice` actor below only ever
controlling *when that thread runs*, never touching the buffer itself. This
isn't the shared reply-synchronicity question from `TUCK-TRANSLATION.md` —
it's a second, separate tension specific to this module, also left for the
same design session.

## The API

```tuck
type SampleKind:
  | skInt16
  | skFloat32

type Format = {sampleRate: int, channels: int, sampleKind: SampleKind}

actor AudioDevice [queue: 16]:
  isRunning: bool = false
  bufferedFrames: int = 0

  on openDevice({sampleRate: int, channels: int, sampleKind: SampleKind, bufferFrames: int}) -> void:
    isRunning = false

  on start() -> void:
    isRunning = true

  on stop() -> void:
    isRunning = false

  on close() -> void:
    isRunning = false

  on select:
    | shutdown -> {}: isRunning = false
```

## In use

```tuck
AudioDevice send openDevice {sampleRate: 48000, channels: 2, sampleKind: skFloat32, bufferFrames: 1024}
AudioDevice send start {}
```

## Open design questions
- The general reply-pattern question is resolved (`TUCK-TRANSLATION.md`) —
  and doesn't even apply here, since every handler above is already the
  small-status shape the resolution recommends. Nothing to change.
- The real-time fill-callback tension above, specific to this module: the
  actor controls lifecycle, but the sample-fill hot path must bypass the
  actor/scheduler model entirely and live on its own `sys.thread` +
  `sys.sync::Handoff`, exactly as the original Nim design specified — this
  file does not attempt to declare that callback's shape in Tuck, since it
  isn't an actor concern at all.
