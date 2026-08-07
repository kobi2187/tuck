#!/bin/bash
# Smoke test for the tuck CLI: builds it, runs every command, checks fail-fast.
set -e
cd "$(dirname "$0")/.."

# run-all-tests.sh builds tuck in stage 1; build it here only when this script
# is run on its own, so the suite does not pay for a second compiler build.
[ -x ./tuck ] || nim c --hints:off --warnings:off -o:tuck tuck.nim

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

# --- independent cases, run concurrently -------------------------------
#
# Each case below builds and runs its own programs in its own
# tests/.smoke_* directory and shares nothing writable with the others,
# so they overlap. Serially this script was 33s — 30 `tuck build` calls
# at ~0.8s each, and that 0.8s is Nim re-analysing tuck_rt and its async
# chain per invocation, which no amount of test-side work removes.
#
# Each case keeps `exit 1` on failure: inside a function run as a
# background job that exits the SUBSHELL, which `wait` reports as a
# nonzero status, so the failure still propagates.

case_inv() {
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
}

case_tdl() {
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
}

case_chaintail() {
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
}

case_errmatch() {
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
}

case_tour123() {
# toStr + string concat + list literals + for loops (tour gaps 1-3)
tg="tests/.smoke_tour123"
rm -rf "$tg" && mkdir -p "$tg"
cat > "$tg/t.tuck" <<'TUCKEOF'
import console
import str
import sys

type Episode:
  minutes: int

fn main() -> void [io]:
  let name = "tuck"
  {text: "hello, " + name} console::printLine
  let n = 42
  {text: n.toStr} console::printLine
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
}

case_errname() {
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
}

case_lib() {
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

# (the Beef backend was removed in 7c84d1f; its --beef check lived here and
# went with it. It had been unreachable anyway — the err-match check above
# aborted this script long before reaching it.)
}

case_ctrlflow() {
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
}

case_valuetype() {
# records are VALUE types (spec §7.1): == compares fields, not identity,
# and a copy is independent of its source
vt="tests/.smoke_valuetype"
rm -rf "$vt" && mkdir -p "$vt"
cat > "$vt/t.tuck" <<'TUCKEOF'
type Point = {x: int, y: int}

fn shift({p: Point}) -> Point:
  p ..x {99}

fn main() -> int:
  let a = {x: 1, y: 2} Point
  let b = {x: 1, y: 2} Point
  var acc = 0
  if a == b:
    acc += 10
  var c = {x: 1, y: 2} Point
  let d = c
  c ..x {50}
  if d.x == 1:
    acc += 7
  return acc
TUCKEOF
./tuck build "$vt/t.tuck" -o:"$vt/out" > /dev/null
rc=0; "$vt/out/t" || rc=$?
[ "$rc" -eq 17 ] || { echo "FAIL: value-type semantics exit $rc, want 17"; exit 1; }
grep -q "= object" "$vt/out/t.nim" || { echo "FAIL: record emitted as ref object"; exit 1; }
rm -rf "$vt"
}

case_nullary() {
# spec 2.3: a bare name IS a call — a zero-arg fn referenced bare must be
# invoked, not taken as a proc reference (`:name` is the fn-ref form)
nl="tests/.smoke_nullary"
rm -rf "$nl" && mkdir -p "$nl"
cat > "$nl/t.tuck" <<'TUCKEOF'
fn getFive() -> int:
  return 5

fn getSeven() -> int:
  return 7

fn main() -> int:
  let a = getFive
  let b = getSeven {}
  return a + b
TUCKEOF
./tuck build "$nl/t.tuck" -o:"$nl/out" > /dev/null
rc=0; "$nl/out/t" || rc=$?
[ "$rc" -eq 12 ] || { echo "FAIL: nullary call exit $rc, want 12"; exit 1; }
rm -rf "$nl"
}

case_matchret() {
# a trailing `match subject:` IS the fn's result — its value arms carry no
# returns of their own, so the implicit-return rewrite must wrap the match
mr="tests/.smoke_matchret"
rm -rf "$mr" && mkdir -p "$mr"
cat > "$mr/t.tuck" <<'TUCKEOF'
type Light:
  | Red
  | Yellow
  | Green

fn code({t: Light}) -> int:
  match t:
    Red: 3
    Yellow: 5
    Green: 9

fn main() -> int:
  return {t: Light.Green} code
TUCKEOF
./tuck build "$mr/t.tuck" -o:"$mr/out" > /dev/null
rc=0; "$mr/out/t" || rc=$?
[ "$rc" -eq 9 ] || { echo "FAIL: match-as-return exit $rc, want 9"; exit 1; }
rm -rf "$mr"
}

case_seqat() {
# std/seq: indexed read/write as named fns (`at`/`setAt`), not `[]` sugar.
# Bounds are a precondition — out of range aborts at the call site.
sq="tests/.smoke_seqat"
rm -rf "$sq" && mkdir -p "$sq"
cat > "$sq/t.tuck" <<'TUCKEOF'
import seq

fn main() -> int:
  var xs = [10, 20, 30]
  {items: xs, index: 1, value: 5} seq::setAt
  let a = {items: xs, index: 0} seq::at
  let b = {items: xs, index: 1} seq::at
  let c = {items: xs, index: 2} seq::at
  return a + b + c
TUCKEOF
./tuck build "$sq/t.tuck" -o:"$sq/out" > /dev/null
rc=0; "$sq/out/t" || rc=$?
[ "$rc" -eq 45 ] || { echo "FAIL: seq at/setAt exit $rc, want 45"; exit 1; }
cat > "$sq/oob.tuck" <<'TUCKEOF'
import seq

fn main() -> int:
  var xs = [10, 20, 30]
  return {items: xs, index: 7} seq::at
TUCKEOF
./tuck build "$sq/oob.tuck" -o:"$sq/oout" > /dev/null
if "$sq/oout/oob" 2>"$sq/err.txt"; then
  echo "FAIL: out-of-bounds at() did not abort"; exit 1
fi
grep -q "out of bounds for seq of length 3" "$sq/err.txt" || { echo "FAIL: bounds precondition message missing"; exit 1; }
rm -rf "$sq"
}

case_index() {
# bracket sugar: xs[i] reads, xs[i] = v writes, xs[i] += v compounds.
# All desugar to the seq::at / seq::setAt calls above — same bounds
# precondition, no new codegen path.
ix="tests/.smoke_index"
rm -rf "$ix" && mkdir -p "$ix"
cat > "$ix/t.tuck" <<'TUCKEOF'
import seq

fn main() -> int:
  var xs = [10, 20, 30]
  xs[1] = 5
  xs[0] += 5
  return xs[0] + xs[1] + xs[2]
TUCKEOF
./tuck build "$ix/t.tuck" -o:"$ix/out" > /dev/null
rc=0; "$ix/out/t" || rc=$?
[ "$rc" -eq 50 ] || { echo "FAIL: bracket index exit $rc, want 50"; exit 1; }

# the tight-`[` rule must not eat list literals or generic/type brackets
cat > "$ix/amb.tuck" <<'TUCKEOF'
import seq

fn firstOf[T]({items: Seq[T]}) -> T:
  return {items: items, index: 0} seq::at

fn main() -> int:
  let ys = [1, 2, 3]
  var grid = [7, 8, 9]
  let a = {items: ys} firstOf
  return a + grid[2] + ys[1]
TUCKEOF
./tuck build "$ix/amb.tuck" -o:"$ix/aout" > /dev/null
rc=0; "$ix/aout/amb" || rc=$?
[ "$rc" -eq 12 ] || { echo "FAIL: bracket ambiguity exit $rc, want 12"; exit 1; }

# bounds still fire through the sugar
cat > "$ix/oob.tuck" <<'TUCKEOF'
import seq

fn main() -> int:
  var xs = [10, 20, 30]
  return xs[7]
TUCKEOF
./tuck build "$ix/oob.tuck" -o:"$ix/oout" > /dev/null
if "$ix/oout/oob" 2>"$ix/err.txt"; then
  echo "FAIL: out-of-bounds xs[7] did not abort"; exit 1
fi
grep -q "out of bounds for seq of length 3" "$ix/err.txt" || { echo "FAIL: sugar lost the bounds precondition"; exit 1; }

# a non-indexable receiver names the type and the fn to define
cat > "$ix/bad.tuck" <<'TUCKEOF'
fn main() -> int:
  let n = 5
  return n[0]
TUCKEOF
if ./tuck ch "$ix/bad.tuck" 2>/dev/null; then
  echo "FAIL: indexing an int was accepted"; exit 1
fi
./tuck ch "$ix/bad.tuck" 2>&1 | grep -q "not indexable" || { echo "FAIL: wrong non-indexable error"; exit 1; }
rm -rf "$ix"
}

case_pool() {
# spec 7.2 pools: declaration diagnostics, and a real acquire/release cycle.
pl="tests/.smoke_pool"
rm -rf "$pl" && mkdir -p "$pl"

# a pool needs a count — without one it has no static footprint
printf 'pool Bufs = Array[8, u8]\n\nfn main() -> int:\n  return 0\n' > "$pl/nocount.tuck"
if ./tuck ch "$pl/nocount.tuck" 2>/dev/null; then
  echo "FAIL: pool without a count was accepted"; exit 1
fi
./tuck ch "$pl/nocount.tuck" 2>&1 | grep -q "needs a slot count" || { echo "FAIL: wrong no-count error"; exit 1; }

# ... and the count must be a number
printf 'pool Bufs = Array[8, u8] [count: many]\n\nfn main() -> int:\n  return 0\n' > "$pl/badcount.tuck"
if ./tuck ch "$pl/badcount.tuck" 2>/dev/null; then
  echo "FAIL: non-numeric count accepted"; exit 1
fi
./tuck ch "$pl/badcount.tuck" 2>&1 | grep -q "whole number" || { echo "FAIL: wrong bad-count error"; exit 1; }

# a pool declares an element type
printf 'pool Bufs [count: 8]\n\nfn main() -> int:\n  return 0\n' > "$pl/noelem.tuck"
if ./tuck ch "$pl/noelem.tuck" 2>/dev/null; then
  echo "FAIL: pool without an element type accepted"; exit 1
fi
./tuck ch "$pl/noelem.tuck" 2>&1 | grep -q "declares its element type" || { echo "FAIL: wrong no-element error"; exit 1; }

# runtime: acquire to exhaustion, release, acquire again
cat > "$pl/t.tuck" <<'TUCKEOF'
type Slot:
  id: int

pool Slots = Slot [count: 2]

fn main() -> int:
  let a = Slots.acquire
  let b = Slots.acquire
  if not a.ok:
    return 91
  if not b.ok:
    return 92
  let c = Slots.acquire        # pool of 2 is exhausted
  if c.ok:
    return 93
  Slots.release {a.value}      # give one back
  let d = Slots.acquire        # ... so this must succeed
  if not d.ok:
    return 94
  return 42
TUCKEOF
./tuck build "$pl/t.tuck" -o:"$pl/out" > /dev/null
rc=0; "$pl/out/t" || rc=$?
[ "$rc" -eq 42 ] || { echo "FAIL: pool acquire/release cycle exit $rc, want 42"; exit 1; }
rm -rf "$pl"
}

case_e25() {
# the pools example is the usage showcase — it must actually run
rm -rf "tests/.smoke_e25" && mkdir -p "tests/.smoke_e25"
./tuck build examples/25-pools.tuck -o:"tests/.smoke_e25/out" > /dev/null
rc=0; "tests/.smoke_e25/out/m_25_pools" || rc=$?
[ "$rc" -eq 4 ] || { echo "FAIL: pools example exit $rc, want 4 (3 sessions + 1 buffer)"; exit 1; }
rm -rf "tests/.smoke_e25"
}

case_e26() {
# actor runtime (spec §9, Phase A): the actor singleton drains its mailbox on
# the scheduler thread and exits with the accumulated state (1+..+10 = 55)
rm -rf "tests/.smoke_e26" && mkdir -p "tests/.smoke_e26"
./tuck build examples/26-actor-run.tuck -o:"tests/.smoke_e26/out" > /dev/null
rc=0; "tests/.smoke_e26/out/m_26_actor_run" || rc=$?
[ "$rc" -eq 55 ] || { echo "FAIL: actor-run example exit $rc, want 55"; exit 1; }
rm -rf "tests/.smoke_e26"
}

case_e27() {
# on select (spec §9.3, Phase B): message arms dispatch by kind + a shutdown
# arm. Accumulate 1..10, finish, wait, exit 55
rm -rf "tests/.smoke_e27" && mkdir -p "tests/.smoke_e27"
./tuck build examples/27-actor-select.tuck -o:"tests/.smoke_e27/out" > /dev/null
rc=0; "tests/.smoke_e27/out/m_27_actor_select" || rc=$?
[ "$rc" -eq 55 ] || { echo "FAIL: actor-select example exit $rc, want 55"; exit 1; }
rm -rf "tests/.smoke_e27"
}

case_e28() {
# async task (spec §9.2, Phase C): a task is an async coroutine, [io] calls are
# implicit yields, calling it schedules it, the runtime drives to completion.
# compute base*2 across two [io] yields, exit 42. (Not in nimCheckExpected —
# needs arsenal on the path + --stackTrace:off, which `tuck build` supplies.)
rm -rf "tests/.smoke_e28" && mkdir -p "tests/.smoke_e28"
./tuck build examples/28-async-task.tuck -o:"tests/.smoke_e28/out" > /dev/null
rc=0; "tests/.smoke_e28/out/m_28_async_task" || rc=$?
[ "$rc" -eq 42 ] || { echo "FAIL: async-task example exit $rc, want 42"; exit 1; }
rm -rf "tests/.smoke_e28"
}

case_e29() {
# operation timeout (spec §9.3): a task races a REAL async read (data at 500ms)
# against a 30ms deadline via `on select`; the timeout wins, exit 2. This is the
# impossible-on-blocking-I/O case working for real.
rm -rf "tests/.smoke_e29" && mkdir -p "tests/.smoke_e29"
./tuck build examples/29-task-timeout.tuck -o:"tests/.smoke_e29/out" > /dev/null
rc=0; "tests/.smoke_e29/out/m_29_task_timeout" || rc=$?
[ "$rc" -eq 2 ] || { echo "FAIL: task-timeout example exit $rc, want 2"; exit 1; }
rm -rf "tests/.smoke_e29"
}

case_e30() {
# async read WINS (spec §9.3): same mechanism, data arrives at 5ms and beats the
# 100ms timeout, exit 1. Proves the read fd genuinely became ready and resumed
# the suspended coroutine — real non-blocking I/O, not just the timeout arm.
rm -rf "tests/.smoke_e30" && mkdir -p "tests/.smoke_e30"
./tuck build examples/30-async-read.tuck -o:"tests/.smoke_e30/out" > /dev/null
rc=0; "tests/.smoke_e30/out/m_30_async_read" || rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL: async-read example exit $rc, want 1"; exit 1; }
rm -rf "tests/.smoke_e30"
}

case_e31() {
# fnsig (spec D#10c): a `:name` fn-ref fills a fnsig-typed slot and calling
# through the slot runs the referenced fn. plus(40,2) via c.add -> exit 42.
rm -rf "tests/.smoke_e31" && mkdir -p "tests/.smoke_e31"
./tuck build examples/31-fnsig-callback.tuck -o:"tests/.smoke_e31/out" --root:"$(pwd)" > /dev/null
rc=0; "tests/.smoke_e31/out/m_31_fnsig_callback" || rc=$?
[ "$rc" -eq 42 ] || { echo "FAIL: fnsig example exit $rc, want 42"; exit 1; }
rm -rf "tests/.smoke_e31"
}

case_e32() {
# duration units (spec 4.2): std/time Milliseconds distinct + `ms` helper,
# `5.ms` resolved cross-module from the import. asInt(42.ms) -> exit 42.
rm -rf "tests/.smoke_e32" && mkdir -p "tests/.smoke_e32"
./tuck build examples/32-duration-units.tuck -o:"tests/.smoke_e32/out" --root:"$(pwd)" > /dev/null
rc=0; "tests/.smoke_e32/out/m_32_duration_units" || rc=$?
[ "$rc" -eq 42 ] || { echo "FAIL: duration-units example exit $rc, want 42"; exit 1; }
rm -rf "tests/.smoke_e32"
}

case_e43() {
# The literal-value payload: `5.double` is `{value: 5} double`. The wrap is made
# in compiler/rewrite.nim BEFORE type checking, so it does not depend on the
# applied name resolving — while it lived inside a type rule, an unknown fn
# skipped the wrap and `5.ms` silently emitted a bare `5`. 10 + 30 -> exit 40.
rm -rf "tests/.smoke_e43" && mkdir -p "tests/.smoke_e43"
./tuck build examples/43-literal-payload.tuck -o:"tests/.smoke_e43/out" --root:"$(pwd)" > /dev/null
rc=0; "tests/.smoke_e43/out/m_43_literal_payload" || rc=$?
[ "$rc" -eq 40 ] || { echo "FAIL: literal-payload example exit $rc, want 40"; exit 1; }
rm -rf "tests/.smoke_e43"
}

case_effects() {
# Effects cross the module boundary, from source AND from the cached index.
# Both paths must reject identically: a pure fn calling an imported [io] fn is
# an error whether the callee was just parsed or restored from .tuck-cache.
# Run twice on purpose — the second run is the one that reads the index.
eff="tests/.smoke_effects"
rm -rf "$eff" && mkdir -p "$eff"
cat > "$eff/lib.tuck" <<'EOF'
fn noisy(value: int) -> int [io]:
  return value + 1
EOF
cat > "$eff/bad.tuck" <<'EOF'
import lib

fn pure(value: int) -> int:
  return value noisy

fn main() -> void:
  return
EOF
cat > "$eff/good.tuck" <<'EOF'
import lib

fn wrapper(value: int) -> int [io]:
  return value noisy

fn main() -> void [io]:
  return
EOF
# warms the index for lib
./tuck ch "$eff/good.tuck" --root:"$eff" > /dev/null || {
  echo "FAIL: correctly-declared [io] propagation rejected"; exit 1; }
for pass in cold warm; do
  if ./tuck ch "$eff/bad.tuck" --root:"$eff" > /dev/null 2>&1; then
    echo "FAIL: imported [io] not enforced on $pass cache"; exit 1
  fi
  ./tuck ch "$eff/bad.tuck" --root:"$eff" 2>&1 | grep -q "requires effect \[io\]" || {
    echo "FAIL: wrong error for imported [io] on $pass cache"; exit 1; }
done
./tuck ch "$eff/good.tuck" --root:"$eff" > /dev/null || {
  echo "FAIL: good case broke after index warm"; exit 1; }
rm -rf "$eff"
}

case_bytype() {
# Payload fields matched to params BY TYPE, with a struct LITERAL receiver.
# The checker matches by name first, then by type for whatever is left
# (typecheck.nim checkCallArgs pass 2), so `alpha` legitimately feeds `first`.
# Lowering has to use that mapping rather than re-deriving it by name — when it
# re-derived, nothing matched and every argument became the literal `none`,
# which the type checker had already waved through. A variable receiver took a
# different path and was always correct, which is why this went unnoticed:
# the exit code below is 42 only if all three arguments arrive in order.
bt="tests/.smoke_bytype"
rm -rf "$bt" && mkdir -p "$bt"
cat > "$bt/t.tuck" <<'EOF'
import sys

fn pick({first: int, second: str, third: bool}) -> int:
  if third:
    return first
  return 0

fn main() -> void [io]:
  let r = {alpha: 42, beta: "x", gamma: true} pick
  r sys::exit
EOF
./tuck build "$bt/t.tuck" -o:"$bt/out" --root:"$(pwd)" > /dev/null
grep -q 'tuck_pick(42, "x", true)' "$bt/out/t.nim" || {
  echo "FAIL: by-type literal payload emitted wrong args:"
  grep 'tuck_pick(' "$bt/out/t.nim"; exit 1; }
rc=0; "$bt/out/t" || rc=$?
[ "$rc" -eq 42 ] || { echo "FAIL: by-type literal payload exit $rc, want 42"; exit 1; }
rm -rf "$bt"
}

# Launch every case, then collect. `wait <pid>` yields that job's status.
pids=""
for c in case_inv case_tdl case_chaintail case_errmatch case_tour123 case_errname case_lib case_ctrlflow case_valuetype case_nullary case_matchret case_seqat case_index case_pool case_e25 case_e26 case_e27 case_e28 case_e29 case_e30 case_e31 case_e32 case_e43 case_effects case_bytype; do
  $c & pids="$pids $!:$c"
done
rc=0
for entry in $pids; do
  wait "${entry%%:*}" || { echo "FAIL: ${entry#*:}"; rc=1; }
done
[ $rc -eq 0 ] || exit 1

# Reported in the same shape as the tests/lib.sh scripts so the runner's
# summary line matches uniformly. This script asserts with `set -e` +
# explicit exits rather than lib.sh, so the count is its own.
echo "cli_smoke.sh: all passed, 0 failed"
