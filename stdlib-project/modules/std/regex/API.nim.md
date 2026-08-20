# std.regex — Nim API

## Purpose
Pattern matching that cannot blow up. Every pattern that compiles runs in time proportional to the input, because the engine is an automaton — backreferences and unbounded lookaround are rejected at compile time rather than accepted and slow.

## Protocols implemented
None of the nine — domain module. A `Regex` is a compiled program, not a container: it has nothing to `get`, `add` or `list`. Its results, however, are enumerated with the vocabulary's own `find` (one) and iterators (all), and `Captures` is `Gettable` by both position and name.

## The API

```nim
type
  Regex* = object
  Match* = object
    span*: HSlice[Index, Index]   ## byte offsets into the haystack
    text*: TextView
  Captures* = object

proc toRegex*(pattern: TextView;
              ignoreCase = false; multiline = false;
              dotMatchesNewline = false; unicode = true): Regex
  ## Compiles. Raises `Failure` with a `Where` at the offending character — and
  ## raises the same way for a backreference or unbounded lookaround, which are
  ## not "slow", they are not supported. Every option is a trailing named argument;
  ## there is no `Options` object to build.
proc tryToRegex*(pattern: TextView; ...): Option[Regex]
proc globToRegex*(glob: TextView): Regex
  ## One gitignore-style line (`*`, `**`, `?`, `[a-z]`, trailing `/`, leading `/`)
  ## into an ordinary Regex. Syntax translation only — see Vocabulary exceptions.

func has*(text: TextView; rx: Regex): bool          ## does it match anywhere? never raises
func find*(text: TextView; rx: Regex): Option[Match]
iterator matches*(text: TextView; rx: Regex): Match
  ## Lazy. Scanning a memory-mapped log stops the moment the caller stops asking.
func capture*(text: TextView; rx: Regex): Option[Captures]
iterator allCaptures*(text: TextView; rx: Regex): Captures

func get*(c: Captures; group: Index): Option[Match]      ## Gettable by number
func get*(c: Captures; name: static string): Option[Match]  ## and by `(?P<name>...)`
func count*(c: Captures): Count

proc replace*(text: TextView; rx: Regex; with: TextView): Text        ## first match; `$1` refs
proc replaceAll*(text: TextView; rx: Regex; with: TextView): Text
proc replaceAll*(text: TextView; rx: Regex;
                 build: proc (c: Captures): Text): Text
  ## Overload, not a third name — Nim picks by argument type.
iterator split*(text: TextView; rx: Regex): TextView
  ## Same word and shape as `core.str.split`, so one habit covers both.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Regex::compile(p)` | `toRegex(p)` | PROTOCOLS' `to<Format>` family — `"\\d+".toRegex()` reads left to right, and `tryToRegex` carries the failure mode in its name. |
| `Options { .. }` struct | trailing named args | Four booleans became four options-last arguments, per the argument-order convention. One less type to discover. |
| `is_match` | `has` | The vocabulary's membership verb. `line.has(rx)` is what a casual coder writes first. |
| `find_all` | `matches` iterator | `find` already means "one, maybe". The plural gets the plural noun. |
| `captures` / `captures_all` | `capture` / `allCaptures` | Singular for the `Option`, plural for the iterator — the same split as `find`/`matches`. |
| `Captures::get(i)` / `::name(s)` | `get` (overloaded) | One verb, two locator types. Nim overloads; the reader never picks a suffix. |
| `replace_all_with(f)` | `replaceAll` (overload) | The closure form is the same operation with a different second argument. |
| `from_glob` | `globToRegex` | Names both ends of the conversion, so it is greppable from either side. |
| `CompileError` enum | `Failure` + `Where` | `core.error`'s one mechanism. The bad character's offset lives in `Where`, exactly as `config-schema-validator` already expects it. |

**Why the type is still `Regex`.** `core.str` already owns `Pattern` (a `Rune | TextView | proc` type class used by `split`, `trim` and `find`). Naming this one `Pattern` too would collide head-on with the friendliest thing in the lower tier. `Regex` is the universally recognised word, so it stays.

## In use

```nim
# log-grep: compile once, scan a mapped file lazily, case-folding correct beyond ASCII
let rx = pattern.toRegex(ignoreCase = opts.ignoreCase)   # calls std.i18n.caseFolded
for line in region.asText().split('\n'):
  for m in line.matches(rx):
    echo file, ":", lineNo, ":", m.text

# todo-cli: small pattern, small input, no ceremony
let filter = "([a-z]+):(\\S+)".toRegex()
line.capture(filter).ifSome(c):
  let key = c.get("key").get().text

# git-lite: one glob per line, list semantics stay the app's own problem
for rule in ignoreFile.lines(): rules.add((rule.globToRegex(), rule.startsWith("!")))
```

## Vocabulary exceptions
`matches`, `capture`, `replace`, `split` and `globToRegex` are domain verbs for text matching; the structural table covers access to containers, not searching within text. Each takes its haystack first, which is what makes `line.has(rx).matches(rx)`-style UFCS chaining read correctly — the haystack is the target, the pattern is the locator.

**`globToRegex` deliberately stops at translation.** A real `.gitignore` is an *ordered* list where a later `!pattern` re-includes what an earlier line excluded, and the rule that wins is the last one that matches — order-dependent evaluation across many patterns, not single-pattern matching. No `Regex` proc grows a `negate` or `priority` argument to paper over that. `git-lite` layers its own last-match-wins walk over a `List[(Regex, bool)]`; the eventual home for that is more plausibly `sys.fs`, which already owns directory traversal, but that is a guess and it is not built here.
