# Batch E — text / string / everyday I-O

20 small programs in `rosetta/examples/e01-*.tuck` .. `e20-*.tuck`. Verified with
`./tuck check FILE --root:/home/kl/prog/tuck_lexer`, then `./tuck build` and run for
everything that checked OK.

Status legend:
- **GREEN** — builds and runs, output correct, no invented (`pending:`) fns involved.
- **PENDING-RUNS** — checks OK, builds OK, runs OK, but only because it calls an
  invented `pending:` fn, which is a stub that prints `TUCK PENDING: <name> invoked
  (not implemented)` and returns a zero value instead of doing real work. The plumbing
  works; the semantics don't exist yet.
- **CHECKS** — `tuck check` passes, `tuck build` fails. Nim-stage error given.
- **PARSE** — parser rejects it. Exact error given.
- **NEEDS** — uses invented fns (also true of every PENDING-RUNS row; called out
  again in the detail column for quick scanning).

| file | task | status | detail |
|---|---|---|---|
| e01-hello-world | hello world | GREEN | prints `Hello, world!` |
| e02-string-length | `.len` on a str | GREEN | prints `11` |
| e03-concat-strings | `a + b` | GREEN | prints `foobar` |
| e04-repeat-string | repeat string n times | CHECKS | invented `repeat`; Nim codegen emits `out` as a raw identifier — `identifier expected, but got 'keyword out'`. Same root cause as e14. |
| e05-reverse-string | reverse a string | PENDING-RUNS | invented `reverse`; stub prints `TUCK PENDING: reverse invoked (not implemented)`, returns `""` |
| e06-palindrome | palindrome check via `reverse` | PENDING-RUNS | same stub; because stub returns `""` ≠ `"level"`, prints "not a palindrome" — a false negative caused by the stub, not the logic |
| e07-upper-lower | `upper`/`lower` | PENDING-RUNS | invented both; both stub, prints two PENDING lines then two blank lines |
| e08-compare-strings | `==` plus invented `lessThan` | CHECKS | Nim codegen error: `extra argument given` — `lessThan[T](payload: T)` was generated ignoring the second field (`b`); pending-stub codegen collapses a 2-field payload to 1 param. Same root cause as e09/e10/e11/e13/e15/e16. |
| e09-substring | invented `substring` | CHECKS | same "extra argument given" codegen bug, 3-field payload |
| e10-split | invented `split` | CHECKS | same codegen bug, 2-field payload |
| e11-join | invented `join` | CHECKS | same codegen bug, 2-field payload |
| e12-trim | invented `trim` | PENDING-RUNS | single-field payload — the one-arg case works; stub runs and prints empty line |
| e13-starts-ends-with | invented `startsWith`/`endsWith` | CHECKS | same codegen bug, 2-field payloads |
| e14-replace | invented `replace` | CHECKS | same `keyword out` Nim error as e04, 3-field payload |
| e15-count-words | reuse invented `split` | CHECKS | same codegen bug as e10 |
| e16-count-char | invented `countOccurrences` | CHECKS | same codegen bug, 2-field payload |
| e17-string-int-convert | invented `parseInt` returning `!int [io]` | PENDING-RUNS | stub prints PENDING line then a raw `TuckResult` tuple `(status: tsOk, err: 0, value: 0)` instead of unwrapped `int` — see note below on `!T` |
| e18-format-greeting | string concat, no new fns | GREEN | prints `Hello, Ada!` |
| e19-read-line-echo | `readLine` from `std/io` | CHECKS | Nim codegen collision: generated `.nim` calls a bare `readLine` that's ambiguous between `syncio.readLine` and `tuck_rt.readLine` — needs qualification in codegen output, not in the source |
| e20-read-write-file-time | `writeFile`/`readFile`/`nowMs` from `std/fs`,`std/time` | CHECKS | same collision bug, this time on `writeFile` vs `syncio.writeFile` |

**Status counts:** GREEN 4, PENDING-RUNS 5, CHECKS 11, PARSE 0.

## Language findings along the way (not stdlib, but worth recording)

- **`expr?` error-propagation from SYNTAX.md does not exist in the parser.** Grepped
  `compiler/parser_expr.nim` / `parser_stmt.nim`: `tkQuestion` only appears in
  `parser_type.nim` (for `?T` optional / `!T` result *type* syntax), never in the
  expression parser. `{a: 10, b: 2} divide?` is a parse error — this was a SYNTAX.md
  documentation error (now corrected by the team lead), not a batch-C authoring
  mistake; `c10-result-error-handling.tuck` was written correctly against the doc as it
  stood and fails `tuck check` today for the same reason this batch's first drafts did.
- **Workaround used throughout this batch:** call an `!T`- or effect-returning fn with
  no `?` at all (bare `{...} readLine`, bare `nowMs`), and either field-access into the
  result directly (`input.line` off a `!{line:str}` works fine, `tuck check` passes) or,
  for `!int`-shaped results, accept that at runtime you get the raw `TuckResult` tuple,
  not an unwrapped value (see e17). There is currently no *checked* way in working Tuck
  to get from `!T` to `T` — no `?`, no visible `match`/unwrap idiom that passed check in
  any spike here. This is a bigger gap than any single stdlib fn: **fallible-result
  unwrapping is missing an end-to-end story**, blocking every fs/io/parse example that
  wants to look natural.
- **Two independent codegen bugs, not language limits, cost 11 of these 20 files their
  BUILD:**
  1. `pending:` stub generation emits a single generic payload param
     (`proc foo*[T](payload: T)`), but the call site emits the struct's fields spread
     out positionally (`foo(xs, 1)`) instead of packed into one struct argument — arity
     mismatch, "extra argument given" at the Nim stage. One-field payloads (`trim`,
     `reverse`, `upper`) happen to line up 1-param-to-1-arg and are fine; 2+ fields
     break. This alone explains 6 of the 11 CHECKS rows (e08, e09, e10, e11, e13, e15,
     e16) and was also hit independently by batch D.
  2. `pending:` stub generation sometimes emits a Nim identifier literally named `out`
     (a Nim keyword) for the return slot — `identifier expected, but got 'keyword out'`
     — hit on `repeat` and `replace` (e04, e14). Unclear yet whether this correlates
     with 2-arg vs 3-arg payloads or is a separate bug; both hits were 2+ arg pending
     fns with a `str` return type.
  3. `std/io.readLine`, `std/fs.writeFile`/`readFile` generate bare (unqualified) Nim
     calls that collide with Nim's own `system`/`syncio` procs of the same name —
     `ambiguous identifier`/`ambiguous call`. `tuck_rt.readLine` needs to be emitted
     qualified. Hit on e19 and e20.
- **Pending-stub runtime behavior is good and worth keeping**: it doesn't crash, it
  prints a clear `TUCK PENDING: <name> invoked (not implemented)` marker to stdout and
  returns a zero value, so files with holes still demonstrate control flow end to end.

## Proposed stdlib API

Ranked by how many of the 20 examples wanted it. The single most important call here:
**Tuck needs a `char`/text-element story.** Every "process character by character" task
(reverse, palindrome, count-char, Caesar-shift-style transforms) was written here
against whole-string ops (`reverse`, `countOccurrences` with a needle *string*, not a
char) purely because there is no char type and no string indexing — `s[0]` on a `str`
is a type error today (per DISCOVERIES.md).

**Recommendation: `str::charAt({text: str, index: int}) -> str`, a length-1 `str`, no
new type — but with eyes open about what that commits to.**

Option A — `charAt` returns a length-1 `str` (byte- or codepoint-sliced under the hood,
caller can't tell which):
  - Fits today's model instantly: no new literal syntax, no new comparison operators,
    `toStr`/`==`/`+` all already work on `str`, zero compiler lift.
  - What breaks later if Tuck wants real Unicode: a "length-1 str" is a lie the moment
    the input has a multi-byte UTF-8 codepoint (é, emoji, CJK) — is index 0 of "café"
    the byte before the é, or the codepoint? If `charAt` is byte-sliced (cheapest to
    implement), `{text: "café", index: 3} charAt` returns half of the é's UTF-8
    encoding — a str that is not valid UTF-8, silently. Every caller that assumed
    "1 char = 1 charAt result" (reverse, palindrome check, Caesar cipher) is wrong on
    non-ASCII input and there is no type-level signal that it's wrong. Retrofitting
    codepoint-awareness later means either an expensive scan on every `charAt` call
    (str has no O(1) codepoint index) or a breaking signature change once callers
    already depend on the byte-sliced behavior.
  - Verdict: acceptable **only if scoped explicitly to ASCII/byte semantics now**, with
    that documented on the signature itself, e.g. `charAt` operating on bytes and a
    separate `codepointAt`/grapheme-aware API deferred. Don't let it quietly become the
    de facto "character" API without that caveat — the examples in this batch (reverse,
    palindrome, count-char) are all ASCII-safe, so the gap wouldn't show up until a
    later batch hits non-ASCII text and silently gets wrong answers, not an error.

Option B — real `char` distinct-over-`u8` type plus `str::bytes`/`str::fromBytes`:
  - Correct foundation for UTF-8 later (a `char`/byte type is honest about being a byte,
    not a "character"); bigger lift now (new literal syntax, comparisons, `toStr`
    overload, plus still needs a *separate* codepoint-aware layer on top for actual
    Unicode correctness — a `u8` alone doesn't solve multi-byte text either).
  - Verdict: don't build this now for the sake of 20 ASCII examples: no task in this
    batch needed byte-level control, and building it early risks over-fitting the type
    to guesses about what UTF-8 handling should look like before there's a real
    multi-byte use case to design against.

Net: ship Option A (`charAt` on bytes, documented as such) to unblock this batch's
class of tasks now; treat full codepoint/grapheme correctness as a distinct, deferred
design question, not something `charAt`'s signature should pretend to have solved.

### std/str — the biggest gap, by far

```tuck
fn upper({text: str}) -> str          # 2 examples (e07, informs e06-style casing tasks)
fn lower({text: str}) -> str          # 1 example (e07)
fn trim({text: str}) -> str           # 1 example (e12) — leading+trailing whitespace
fn reverse({text: str}) -> str        # 2 examples (e05, e06) — needed for palindrome
                                       #   check; also the #1 blocker DISCOVERIES.md
                                       #   already called out for reverse/anagram tasks
fn split({text: str, sep: str}) -> Seq[str]      # 2 examples (e10, e15) — word count,
                                                  #   CSV-style parsing; highest-value
                                                  #   single addition, unlocks a whole
                                                  #   class of parsing examples
fn join({items: Seq[str], sep: str}) -> str      # 1 example (e11) — the natural dual
                                                  #   of split, near-mandatory once
                                                  #   split exists
fn startsWith({text: str, prefix: str}) -> bool  # 1 example (e13)
fn endsWith({text: str, suffix: str}) -> bool    # 1 example (e13)
fn replace({text: str, target: str, replacement: str}) -> str   # 1 example (e14)
fn substring({text: str, start: int, length: int}) -> str       # 1 example (e09)
fn repeat({text: str, times: int}) -> str        # 1 example (e04)
fn countOccurrences({text: str, needle: str}) -> int   # 1 example (e16); needle is a
                                                        #   str not a char — see the
                                                        #   char-type ruling above
fn lessThan({a: str, b: str}) -> bool            # 1 example (e08) — lexicographic
                                                  #   ordering; str only has `==` today
fn parseInt({text: str}) -> !int [io]            # 1 example (e17) — MUST be `!T` since
                                                  #   "abc" parseInt is a real failure
                                                  #   mode; but see the `!T`-unwrap gap
                                                  #   above — this fn is nearly useless
                                                  #   in practice until `?`/match on
                                                  #   `!T` actually works
```

Note `toStr` already exists (`std/str.toStr[T]`) and covers int-to-string; no gap there.

### std/io — small, already close to sufficient

No new fns needed; `print`/`printLine`/`readLine` from the existing `std/io` covered
every I/O task in this batch (e19). The blocker for e19/e20 was codegen (naming
collision), not a missing signature.

### std/fs — already sufficient for this batch

`readFile`/`writeFile` from the existing `std/fs` covered e20 with no new signatures
needed. Same codegen-collision blocker as io, not a missing fn.

### std/time — already sufficient for this batch

`nowMs` from the existing `std/time` covered "current time" (e20); no wall-clock
date/calendar fn (year/month/day) was reached for in this batch since none of the 20
tasks needed calendar formatting — flagging as a likely near-future gap
(`fn today() -> {year: int, month: int, day: int}` or similar) but not counted as
demanded here since no example actually called for it.

## Summary

- 4 GREEN, 5 PENDING-RUNS (stub-only, correct plumbing), 11 CHECKS (compiles Tuck-side,
  fails at the Nim stage), 0 PARSE rejections against files written to avoid known gaps.
- Two codegen bugs (multi-field pending-stub payload collapse; bare-name collision with
  Nim stdlib procs of the same name) account for all 11 CHECKS failures — none are
  fundamental language limits, all are compiler bugs in the pending-stub / extern-fn
  codegen path.
- The single biggest stdlib gap is **`std/str`**, needing at minimum `split` and `join`
  (the highest-leverage pair — unlocks parsing/formatting broadly) plus `reverse`,
  `upper`/`lower`, `trim`, `startsWith`/`endsWith`, `replace`, `substring`, `repeat`,
  `countOccurrences`, `lessThan`, `parseInt`.
- The single biggest *design* gap is the missing `!T` → `T` unwrap story (no working
  `?`, no verified match-based unwrap) — worse than any one function, since it silently
  undermines every fallible fn (`parseInt`, `readFile`, `readLine`) even once they're
  implemented.
