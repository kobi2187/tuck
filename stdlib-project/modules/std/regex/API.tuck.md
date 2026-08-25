# std.regex — Tuck translation

## Shape decision
Freeform `pending:` over a compiled-pattern `{id: int}` handle, matching
the `sys` tier's handle convention. **Compiler-verified**, `./tuck ch`: `OK`.

## The API

```tuck
type RegexError:
  | BadPattern
  | TooComplex

type Match = {start: int, stop: int, text: str}

pending:
  fn compile({pattern: str, caseless: bool}) -> !{id: int} [io, error: RegexError]
  fn findFirst({id: int, subject: str}) -> Match?
  fn findAll({id: int, subject: str}) -> Seq[Match]
  fn matches({id: int, subject: str}) -> bool
  fn replaceAll({id: int, subject: str, with: str}) -> str
  fn splitBy({id: int, subject: str}) -> Seq[str]
  fn groupOf({id: int, subject: str, index: int}) -> Match?
  fn fromGlob({glob: str}) -> !{id: int} [io, error: RegexError]
```

## Notes
- **A compiled regex is a handle, not a value.** It holds an automaton the
  engine owns; `{id: int}` keeps it out of Tuck's value world entirely,
  which is the same resolution `std.db` reached for connections.
- **`compile` is `[io]`** — not because it touches the OS, but because
  fallible returns require it. That is a slightly awkward consequence of
  the `!T`-implies-`[io]` rule for something that is really a pure
  computation over a pattern string; worth noting as a small mismatch
  rather than pretending it reads naturally.
- **`Match` carries `text` as a copy.** In the Nim design it was a
  `TextView` borrowed from the subject — zero-copy. Without views it copies,
  which for `log-grep`-style scanning over large inputs is exactly the
  regression `sys.mmap` also hit. Same root cause, recorded in both places.
- **`fromGlob` survives** with its round-2 boundary intact: it does the
  mechanical glob→regex translation and explicitly *declines* gitignore's
  ordered/negated list semantics, which the Nim design flagged as belonging
  closer to `sys.fs`.
- **`TooComplex` is kept as a real variant.** A regex engine that can hit
  catastrophic backtracking should say so rather than hang, and having the
  variant in the signature forces callers to see it.
