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
# mutation site: `..` on an invariant-carrying var validates after the chain
cat > "$inv/mut.tuck" <<'EOF'
type Temperature:
  celsius: int
  invariant:
    celsius >= -273

fn main() -> void:
  var t = {celsius: 0} Temperature
  t ..celsius {-400}
  return
EOF
./tuck build "$inv/mut.tuck" -o:"$inv/out3" > /dev/null
if "$inv/out3/mut" 2>/dev/null; then
  echo "FAIL: invariant violation at mutation did not abort"; exit 1
fi
"$inv/out3/mut" 2>&1 | grep -q "Invariant violated" || { echo "FAIL: no invariant message at mutation"; exit 1; }
# !T-wrapped return: the payload validates before tok() wraps it
cat > "$inv/wrap.tuck" <<'EOF'
type Temperature:
  celsius: int
  invariant:
    celsius >= -273

fn read() -> !Temperature [io]:
  return {celsius: -400} Temperature

fn main() -> void [io]:
  let r = {} read
  return
EOF
./tuck build "$inv/wrap.tuck" -o:"$inv/out4" > /dev/null
if "$inv/out4/wrap" 2>/dev/null; then
  echo "FAIL: invariant violation inside !T return did not abort"; exit 1
fi
"$inv/out4/wrap" 2>&1 | grep -q "Invariant violated" || { echo "FAIL: no invariant message in !T return"; exit 1; }
# extern boundary: a call to an extern fn returning an invariant-carrying
# type validates at the call site (emission check — no rt impl to run)
cat > "$inv/ext.tuck" <<'EOF'
type Temperature:
  celsius: int
  invariant:
    celsius >= -273

extern:
  fn readSensor({pin: int}) -> Temperature

fn main() -> void:
  let t = {pin: 3} readSensor
  return
EOF
./tuck compile "$inv/ext.tuck" -o:"$inv/out5" > /dev/null
grep -q "validate(" "$inv/out5/ext.nim" || { echo "FAIL: extern call site not validated"; exit 1; }
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

# `..` chain as the fn's tail: mutate, then return the base var
cht="tests/.smoke_chaintail"
rm -rf "$cht" && mkdir -p "$cht"
cat > "$cht/t.tuck" <<'EOF'
import sys

type Counter:
  n: int

fn bump({self: Counter}) -> Counter:
  self ..n {41}

fn main() -> void [io]:
  var c = {n: 0} Counter
  c ..bump ..n {42}
  c.n sys::exit
EOF
./tuck build "$cht/t.tuck" -o:"$cht/out" > /dev/null
rc=0; "$cht/out/t" || rc=$?
[ "$rc" -eq 42 ] || { echo "FAIL: chain-tail program exit $rc, want 42"; exit 1; }
rm -rf "$cht"

# match over r.err: arms compile to hashed code constants, branch correctly
em="tests/.smoke_errmatch"
rm -rf "$em" && mkdir -p "$em"
cat > "$em/t.tuck" <<'EOF'
import sys

type ParseError:
  | Empty
  | TooLong

fn parseTitle({raw: str}) -> !str [io, error: ParseError]:
  if raw == "":
    err Empty
  return raw

fn main() -> void [io]:
  let r = {raw: ""} parseTitle
  if r.ok:
    0 sys::exit
  match r.err:
    Empty: 42 sys::exit
    TooLong: 7 sys::exit
EOF
./tuck build "$em/t.tuck" -o:"$em/out" > /dev/null
rc=0; "$em/out/t" || rc=$?
[ "$rc" -eq 42 ] || { echo "FAIL: err-match branch wrong exit $rc, want 42"; exit 1; }
rm -rf "$em"

# toStr + string concat + list literals + for loops (tour gaps 1-3)
tg="tests/.smoke_tour123"
rm -rf "$tg" && mkdir -p "$tg"
cat > "$tg/t.tuck" <<'TUCKEOF'
import io
import str
import sys

type Episode:
  minutes: int

fn main() -> void [io]:
  let name = "tuck"
  {text: "hello, " + name} io::printLine
  let n = 42
  {text: n.toStr} io::printLine
  let eps = [{minutes: 10} Episode, {minutes: 32} Episode]
  var total = 0
  for e in eps:
    total = total + e.minutes
  total sys::exit
TUCKEOF
./tuck build "$tg/t.tuck" -o:"$tg/out" > /dev/null
out=$("$tg/out/t"; true)
rc=0; "$tg/out/t" > /dev/null || rc=$?
echo "$out" | grep -q "hello, tuck" || { echo "FAIL: concat output"; exit 1; }
echo "$out" | grep -q "^42$" || { echo "FAIL: toStr output"; exit 1; }
[ "$rc" -eq 42 ] || { echo "FAIL: list/for sum exit $rc, want 42"; exit 1; }
rm -rf "$tg"

# unhandled report names the error via the reverse table (debug builds)
en="tests/.smoke_errname"
rm -rf "$en" && mkdir -p "$en"
cat > "$en/t.tuck" <<'TUCKEOF'
errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    ...

type ParseError:
  | Empty

fn parseTitle({raw: str}) -> !str [io, error: ParseError]:
  if raw == "":
    err Empty
  return raw

fn main() -> void [io]:
  {raw: ""} parseTitle
  return
TUCKEOF
./tuck build "$en/t.tuck" -o:"$en/out" > /dev/null
"$en/out/t" 2>&1 | grep -q "TUCK ERROR NAME: t/ParseError.Empty" || { echo "FAIL: unhandled report missing error name"; exit 1; }
rm -rf "$en"

# top-level statements are declarations-only violations; library builds
lib="tests/.smoke_lib"
rm -rf "$lib" && mkdir -p "$lib"
printf 'fn f({a: int}) -> int:\n  return a\n\nlet x = {a: 1} f\n' > "$lib/bad.tuck"
if ./tuck ch "$lib/bad.tuck" 2>/dev/null; then
  echo "FAIL: top-level statement accepted"; exit 1
fi
./tuck ch "$lib/bad.tuck" 2>&1 | grep -q "top-level statements" || { echo "FAIL: wrong top-level error"; exit 1; }
printf 'fn helper({a: int}) -> int:\n  return a\n' > "$lib/libmod.tuck"
./tuck build "$lib/libmod.tuck" -o:"$lib/out" | grep -q "library (no fn main)" || { echo "FAIL: library build message missing"; exit 1; }
test -f "$lib/out/libmod.nim" || { echo "FAIL: library did not emit Nim"; exit 1; }
test ! -f "$lib/out/libmod" || { echo "FAIL: library build produced a binary"; exit 1; }
rm -rf "$lib"

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
# control flow: loop/break, for-cond, continue, ranges, indexed for, fn inline
cf="tests/.smoke_ctrlflow"
rm -rf "$cf" && mkdir -p "$cf"
cat > "$cf/cf.tuck" <<'TUCKEOF'
fn inline bump({x: int}) -> int:
  return x + 1

fn main() -> int:
  var acc = 0
  loop:
    acc += 1
    if acc == 5:
      break
  for acc > 3:
    acc -= 1
  for i in 0 ..< 4:
    if i == 2:
      continue
    acc += i
  for i in 1 .. 3:
    acc += i
  let xs = [10, 20, 30]
  for idx, item in xs:
    acc += idx
  return bump {x: acc}
TUCKEOF
./tuck build "$cf/cf.tuck" -o:"$cf/out" > /dev/null
rc=0; "$cf/out/cf" || rc=$?
[ "$rc" -eq 17 ] || { echo "FAIL: control-flow exit code $rc != 17"; exit 1; }
grep -q "{.inline.}" "$cf/out/cf.nim" || { echo "FAIL: fn inline lost {.inline.}"; exit 1; }
rm -rf "$cf"

echo "cli smoke OK"
