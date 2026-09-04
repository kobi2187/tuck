# spellchecker — dogfooding findings

## What was built

`spellcheck.tuck` (~100 lines) is a small, real slice of the full APP.md
spellchecker: a hardcoded `Seq[str]` dictionary, a hardcoded sentence,
whitespace tokenization, dictionary membership lookup, and a Levenshtein
edit-distance suggestion for unknown words. It typechecks (`./tuck ch`),
builds (`./tuck b`), and runs, printing OK/unknown+suggestion per word.

Out of scope, per the task and per APP.md's own harder ambitions: real
Unicode/multi-script word segmentation (UAX #29-style), Markdown/URL
exclusion, frequency-ranked suggestion ordering, multi-language dictionaries,
and batch/file-based operation. `tokenize` only splits on the literal space
character — noted in a comment in the file as a real, unaddressed gap, not
solved by pretending it's out of scope for the wrong reason: it's genuinely
a different, harder problem (APP.md's own validation note says so).

## Missing stdlib functions needed

- **`std/seq` — a growable `Seq`.** Only `at`/`setAt` exist today (fixed-size,
  index-only). Building `tokenize`'s result list or the DP table in
  `levenshtein` needed a fixed-capacity literal array (`["", "", ..., ""]`,
  16 slots) filled via `setAt`, with a separate `count`/bounds tracked by
  hand. This works for a toy input but caps token count and word length at
  whatever literal size was typed. Proposed: `alloc.vec::push[T]({items: Seq[T], value: T}) -> void` (grow-by-one) or a `make[T]({size: int, fill: T}) -> Seq[T]` constructor — either would remove the hand-rolled capacity constants. Not stubbed via `pending:` since the whole file's control flow depends on it; worked around instead with fixed-size literals.
- **`std/i18n::segmentWords({text: str}) -> Seq[str]`** (or similar) — real
  word-boundary segmentation, per APP.md's own note. Not stubbed as
  `pending:` in this file because a stub returns a zero value (empty seq) at
  runtime, which would make the program print nothing — worse for a
  dogfooding demo than an honest, working space-split with a comment
  admitting the gap. Proposed only, not called.
- **`loadDictionaryFile({path: str}) -> Seq[str]`** (some `sys.fs`-backed
  module) — declared as a `pending:` typed hole in the file (line 17,
  unused/uncalled) purely to demonstrate the mechanism; a real dictionary
  load belongs here once file IO + a growable `Seq` both exist.

## Compiler bugs / friction hit

None found. Two non-bug frictions worth recording:

- Multi-line array/string-concat literals must indent continuation lines by
  exactly one 2-space level from the statement, not by visual alignment
  under the opening bracket — `TK-LX06` fired on a dictionary literal
  wrapped across three lines with column-aligned continuation. Fixed by
  putting the whole literal on one line. Not a bug — the diagnostic message
  explained exactly why (indentation is structure) — just a style habit
  carried over from other languages.
- String literals have no escape sequences (`\"` raised "Unexpected
  character: \\", a lexical error, not silently mis-lexed). Worked around
  with single-quote delimiters for the human-readable message instead of
  escaping embedded double quotes. Worth documenting explicitly in
  `LANGUAGE-OVERVIEW.md` §0 if it isn't already, since every reader's first
  instinct is `\"`.

## Interface/mixin/actor design notes

No natural interface, mixin, or actor point in this slice. Dictionary
lookup is one strategy (linear scan over a hardcoded list) with no second
implementation to justify a `Dictionary` interface — introducing one here
would be interface-for-one-implementer, which the app doesn't need. No
shared mutable coordinator exists or is needed, so no `actor` case either.
If a future pass adds a real large-wordlist-backed dictionary (hash set)
alongside this toy linear one, *that* would be the moment an interface earns
its keep — flagging it here rather than building it speculatively now.

## Joy-of-use verdict

Pleasant once the postfix-record calling convention and the `Seq`
at/setAt-only reality both clicked — the language itself (records, `for`
loops, `if`-as-expression, `alias`-free field payloads) stayed out of the
way for a straightforward tokenizer + DP algorithm. The friction was almost
entirely `Seq`'s current fixed-capacity nature: implementing Levenshtein
with only indexed mutation (no push, no dynamic sizing) forced a
single-row-DP variant with a literal-sized backing array and manual bounds
constants, which is exactly the kind of thing a real program would trip
on immediately outside a toy dictionary this small.
