#!/bin/bash
# One program using most of the language at once, driven through the whole
# pipeline and BOTH backends, plus the effect checker's negative case.
#
# The value here is breadth, not depth: registers, compositions, invariants,
# transitions, a decision table and a sum type all in one module, so a change
# that breaks an interaction between two features shows up even when each
# feature's own test still passes.
#
# Replaces tests/end_to_end.nim, which ran the stages in-process and dumped the
# AST/Nim/Odin to stdout for a human to eyeball. Nothing asserted on the dump,
# so the real test was "no stage crashed" — that is what runs here, via the
# binary, with the AST dump kept as an explicit `tuck p --ast` check.
cd "$(dirname "$0")/.."
. tests/lib.sh

src <<'TUCKEOF'
fn addOne(x: int) -> int:
  return x + 1

type Controls:
  volume: int
  muted: bool

type Connection:
  latency: int

type PlayerComposition = Controls + Connection {latency -> delay}

register RCC_CR at 0x40021000:
  HSION: bit 0 [read, write]
  HSIRDY: bit 1 [read]

type Temperature:
  celsius: float
  invariant:
    celsius >= -273.15

type TrafficLight:
  | Red
  | Yellow
  | Green
  transitions:
    Red -> Green
    Green -> Yellow
    Yellow -> Red

decision classifyPacket({priority: int, size: int, encrypted: bool}) -> int:
  | 2    128   true  -> 1
  | 2    128   false -> 2
  | 2    64    _     -> 3
  | 1     _     _     -> 4
  | _       _     _     -> 5

fn main() -> int:
  let val1 = 9 addOne
  let val2 = {priority: 2, size: 64, encrypted: false} classifyPacket
  return val2
TUCKEOF
ok_check "the kitchen-sink module typechecks"
# Row `| 2 64 _ -> 3` is the first one matching (2, 64, false).
runs      "decision table picks the first matching row" 3
emits     "Nim backend emits the decision fn"  'classifyPacket'
emits_odin "Odin backend emits the decision fn" 'classifyPacket'

# The AST serializer has to survive every one of those node kinds. A decision
# table is a dkFn carrying isDecision, not a kind of its own — checking the
# flag proves the table reached the serializer rather than being flattened.
if ./tuck p "$_cur/t.tuck" --ast 2>/dev/null | grep -q '"isDecision": true'; then
  _ok "AST serializes the whole module"
else
  _no "AST serializes the whole module" "no decision fn in tuck p --ast output"
fi

# A pure function calling an [io] one is the effect checker's core rejection.
src <<'TUCKEOF'
fn writeLog() [io]:
  discard

fn doWork() -> void:
  {} writeLog
TUCKEOF
bad_check "a pure fn cannot call an [io] fn" 'requires effect \[io\]'

finish
