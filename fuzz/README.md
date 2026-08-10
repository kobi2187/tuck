# Fuzzing the front end

Two mechanisms, because they find different defects.

## 1. libFuzzer target — finds CRASHES

`fuzz_frontend.nim` feeds arbitrary bytes to the lexer and parser. A
`SyntaxError` is the correct outcome and is discarded; anything else — an
`IndexDefect`, an `OverflowDefect`, a failed assert, a hang — takes the
process down, which is what libFuzzer reports.

```bash
nim c fuzz/fuzz_frontend.nim
./fuzz/fuzz_frontend -fork=4 -ignore_crashes=1 -max_len=2048 \
  -dict=fuzz/tuck.dict -artifact_prefix=fuzz/findings/ fuzz/corpus/
```

`tuck.dict` is a keyword dictionary. It matters: without it the corpus
plateaued around 6 inputs; with it the run reached 61, because the mutator
could produce tokens the grammar actually recognises instead of hunting for
`fn` a byte at a time.

Replay a finding without libFuzzer or the sanitizers:

```bash
nim c fuzz/replay.nim
./fuzz/replay fuzz/findings/leak-<hash>
```

`replay` reports, per input, `ACCEPTED` / `rejected` with the diagnostic /
`RAISED` — which is what makes it useful for triage rather than just
reproduction.

**Note on `leak-*` artifacts.** Nim's ARC allocates the exception object for
a rejection, and LeakSanitizer reports it. They are not findings. Replaying
them shows a clean rejection every time. They are still worth reading, which
is how the `tkPipe` diagnostics were found.

## 2. Rejection corpus — finds MISSING errors

libFuzzer structurally cannot find "invalid input was accepted", because
accepting garbage is not a crash. That half is `tests/suites/duplicates.nim`: inputs
that MUST be rejected, asserted to be.

This is where the more serious defects were. Twelve shapes of duplicate
declaration passed the whole front end and typechecker, reached codegen, and
emitted invalid target code — the user got a Nim redefinition error naming
generated code they never wrote.

When adding a rejection test, add the must-still-be-ACCEPTED cases beside it.
`duplicates.sh` has three; they are what shows the new rule does not
over-reach, and they were the reason the fix could be trusted against the 42
examples.

## What this has found so far

| Class | Finding |
|---|---|
| foundation | The front end called `quit(1)` on rejection, so no caller could tell a rejection from a crash. Now raises `SyntaxError`. |
| missing error | Three copies of the lex-then-parse sequence, one guarded — `tuck ch` on a stray `@` printed a Nim stack trace. |
| missing error | Duplicate fn / type / object / const / field / variant / parameter, all accepted, all reaching codegen. |
| unfriendly | `Expected expression but got: tkPipe` — nine findings, all leaking the token enum. |

## The largest missing-error source: `unknownType`

`compatible` returns true whenever either side is Unknown
(`typecheck.nim`), so **every Unknown is a check that silently passes**.
`unknownType`'s own doc says "every one found so far turned out to be a bug
it was hiding". That is now measured rather than asserted.

Building with that line returning `false` instead:

```bash
# the experiment, not a supported build
nim c -d:strictUnknown -o:tuck_strict tuck.nim
```

turns **7 of the 43 examples red**, each a real gap:

| example | hidden by Unknown |
|---|---|
| `08-actors_isolated_state` | an untyped value assigned to a sum type |
| `22-error-policy` | a fn returning `<unknown>` against a declared `!{value: u16}` |
| `27-actor-select`, `42-net-echo` | a fn whose body the checker cannot type satisfying `-> bool` |

The `-> bool` cases are the sharpest: a predicate the checker gave up on
still passes a bool return, and codegen then emits what the backend rejects.

This is not a one-line fix — Unknown is load-bearing for gradual typing
(sketch code, an unknown module prefix, a pending fn's callers), which is
why the line is still there. Narrowing it means giving each of those cases
its own named sentinel, which `typecheck_util.nim` already began
(`pendingType`, `typeParamType`, `afterErrorType`). The 7 failures are the
work list.

## Not yet covered

- The TYPECHECKER and both backends. This target stops at the parser; a
  separate harness could take a parsed module through `typecheckModule`.
- `type T: next: T` (a value type containing itself) is accepted. Whether
  that should be rejected is a language question, not a compiler bug —
  needs a ruling before a test asserts either way.
