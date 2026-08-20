# std.i18n — Nim API

## Purpose
The parts of human text that are harder than they look: where words begin and end, when two differently-encoded strings are the same string, how to sort names in a given language, and how close one word is to another.

## Protocols implemented
`Collection` on the segmenters (they enumerate pieces of text — `list` is the primitive, so `first`, `count` and `toSeq` all arrive free). `Comparable` from `core.cmp` on `Collator`. Everything else is domain verbs.

## The API

```nim
type
  Form* = enum Composed, Decomposed        ## NFC, NFD — the two that matter
  Locale* = object                          ## "en-US", "tr-TR", "ja-JP"

proc normalize*(text: TextView; form = Composed): Text
  ## The one call that makes "café" typed two different ways compare equal.
  ## Default is Composed because that is what the web and most files use.
proc isNormalized*(text: TextView; form = Composed): bool
  ## Cheap check first — most text already is, and then normalize does nothing.

iterator words*(text: TextView; locale = Locale.default): TextView
  ## Unicode word boundaries (UAX #29), not split-on-space: handles contractions,
  ## hyphenation, and scripts with no spaces at all.
iterator sentences*(text: TextView; locale = Locale.default): TextView
iterator graphemes*(text: TextView): TextView
  ## What a person calls "one character" — an emoji with a skin-tone modifier
  ## is one grapheme, several runes, many bytes.

proc upper*(text: TextView; locale = Locale.default): Text
proc lower*(text: TextView; locale = Locale.default): Text
  ## Locale matters: Turkish 'I' lowercases to 'ı', not 'i'. The default locale
  ## is the invariant one, so behaviour is reproducible unless you ask otherwise.
proc foldCase*(text: TextView): Text
  ## For caseless *comparison*, not display. This is what `log-grep -i` wants.

type Collator* = object
proc newCollator*(locale: Locale; caseSensitive = true): Collator
proc compare*(c: Collator; a, b: TextView): Order
  ## core.cmp's Order, so `sortedBy` and every other generic sort works unchanged.

proc editDistance*(a, b: TextView; limit = high(int)): int
  ## Damerau-Levenshtein over graphemes, not bytes. `limit` stops early —
  ## a spellchecker asking "within 2?" should not pay for a distance of 40.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `nfc()` / `nfd()` | `normalize(text, form =)` | two cryptic acronyms become one verb with a named option; `Composed`/`Decomposed` say what happens |
| `UnicodeSegmentation::unicode_words()` | `words(text)` | it is an iterator over words; the ceremony added nothing |
| `to_lowercase` vs `to_lowercase_locale` | `lower(text, locale =)` | one proc, optional argument, per the argument-order rule |
| `to_fold_case` | `foldCase` with a `## for comparison, not display` note | the doc comment is the rename — this is the one everybody picks wrong |
| `Collator::sort_key()` | `compare(c, a, b): Order` | returning `core.cmp`'s `Order` plugs straight into every existing sort; a sort-key byte string would be a second mechanism |
| `damerau_levenshtein` | `editDistance` | the algorithm's authors are not the caller's concern; `limit` is |
| `Grapheme cluster` | `graphemes` | the word "cluster" is what makes people think it is advanced |

## In use

```nim
# spellchecker: word boundaries that work outside English
for w in document.words():
  if not dictionary.has(w.foldCase()):
    let suggestions = dictionary.toSeq()
      .filter(c => editDistance(w, c, limit = 2) <= 2)
      .sortedBy(c => c.frequency)
    echo w, " → ", suggestions.first()

# doc-convert-tester: round-trip diffing that is not fooled by encoding
assert normalize(original) == normalize(converted)

# log-grep -i, correct beyond ASCII
if line.foldCase().contains(pattern.foldCase()): echo line
```

## Vocabulary exceptions
- **`editDistance` lives here, and the placement is still arguable.** It is not numeric enough for `std.math`, and `core.str` is freestanding while the algorithm needs a working buffer. It sits in `std.i18n` because "did the user mean a different word" is a human-text question and because it must count *graphemes* to be correct — which requires this module's tables anyway. The strongest counter-argument stands: edit distance over arbitrary token sequences (diffing, DNA, fuzzy matching) has nothing to do with internationalization, and a future `std.text-algorithms` would have a fair claim on it.
- `normalize`, `foldCase`, `compare` and `editDistance` are domain verbs. `words`, `sentences` and `graphemes` use `Collection`'s `list` shape under different names, because three differently-named iterators over the same text are clearer than one `list` with a `kind` parameter — a case where the vocabulary's own rule 2 (never invent a synonym) yields to legibility, and it is recorded rather than hidden.
