# std.testing — Nim API

## Purpose
Tests, benchmarks, property/fuzz targets and crash-injection in one runner, with nothing to install. It reads like Nim's own `unittest` — `suite`, `test`, `check` — with the pieces `unittest` never had: table-driven cases, shrinking fuzz, and a way to kill the program mid-write and assert what survived.

## Protocols implemented
None of the nine for the runner — a test framework is control flow, not a value shape. `Report` is a `Collection[Outcome]`, so `count`, `keepIf` and `each` come free when you want to post-process a run.

## The API

```nim
type
  Test* = object       ## the per-test handle: logging, subtests, cleanup, skipping
  Bench* = object
  Draw* = object       ## the fuzz runner's source of structured randomness
  Outcome* = enum Passed, Failed, Skipped

template suite*(name: static string; body: untyped)
template test*(name: static string; body: untyped)
  ## Inside, `it` is the `Test`. Nim's own words, so nobody relearns the outer shape.
template check*(condition: untyped)
  ## Fails and keeps going. The failure message is built from the *expression tree*,
  ## so `check a.len == b.len` prints both sides without you naming them.
template require*(condition: untyped)     ## fails and stops this test immediately

proc expect*[T](t: var Test; got, want: T)          ## the two-value form, with a diff
template expectFailure*(t: var Test; work: untyped) ## passes only if `work` raised
proc note*(t: var Test; msg: string)
proc skip*(t: var Test; why: string) {.noreturn.}
proc cleanup*(t: var Test; work: proc ())           ## LIFO, runs even after a raise
proc tempFolder*(t: var Test): Path                 ## removed for you

template forEach*[C](t: var Test; cases: openArray[C]; body: untyped)
  ## Table-driven. Each case becomes its own named subtest, individually re-runnable
  ## with `-run Suite/case3`, so a failure names itself.

template benchmark*(name: static string; body: untyped)
proc rounds*(b: Bench): Count       ## how many iterations the runner chose
proc resetClock*(b: var Bench)

template fuzz*(name: static string; body: untyped)  ## `it` is a Test, `draw` is a Draw
proc byte*(d: var Draw): byte
proc bytes*(d: var Draw; upTo: Count): List[byte]
proc text*(d: var Draw; upTo: Count): Text          ## always valid UTF-8, combining marks included
proc seedWith*(t: var Test; corpus: openArray[View[byte]])
  ## Seed cases are replayed as ordinary tests too, so a shrunk failure becomes a regression test.

proc runTests*(pattern = ""): Report
proc runBenchmarks*(pattern = ""): Report
proc runFuzz*(target: string; forTime: Duration): Report
  ## On failure, shrinks the underlying byte source toward empty and reports the
  ## smallest input that still reproduces — two random kilobytes is not a bug report.
iterator list*(r: Report): (string, Outcome)

# fault injection
proc killChild*(t: var Test; bin: string; args: openArray[string];
                when: KillWhen): ExitStatus
  ## A real subprocess, a real SIGKILL. Page cache and fsync behave for real.
type KillWhen* = object
  case kind*: KillKind
  of AfterDelay: delay*: Duration
  of AfterMarker: marker*: Path   ## the child touches this right after the write under test
template withFaults*(t: var Test; faults: Faults; body: untyped)
proc failWrite*(f: var Faults; nth: Count; why: string)
proc corruptRead*(f: var Faults; nth: Count; mangle: proc (buf: var openArray[byte]))
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `T` (the handle) | `Test` | A one-letter type is a Go idiom, not a readable one. |
| `expect_eq(t, got, want)` | `check` / `expect` | `check` is Nim's own word and needs no arguments named at all; `expect` stays for when you want the got/want diff. |
| `expect_err` | `expectFailure` | Under the raise rule there is no `Err` value to inspect — the thing you assert is that it raised. |
| `table(t, cases, f)` | `forEach(t, cases)` | Reads at the call site as what it does; "table" describes the data, not the action. |
| `Unstructured` | `Draw` | You *draw* values from it. "Unstructured" names what it isn't. |
| `B::n()` / `reset_timer` | `rounds` / `resetClock` | Plain nouns; `n` is a variable name, not an API. |
| `fault::Injector` | `Faults` + `withFaults` | The scoped template means faults cannot leak past the block that armed them. |
| `fault::kill_subprocess` | `killChild` | `sys.process` already calls it a `Child`; one word for one concept. |
| `KillTrigger::AfterMarkerFile` | `KillWhen.AfterMarker` | The question is *when*, and the answer belongs in the type name. |

## In use

```nim
# cli-hangman: pure state machine, zero fakes, zero I/O — the control case
suite "guessing":
  test "a repeat guess costs nothing":
    it.forEach(cases):
      check guess(case.state, case.letter) == case.want

# diff-patch: the property, with a small counterexample when it breaks
fuzz "apply(diff(a,b), a) == b":
  let a = draw.text(upTo = 4096)
  let b = draw.text(upTo = 4096)
  check apply(diff(a, b), a) == b

# kv-store-server: kill it mid-append, then prove nothing acknowledged was lost
let status = it.killChild("kvstore", @["--wal", wal], when = afterMarker(marker))
check replay(wal).acknowledged == expected
```

## Vocabulary exceptions
`check`, `expect`, `skip`, `note`, `fuzz`, `benchmark` and `killChild` are domain verbs — assertions are control flow, and PROTOCOLS' table describes operations on values. `check` deliberately shadows nothing: it is a template, so the condition's source text survives into the failure message, which is the single thing that makes a bare `check a == b` more useful than `expect(t, a, b)`.

`Draw`'s methods (`byte`, `bytes`, `text`) are named for what they produce rather than taking a `kind` argument, because a fuzz target reads better as a sequence of nouns than as a sequence of enum lookups. `runFuzz`'s shrinking works on the raw byte source, so it never needs to know a target called `text` twice.
