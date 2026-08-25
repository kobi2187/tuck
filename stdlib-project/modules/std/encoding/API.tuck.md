# std.encoding — Tuck translation

## Shape decision
A recursive **sum type** as the universal document model, plus freeform
`pending:` codecs. **Compiler-verified**, `./tuck ch`: `OK`.

This is the module that most vindicates sum types as Tuck's answer for
trees.

## The API

```tuck
type Json:
  | JNull
  | JBool({b: bool})
  | JNum({n: float})
  | JStr({s: str})
  | JArr({items: Seq[Json]})
  | JObj({keys: Seq[str], vals: Seq[Json]})

type EncodingError:
  | Malformed
  | Truncated
  | UnsupportedFeature
  | TypeMismatch

pending:
  fn parseJson({t: str}) -> !Json [io, error: EncodingError]
  fn tryParseJson({t: str}) -> Json?
  fn toJsonText({j: Json, indent: int}) -> str
  fn jsonGet({j: Json, key: str}) -> Json?
  fn jsonAt({j: Json, index: int}) -> Json?

  fn parseToml({t: str}) -> !Json [io, error: EncodingError]
  fn toTomlText({j: Json}) -> str

  fn parseCsvRows({t: str, sep: str}) -> !{rows: Seq[Seq[str]]} [io, error: EncodingError]
  fn toCsvText({rows: Seq[Seq[str]], sep: str}) -> str

  fn toBase64({bytes: Seq[u8]}) -> str
  fn fromBase64({t: str}) -> Seq[u8]?

  fn nextXmlEvent({fd: int}) -> {name: str, text: str}? [io]
```

## Notes on the translation
- **The recursive `Json` sum type is the right shape and it works** —
  `JArr({items: Seq[Json]})` recursing through `Seq` typechecks and builds.
  Exhaustive `match` over the variants means a codec that forgets `JNull`
  is a compile error, which the Nim design's `case object` gave too but
  Tuck enforces harder.
- **One document model serves JSON and TOML.** Both are
  "scalars, lists, and string-keyed maps," so `parseToml -> Json` avoids a
  second parallel tree type. Worth naming as a deliberate simplification of
  the Nim design, which had per-format types.
- **`JObj` uses parallel `keys`/`vals` `Seq`s** rather than a map, because
  `alloc.map` is blocked on the key-hashing question. It also preserves key
  order, which JSON round-tripping wants — so this may be right regardless.
- **CSV keeps its deliberately different calling convention.** Round-0's
  finding #9: CSV has no native type system, so automatic type inference
  ("is `007` a string or 7?") is a silent-corruption risk. Returning
  `Seq[Seq[str]]` — everything is text until the caller says otherwise —
  is that rule, expressed more plainly than the Nim version could.
- **XML stays streaming-only**, which was round-0's finding #1: the
  `XmlReader` has DTD/external-entity processing *structurally absent*, not
  behind a flag, so XXE cannot be reached even by a caller who wants it.
  `nextXmlEvent` over an `fd` handle keeps that.
- **`ics` and `FeedReader` (RSS/Atom) are not translated** — both are thin
  layers over the XML/text primitives, and both need `std.chrono`'s
  `Recurrence`, which is deferred. Noted so they aren't forgotten.

## The inclusion policy still holds
Round-2's stated test — a format belongs in `std` only if it's a
general-purpose interchange format *and* has a small, unambiguous, securely
separable grammar — is unaffected by the language change. YAML stays
excluded on the record; unified-diff stays out as one tool's output format.
