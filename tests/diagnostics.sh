#!/bin/bash
# Every diagnostic code resolves, explains itself, and reaches the user.
#
# A code is a PROMISE: once published it names that diagnostic forever, so a
# user who searched for TK-TY05 last year must land on the same rule today.
# These tests hold the two halves of that promise — the code appears in the
# message the compiler prints, and `tuck explain` answers for it.
cd "$(dirname "$0")/.."
. tests/lib.sh

# --- the code reaches the user -------------------------------------------

src <<'EOF'
type A:
  x: int

type B:
  x: str

object C:
  + A
  + B

fn main() -> int:
  return 0
EOF
bad_check "a composed collision carries TK-TY05" 'TK-TY05'

src <<'EOF'
fn main() -> void:
  let x = 5.ms
  return
EOF
bad_check "an unresolvable name carries TK-TY03" 'TK-TY03'

# A parse rejection carries its code in the [stage code] tag rather than the
# message body, so this asserts the tag the driver prints.
_dir=$(mktemp -d); trap 'rm -rf "$_dir"' EXIT
printf 'ac:\n  t: int\n' > "$_dir/t.tuck"
if ./tuck ch "$_dir/t.tuck" 2>&1 | grep -q 'TK-PA03'; then
  _ok "a misspelled top-level keyword carries TK-PA03"
else
  _no "a misspelled top-level keyword carries TK-PA03" \
      "$(./tuck ch "$_dir/t.tuck" 2>&1 | sed -n '2p')"
fi

# --- explain answers for every code --------------------------------------

# The registry is only useful if every code in it has an explanation. Walking
# the enum by hand would go stale; this walks what the compiler actually
# reports, so a code added without an explanation fails here.
# Only DECLARED codes — `dcFoo = "TK-XX01"`. A bare TK-XX01 elsewhere in the
# file is an illustration in a comment, not a registry entry, and matching
# those reported two phantom codes the first time this ran.
missing=0
for c in $(grep -oE '= "TK-[A-Z]{2}[0-9]{2}"' compiler/diagnostics.nim \
           | grep -oE 'TK-[A-Z]{2}[0-9]{2}' | sort -u); do
  out=$(./tuck explain "$c" 2>&1)
  case "$out" in
    *"no such diagnostic"*|*"No code assigned"*)
      printf '  no explanation: %s\n' "$c"; missing=$((missing + 1));;
  esac
done
if [ "$missing" -eq 0 ]; then
  _ok "every code in the registry explains itself"
else
  _no "every code in the registry explains itself" "$missing without one"
fi

# An unknown code must not be silently accepted.
if ./tuck explain TK-ZZ99 >/dev/null 2>&1; then
  _no "an unknown code is rejected" "TK-ZZ99 was accepted"
else
  _ok "an unknown code is rejected"
fi

# The short form is what a user actually types after reading an error.
if ./tuck explain ty05 2>&1 | grep -q 'set union'; then
  _ok "a code resolves without its TK- prefix, case-insensitively"
else
  _no "a code resolves without its TK- prefix, case-insensitively" \
      "$(./tuck explain ty05 2>&1 | head -1)"
fi

finish
