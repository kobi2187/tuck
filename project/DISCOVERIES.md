# DISCOVERIES

Append-only. 1-3 lines per entry: what was assumed, what turned out true.

## D1 — tests/odin_backend.nim needs artifacts nothing generates (T1)
Assumed the test suite was self-contained. It is not: `odin_backend.nim`
checks `examples/*.odin`, but nothing in the repo emits them and they are not
committed (build artifacts). Result was 35 "missing emitted Odin" + 12
cascading "no binary to run" = 47 phantom failures on a clean tree.
Fix: `run-all-tests.sh` emits them in a prep step before running tests.
After the prep step, odin_backend passes fully.

## D2 — cli_smoke.sh aborts early, hiding the rest of the suite (T1)
`cli_smoke.sh` runs under `set -e` and `exit 1`s at the first failure. It was
failing at line 179, so roughly 400 further lines of smoke checks never ran at
all. A single reported failure there means "1 known failure + everything after
it unverified", not "1 failure". Worth splitting into per-case reporting later
if the suite is to be a real gate; NOT done here (out of scope, would change
test conventions mid-refactor).

## D3 — err-match is genuinely broken: mangled vs unmangled error ids (pre-existing)
Baseline failure `err-match branch wrong exit 0, want 42` is a real compiler
bug, not harness noise. Emitted Nim constructs the error with the MANGLED enum
name but matches with the UNMANGLED one:
  construct (codegen.nim:561): errCode("t/tuck_ParseError.Empty")
  match arm (codegen.nim:838): errCode("t/ParseError.Empty")
Never equal -> every arm falls through `else: discard` -> main returns -> exit 0.
Root cause: `errNameFor` (codegen.nim:192) namespaces whatever `enumName` it is
given; the construction path passes an already-mangled name (`v.fieldName`),
the match path passes the raw AST name. One helper, two callers, disagreeing
inputs.
NOT fixed here: this is a behavior change, and the plan forbids mixing behavior
changes into a structural refactor. Recorded as the one known-red item in the
baseline. NOTE: `errNameFor` is one of the byte-identical helpers T2 extracts
into codegen_common.nim — T2 must preserve current behavior exactly (bug and
all), and the fix becomes a clean one-line follow-up afterwards.
