# core.fmt — Tuck translation

## Shape decision
Two `interface`s (Tuck's counterpart to Nim `concept`s) plus freeform
`pending:` verbs. **Compiler-verified**, `./tuck ch`: `OK`.

## The API

```tuck
type Style = {width: int, precision: int, alignRight: bool}

interface Showable:
  fn show({self: Self}) -> str

interface Inspectable:
  fn inspect({self: Self}) -> str

pending:
  fn styled({text: str, style: Style}) -> str
  fn pad({text: str, width: int, alignRight: bool}) -> str
  fn render({v: Showable}) -> str
  fn renderDebug({v: Inspectable}) -> str
```

## The big shape change: sinks become returns

**`TextSink` is gone, and with it the whole `show(x, var TextSink)`
signature style.** Three reasons, all structural rather than stylistic:

1. A sink is a *mutable output parameter* — the callee writes through it.
   Tuck forbids exactly that (`TK-TY15`: a callee cannot write through a
   parameter). The `self ..field` exemption covers object members mutating
   their *own* state, not writing into a caller's buffer.
2. `TextBuffer[N: static int]` wrapped `array[N, byte]` with a used-count.
   Expressible as an object over `Array[N, u8]`, but its whole purpose was
   being the thing `show` writes *into*, which point 1 rules out.
3. `show` returning `str` is what the real `std/str.tuck` already does
   (`fn toStr[T]({value: T}) -> str`), so this matches the language's own
   existing shape rather than importing Nim's.

**The property `secrets-vault` depended on survives unchanged**, which was
the one thing worth checking: a type that implements neither interface has
no `show`, so it cannot be rendered — accidental secret-logging stays a
compile error, exactly as the Nim design intended, just via a missing
`satisfies Showable` rather than a missing `show` overload.

**The honest cost**, consistent with `core.str`'s ruling: `show` returning
`str` allocates where the sink version didn't. Per the tier's "no *hidden*
allocation" rule, that's visible in the return type and therefore
acceptable — but `mp3-player`'s "redrawn 4x/sec, zero allocation on the UI
path" claim from the Nim design no longer holds as written. A
fixed-buffer path for that case is a real open question, deferred with
the other callback/buffer-shaped ones.

## Notes
- `put` (the chainable sink-builder) is dropped with `TextSink`; Tuck's
  own chaining idiom is UFCS on values (`text.trim().split(",")`), which
  needs no sink object.
- `fields` (the `inspect`-writing helper template) is dropped — it exists
  to structure writes into a sink.
- `Style` survives as a plain record passed as a trailing argument, which
  is exactly the "options last" convention `PROTOCOLS.md` already
  specifies and Tuck's named-argument style already supports.
