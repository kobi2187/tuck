#!/bin/bash
# The INNER-LOOP gate: does the tree still build and typecheck?
#
# Runs only the check-only suites — no `tuck build`, so no Nim compile-and-link,
# which is what the full suite spends nearly all its time on: a `tuck build` is
# ~1.05s against ~5ms for a `tuck ch`.
#
# What it does NOT cover: anything asserting a program's exit code or its
# runtime output, and the Odin `odin build` layer. Run ./run-all-tests.sh
# before committing.
set -eu
cd "$(dirname "$0")"

nim c --hints:off --warnings:off -o:tests/run tests/runner.nim
exec ./tests/run --quick "$@"
