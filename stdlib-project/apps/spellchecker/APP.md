# App: spellchecker

A CLI text linter: `spellcheck document.txt` tokenizes text into words (correctly across languages/scripts, not just split-on-space), looks each up against a dictionary, and for unknown words suggests corrections within edit-distance 2, ranked by frequency. Supports `--lang` for multiple dictionaries and respects code-block/URL exclusion in Markdown input.

## Why this is a good validation target
`std.i18n` has so far only been validated for case-folding (`log-grep`) and Unicode-normalization-for-diffing (`doc-convert-tester`). This app is the first to need real word-boundary segmentation — which is genuinely hard across languages (English space-splitting doesn't work for Chinese/Japanese/Thai, and even in English, hyphenation, contractions, and Unicode combining marks complicate "what is a word") — and it's the primary exercise for edit-distance, which doesn't obviously live in any module drafted so far.

## Features
- Unicode-correct word tokenization (respecting locale/script boundaries, not naive whitespace splitting).
- Dictionary lookup (a large wordlist, loaded once, queried per token) with frequency-ranked suggestion generation via bounded edit distance.
- Markdown-aware mode: skip fenced code blocks, inline code spans, and URLs.
- Batch mode over multiple files with a summary report (files checked, issues found, suggestions).

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| std | `std.i18n` | word-boundary segmentation (UAX #29-style text segmentation) — the module's first real test beyond case-folding/normalization |
| alloc | `alloc.set` | the dictionary as a large hash set for O(1) membership checks |
| std | `std.math` | **candidate for edit-distance** — or does this belong somewhere else? See validation note |
| sys | `sys.fs` | loading the dictionary file, reading input documents |
| std | `std.regex` | Markdown code-block/URL exclusion patterns |
| std | `std.cli` | batch summary report formatting |
| core | `core.str` | substring/codepoint iteration underneath tokenization |
| std | `std.testing` | tokenizer correctness across scripts is exactly the kind of thing that wants a table-driven test with real multilingual fixtures |

## Validation note: where does edit-distance actually belong?
Bounded edit (Levenshtein/Damerau-Levenshtein) distance is a generic string algorithm, not really a "math" operation in the sense `std.math` was designed for (elementary functions, decimals, statistics) — but it's also not obviously part of `std.i18n` (which is about Unicode correctness, not string algorithms in general), and it doesn't fit `core.str` either (that tier is freestanding and edit-distance's DP table needs `alloc.vec`). The resolution proposed in `modules/std/i18n/API.md`'s update is to add a narrowly-scoped `std.i18n::edit_distance` function specifically because "did the user mean a different word in this dictionary" is fundamentally an i18n-adjacent, human-text concern, not a general numeric one — but this is flagged as a real judgment call, not an obvious answer, and the module doc should say so explicitly.
