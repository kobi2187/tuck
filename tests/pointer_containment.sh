#!/bin/bash
# Pointer-kind types are legal ONLY at the extern boundary.
#
# Tuck is a safe language: unsafe types exist to talk to C and nowhere else. A
# pointer may be produced by an extern and consumed by another extern or a
# converter, but it may never be STORED — so no pointer outlives the expression
# that obtained it, and a dangling reference is unreachable from safe Tuck.
#
# `examples/34-ffi-cstring.tuck:17` already stated this as a comment ("cstring
# stays usable only at the edge, which keeps the copy visible") and reasoned
# about the lifetime by hand. These tests make the comment a rule.
#
# Pointer-kind = `cstring`, plus any FIELDLESS extern type (an opaque C handle:
# `typedef struct Foo Foo;` — unknown size, only ever held as a pointer; Nim
# emits `ptr FooObj`, Odin `rawptr`).
cd "$(dirname "$0")/.."
. tests/lib.sh

# --- legal: the extern boundary itself -----------------------------------

src <<'EOF'
extern [c, header: "string.h"]:
  type Buf = {}
  fn memcmp({a: Buf, b: Buf, n: usize}) -> i32 [emit: "memcmp"]

fn main() -> int:
  return 0
EOF
ok_check "opaque handle in an extern signature"

# Buf is the builtin uint8_t* — cstring's byte-array sibling. Builtin rather
# than a user-declared `type Buf = {}`, which would emit {.importc: "Buf",
# header: ...} and claim a C typedef named Buf exists in that header.
src <<'EOF'
extern [c, header: "string.h"]:
  fn memcmp({a: Buf, b: Buf, n: usize}) -> i32 [emit: "memcmp"]

fn main() -> int:
  return 0
EOF
ok_check "Buf as an extern parameter"
emits      "Buf is a real pointer in Nim"  'ptr UncheckedArray\[uint8\]'
emits_odin "Buf is a real pointer in Odin" '\[\^\]u8'

# A pointer may be passed INTO C: Tuck is handing over something C already
# holds, and nothing raw ends up in a Tuck variable.
src <<'EOF'
extern [c, header: "string.h"]:
  fn puts({s: cstring}) -> i32 [emit: "puts"]

fn main() -> int:
  return 0
EOF
ok_check "cstring as an extern parameter"

# --- illegal: a pointer coming back OUT of C ------------------------------
#
# A returned pointer lands in a Tuck variable, and from there its lifetime is
# C's business and unknowable here. The binding must return a safe type and
# copy in its implementation, so forgetting the conversion is impossible
# rather than merely discouraged.
src <<'EOF'
extern [c, header: "zlib.h", lib: "z"]:
  fn zlibVersion() -> cstring [emit: "zlibVersion"]

fn main() -> int:
  return 0
EOF
bad_check "cstring as an extern return" "never returned out of it"

src <<'EOF'
extern [c, header: "string.h"]:
  fn grab() -> Buf [emit: "grab"]

fn main() -> int:
  return 0
EOF
bad_check "Buf as an extern return" "never returned out of it"

# ...including buried in a wrapper or a record
src <<'EOF'
extern [c, header: "zlib.h", lib: "z"]:
  fn tryVersion() -> !cstring [io, emit: "tryVersion"]

fn main() -> int:
  return 0
EOF
bad_check "cstring buried in a fallible return" "never returned out of it"

# --- illegal: every way a pointer could be stored or escape ---------------

src <<'EOF'
extern [c, header: "string.h"]:
  type Buf = {}

type Holder:
  saved: Buf

fn main() -> int:
  return 0
EOF
bad_check "handle in a record field" "only.*extern|pointer"

src <<'EOF'
extern [c, header: "string.h"]:
  type Buf = {}

fn leak({b: Buf}) -> Buf:
  return b

fn main() -> int:
  return 0
EOF
bad_check "handle in a plain fn signature" "only.*extern|pointer"

src <<'EOF'
type Holder:
  raw: cstring

fn main() -> int:
  return 0
EOF
bad_check "cstring in a record field" "only.*extern|pointer"

src <<'EOF'
fn sneaky({p: cstring}) -> cstring:
  return p

fn main() -> int:
  return 0
EOF
bad_check "cstring in a plain fn signature" "only.*extern|pointer"

# A mixin is NOT an extern. It shares an AST arm with dkExtern
# (typecheck.nim checkDecl / resolveDeclTypeRefs recurse via mixinMembers), so a
# check keyed on "am I in that arm" instead of on the parent's isExtern would
# miss this. Second leak path, tested on purpose.
src <<'EOF'
mixin Sneaky:
  fn grab({p: cstring}) -> cstring:
    return p

fn main() -> int:
  return 0
EOF
bad_check "cstring in a mixin member" "only.*extern|pointer"

src <<'EOF'
actor Driver [queue: 8]:
  held: cstring

  on ping({n: int}) -> void:
    return

fn main() -> int:
  return 0
EOF
bad_check "cstring in an actor field" "only.*extern|pointer"

src <<'EOF'
extern [c, header: "string.h"]:
  type Buf = {}

fn collect() -> Seq[Buf]:
  return []

fn main() -> int:
  return 0
EOF
bad_check "handle as a Seq element" "only.*extern|pointer"

src <<'EOF'
type Holder:
  bytes: Buf

fn main() -> int:
  return 0
EOF
bad_check "Buf in a record field" "only.*extern|pointer"

# --- the sanctioned crossing still works end to end ----------------------

# examples/34-ffi-cstring reads libz's version string — a real C `char*` — and
# must still reach Tuck as a `str`. Under the params-only rule the pointer no
# longer crosses: the binding returns str and the copy happens in the impl
# module, so this asserts the WRAPPING works, not just that the rule fires.
if ./tuck build examples/34-ffi-cstring.tuck -o:"$_dir/ffi" --root:"$(pwd)" \
     > "$_dir/ffi.log" 2>&1; then
  rc=0; "$_dir/ffi/m_34_ffi_cstring" > /dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then _ok "34-ffi-cstring still builds and runs"
  else _no "34-ffi-cstring still builds and runs" "exit $rc, want 0"; fi
else
  _no "34-ffi-cstring still builds and runs" "$(tail -2 "$_dir/ffi.log")"
fi

finish
