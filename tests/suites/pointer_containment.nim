## Pointer-kind types are legal ONLY at the extern boundary.
##
## Tuck is a safe language: unsafe types exist to talk to C and nowhere else. A
## pointer may be produced by an extern and consumed by another extern or a
## converter, but it may never be STORED — so no pointer outlives the expression
## that obtained it, and a dangling reference is unreachable from safe Tuck.
##
## `examples/34-ffi-cstring.tuck:17` already stated this as a comment ("cstring
## stays usable only at the edge, which keeps the copy visible") and reasoned
## about the lifetime by hand. These tests make the comment a rule.
##
## Pointer-kind = `cstring`, plus any FIELDLESS extern type (an opaque C handle:
## `typedef struct Foo Foo;` — unknown size, only ever held as a pointer; Nim
## emits `ptr FooObj`, Odin `rawptr`).

import std/os
import ../harness

proc run*(t: var T) =
  # --- legal: the extern boundary itself -----------------------------------

  t.src """
extern [c, header: "string.h"]:
  type Buf = {}
  fn memcmp({a: Buf, b: Buf, n: usize}) -> i32 [emit: "memcmp"]

fn main() -> int:
  return 0
"""
  t.okCheck "opaque handle in an extern signature"

  # Buf is the builtin uint8_t* — cstring's byte-array sibling. Builtin rather
  # than a user-declared `type Buf = {}`, which would emit {.importc: "Buf",
  # header: ...} and claim a C typedef named Buf exists in that header.
  t.src """
extern [c, header: "string.h"]:
  fn memcmp({a: Buf, b: Buf, n: usize}) -> i32 [emit: "memcmp"]

fn main() -> int:
  return 0
"""
  t.okCheck   "Buf as an extern parameter"
  t.emits     "Buf is a real pointer in Nim", "ptr UncheckedArray\\[uint8\\]"
  t.emitsOdin "Buf is a real pointer in Odin", "\\[\\^\\]u8"

  # A pointer may be passed INTO C: Tuck is handing over something C already
  # holds, and nothing raw ends up in a Tuck variable.
  t.src """
extern [c, header: "string.h"]:
  fn puts({s: cstring}) -> i32 [emit: "puts"]

fn main() -> int:
  return 0
"""
  t.okCheck "cstring as an extern parameter"

  # --- illegal: a pointer coming back OUT of C ------------------------------
  #
  # A returned pointer lands in a Tuck variable, and from there its lifetime is
  # C's business and unknowable here. The binding must return a safe type and
  # copy in its implementation, so forgetting the conversion is impossible
  # rather than merely discouraged.
  t.src """
extern [c, header: "zlib.h", lib: "z"]:
  fn zlibVersion() -> cstring [emit: "zlibVersion"]

fn main() -> int:
  return 0
"""
  t.badCheck "cstring as an extern return", "never returned out of it"

  t.src """
extern [c, header: "string.h"]:
  fn grab() -> Buf [emit: "grab"]

fn main() -> int:
  return 0
"""
  t.badCheck "Buf as an extern return", "never returned out of it"

  # ...including buried in a wrapper or a record
  t.src """
extern [c, header: "zlib.h", lib: "z"]:
  fn tryVersion() -> !cstring [io, emit: "tryVersion"]

fn main() -> int:
  return 0
"""
  t.badCheck "cstring buried in a fallible return", "never returned out of it"

  # --- illegal: every way a pointer could be stored or escape ---------------

  t.src """
extern [c, header: "string.h"]:
  type Buf = {}

type Holder:
  saved: Buf

fn main() -> int:
  return 0
"""
  t.badCheck "handle in a record field", "only.*extern|pointer"

  t.src """
extern [c, header: "string.h"]:
  type Buf = {}

fn leak({b: Buf}) -> Buf:
  return b

fn main() -> int:
  return 0
"""
  t.badCheck "handle in a plain fn signature", "only.*extern|pointer"

  t.src """
type Holder:
  raw: cstring

fn main() -> int:
  return 0
"""
  t.badCheck "cstring in a record field", "only.*extern|pointer"

  t.src """
fn sneaky({p: cstring}) -> cstring:
  return p

fn main() -> int:
  return 0
"""
  t.badCheck "cstring in a plain fn signature", "only.*extern|pointer"

  # A mixin is NOT an extern. It shares an AST arm with dkExtern
  # (typecheck.nim checkDecl / resolveDeclTypeRefs recurse via mixinMembers), so a
  # check keyed on "am I in that arm" instead of on the parent's isExtern would
  # miss this. Second leak path, tested on purpose.
  t.src """
mixin Sneaky:
  fn grab({p: cstring}) -> cstring:
    return p

fn main() -> int:
  return 0
"""
  t.badCheck "cstring in a mixin member", "only.*extern|pointer"

  t.src """
actor Driver [queue: 8]:
  held: cstring

  on ping({n: int}) -> void:
    return

fn main() -> int:
  return 0
"""
  t.badCheck "cstring in an actor field", "only.*extern|pointer"

  t.src """
extern [c, header: "string.h"]:
  type Buf = {}

fn collect() -> Seq[Buf]:
  return []

fn main() -> int:
  return 0
"""
  t.badCheck "handle as a Seq element", "only.*extern|pointer"

  t.src """
type Holder:
  bytes: Buf

fn main() -> int:
  return 0
"""
  t.badCheck "Buf in a record field", "only.*extern|pointer"

  # --- returning: memory pointers no, opaque handles yes -------------------

  # The rule is about MEMORY, not about pointers. A returned cstring/Buf points
  # at bytes whose lifetime is C's and unknowable here — that is the hazard.
  t.src """
extern [c, header: "zlib.h"]:
  fn zlibVersion() -> cstring

fn main() -> int:
  return 0
"""
  t.badCheck "an extern may not return cstring", "never returned out of it"

  t.src """
extern [c, header: "x.h"]:
  fn getBuf() -> Buf

fn main() -> int:
  return 0
"""
  t.badCheck "an extern may not return Buf", "never returned out of it"

  # An OPAQUE HANDLE is exempt: `typedef struct Counter Counter;` has no
  # definition, so there is nothing to dereference and no memory Tuck can read.
  # It is a token the library hands out and takes back — every real C API works
  # this way (FILE*, sqlite3*). Barring it left counterNew unwritable in ANY
  # form, since a handle has no by-value equivalent to copy out.
  t.src """
extern [c, header: "point.h"]:
  type Counter = {}
  fn counterNew({start: i32}) -> Counter
  fn counterFree({c: Counter}) -> void

fn main() -> int:
  return 0
"""
  t.okCheck "an extern MAY return an opaque handle"

  # ...but the containment rule is unchanged: a handle still cannot be STORED.
  t.src """
extern [c, header: "point.h"]:
  type Counter = {}
  fn counterNew({start: i32}) -> Counter

type Holder:
  c: Counter

fn main() -> int:
  return 0
"""
  t.badCheck "an opaque handle still may not be stored", "only.*extern|pointer"

  # --- the sanctioned crossing still works end to end ----------------------

  # examples/34-ffi-cstring reads libz's version string — a real C `char*` — and
  # must still reach Tuck as a `str`. Under the params-only rule the pointer no
  # longer crosses: the binding returns str and the copy happens in the impl
  # module, so this asserts the WRAPPING works, not just that the rule fires.
  let ffi = t.dir / "ffi"
  let buildIdx = t.needCmd @[tuckExe, "build", "examples/34-ffi-cstring.tuck",
                             "-o:" & ffi, "--root:" & t.root]
  # The run must wait for the build: needCmd registers with no dependency, so
  # the run would otherwise be launched into a directory the pool has not
  # written yet. needCmdAfter is the same registration WITH a dep; its prep hook
  # is not needed here, hence the empty one.
  let runIdx = t.needCmdAfter(@[ffi / "m_34_ffi_cstring"], buildIdx,
                              proc (dir: string) = discard, ffi)
  if t.phase == pReport:
    let (brc, bout) = t.resultOf(buildIdx)
    if brc != 0:
      t.no "34-ffi-cstring still builds and runs", bout
    else:
      let (rrc, _) = t.resultOf(runIdx)
      if rrc == 0: t.ok "34-ffi-cstring still builds and runs"
      else: t.no "34-ffi-cstring still builds and runs", "exit " & $rrc & ", want 0"

  t.finish()
