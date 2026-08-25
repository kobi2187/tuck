# alloc.string — Tuck translation

## Shape decision
Freeform `pending:` verbs over the built-in `str`. **No `Text` type** — the
Nim design's owned/borrowed split (`alloc.string::Text` vs
`core.str::TextView`) has no Tuck counterpart, because `str` is the one
text type and the borrowed half can't exist at all (see `core.slice`).

**Compiler-verified**, `./tuck ch`: `OK`, 10/10 `PENDING`.

## The API

```tuck
pending:
  fn append({t: str, other: str}) -> str
  fn appendRune({t: str, r: Rune}) -> str
  fn insertAt({t: str, index: int, other: str}) -> str
  fn removeRange({t: str, fromByte: int, toByte: int}) -> str
  fn clear({t: str}) -> str
  fn repeat({t: str, times: int}) -> str
  fn join({parts: Seq[str], sep: str}) -> str
  fn replace({t: str, what: str, with: str}) -> str
  fn padLeft({t: str, width: int, fill: Rune}) -> str
  fn padRight({t: str, width: int, fill: Rune}) -> str
```

Call sites use `..`, per `TUCK-TRANSLATION.md`:

```tuck
var line = "hello"
line ..append {other: ", world"}
```

## Notes
- **This module's boundary with `core.str` is now thin.** `core.str` holds
  the read-only verbs (`find`, `split`, `trim`, `startsWith`); this one
  holds the building verbs (`append`, `join`, `replace`, `pad*`). With one
  `str` type underneath both, that split is a *documentation* choice, not a
  type-enforced one as it was in the Nim design. Worth asking whether the
  two should simply merge into one `str` module — flagged, not decided.
- **`join` takes `Seq[str]`** and is the one verb here that most obviously
  belongs with the sequence operations in `core.iter` (it's `concat` with a
  separator). Left here because it produces text; noted because it's a
  genuine judgment call.
- The `TextSink`-writing constructors from the Nim design are gone with
  `TextSink` itself — see `core.fmt`.
- **Same open performance question as `alloc.vec`**: `str` is a Nim `string`
  value, so `append` in a loop may be O(n²) unless ARC/ORC moves on the
  self-assignment. Building text incrementally is *the* common case for this
  module, so it is arguably the most important place to benchmark first.
