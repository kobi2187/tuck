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

## D5 — err-match fix must strip the prefix, NOT apply it (attempt 1 failed)
First attempt canonicalized by MANGLING the match-arm name
(canonicalEnumName = mangleName(enumName)) so both sites hashed
"t/tuck_ParseError.Empty". err-match then correctly exited 42 — but it broke
cli_smoke.sh's unhandled-error-report check, which prints the error NAME to the
user: got "TUCK ERROR NAME: t/tuck_ParseError.Empty", want "t/ParseError.Empty".
Mangling leaked into user-facing output.
Lesson: error ids are a cross-module IDENTITY concern; `tuck_` is a backend
name-collision concern. They must not mix. The correct fix canonicalizes the
OTHER direction — strip the prefix so ids hash the SOURCE name — which fixes
err-match and keeps the report output clean.
Process lesson: verifying only the case named in the bug report (exit 42) missed
a sibling consumer of the same string. Grep every reader of an id before
changing how it is built.

Attempt 2 (strip the prefix instead of applying it) passed all three paths —
err-match exit 42, ids in source form, report printing the clean name — but is
still string surgery: it guesses at a fact from spelling and needs a
codegen_common -> mangle import to know the prefix.

RIGHT FIX (user's, adopted): every node stores its PRE-MANGLED name. The mangle
pass knows the original at the moment it renames and currently throws it away;
recording it turns a derived-by-convention guess into stored data.
  - `sourceName` field on the common section of Type / Expr / Decl in ast.nim
  - set at mangle.nim's 4 rename sites (87 tkNamed, 122 exkVar, 304 decls,
    307 mixin members)
  - errNameFor reads sourceName; no prefix logic, no mangle import
Kills the whole bug class: ANY consumer wanting the user-facing name (error
ids, diagnostics, reports) reads the same field instead of re-deriving it, and
it no longer depends on which pass has run.

## D6 — mangling is about EMITTED IDENTIFIERS only (the real err-match fix)
Both earlier attempts missed the point. Mangling exists so an emitted name
cannot collide with a symbol in the target language (`tuck_Feed` so we never
bind Nim's own `Feed`). It is a property of GENERATED CODE.
An error id is not generated code: errCode() folds the string to a uint16 at
compile time (tuck_rt.nim:98) and tuckErrName prints it back to the user. It
never becomes an identifier, so it never had a collision problem — mangling it
was meaningless from the start.
So the bug was never "the two sites disagree about the prefix"; it was that a
MANGLED name was fed into the id at all. Fix: nodes record `sourceName` at the
moment mangle renames them, and the three id-building sites ask for the written
name (`writtenName`) instead of the emitted one.
Verified: ids agree in source form (t/ParseError.Empty), err-match exits 42,
the report prints the clean name, AND emitted identifiers stay mangled
(tuck_ParseError, tuck_main) — the two concerns are now separate.

## D7 — cli_smoke.sh's abort-on-first-failure was hiding a QUEUE of bugs
Predicted in D2, confirmed three times over. Fixing err-match did not make the
suite green; it advanced the abort point to the next latent failure, twice:
  1. `no .bf source emitted` — the Beef backend was deleted in 7c84d1f but its
     --beef check stayed in cli_smoke.sh. Dead test for a removed feature,
     unreachable until now. Deleted.
  2. `duration-units exit 1` — see D8 for the real diagnosis. CONFIRMED
     PRE-EXISTING: reproduces identically with all refactor changes stashed.
     Still open, NOT introduced here.
Duration-units is the last check in the file, so the queue is now exhausted.
Lesson: a `set -e` script that exits on first failure reports "1 failure" when
it means "1 failure plus everything after it unverified". Per-check reporting
would have surfaced all three on day one.

## D8 — postfix application is dropped on LITERALS (silent wrong answer)
My first diagnosis ("5.ms fails to lower across a module boundary") was wrong
on both counts — not cross-module, not about the record literal it appears in.
Minimal reproduction, one module, no imports but sys:

  fn addTen(value: int) -> int:
    return value + 10
  let y = 5.addTen     -> emits `var y = 5`,            exits 5   WRONG
  let n = 5
  let y = n.addTen     -> emits `var y = tuck_addTen(n)`, exits 15  right

So postfix application works on a VARIABLE receiver and is silently dropped on
a LITERAL receiver. Independent of payload style: bare `(value: int)` (the form
std/time's `ms` uses), `{value: int}`, and `{n: int}` all behave the same.

Severity is higher than the smoke failure suggests. `{d: 5.ms}` fails LOUDLY
only because Milliseconds is a distinct type, so Nim rejects the bare int. With
a plain int receiver nothing type-checks against it and the program just
computes the wrong number — `5.addTen` is 5, not 15, with no diagnostic.

ROOT CAUSE: codegen (both backends) special-cased a numeric-literal receiver
BEFORE consulting semLayer.hasCall, and gated it on `isKnownFn(e.fieldName)`.
By codegen time decls are mangled (tuck_addTen) while fieldName is the source
name (addTen), so findFn always missed, isKnownFn returned false, and the
`else` emitted just the receiver — dropping the call. Same mangled-vs-source
mismatch as the err-match bug (D6), in a second place.

FIX: delete the special case so a literal receiver takes the same
semLayer.hasCall path a variable receiver already took (the checker stamps a
real call node for both — typecheck.nim:213), and delete isKnownFn, now dead.

BUT the deleted branch was also load-bearing for a case the checker CANNOT
resolve: 01-data-flow.tuck is a walking skeleton with `timeout: 5.ms` and no
`import time`, so `ms` is undeclared, nothing gets stamped, and the fallthrough
emitted literal Nim `5.ms` — invalid, since a number has no fields. Restored as
a fallback AFTER the hasCall check (not before it), so it only catches what the
checker could not resolve. A declared helper never reaches it.
Verified: 5.addTen -> tuck_addTen(5) exits 15; duration-units exits 42;
01-data-flow still passes nim check; full suite GREEN on both backends.

## D4 — dkMixin overload scoped: 24 sites, 9 files, 0 tests (T4)
Two parser sites CREATE the tagged nodes:
  parser.nim:798  Decl(kind: dkMixin, name: "extern", ...)
  parser.nim:867  Decl(kind: dkMixin, name: "pending", ...)
Consumers then re-derive intent by string-comparing d.name at
ast_query.nim:49, semantics.nim:160, tuck.nim:243, and both codegens
(codegen.nim:1562, codegen_odin.nim:1847 comment the workaround explicitly).
A user-declared mixin actually named `extern` would be silently misclassified —
same failure class the exkSelect fix removed.
Blast radius: 24 references across 9 files, but ZERO in tests/ — the construct
is verified only through behavior, so the node-kind change is internal and the
existing suite is a valid gate.
Sequencing: two of the 9 files are codegen.nim/codegen_odin.nim, which T2 is
editing. T4 must land after T2 to avoid a conflict.
