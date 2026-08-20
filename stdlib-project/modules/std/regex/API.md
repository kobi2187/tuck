# std.regex

## Purpose
A regular-expression engine with a guaranteed linear-time (in input length) matching bound — no catastrophic backtracking is possible for any pattern, by construction of the algorithm, not by caller discipline.

## Design lineage
Modeled on Go's `regexp` and Rust's `regex` crate, both RE2-derived: matching is compiled to a finite automaton (Thompson NFA simulation or a lazy DFA), so worst-case time is `O(pattern_size * input_size)` regardless of input — deliberately **excluding** backreferences and arbitrary lookaround, the two features that make backtracking engines (PCRE, most languages' built-in regex) exponential on adversarial input. This exclusion is the entire point, not an oversight.

## Proposed API
```
struct Regex;
impl Regex {
    fn compile(pattern: &str) -> core::types::Result<Regex, CompileError>;
    fn compile_with(pattern: &str, opts: Options) -> core::types::Result<Regex, CompileError>;
    // Added for git-lite: compiles a single gitignore-style glob line (`*`, `**`, `?`, bracket
    // classes, trailing `/` for directory-only, leading `/` for root-anchoring) into an
    // equivalent Regex. Mechanical syntax translation only — does NOT implement gitignore's
    // ordered/negated multi-pattern list semantics; see Key design decisions and the Gap noted
    // paragraph below.
    fn from_glob(pattern: &str) -> core::types::Result<Regex, CompileError>;

    fn is_match(&self, haystack: &str) -> bool;
    fn find(&self, haystack: &str) -> Option<Match>;
    fn find_all<'h>(&self, haystack: &'h str) -> impl core::iter::Iterator<Item = Match<'h>>;
    fn captures<'h>(&self, haystack: &'h str) -> Option<Captures<'h>>;
    fn captures_all<'h>(&self, haystack: &'h str) -> impl core::iter::Iterator<Item = Captures<'h>>;

    fn replace(&self, haystack: &str, repl: &str) -> alloc::string::String;      // first match; $1-style refs
    fn replace_all(&self, haystack: &str, repl: &str) -> alloc::string::String;
    fn replace_all_with(&self, haystack: &str, f: impl Fn(&Captures) -> alloc::string::String) -> alloc::string::String;

    fn split<'h>(&self, haystack: &'h str) -> impl core::iter::Iterator<Item = &'h str>;
}

struct Options { case_insensitive: bool, multi_line: bool, dot_matches_newline: bool, unicode: bool /* default true */ }

struct Match<'h> { start: usize, end: usize, text: &'h str }
struct Captures<'h>;
impl<'h> Captures<'h> {
    fn get(&self, i: usize) -> Option<Match<'h>>;
    fn name(&self, name: &str) -> Option<Match<'h>>;   // named groups: (?P<name>...)
}

enum CompileError { SyntaxError { pos: usize, msg: alloc::string::String },
                     UnsupportedConstruct { what: &'static str } }   // backreferences etc. — rejected at compile time
```

## Key design decisions
- **Backreferences and unbounded lookaround are rejected at `compile()` time with `UnsupportedConstruct`**, not silently accepted and slow-pathed — the linear-time guarantee has to be a property of every pattern that compiles, or it isn't a guarantee. Bounded lookahead/lookbehind (fixed-width) is supported since it doesn't break the automaton construction.
- **Unicode-aware by default (`Options::unicode = true`)**: case-insensitive matching and character classes use Unicode properties (`\p{L}`), not ASCII-only semantics, because a bolt-on "unicode mode" flag is how most engines end up wrong-by-default for non-ASCII text.
- **`find_all`/`captures_all` return lazy iterators over `core.iter`**, not pre-collected `Vec`s, so scanning a large mapped file doesn't force materializing every match before the caller can act on the first one — matches Design Principle 3 directly against `sys.mmap`-backed input.
- Compilation is a distinct, fallible step from every other call (`compile` returns `Result`, everything else is infallible given a valid `Regex`) so a hot loop matching the same pattern against many lines never re-pays parse/compile cost, and errors are caught once at startup rather than scattered through match call sites.

- **`Regex::from_glob` compiles one gitignore-style glob line into a `Regex`, added for `git-lite`.** Path-glob syntax (`*` not crossing `/`, `**` crossing `/`, `?`, bracket classes, a trailing `/` meaning directory-only, a leading `/` anchoring to the ignore-file's root) translates mechanically into a regular expression, so this is genuinely in `std.regex`'s scope: it's a syntax front-end that produces an ordinary `Regex`, not a new matching algorithm. **What `from_glob` deliberately does not do is implement `.gitignore`'s list-level matching algorithm** — see Gap noted below.

**Gap noted (not resolved here):** `.gitignore`-style *pattern-list matching* is meaningfully different from what a single `Regex`'s `is_match`/`find` interface can express, and this project's module list has no clean existing home for the missing piece. A real `.gitignore` is an *ordered list* of patterns where later lines can `!negate` (re-include) a path an earlier line excluded, and the rule that actually applies to a given path is "the last pattern in the file that matches it," not "any pattern that matches it" — order-dependent, stateful evaluation across multiple compiled patterns, not single-pattern matching. No `Regex` method should grow a `negate`/`priority` parameter to paper over this. `git-lite` needs it and it isn't resolved this round: the mechanical piece (`from_glob`, one line → one `Regex`) lives here since it's an ordinary regex-syntax question, but the list-evaluation piece (an ordered `Vec<(Regex, bool)>` walked last-match-wins per candidate path) is closer to a file-tree-traversal-filtering concern than a text-matching one — `sys.fs` (which already owns directory traversal) is a more plausible eventual home than `std.regex`, but that's a placement guess, not a resolved decision, and it isn't built here either way.

## Validated by applications
- **log-grep**: the direct stress test of the linear-time claim — searching large files/directory trees with user-supplied patterns (including adversarial-looking ones like nested quantifiers) must not have pathological slowdowns; this app is why `compile()` rejects backreferences outright rather than accepting them with a documented "may be slow" caveat, since a grep-like tool is exactly where an attacker or a careless pattern could otherwise cause a hang. `find_all` as a lazy iterator directly composes with `core.iter`'s line-by-line adapter over the `sys.mmap`-backed file region with the zero-copy chain the app's own "Anticipated API stress points" section calls out.
- **todo-cli**: uses `Regex` for parsing/matching parts of the filter query mini-language (`project:home +urgent`) — a small-pattern, small-input use case that validates the API isn't over-engineered for the common "just check if this token matches" case; `is_match`/`captures` (not the streaming variants) are the ones actually used here.
- **podcast-subscriber**: uses `Regex` for cleanup of malformed/non-conformant feed text (e.g., stray unescaped `&` in titles) before XML parsing — a narrow, defensive use that confirms `replace_all_with` (closure-based replacement) is needed, not just static `$1`-style substitution, since the cleanup logic is conditional on surrounding characters.
- **spellchecker**: validates plain `Regex` — no new surface needed — for Markdown code-fence/inline-code/URL exclusion: fenced code blocks (` ``` `-delimited, spanning multiple lines) are matched via `Options::dot_matches_newline`/`multi_line`, inline code spans and bare URLs via ordinary `find_all`, confirming the existing `Options`/iterator surface is sufficient for this app without extension.
- **git-lite**: validates `from_glob` for translating `.gitignore` lines into `Regex` objects, and is the forcing case for the Gap noted paragraph above — the app's actual `add`-time exclude behavior needs the ordered/negated list semantics `std.regex` alone doesn't provide, so `git-lite` layers its own small ordered-rule-list evaluator on top of `from_glob`-compiled patterns rather than std.regex growing that behavior.
- **doc-convert-tester**: exercises `split` and named captures (`Captures::name`) for lightweight Markdown-to-HTML inline-element detection (bold/italic/link spans) — confirms named groups are load-bearing for readable format-conversion code, not a nice-to-have.

## Open questions / risks
Whether to support Unicode grapheme-cluster-aware `.` matching (as opposed to codepoint-aware, the current default) is unresolved; `std.i18n` owns grapheme segmentation, and whether `std.regex` should depend on it or stay codepoint-only to keep its dependency graph minimal is an open tension between Principle 1 (layer by dependency) and correctness on emoji/combining-sequence-heavy input.
