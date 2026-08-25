# sys.window — Tuck translation

## Shape decision
`actor`, per direct guidance — one window/surface is the whole shape of
every domain persona in `DOMAINS.md` that needed this (`Finding A`'s own
text: "no app or domain persona... needs more than one surface at a time").
Matches a real singleton exactly.

**Compiler-verified**, `./tuck ch`: `OK`. See `TUCK-TRANSLATION.md` for why
`pending` isn't used here (not yet supported inside `actor`).

## The reply shape — resolved: a cheap default, plus an opt-in stream

Two different needs were being conflated in the original design: "where's
the mouse right now" (cheap, a few bytes, no correlation needed) and "give
me every discrete keystroke, none dropped" (a real stream). Split into two
public fields per `TUCK-TRANSLATION.md`'s resolved pattern:

- **`state: WindowState`** — the cheap default. A snapshot (cursor
  position, held-keys bitset) small enough to read directly with no token
  at all, since it's a single current value, not one of many concurrent
  requests.
- **`events: Seq[InputEvent]`** — opt-in, for a caller that actually needs
  discrete, lossless input (a text-input widget, not a game sampling once a
  frame). Freed via `ackEvents {upTo}`, keyed by an **actor-assigned**
  sequence number — not a caller-chosen token like `std.db`'s, because this
  is one ordered stream everyone reads the same way, not many independent
  requests each wanting their own distinct answer.

**Recommended default overflow policy: drop-oldest.** Unlike DB rows or
queue entries, a stale keystroke from several frames ago matters less than
a recent one — this is the one place in the whole reply-pattern discussion
where losing old data has an obvious right answer rather than being a
correctness bug.

Both fields coexist on the same actor: a caller that only ever reads
`state` never pays for `events` at all.

## The API

```tuck
type EventKind:
  | ekKey
  | ekMouseButton

type InputEvent = {seq: i64, kind: EventKind, keyCode: int, pressed: bool}
type WindowState = {mouseX: float, mouseY: float, heldKeys: u64}

actor Window [queue: 32]:
  isOpen: bool = false
  state: WindowState = {mouseX: 0.0, mouseY: 0.0, heldKeys: 0} WindowState
  events: Seq[InputEvent] = []

  on open({title: str, width: int, height: int}) -> void:
    isOpen = true

  on close() -> void:
    isOpen = false

  on present() -> void:
    return

  on ackEvents({upTo: i64}) -> void:
    return           # drops every buffered event with seq <= upTo

  on select:
    | shutdown -> {}: isOpen = false
```

## In use

```tuck
Window send open {title: "demo", width: 800, height: 600}
let mx = Window.state.mouseX      # cheap default: current sampled state
let evs = Window.events           # opt-in: the discrete lossless stream
Window send ackEvents {upTo: 0}
```

## Open design questions
- `present()`'s own contract (does it need to know which pixel buffer to
  flip, or is that handled some other way for an actor-shaped surface) is
  not resolved here — the Nim design's `pixels(s): var openArray[byte]`
  presupposes a mutable direct-memory handle, which is exactly the
  cross-actor-reference-sharing case `TUCK-TRANSLATION.md` flags as needing
  the arena/dedicated-memory-region escape hatch, not the small-message
  pattern. Left for that same design session, not guessed at here.
- `handle()` (the raw native window handle, for GPU context creation via
  `sys.ffi`) isn't represented above — it's a one-time, rarely-changing
  value, so it likely wants to be its own small field (or read once via a
  single request/reply exchange) rather than routed through either
  `state` or `events`; not designed here since no immediate use forced it.
