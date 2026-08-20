# std.i18n

## Purpose
Unicode normalization (NFC/NFD/NFKC/NFKD), locale-aware collation (sorting/comparison), and locale-aware formatting of numbers, dates, and currency — the internationalization surface every other `std` module (`regex`'s case folding, `chrono`'s display, `math`'s `Decimal` display) can build on rather than reimplement.

## Design lineage
Modeled on ICU (International Components for Unicode), "the de facto standard nearly every language wraps" per the report — not reimplemented from scratch, but scoped down to the subset of ICU's surface that recurring app needs actually exercise (normalization, collation, basic locale-aware formatting), rather than exposing ICU's full breadth (calendars beyond Gregorian, complex text layout, message formatting with plurals/genders) which is left to the extended ecosystem per Principle 5's "batteries included, not everything included."

## Proposed API
```
mod normalize {
    enum Form { Nfc, Nfd, Nfkc, Nfkd }
    fn to(s: &str, form: Form) -> alloc::string::String;
    fn is_normalized(s: &str, form: Form) -> bool;         // cheap check, avoids a reallocation when already normalized
}

mod collate {
    struct Collator;
    impl Collator {
        fn for_locale(locale: &Locale) -> Collator;
        fn with_strength(self, s: Strength) -> Collator;    // Primary (base letter) .. Tertiary (case/accents)
        fn compare(&self, a: &str, b: &str) -> core::cmp::Ordering;   // the one comparison mechanism (core.cmp)
        fn sort_key(&self, s: &str) -> alloc::vec::Vec<u8>;            // precomputed key for repeated sorts
    }
    enum Strength { Primary, Secondary, Tertiary }

    // implements core.cmp::Ord-compatible sorting for any alloc.vec of strings, given a Collator
    fn sort(items: &mut [alloc::string::String], collator: &Collator);
}

mod casefold {
    fn fold(s: &str) -> alloc::string::String;                          // full Unicode case folding, for caseless comparison
    fn eq_caseless(a: &str, b: &str) -> bool;                            // correct beyond ASCII (İ/i, ß/ss, etc.)
}

struct Locale(alloc::string::String);      // BCP 47 tag, e.g. "en-US", "de-DE"
impl Locale { fn default_system() -> Locale; }   // reads sys.env locale settings

mod format {
    fn number(n: f64, locale: &Locale) -> alloc::string::String;                        // "1,234.5" vs "1.234,5"
    fn currency(amount: &std::math::Decimal, currency_code: &str, locale: &Locale) -> alloc::string::String;
    fn date(d: &std::chrono::LocalDate, locale: &Locale, style: DateStyle) -> alloc::string::String;
    enum DateStyle { Short, Medium, Long }
}

mod segment {
    fn graphemes(s: &str) -> impl core::iter::Iterator<Item = &str>;    // user-perceived characters, not codepoints
    fn words(s: &str) -> impl core::iter::Iterator<Item = &str>;        // UAX #29 word-boundary rules — see decisions
}

// Added for spellchecker: bounded string-edit distance. See "Where does edit-distance belong?"
// in Key design decisions for why this lives here rather than std.math or core.str.
mod edit_distance {
    // Damerau-Levenshtein distance over Unicode scalar values (core.str codepoint iteration, not
    // bytes — a multi-byte codepoint counts as one edit, not the length of its UTF-8 encoding).
    // Adjacent-transposition counts as a single edit, matching the single most common human typo
    // pattern ("teh" -> "the") better than plain Levenshtein.
    fn distance(a: &str, b: &str) -> usize;
    // Bounded variant: returns None as soon as the distance is known to exceed `max`, so a
    // suggestion search over a large dictionary doesn't pay for a full DP table per candidate
    // when the caller only cares about e.g. distance <= 2.
    fn distance_bounded(a: &str, b: &str, max: usize) -> Option<usize>;
}
```

## Key design decisions
- **Normalization is exposed as a pure function over `&str`, with an `is_normalized` fast-path check** — a round-trip diffing tool comparing "did this text survive conversion" needs to normalize *before* comparing, and needs to do so cheaply for the overwhelmingly common case (already-NFC text) without a full re-encode; `is_normalized` exists specifically to make that fast path explicit rather than forcing every comparison through a full normalization pass.
- **`Collator::compare` returns `core.cmp::Ordering`, the same type every other comparison in this stdlib returns** — locale-aware string sorting is a real place a naive design would invent a bespoke `-1/0/1` integer convention (as many locale libraries historically have); this design routes it through Principle 4's one comparison mechanism instead, so `alloc.map`'s ordered variants and `std.i18n`'s collator can both back a "sort tasks by name, locale-correctly" feature with the same `Ord`-shaped call.
- **`casefold::eq_caseless` is a distinct function from `Collator` with `Strength::Primary`**, even though both can approximate caseless comparison, because case folding (`std.regex`'s `-i` flag, per `log-grep`'s requirement) is a narrower, faster, locale-*independent* operation, while collation-based comparison is locale-sensitive and heavier; conflating them into one function would force every caseless regex match to carry locale overhead it doesn't need.
- **`segment::graphemes` exists as a first-class export because `core.str`/`alloc.string` deliberately only offer codepoint-level iteration** (Tier 0/1 must stay allocation- and ICU-data-table-free) — user-perceived-character-correct text handling (an emoji-with-modifier not splitting mid-cluster) is pushed up to `std.i18n` specifically so the lower tiers stay small, which is Principle 1 (layer by dependency) applied to Unicode complexity itself, not just OS dependency.

- **`segment::words` implements UAX #29 word-boundary rules, not whitespace/punctuation splitting** — `spellchecker` is the module's first real test of this beyond the function's prior existence as a sketch: correct tokenization keeps contractions (`don't`) as one token, splits on punctuation without breaking numeric/currency tokens (`$19.99`) incorrectly, and doesn't degrade to whitespace-splitting for scripts that don't delimit words with spaces at all. **Honest limitation, stated rather than hidden:** for CJK/Thai-style scripts, `segment::words` applies UAX #29's default rules, which conservatively treat runs of ideographic/Thai characters as one break-opportunity-free chunk rather than further-segmenting into individual words — true dictionary-based CJK/Thai word segmentation is an ICU capability this module does not attempt to reproduce, consistent with `Design lineage`'s "scoped down to the subset ICU's surface that recurring app needs actually exercise." `spellchecker`'s own feature list is Latin/`--lang`-dictionary-fronted, so this limitation doesn't block its validation here, but it's a real, named gap for any future app wanting correct CJK/Thai tokenization.
- **`edit_distance` is added to `std.i18n`, not `std.math` or `core.str` — resolving the placement question `spellchecker`'s own validation note raises explicitly as a judgment call, and this module agrees with the app's proposal, but records the reasoning rather than presenting it as obviously correct.** Bounded edit distance over dictionary words is functionally inseparable from "is this token a plausible human mistake of a known word" — a text-*correctness* question about human-authored strings, the same category `casefold`/`collate`/`segment` already own — rather than a numeric algorithm (`std.math`'s surface is elementary functions/decimals/statistics; a string-alignment DP table doesn't fit that any better than string algorithms in general would), and it structurally can't live in `core.str` (freestanding, no `alloc.vec` for the DP table). The strongest counter-argument, recorded here rather than left implicit: `edit_distance` has plenty of uses with nothing to do with human language (fuzzy CLI command matching, log/DNA-adjacent string-diffing) and a caller reaching for generic string-distance in one of those contexts has no strong reason to look in `std.i18n` for it. The placement is defensible, not inevitable — see Open Questions.

## Validated by applications
- **doc-convert-tester**: the primary consumer — its round-trip diffing explicitly uses `normalize::to(_, Form::Nfc)` on both sides of an A→B→A conversion before comparing, specifically so that equivalent-but-differently-encoded Unicode (a precomposed é vs. e+combining-acute) doesn't register as a false conversion failure; this app's "Anticipated API stress points" section calls this out directly, and it's the forcing function behind `is_normalized`'s existence as a fast-path rather than the harness eating a full re-normalization cost on every diff.
- **log-grep**: the primary consumer of `casefold` — `-i` case-insensitive matching must be "correct beyond ASCII" per the app's own feature list, so `std.regex`'s case-insensitive mode is specified to call into `std.i18n::casefold` rather than implementing its own ASCII-only lowercase table, which is the concrete dependency edge validating that `std.regex` and `std.i18n` compose cleanly rather than each shipping a competing, subtly-different notion of "case insensitive."
- **todo-cli**: uses `collate::sort` for locale-correct alphabetical sorting of task/project names in list views (an ordinary `byte`-order sort would misorder accented names for non-English users), and `format::date` for locale-appropriate due-date display — a modest but real exercise of the formatting half of the module.
- **spellchecker**: the primary consumer of both additions above — `segment::words` for Unicode-correct tokenization (the module's first real exercise beyond case-folding/normalization, per this app's own framing) feeding dictionary lookup via `alloc.set`, and `edit_distance::distance_bounded(token, candidate, 2)` for ranked suggestion generation, run against dictionary entries (typically prefiltered by an app-level length heuristic to keep the search tractable against a large wordlist — not a module concern).
- **secrets-vault**: does not use `std.i18n` at all — site names and usernames are treated as opaque strings, not sorted or normalized, which is a deliberate negative check that the module's cost stays confined to programs that actually display or compare human text meaningfully.

## Open questions / risks
- Whether `std.i18n` should ship its own copy of Unicode/CLDR data tables (increasing binary size for every consumer, even ones only using `normalize`) or support a pluggable/loadable data-table backend (smaller default footprint, extra complexity) is unresolved and is the module's most consequential open implementation question, distinct from but analogous to the tension the report notes in embedded toolkits between "batteries included" and footprint discipline.
- Whether `edit_distance`'s placement here (rather than `std.math`, or a home neither module currently has room for) is the right long-term call is left explicitly open, per the judgment call recorded in Key design decisions; a second, unrelated consumer of generic string-distance (fuzzy CLI matching, log/gene-diffing tools) would be a reasonable future forcing case to revisit this.
- Dictionary-based (not rule-based) word segmentation for CJK/Thai-style scripts is out of scope, per the honest limitation recorded in Key design decisions — unresolved because no validating app in this corpus exercises those scripts, not because the gap is considered acceptable indefinitely.
