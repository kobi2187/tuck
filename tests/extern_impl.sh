#!/bin/bash
# `extern [impl: nim "...", odin "..."]` — naming the backend-language module
# that implements a header-less extern block.
#
# Before this existed there were exactly two ways to bind anything: a C header
# (`extern [c, header:]`), or adding a proc to compiler/tuck_rt.nim and its
# hand-mirrored Odin twin. So every stdlib block cost an edit to the compiler's
# own runtime, twice. `impl:` makes the stdlib growable from outside the
# compiler, which is what the ~95-block catalogue in stdlib-blocks.md needs.
#
# The Tuck signature is the contract and both backends converge on it: Nim can
# re-export unqualified, Odin cannot, so the Odin side gets a generated
# forwarder into the aliased package. Call sites are identical either way.
cd "$(dirname "$0")/.."
. tests/lib.sh

# --- a real Nim stdlib proc, with no tuck_rt.nim edit --------------------

src <<'EOF'
extern [impl: nim "std/strutils"]:
  fn startsWith({s: str, prefix: str}) -> bool

fn main() -> int:
  if {s: "hello", prefix: "he"} startsWith:
    return 7
  return 9
EOF
ok_check "impl: nim parses and checks"
emits    "the impl module is imported"    'import std/strutils'
# Nim exports by MODULE NAME, not by path: `export std/strutils` is a syntax
# error, so the basename is what gets re-exported.
emits    "and re-exported by basename"    'export strutils'
runs     "the bound Nim proc really runs" 7

# --- a backend-language module name is NOT a path ------------------------

# "std/strutils" and "core:strings" name modules in the backend's own
# namespace. Only ./ and ../ mark a path relative to the .tuck source, so these
# must ride through untouched however -o: moves the output.
src <<'EOF'
extern [impl: nim "std/strutils", odin "core:strings"]:
  fn startsWith({s: str, prefix: str}) -> bool

fn main() -> int:
  return 0
EOF
emits      "nim module name passes through"  'import std/strutils'
emits_odin "odin module name passes through" 'import strings "core:strings"'

# --- Odin gets a forwarder, because it has no unqualified import ---------

src <<'EOF'
extern [impl: odin "core:strings"]:
  fn startsWith({s: str, prefix: str}) -> bool

fn main() -> int:
  if {s: "hello", prefix: "he"} startsWith:
    return 7
  return 9
EOF
emits_odin "odin forwards into the aliased package" 'return strings\.startsWith'
# The call site stays unqualified — identical to the Nim backend's.
emits_odin "odin call site is unqualified"          'if startsWith\('

# --- both backends, one signature, end to end ----------------------------

# examples/34-ffi-cstring is the real case this was built for: libz's version
# is a C `char*`, which the params-only pointer rule forbids from crossing into
# Tuck. The binding declares `-> str` and each backend's shim
# (examples/shim/zlib_shim.nim / .odin) copies it. Asserted on the Nim side by
# running it; the Odin side is gated by tests/odin_backend.sh.
if ./tuck build examples/34-ffi-cstring.tuck -o:"$_dir/z" --root:"$(pwd)" \
     > "$_dir/z.log" 2>&1; then
  out=$("$_dir/z/m_34_ffi_cstring" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    _no "34-ffi-cstring runs" "exit $rc, want 0"
  elif echo "$out" | grep -qE '^[0-9]+\.[0-9]'; then
    _ok "34-ffi-cstring prints libz's real version ($out)"
  else
    _no "34-ffi-cstring prints libz's real version" "got: $out"
  fi
else
  _no "34-ffi-cstring builds" "$(tail -2 "$_dir/z.log")"
fi

# The path in that example is written ./shim/... — relative to the .tuck file,
# which is the only frame of reference its author has. -o: moves the output, so
# the compiler rebases it; the author never adjusts what they wrote.
src <<'EOF'
extern [impl: nim "./nowhere/mod"]:
  fn f() -> int

fn main() -> int:
  return 0
EOF
emits "a ./ path is rebased off the output dir" 'import \.\..*nowhere/mod'

finish
