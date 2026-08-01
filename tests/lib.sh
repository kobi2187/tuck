# tests/lib.sh — assertions for tuck-driven tests.
#
# Every test here drives the ./tuck BINARY. Nothing imports the compiler as a
# Nim library, which is what the old tests/*.nim did: each of those linked
# compiler/codegen + typecheck + parser, so `nim c` re-ran semantic analysis
# over the whole compiler once per test file. Ten builds of the compiler to
# run nine tests. Now nim builds tuck once, and tuck does the rest.
#
# Usage: source this, call the assertions, end with `finish`.
#
#   src <<'EOF' ... EOF     write a .tuck file into this test's scratch dir
#   ok_check NAME           `tuck ch` must succeed
#   bad_check NAME PATTERN  `tuck ch` must fail, message matching PATTERN
#   runs NAME CODE          build and run; exit code must equal CODE
#   emits NAME PATTERN      emitted Nim must contain PATTERN
#   omits NAME PATTERN      emitted Nim must NOT contain PATTERN
#   outputs NAME PATTERN    program stdout/stderr must match PATTERN
#
# NAME labels the case in the report; each call re-uses the file written by
# the preceding `src`.
set -u

TUCK=${TUCK:-./tuck}
_pass=0
_fail=0
_dir=$(mktemp -d)
_cur=""
trap 'rm -rf "$_dir"' EXIT

# _quiet=1 makes the assertions RECORD their outcome in $_lastok without
# reporting it — that is how bug_fixed/bug_open re-interpret an assertion
# whose failure is sometimes the expected result.
_quiet=0
_lastok=1

_ok() {
  _lastok=1
  [ "$_quiet" = "1" ] && return 0
  _pass=$((_pass + 1)); printf '  PASS  %s\n' "$1"
}
_no() {
  _lastok=0
  [ "$_quiet" = "1" ] && return 0
  _fail=$((_fail + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"
}

# Run an assertion for its OUTCOME only: `try runs "x" 2` then bug_fixed/bug_open.
try() { _quiet=1; "$@"; _quiet=0; }

_n=0
src() {
  # Reads the .tuck source on stdin. Each snippet gets its own directory so a
  # stale artifact from a previous case can never satisfy this one.
  #
  # Counted with its OWN counter, not pass+fail: assertions run under `try`
  # deliberately do not touch those, so deriving the directory from them made
  # consecutive cases collide — one case's binary answering another's `runs`.
  _n=$((_n + 1))
  _cur="$_dir/t$_n"
  mkdir -p "$_cur"
  cat > "$_cur/t.tuck"
}

_build() {
  # Compile to Nim AND link, since `runs` needs a binary. Output and exit
  # status are captured for the caller to inspect.
  "$TUCK" build "$_cur/t.tuck" -o:"$_cur/out" --root:"$(pwd)" > "$_cur/build.log" 2>&1
}

ok_check() {
  if "$TUCK" ch "$_cur/t.tuck" --root:"$(pwd)" > "$_cur/check.log" 2>&1; then
    _ok "$1"
  else
    _no "$1" "expected a clean check, got: $(tail -1 "$_cur/check.log")"
  fi
}

bad_check() {
  if "$TUCK" ch "$_cur/t.tuck" --root:"$(pwd)" > "$_cur/check.log" 2>&1; then
    _no "$1" "expected a type error, but the check passed"
  elif grep -qE "$2" "$_cur/check.log"; then
    _ok "$1"
  else
    _no "$1" "wrong error; wanted /$2/, got: $(tail -1 "$_cur/check.log")"
  fi
}

runs() {
  if ! _build; then
    _no "$1" "build failed: $(tail -2 "$_cur/build.log")"
    return
  fi
  local rc=0
  "$_cur/out/t" > "$_cur/run.log" 2>&1 || rc=$?
  if [ "$rc" -eq "$2" ]; then _ok "$1"; else
    _no "$1" "exit $rc, want $2: $(tail -1 "$_cur/run.log")"
  fi
}

outputs() {
  if grep -qE "$2" "$_cur/run.log" 2>/dev/null; then _ok "$1"; else
    _no "$1" "output did not match /$2/: $(tail -1 "$_cur/run.log" 2>/dev/null)"
  fi
}

_emitted() {
  # `tuck c` stops at Nim source — no linking, so this is the cheap path for
  # tests that only care about what was emitted.
  "$TUCK" c "$_cur/t.tuck" -o:"$_cur/out" --root:"$(pwd)" > "$_cur/emit.log" 2>&1 \
    && cat "$_cur/out/t.nim"
}

emits() {
  if _emitted | grep -qE "$2"; then _ok "$1"; else
    _no "$1" "emitted Nim lacks /$2/"
  fi
}

omits() {
  if _emitted | grep -qE "$2"; then
    _no "$1" "emitted Nim contains /$2/ but should not"
  else _ok "$1"; fi
}

# --- known-bug tri-state -----------------------------------------------
#
# A bug entry states the CORRECT behaviour as a real assertion, plus whether
# the compiler does that yet:
#
#   bug_fixed NAME     — assertion must hold. If it breaks, it REGRESSED.
#   bug_open  NAME     — assertion is expected to fail. If it starts passing,
#                        the suite fails and tells you to flip it to
#                        bug_fixed, which is how a fix gets locked in.
#
# Both read the outcome of the assertion that ran just before them, so:
#   runs "x" 2 ; bug_fixed "x"
# Nothing is ever deleted, so a bug that returns is caught by the test
# written when it was first found.
_open=0

_last_ok() { [ "$_lastok" = "1" ]; }

bug_fixed() {
  if _last_ok; then _ok "$1 (regression guard)"; else
    _no "$1" "REGRESSED — this was fixed and has come back"; fi
}

bug_open() {
  if _last_ok; then
    _no "$1" "NOW PASSING — that is GOOD. Change bug_open to bug_fixed to lock it in."
  else
    _open=$((_open + 1)); printf '  OPEN  %s (known bug, still reproduces)\n' "$1"
  fi
}

emits_odin() {
  # Same as `emits`, against the Odin backend's output.
  if "$TUCK" c "$_cur/t.tuck" --odin -o:"$_cur/odin" --root:"$(pwd)" > "$_cur/odin.log" 2>&1 \
     && grep -qE "$2" "$_cur/odin/t.odin" 2>/dev/null; then _ok "$1"; else
    _no "$1" "emitted Odin lacks /$2/"; fi
}

finish() {
  [ "$_open" -eq 0 ] || printf 'open bugs: %d\n' "$_open"
  printf '%s: %d passed, %d failed\n' "${0##*/}" "$_pass" "$_fail"
  [ "$_fail" -eq 0 ] || exit 1
}
