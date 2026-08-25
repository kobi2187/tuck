# core.types — Tuck translation

## Shape decision
Freeform `pending:` over `distinct` aliases. No object, no actor — this
tier defines the vocabulary everything else is written in terms of.

**Compiler-verified**, `./tuck ch`: `OK`.

## The finding that removes most of this module

**`Option[T]` disappears entirely, the same way `Result[T,E]` already did
in the Nim pass.** Tuck has `?T` built in, with `.ok`/`.value` as the
guarded access idiom (`LANGUAGE-OVERVIEW.md` §4) — verified: a `pending fn`
returning `{index: int}?` typechecks and reads back through `r.ok` /
`r.value.index`. So the Nim design's whole `Option` block —
`some`/`none`/`isSome`/`isNone`/`get`/`get(fallback)`/`orCompute`/
`orRaise`/`map`/`keep`/`ifSome` — has no Tuck counterpart to write: the
language supplies the carrier, and the checker enforces the guard
(accessing `.value` unguarded is an error, `guard it first`).

That is the second time this corpus's two-carrier design collapsed into
one Tuck rule. The Nim pass already noted `Result` dissolving into
"failure raises, `try`-prefix opts out"; `?T` finishes the job for absence.
`core.types` is left holding only the numeric aliases.

## The API

```tuck
distinct Rune = i32
distinct Index = int
distinct Count = int

pending:
  fn rune({value: i32}) -> Rune
  fn asI32({r: Rune}) -> i32
  fn index({value: int}) -> Index
  fn count({value: int}) -> Count
```

## Notes on the translation
- **`Rune`/`Index`/`Count` become `distinct`**, which is exactly the Nim
  design's intent (`Index` "never used as just a number") and is a real
  Tuck feature with the same meaning — `std/time.tuck` already uses
  `distinct Milliseconds = u32` for precisely this "same bits, incompatible
  at compile time" purpose.
- **`Bytes` is dropped.** The Nim design defined it as `openArray[byte]`,
  a Nim-specific parameter idiom; Tuck's own equivalent is `Seq[u8]` used
  directly, and `std/net.tuck` already passes byte payloads as `str` or
  `Seq[u8]` without an alias. Adding one here would be a synonym, which
  `PROTOCOLS.md`'s no-synonyms rule already forbids.
- The constructors are `pending` rather than concrete because a `distinct`
  conversion in Tuck is a plain postfix call (`value Milliseconds`, per
  `std/time.tuck`) — whether these helper fns are worth having at all, or
  whether callers should just write the conversion inline, is a real style
  question this file doesn't settle.
