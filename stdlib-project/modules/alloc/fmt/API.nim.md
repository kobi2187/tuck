# alloc.fmt — Nim API

**Purpose**
Turn values into `Text`. One call for the common case, one reusable buffer for the hot loop, and not a single new concept — this is `core.fmt`'s existing machinery pointed at an allocator.

**Protocols implemented**
None of the nine. This module contributes `to<Format>` verbs (`toText`, `toDebugText`), which PROTOCOLS lists as a vocabulary entry rather than a protocol — the same role `std.encoding`'s codecs play.

## The API

```nim
proc toText*[T](value: T; memory = defaultMemory()): Text
  ## The one you'll use. Works for any type with a core.fmt `Display` — which is every type in the library.
proc tryToText*[T](value: T; memory = defaultMemory()): Option[Text]
proc toDebugText*[T](value: T; memory = defaultMemory()): Text
  ## The developer-facing rendering. A Secret[T] implements this (redacted) and never implements Display,
  ## so logging a passphrase is a compile error rather than a leak.

macro fmt*(spec: static string; memory = defaultMemory()): Text
  ## fmt"{name} scored {score}" — Nim's own string-literal macro, parsing core.fmt's spec syntax.
  ## One spec syntax in the whole library, defined once, in core.fmt.

proc write*(t: var Text; value: auto)
  ## Appends one Display value. This is alloc.string's Streamable `write`, overloaded — not a new verb.
macro writeFmt*(t: var Text; spec: static string)
  ## Appends a whole formatted line into an existing buffer. Zero allocations when it already fits.

proc join*(items: auto; sep: TextSlice; memory = defaultMemory()): Text
  ## Any Collection into one Text, sized in a single pass. The other thing everyone hand-rolls.
proc pad*(t: Text; width: int; fill = ' '.Rune; align = alignLeft): Text
proc `&`*(a: Text; b: TextSlice): Text
  ## Present, and deliberately the slowest path here. Reach for `fmt` or `writeFmt` in a loop.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `format(args)` / `format!` | `fmt"..."` | Nim's native string-literal macro. `let s = fmt"{n} files"` is one line with no parentheses |
| `format_in(args, a)` | `fmt("...", memory = a)` | the same named argument every other module uses |
| `to_string(v)` | `toText(v)` | the `to<Format>` verb, and `Text` is what it returns — so the name says the type |
| `debug_string(v)` | `toDebugText(v)` | same word plus the one distinction that matters, instead of a different word entirely |
| `write_into(sb, args)` | `t.writeFmt("...")` | target first, UFCS, and it's obviously the same `write` alloc.string already has |
| `StringBuilder` sink | `Text` itself | there's no second type: alloc.string made `Text` `Streamable`, so any Text is a builder |
| *(none)* | `join`, `pad` | new: both are hand-rolled in every CLI app in the set, and both are one-liners over `Collection` |

## In use — log-grep, formatting millions of match lines

```nim
var line = newText(capacity = 256)          # one buffer for the whole scan
for m in matches:
  line.clear()                              # keeps the capacity, drops the content
  line.writeFmt("{m.file}:{m.line}: ")      # no allocation after the first few lines
  line.write(m.text.highlighted())
  stdout.write(line)
```

And todo-cli, where the volume is low and the easy path is the right one:

```nim
for task in filtered:
  echo fmt"{task.due.toText():>10}  {task.priority}  {task.title}  {join(task.tags, sep = \" \")}"
```

## Vocabulary exceptions

- **`fmt` is a macro, not a verb.** It is syntax for building a `Text`, in the same way `[1, 2, 3]` is syntax for building a sequence — it takes no target and obeys no argument order because it has no arguments in the ordinary sense. Naming it `format` would suggest a verb that acts on something.
- **`&` is provided and gently discouraged.** Nim programmers reach for `a & b` reflexively, so refusing to define it would just push people to write worse code by hand. It's documented as the quadratic-concatenation trap the Rust design cited Go's `strings.Builder` to avoid, with `writeFmt` named as the fix, right there in the doc comment.
- **This module defines no new types and no new concepts.** Every type that already renders through `core.fmt` works here for free. A separate `ToText`-style protocol is explicitly rejected — that is exactly the accidental second mechanism PROTOCOLS' rule 2 exists to prevent.

## A note on failure

`toText` and `fmt` raise `OutOfMemory` like everything else in the tier; `tryToText` is the non-raising sibling. This matters on embedded-sensor-node, where rendering a sensor reading for a debug UART line comes out of an 8 KB arena and can genuinely fail. Pretending formatting cannot fail would be the one place the tier lied — and unlike the Rust design, the try-rule means the honest version costs the ordinary caller nothing.
