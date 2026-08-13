#!/bin/bash
# The pre-commit gate. Builds tuck, emits the examples' Odin, runs every suite.
#
# A wrapper: the suite itself is tests/runner.nim, and the 30 tests/*.sh it
# used to drive are now tests/suites/*.nim. This entry point stays because it
# is what the muscle memory and the docs reach for.
#
# Run one suite:      tests/run loop_var_type
# The inner loop:     ./quick-test.sh   (check-only, no `tuck build`)
# Re-bless goldens:   tests/run --bless
set -eu
cd "$(dirname "$0")"

# tests/run is a script that rebuilds the runner before exec'ing it, so the
# build line lives in exactly one place.
exec ./tests/run "$@"
