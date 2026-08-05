#!/bin/bash
# Every gated example must compile through tuck; the rest may fail.
#
# Replaces tests/compile_all_examples.nim. That one ran the pipeline in-process
# (linking parser + typecheck + codegen into a Nim program), then re-verified
# the emitted Nim with ~25 serial `nim check` calls. Both are gone: `tuck c`
# does the same compile, and the emitted code is gated end-to-end by
# tests/odin_backend.nim and tests/cli_smoke.sh, which COMPILE AND RUN it.
#
# Gated = must compile. Ungated examples reference deliberately-undeclared
# sketch functions (fetch, merge, ...) and are allowed to fail; they are still
# built here so a crash is visible, just not fatal. Move a name into the gated
# list when it goes green.
cd "$(dirname "$0")/.."
. tests/lib.sh

gated="
01-data-flow 02-builder-mutation 03-functions-bake 04-sum-types-interface
05-actors-effects 06-transitions-example 07-comments 08-actors_isolated_state
09-decision-table 10-invariants 11-embedded-feature
12-transition-the-ctor-exception 13-arena-mem 14-task 15-type-attributes
17-input-merge 18-alias 19-event-registry 20-embedded-mp3-player
21-decision-bitmask 22-error-policy
23-units 24-stdlib 25-pools 26-actor-run 27-actor-select 28-async-task
29-task-timeout 30-async-read 31-fnsig-callback 32-duration-units
33-ffi-zlib 34-ffi-cstring 35-ffi-struct 36-ffi-enum-callback
38-division 39-if-match-expr 40-saturating 41-tostr-concat 42-net-echo
http
"

# NOT gated, and why:
#   16-actor-tasks-unified-syntax — genuinely broken: dotted select sources
#     (`resp.ok`, `timeout.5s`) parse as opaque strings. See MISSING-FEATURES.
#   37-ffi-handle — compiles only with the examples dir as --root, because its
#     `lib: "cffi/point.c"` is relative to that. It IS compile- and run-gated
#     in odin_backend.sh, which sets that up.
#
# Everything else above was ungated purely by drift: 15 examples compiled fine
# and nothing here would have noticed them breaking. Several were run-gated in
# odin_backend.sh while invisible to this file, so a Nim-side regression was
# silent. Add a name here the moment it goes green.

out=$(mktemp -d)
trap 'rm -rf "$out" "$_dir"' EXIT

is_gated() { case " $(echo $gated) " in *" $1 "*) return 0;; *) return 1;; esac; }

for f in examples/*.tuck; do
  name=$(basename "$f" .tuck)
  if ./tuck c "$f" -o:"$out/$name" --root:"$(pwd)" > "$out/$name.log" 2>&1; then
    is_gated "$name" && _ok "compile $name"
  elif is_gated "$name"; then
    _no "compile $name" "gated regression: $(tail -1 "$out/$name.log")"
  else
    printf '  skip  %s (not gated) — %s\n' "$name" "$(tail -1 "$out/$name.log")"
  fi
done

finish
