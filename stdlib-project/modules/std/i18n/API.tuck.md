# std.i18n — Tuck translation

## Shape decision
Freeform `pending:` verbs over `str`. **Compiler-verified**, `./tuck ch`:
`OK`.

## The API

```tuck
type NormalForm:
  | Composed
  | Decomposed

type Locale = {id: str}

pending:
  fn normalize({t: str, form: NormalForm}) -> str
  fn isNormalized({t: str, form: NormalForm}) -> bool
  fn foldCase({t: str}) -> str
  fn compareLocale({loc: Locale, a: str, b: str}) -> Order
  fn wordsOf({t: str, loc: Locale}) -> Seq[str]
  fn graphemesOf({t: str}) -> Seq[str]
  fn editDistance({a: str, b: str}) -> int
```

## Notes
- **`normalize(form:)` keeps the Nim pass's best rename** — `nfc()`/`nfd()`
  were "two cryptic acronyms"; one verb with `Composed`/`Decomposed` says
  what happens.
- **`isNormalized` first is the right shape** — most text already is, so
  the cheap check saves the allocating call. That matters more here than in
  Nim, since `normalize` returns a new `str`.
- **`compareLocale` returns `core.cmp`'s `Order`**, which plugs into every
  sort without a second mechanism — the Nim design's point about avoiding a
  sort-key byte string, unchanged.
- **`editDistance` stays here**, with its placement recorded as a genuine
  judgment call (round 2): it isn't numeric enough for `std.math` and needs
  more than `core.str`. The Nim design documented the counter-argument
  rather than asserting the choice; that honesty carries over.
- **`Collator` as an object collapses to `compareLocale`** taking the
  locale as an argument — the object held only configuration.
- **`graphemesOf` is worth having explicitly.** "Characters" in the sense
  users mean (a family emoji, an accented letter) are grapheme clusters,
  not runes; `core.str::runeCount` answers a different question and the two
  should not be confused.
