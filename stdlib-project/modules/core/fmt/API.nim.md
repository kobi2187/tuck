# core.fmt — Nim API

## Purpose
Turning values into text without allocating. A type says how to describe itself; the description goes into whatever sink you hand it — a 64-byte stack buffer on a microcontroller, or (one tier up) a growable `Text`.

## Protocols implemented
`Streamable` — the write half. `TextSink` provides `write(sink, data): int`; it has no `read`, because a sink is one-directional by construction. That gap is named rather than filled with a raising stub.

## The API

```nim
type
  TextSink* = concept var s
    ## Anywhere text can go. Implement `write` and everything below works.
    write(s, TextView) is int
    write(s, Rune) is int

  Showable* = concept x
    ## How this value looks to a person. Stable, user-facing.
    show(x, var TextSink)
  Inspectable* = concept x
    ## How this value looks to a programmer. Structural, and free to change.
    inspect(x, var TextSink)

  Style* = object
    ## Every formatting option, passed as one trailing named argument.
    width*: Count
    precision*: Count
    fill*: Rune
    alignRight*: bool

  TextBuffer*[N: static int] = object
    ## A fixed stack sink. Implements TextSink. `--mm:none` safe.
    room: array[N, byte]
    used: Count

proc write*[N](buf: var TextBuffer[N], data: TextView): int
  ## Writes what fits and returns how much. Never raises, never truncates silently
  ## without saying so — check `isFull`.
proc write*[N](buf: var TextBuffer[N], r: Rune): int
func text*[N](buf: TextBuffer[N]): TextView
func isFull*[N](buf: TextBuffer[N]): bool
proc clear*[N](buf: var TextBuffer[N])

proc show*[T: Showable](x: T, into: var TextSink, style = Style())
proc inspect*[T: Inspectable](x: T, into: var TextSink, style = Style())

proc put*[T](sink: var TextSink, x: T, style = Style()): var TextSink {.discardable.}
  ## Chainable: `buf.put(mins).put(":").put(secs)` — one value in play, left to right.

template fields*(sink: var TextSink, name: static string, body: untyped)
  ## Helper for writing `inspect` by hand: `sink.fields("Point"): field("x", p.x)`.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Display` | `Showable` / `show` | Ruby's `to_s`, said as a verb. `Display` sounds like a screen. |
| `Debug` | `Inspectable` / `inspect` | Ruby's `inspect`, which already means exactly this to a huge number of people. |
| `Write` (the trait) | `TextSink` | "Write" as a noun is confusing next to `write` as a verb. `TextSink` names the role. |
| `write_str` / `write_char` | `write` (overloaded) | Nim overloads; one verb, matching the protocol table's `write(handle, data)`. |
| `Formatter` + flag methods | `Style` object | Width/precision/fill were four accessor methods on a mutable object; now one plain record passed as a named argument, per the options-last convention. |
| `FixedBuf<N>` | `TextBuffer[N]` | "Buf" is an abbreviation nobody needs. |
| `debug_struct(name)` builder | `fields` template | The builder was three chained calls to write one line; a template with a body is the Nim way and reads like the output. |
| `write!` macro | `put` (chainable) | UFCS chaining replaces a format-string macro for the common case, keeping stack depth at one. |

## In use

```nim
# mp3-player: playback position, redrawn 4x/sec, zero allocation on the UI path
var line: TextBuffer[32]
line.clear()
line.put(pos.mins, style = Style(width: 2, fill: '0'.Rune))
    .put(":")
    .put(pos.secs, style = Style(width: 2, fill: '0'.Rune))
screen.draw(line.text())

# secrets-vault: a secret can be inspected but never shown
proc inspect*(s: Secret, into: var TextSink) = into.put("Secret(hidden)")
# no `show` proc exists for Secret -> `echo password` fails to compile
```

## Vocabulary exceptions
`show` and `inspect` are domain verbs replacing what could have been `toText`. They earn their names because the split between them is the point (`secrets-vault` relies on a type having one and not the other), and a single `toText` would have collapsed exactly the distinction that makes accidental secret-logging a compile error.
