#!/bin/bash
# `when TARGET == "value":` — compile-time platform selection (spec §8.3).
# Was a fully speced, entirely unimplemented section (not even lexed past a
# dead `tkWhen` token) until this suite's sibling implementation landed:
# compiler/{ast,parser,modules}.nim + tuck.nim's `--target:NAME` flag.
#
# This needs its own suite rather than lib.sh's ok_check/emits/etc. because
# those hardcode their `$TUCK` argv with no way to pass --target: through —
# so the assertions here call `$TUCK` directly. `_cur`/`src`/`_ok`/`_no` are
# lib.sh primitives; the target-aware calls are the only new plumbing.
cd "$(dirname "$0")/.."
. tests/lib.sh

_check_target() {
  # $1 name  $2 target-flag-or-empty  $3 expect(0 ok / nonzero fail)
  local out rc=0
  if [ -n "$2" ]; then
    out=$("$TUCK" ch "$_cur/t.tuck" --root:"$(pwd)" --target:"$2" 2>&1) || rc=$?
  else
    out=$("$TUCK" ch "$_cur/t.tuck" --root:"$(pwd)" 2>&1) || rc=$?
  fi
  if [ "$3" -eq 0 ] && [ "$rc" -eq 0 ]; then _ok "$1"
  elif [ "$3" -ne 0 ] && [ "$rc" -ne 0 ]; then _ok "$1"
  else _no "$1" "exit $rc (wanted $([ "$3" -eq 0 ] && echo 0 || echo nonzero)): $(echo "$out" | tail -1)"
  fi
}

_emit_target() {
  # $1 target-flag-or-empty  ->  emitted Nim on stdout, "" on failure
  if [ -n "$1" ]; then
    "$TUCK" c "$_cur/t.tuck" -o:"$_cur/out_$1" --root:"$(pwd)" --target:"$1" \
      >"$_cur/emit_$1.log" 2>&1 && cat "$_cur/out_$1/t.nim"
  else
    "$TUCK" c "$_cur/t.tuck" -o:"$_cur/out_none" --root:"$(pwd)" \
      >"$_cur/emit_none.log" 2>&1 && cat "$_cur/out_none/t.nim"
  fi
}

# --- selection picks the right block, drops the other entirely -------------

src <<'TUCKEOF'
when TARGET == "stm32f4":
  fn initClock() -> int:
    return 1

when TARGET == "rp2040":
  fn initClock() -> int:
    return 2

fn main() -> int:
  return initClock
TUCKEOF

out_stm=$(_emit_target stm32f4)
if echo "$out_stm" | grep -q 'return 1' && ! echo "$out_stm" | grep -q 'return 2'; then
  _ok "--target:stm32f4 emits only that block's body"
else
  _no "--target:stm32f4 emits only that block's body" "got: $out_stm"
fi

out_rp=$(_emit_target rp2040)
if echo "$out_rp" | grep -q 'return 2' && ! echo "$out_rp" | grep -q 'return 1'; then
  _ok "--target:rp2040 emits only that block's body"
else
  _no "--target:rp2040 emits only that block's body" "got: $out_rp"
fi

out_none=$(_emit_target "")
if ! echo "$out_none" | grep -qE 'proc tuck_initClock'; then
  _ok "no --target: both blocks are dropped, neither body is emitted"
else
  _no "no --target: both blocks are dropped, neither body is emitted" \
      "initClock was emitted with no --target given: $out_none"
fi

# --- the Odin backend sees the same selection, no codegen changes needed ---

"$TUCK" c "$_cur/t.tuck" --odin -o:"$_cur/odin_rp" --root:"$(pwd)" \
  --target:rp2040 >"$_cur/odin.log" 2>&1
odin_out=$(cat "$_cur/odin_rp/t.odin" 2>/dev/null)
if echo "$odin_out" | grep -q 'return 2' && ! echo "$odin_out" | grep -q 'return 1'; then
  _ok "the Odin backend resolves the same --target selection"
else
  _no "the Odin backend resolves the same --target selection" "got: $odin_out"
fi

# --- a target that matches nothing drops every block, same as no target ----
# (checked by emitted content, not `tuck ch`'s exit code: an undeclared
# `initClock` still gradually type-checks either way — see task_plan.md's
# "Unknown type for undeclared symbols" note — so only the EMITTED code can
# tell whether the blocks were actually dropped.)

out_bogus=$(_emit_target bogus-target)
if ! echo "$out_bogus" | grep -qE 'proc tuck_initClock'; then
  _ok "an unrecognised --target value drops every when block too"
else
  _no "an unrecognised --target value drops every when block too" \
      "initClock was emitted for a target that names no block: $out_bogus"
fi

# --- only the one supported shape parses ------------------------------------

src <<'TUCKEOF'
when FOO == "x":
  fn f() -> int:
    return 1

fn main() -> int:
  return 0
TUCKEOF
_check_target "'when' rejects anything but 'when TARGET == \"...\":'" "" 1

finish
