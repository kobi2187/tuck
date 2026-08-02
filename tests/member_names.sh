#!/bin/bash
# Two objects may declare a member fn of the same name.
#
# `Dog.noise` and `Cat.noise` are different functions. Nim tolerated the clash
# because it overloads on the `self` parameter's type; Odin does not overload,
# so the emitted package had two `noise :: proc` at top level and failed with
# "Redeclaration of 'noise' in this scope".
#
# This is the shape interfaces exist for — several types answering the same
# call — so it has to work before dispatch can be built on it.
cd "$(dirname "$0")/.."
. tests/lib.sh

src <<'EOF'
object Dog:
  name: str
  fn noise({self: Dog}) -> int:
    return 1

object Cat:
  lives: int
  fn noise({self: Cat}) -> int:
    return 41

fn main() -> int:
  return 0
EOF
ok_check   "two objects may share a member fn name"
emits      "Nim keeps them apart"  'tuck_Dog_noise|noise\*\(self: var tuck_Dog\)'
emits_odin "Odin keeps them apart" 'tuck_Dog_noise'

# The real gate: the emitted Odin must COMPILE. Emission alone proved nothing
# here — the old output looked plausible and only `odin build` rejected it.
odin_exe=$(command -v odin || true)
for c in /home/kl/apps/Odin/odin /opt/odin/odin; do
  [ -n "$odin_exe" ] && break
  [ -x "$c" ] && odin_exe=$c
done
if [ -n "$odin_exe" ]; then
  proj="$_dir/odinpkg"
  mkdir -p "$proj"
  ./tuck c "$_cur/t.tuck" -o:"$_cur/od" --odin --root:"$(pwd)" >/dev/null 2>&1
  cp "$_cur/od/t.odin" "$proj/main.odin"
  mkdir -p "$proj/tuckrt" && cp compiler/tuckrt/*.odin "$proj/tuckrt/" 2>/dev/null
  [ -f compiler/tuckrt/minicoro.a ] && cp compiler/tuckrt/minicoro.a "$proj/tuckrt/"
  if "$odin_exe" build "$proj" -o:none -out:"$proj/prog" > "$proj/build.log" 2>&1; then
    _ok "the emitted Odin compiles"
  else
    _no "the emitted Odin compiles" "$(grep -i error "$proj/build.log" | head -2)"
  fi
else
  printf '  skip  odin not found\n'
fi

# Three objects, same name, and each still calls its own.
src <<'EOF'
object A:
  n: int
  fn size({self: A}) -> int:
    return 1

object B:
  n: int
  fn size({self: B}) -> int:
    return 2

object C:
  n: int
  fn size({self: C}) -> int:
    return 39

fn main() -> int:
  return 0
EOF
ok_check "three objects may share a member fn name"

# OPEN: a member fn still collides with a TOP-LEVEL fn of the same name.
#
# This one is the CHECKER, not emission. collectSigs registers object members
# under their bare name into the same flat fnSigs as top-level fns
# (typecheck.nim — "keyed by name alone, no overloading"), so `Dog.noise`
# overwrites the free `noise` and the call demands a `self`. Pools already show
# the fix — they key qualified (`Pool.acquire`) — but applying it to members
# means changing call resolution, not just emission, so it is its own change.
src <<'EOF'
fn noise({n: int}) -> int:
  return n

object Dog:
  name: str
  fn noise({self: Dog}) -> int:
    return 1

fn main() -> int:
  return {n: 41} noise
EOF
try ok_check "a member fn and a top-level fn may share a name"
bug_open "member fn shadows a top-level fn of the same name"

finish
