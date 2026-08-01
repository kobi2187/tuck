#!/bin/bash
# End-to-end guard for the Odin backend: every gated example must compile
# with `odin build`, and the ones with a known answer must RUN and produce it.
#
# The run layer is the point. 26-actor-run compiled cleanly for a whole
# session while hanging forever at runtime (actors are daemons, so driving
# the scheduler for them never terminates) — a compile-only check called
# that a pass. Exit codes catch it.
#
# Skips with a notice when Odin is absent, unless TUCK_REQUIRE_ODIN=1, so
# CI can insist the check actually ran rather than silently vanishing.
#
# Was a Nim program, but imported nothing from the compiler — it only copied
# files and shelled out to `odin build`. So it paid a full compiler rebuild
# to run subprocesses a shell runs natively.
cd "$(dirname "$0")/.."
. tests/lib.sh

exampleDir=examples
outDir=tests/odin_out
rtDir=compiler/tuckrt

# Examples whose emitted Odin must compile. Add one when it goes green so a
# regression is a failure rather than a silent skip.
odin_compile="
01-data-flow 02-builder-mutation 03-functions-bake 04-sum-types-interface
05-actors-effects 06-transitions-example 07-comments 08-actors_isolated_state
09-decision-table 10-invariants 11-embedded-feature
12-transition-the-ctor-exception 13-arena-mem 15-type-attributes 17-input-merge
18-alias 19-event-registry 21-decision-bitmask 22-error-policy 23-units
24-stdlib 25-pools 26-actor-run 31-fnsig-callback 32-duration-units
33-ffi-zlib 34-ffi-cstring 35-ffi-struct 36-ffi-enum-callback 37-ffi-handle
28-async-task 38-division 39-if-match-expr 40-saturating 41-tostr-concat
"

# Examples with a known exit code: these must RUN, not merely compile.
#   26-actor-run     55  1+..+10 drained through the actor mailbox
#   31-fnsig-callback 42 40 + 2 through a baked callback slot
#   33-ffi-zlib       0  real libz reached: compressBound(1000) == 1013
#   34-ffi-cstring    0  libz's version via a real char*, compressBound right
#   35-ffi-struct     0  C struct by value both ways, asserted in-program
#   36-ffi-enum-callback 0  C enum with explicit values + a callback C invokes
#   37-ffi-handle     0  opaque handle: C mallocs, derefs and frees it
#   28-async-task    42  Odin coroutine runtime over minicoro really runs
#   38-division       0  R1: /i truncates, /f does not — both backends agree
#   39-if-match-expr  0  R2/R3: value-position if and match agree
#   40-saturating     0  [saturating] must CLAMP (a miss returns 4464)
#   41-tostr-concat   0  postfix application + unqualified call + concat
odin_run="26-actor-run:55 31-fnsig-callback:42 33-ffi-zlib:0 34-ffi-cstring:0
35-ffi-struct:0 36-ffi-enum-callback:0 37-ffi-handle:0 28-async-task:42
38-division:0 39-if-match-expr:0 40-saturating:0 41-tostr-concat:0"

odin_exe=$(command -v odin || true)
for c in /home/kl/apps/Odin/odin /opt/odin/odin; do
  [ -n "$odin_exe" ] && break
  [ -x "$c" ] && odin_exe=$c
done
if [ -z "$odin_exe" ]; then
  if [ "${TUCK_REQUIRE_ODIN:-}" = "1" ]; then
    echo "FAIL: odin not found and TUCK_REQUIRE_ODIN=1"; exit 1
  fi
  echo "SKIP Odin backend check: odin not found (set TUCK_REQUIRE_ODIN=1 to require it)."
  echo "odin_backend.sh: 0 passed, 0 failed"
  exit 0
fi
echo "Odin backend check with: $odin_exe"

mkdir -p "$outDir"

build_one() {
  # Assemble a self-contained Odin package: the emitted main.odin, the Tuck
  # runtime, any imported Tuck modules, and the C fixtures an FFI example
  # binds against. The emitted `foreign import` path is relative to the
  # package, so the objects must sit at the same relative spot inside the copy.
  local base=$1 proj="$outDir/${1//-/_}"
  rm -rf "$proj"; mkdir -p "$proj/tuckrt"
  cp "$exampleDir/$base.odin" "$proj/main.odin"
  cp "$rtDir"/*.odin "$proj/tuckrt/" 2>/dev/null
  [ -f "$rtDir/minicoro.a" ] && cp "$rtDir/minicoro.a" "$proj/tuckrt/"
  if [ -d "$exampleDir/cffi" ]; then
    mkdir -p "$proj/cffi"
    for f in "$exampleDir"/cffi/*.c; do
      [ -e "$f" ] || continue
      cc -c -fPIC "$f" -o "$proj/cffi/$(basename "${f%.c}").o" 2>/dev/null
    done
  fi
  for modDir in "$exampleDir"/mod_*; do
    [ -d "$modDir" ] || continue
    mkdir -p "$proj/$(basename "$modDir")"
    cp "$modDir"/*.odin "$proj/$(basename "$modDir")/" 2>/dev/null
  done
  "$odin_exe" build "$proj" -o:none -out:"$proj/prog" > "$proj/build.log" 2>&1
}

# Each example builds into its OWN package dir and reads only shared inputs,
# so the 35 `odin build` calls are independent — run them $(nproc) at a time
# and collect verdicts afterwards. Serial, this loop was 11.5s of the suite.
export -f build_one
export odin_exe exampleDir outDir rtDir
# TEST_JOBS is set by run-all-tests.sh, which already runs the test scripts
# concurrently — without it this loop would spawn nproc jobs inside each of
# nproc scripts and thrash. Standalone runs get the full box.
echo "$odin_compile" | tr ' ' '\n' | grep -v '^$' | \
  xargs -P "${TEST_JOBS:-$(nproc)}" -I{} bash -c 'build_one "$1" || true' _ {}

for base in $odin_compile; do
  if [ ! -f "$exampleDir/$base.odin" ]; then
    _no "compile $base" "missing emitted Odin (run \`tuck c examples/$base.tuck --odin\` first)"
  elif [ -x "$outDir/${base//-/_}/prog" ]; then
    _ok "compile $base"
  else
    _no "compile $base" "$(grep -i error "$outDir/${base//-/_}/build.log" 2>/dev/null | head -3)"
  fi
done

for entry in $odin_run; do
  base=${entry%:*}; want=${entry#*:}
  prog="$outDir/${base//-/_}/prog"
  if [ ! -x "$prog" ]; then
    _no "run $base" "no binary to run"
    continue
  fi
  rc=0; "$prog" > /dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then _ok "run $base -> $rc"; else
    _no "run $base" "exited $rc, expected $want"; fi
done

finish
