# sys.audio — Nim API

## Purpose
Open the system's default audio output device and submit PCM frames to it —
the thin device-I/O layer, not a mixing engine, an effects chain, or a codec
(decoding compressed formats is `std.encoding`/`std.compress`'s job, not
this one's). A game's own mixer, or `mp3-player`'s playback thread, writes
finished samples here; this module's whole job is getting them to the
speaker with predictable latency.

*New in this pass.* `DOMAINS.md`'s game-domain analysis found no audio
module anywhere in the 65 — `mp3-player` validated the real-time *threading*
discipline around audio (`sys.sync::SpscRing`, `sys.thread`) but never an
actual device primitive underneath it. Recommended rung **B1**: bundled in
the offline toolchain install rather than fetched on demand, because a game
with no audio at all is not a shippable game, the same "hand-roll a device
binding from raw FFI" failure mode `std.db` avoids for the database case.
Fancier engines — spatial audio, DSP effect chains — stay rung B2/C, built
on top of this bundled baseline rather than inside it.

## Protocols implemented
`Device` is `Resource` + `Lifecycle` (`start`/`stop`) — a device is opened
once and then turned on and off repeatedly, exactly `Lifecycle`'s shape.
Writing samples is a domain verb; a ring of audio frames is not a
`Collection` in the sense the other eight protocols mean it.

## The API

```nim
type
  Device* = object          ## Resource + Lifecycle
  Format* = object
    sampleRate*: int         ## e.g. 48000
    channels*: int           ## 1 = mono, 2 = stereo
    sampleKind*: SampleKind
  SampleKind* = enum skInt16, skFloat32

  WriteCallback* = proc (buf: var openArray[byte]) {.nimcall.}
    ## Called on the audio thread to fill one buffer. `{.nimcall.}` on
    ## purpose — Nim closures allocate, and this runs where `sys.sync`'s
    ## `Handoff` already established that allocation is not allowed. State
    ## reaches it only through a `Handoff`/`Channel`, never a capture.

proc openDevice*(format: Format; bufferFrames = 1024): Device
  ## `bufferFrames` trades latency for underrun safety — the one tuning knob
  ## this module exposes, because every real device disagrees about the
  ## right default and a hidden one would just move the disagreement into a
  ## bug report instead of a signature.
proc tryOpenDevice*(format: Format; bufferFrames = 1024): Option[Device]

proc start*(d: var Device; fill: WriteCallback): bool
  ## `Lifecycle`. From this call on, `fill` runs on a dedicated real-time
  ## thread this module owns — the caller never touches it directly, the
  ## same ownership split `sys.thread::run` already uses for a spawned
  ## worker.
proc stop*(d: var Device): bool
proc isRunning*(d: Device): bool
proc close*(d: var Device)

proc write*(d: var Device; frames: openArray[byte]): int {.discardable.}
  ## The pull-callback model above (`start(d, fill)`) is the primary path,
  ## for anything that must never block; `write` is the push alternative for
  ## code that already has its own timing loop and can tolerate blocking
  ## when the device's buffer is full. Returns bytes actually accepted.

proc bufferedFrames*(d: Device): int
  ## How much is queued but not yet played — the number a UI reads to draw
  ## an accurate playhead position, and the number `mp3-player`-style
  ## seek-ahead logic checks before deciding it's safe to fill more.
```

## Friendly-naming notes

| Precedent (PortAudio/CoreAudio/WASAPI) | Nim name | Why |
|---|---|---|
| `Pa_OpenDefaultStream` | `openDevice(format, bufferFrames =)` | one call, no separate "default vs. named device" API — no app in this project's validation set picks a non-default device |
| `Pa_StartStream` / `Pa_StopStream` | `start` / `stop` | `Lifecycle`'s exact words, no renaming needed |
| the callback's raw `void*` userData | a `Handoff`/`Channel` from `sys.sync` | this module doesn't invent a second state-passing mechanism when one already exists and is already proven safe on this exact real-time path |
| `Pa_GetStreamWriteAvailable` | `bufferedFrames` (inverted: filled, not free) | reads as the question a caller actually asks — "how far behind am I" |

## In use

```nim
# a game's mixer (per DOMAINS.md): fixed-size ring feeds the device, nothing allocates
let (toAudio, fromMixer) = newHandoff[array[1024, float32]](capacity = 4, memory = audioPool)

proc fillCallback(buf: var openArray[byte]) {.nimcall.} =
  fromMixer.tryReceive().ifSome(chunk): copyOut(chunk, buf)
  # a missed chunk is one silent buffer, same reasoning sys.sync's own example already states

var dev = openDevice(Format(sampleRate: 48000, channels: 2, sampleKind: skFloat32))
discard dev.start(fillCallback)
# ...mixer thread pushes finished frames into toAudio every tick...
dev.stop()
dev.close()
```

## Vocabulary exceptions
- **`write` and `bufferedFrames` are domain verbs.** `write` overlaps
  `Streamable`'s name on purpose — submitting audio frames really is "write
  these bytes somewhere" — but `Device` is deliberately not declared
  `Streamable` itself, because `read`/`copy`/`first` on an audio output make
  no sense the way they do on a file or socket; only the one directional
  verb applies.
- **The pull-callback (`start(d, fill)`) is primary; `write` is the
  alternative, not the default.** Getting the real-time contract right
  (no allocation, no lock, `{.nimcall.}` only) matters more than API
  symmetry with `sys.fs`/`sys.net`'s push-oriented `write`.
- **Left unresolved, on purpose.** Input (microphone capture), device
  enumeration/selection, and sample-rate conversion are all out of this
  module — no domain persona in `DOMAINS.md`'s set needs them yet, and per
  this project's own standing rule, a primitive gets added when a real
  requirement forces its shape, not in anticipation of one.
