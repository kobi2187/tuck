#!/bin/bash
# Smoke test for the tuck CLI: builds it, runs every command, checks fail-fast.
set -e
cd "$(dirname "$0")/.."

nim c --hints:off --warnings:off -o:tuck tuck.nim

./tuck l  examples/07-comments.tuck  > /dev/null
./tuck p  examples/07-comments.tuck  > /dev/null
./tuck ch examples/01-data-flow.tuck > /dev/null
out=$(mktemp -d)
./tuck c  examples/07-comments.tuck -o:"$out" > /dev/null
test -f "$out/07-comments.nim"

# fail-fast: type error must exit nonzero with file:line:col
bad="$out/bad.tuck"
printf 'fn f({a: int}) -> int:\n  return "nope"\n' > "$bad"
if ./tuck ch "$bad" 2>/dev/null; then
  echo "FAIL: expected nonzero exit on type error"; exit 1
fi
./tuck ch "$bad" 2>&1 | grep -q "bad.tuck:2:" || { echo "FAIL: no file:line:col prefix"; exit 1; }

rm -rf "$out"

# invariants: validate() auto-inserted at construction and return sites
inv="tests/.smoke_inv"
rm -rf "$inv" && mkdir -p "$inv"
cat > "$inv/viol.tuck" <<'EOF'
type Temperature:
  celsius: int
  invariant:
    celsius >= -273

fn main() -> void:
  let t = {celsius: -400} Temperature
  return
EOF
./tuck build "$inv/viol.tuck" -o:"$inv/out" > /dev/null
if "$inv/out/viol" 2>/dev/null; then
  echo "FAIL: invariant violation at construction did not abort"; exit 1
fi
"$inv/out/viol" 2>&1 | grep -q "Invariant violated" || { echo "FAIL: no invariant message"; exit 1; }
cat > "$inv/ok.tuck" <<'EOF'
type Temperature:
  celsius: int
  invariant:
    celsius >= -273

fn freeze() -> Temperature:
  return {celsius: 0} Temperature

fn main() -> void:
  let t = {} freeze
  return
EOF
./tuck build "$inv/ok.tuck" -o:"$inv/out2" > /dev/null
"$inv/out2/ok" || { echo "FAIL: valid invariant program aborted"; exit 1; }
rm -rf "$inv"

# type-directed lowering: record var as whole payload explodes to params
tdl="tests/.smoke_tdl"
rm -rf "$tdl" && mkdir -p "$tdl"
cat > "$tdl/p.tuck" <<'EOF'
type Player = {position: int, step: int}

fn advance({position: int, step: int}) -> int:
  return position + step

fn main() -> void:
  let p = {position: 10, step: 5} Player
  let n = p advance
  return
EOF
./tuck build "$tdl/p.tuck" -o:"$tdl/out" > /dev/null
grep -q "advance(p.position, p.step)" "$tdl/out/p.nim" || { echo "FAIL: record var not exploded"; exit 1; }
"$tdl/out/p" || { echo "FAIL: exploded program did not run"; exit 1; }
rm -rf "$tdl"

# tuck build --beef: scaffolds a Beef project and builds it with BeefBuild
# when a toolchain is present; always emits the .bf source either way.
bf="tests/.smoke_beef"
rm -rf "$bf" && mkdir -p "$bf"
cat > "$bf/hi.tuck" <<'EOF'
fn main() -> void:
  return
EOF
./tuck build "$bf/hi.tuck" --beef -o:"$bf/out" > /dev/null
test -f "$bf/out/hi.bf" || { echo "FAIL: no .bf source emitted"; exit 1; }
BEEF_BUILD_BIN="${BEEFBUILD_BIN:-}"
[ -z "$BEEF_BUILD_BIN" ] && command -v BeefBuild >/dev/null 2>&1 && BEEF_BUILD_BIN=$(command -v BeefBuild)
[ -z "$BEEF_BUILD_BIN" ] && [ -f /opt/beef/IDE/dist/BeefBuild ] && BEEF_BUILD_BIN=/opt/beef/IDE/dist/BeefBuild
if [ -n "$BEEF_BUILD_BIN" ]; then
  test -x "$bf/out/hi_beef" || { echo "FAIL: no Beef binary built"; exit 1; }
  "$bf/out/hi_beef" || { echo "FAIL: Beef binary did not run"; exit 1; }
else
  echo "SKIP Beef build check: BeefBuild not found (set BEEFBUILD_BIN)"
fi
rm -rf "$bf"
echo "cli smoke OK"
