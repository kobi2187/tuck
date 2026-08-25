# core.str — Tuck translation

## Shape decision
Freeform `pending:` over Tuck's built-in `str`. **Compiler-verified**,
`./tuck ch`: `OK`, 16/16 signatures `PENDING`.

## The two findings that reshape this module

**1. `TextView` collapses into plain `str`.** The Nim design defined
`TextView = distinct View[byte]` — a borrowed window. Per `core.slice`'s
finding, Tuck forbids storing that pointer at all, and `str` is already the
language's own text type, passed without copying (rule #4). So the borrowed
/owned distinction the Nim design drew between `core.str::TextView` and
`alloc.string::Text` has no Tuck counterpart: there is one `str`, and the
zero-copy property comes from the checker, not from a view type.

**2. Every returning operation now genuinely allocates or copies.** In the
Nim design, `split`/`trim`/`slice` returned `TextView`s — free
re-windowings into the caller's own bytes. Here they return `str`/`Seq[str]`
by value. That's a real, honest cost increase this file should not hide:
what was zero-allocation in the `core` tier is not, which sits awkwardly
with the tier's own "nothing here allocates" premise. **This is the single
biggest open question across the whole `core` tier** — see the note at the
end.

## The API

```tuck
distinct Rune = i32

pending:
  fn runeCount({t: str}) -> int
  fn isEmpty({t: str}) -> bool
  fn find({t: str, what: str}) -> {index: int}?
  fn has({t: str, what: str}) -> bool
  fn startsWith({t: str, prefix: str}) -> bool
  fn endsWith({t: str, suffix: str}) -> bool
  fn split({t: str, at: str}) -> Seq[str]
  fn trim({t: str}) -> str
  fn trimStart({t: str}) -> str
  fn trimEnd({t: str}) -> str
  fn slice({t: str, fromByte: int, toByte: int}) -> str?
  fn runeAt({t: str, byteOffset: int}) -> {r: Rune}?
  fn toLower({t: str}) -> str
  fn toUpper({t: str}) -> str
  fn parseInt({t: str}) -> {value: i64}?
  fn parseFloat({t: str}) -> {value: float}?
```

## Notes on individual translations
- **`Pattern` (the `Rune | TextView | proc` union) is dropped.** Tuck has
  no union-of-types parameter and no overloading verified in this pass;
  `split`/`find`/`has` take a plain `str` needle. A predicate-taking variant
  (`split(isSpace)`) would need `fnsig` and is left out for the same
  callback-design reason `core.array` records.
- **`asText`/`tryAsText`/`asTextUnchecked` are dropped.** They exist to
  validate raw bytes into a `TextView`; with `str` as the only text type,
  the equivalent question is "how does a `Seq[u8]` from a socket become a
  `str`" — which is really `std.encoding`'s job, not this module's.
- **`count` (bytes) vs `runeCount` (characters)** survives as the one
  genuinely load-bearing distinction from the original, kept explicit.
- Absence is `?T` throughout, per `core.types`'s finding.

## The tier-wide question this raised, and its ruling
`core`'s original premise was "no allocator, no OS — nothing here
allocates." That held in the Nim design because every operation returned a
borrowed `View`. It cannot hold here: `split` returning `Seq[str]` must
allocate somewhere.

**Ruled: `core`'s claim is "no *hidden* allocation," not "no allocation."**
An operation that allocates says so in its return type — `-> Seq[str]`
is visibly a new value, `-> bool` visibly is not. This keeps each module's
vocabulary whole (rather than splitting `core.str`'s verbs across two
tiers) and matches Tuck's explicit-over-implicit bias throughout the rest
of the language. Applies identically to `core.iter`, `core.convert` and
`core.fmt`.
