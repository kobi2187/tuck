#!/bin/bash
# Replay the fuzz corpus: every saved input must be handled, not crash.
#
# The corpus in fuzz/corpus/ is what a libFuzzer run discovered — inputs that
# reached new code paths in the lexer and parser. Most are malformed. The
# contract is not that they parse, it is that each one produces a DIAGNOSTIC
# rather than taking the compiler down.
#
# This is the cheap half of fuzzing: no libFuzzer, no sanitizers, no mutation
# — just the inputs a real run already found, replayed in a second. It catches
# the regression where a refactor reintroduces a crash on input that used to
# be handled cleanly.
#
# To grow the corpus, run the fuzzer (see fuzz/README.md) and commit whatever
# new inputs it saves.
set -u
cd "$(dirname "$0")/.."

pass=0
fail=0
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

for f in fuzz/corpus/* fuzz/findings/*; do
  [ -f "$f" ] || continue
  # `parse` rather than `check`: the corpus targets the FRONT END, and a
  # malformed file has nothing for the typechecker to say anyway.
  # Output goes through a file rather than $(...): fuzz inputs contain NUL
  # bytes, and command substitution drops them with a warning per input.
  ./tuck parse "$f" > "$tmp" 2>&1
  rc=$?
  out=$(tr -d '\0' < "$tmp")
  # Exit 0 (parsed) and exit 1 (rejected with a diagnostic) are both correct.
  # Anything else — a signal, an unhandled Nim exception — is the failure.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
    echo "  FAIL  $f exited $rc"
    echo "$out" | head -3 | sed 's/^/        /'
    fail=$((fail + 1))
  elif printf '%s' "$out" | grep -q "Error: unhandled exception\|SIGSEGV\|Traceback"; then
    echo "  FAIL  $f crashed rather than reporting"
    echo "$out" | head -3 | sed 's/^/        /'
    fail=$((fail + 1))
  else
    pass=$((pass + 1))
  fi
done

printf 'fuzz_corpus.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
