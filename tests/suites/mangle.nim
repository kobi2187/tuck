## The name-mangling lowering pass (compiler/mangle.nim).
##
## The failure mode this guards against is subtle: renaming a DECLARATION but
## missing one of its reference sites produces output that looks fine and
## fails to compile — or worse, silently binds a runtime proc of the same
## name. So every case here checks the declaration AND a reference together.
##
## Drives `tuck c` and greps the emitted Nim, which is what the old
## mangle_tests.nim asserted on too — it just reached it by linking the
## compiler instead of running it.

import ../harness

proc run*(t: var T) =
  # A fn declaration and its call site must move together.
  t.src """
fn helper({a: int}) -> int:
  return a

fn main() -> int:
  return {a: 5} helper
"""
  t.emits "fn decl mangled",        "proc tuck_helper"
  t.emits "fn call site mangled",   "tuck_helper\\("
  t.omits "no bare fn decl",        "proc helper"
  # Idempotence: each backend lowers its own deepCopy, and a pass that
  # double-prefixed would produce tuck_tuck_helper on the second run.
  t.omits "no double prefix",       "tuck_tuck_"
  # Mangling is a whole-program pass that runs BEFORE either backend, so the two
  # cannot diverge by construction — but nothing said so, and the interface work
  # showed how quietly a backend can fall behind when only one is asserted.
  t.emitsOdin "Odin: fn decl mangled",      "tuck_helper :: proc"
  t.emitsOdin "Odin: fn call site mangled", "tuck_helper\\("
  t.omitsOdin "Odin: no double prefix",     "tuck_tuck_"

  # The whole point: a user fn named like a runtime proc must not collide.
  t.src """
fn ready() -> bool:
  return true

fn main() -> int:
  if ready:
    return 1
  return 0
"""
  t.emits "fn named 'ready' is safe",  "proc tuck_ready"
  t.omits "runtime 'ready' untouched", "proc ready\\*"

  # Type declarations and every mention of the type.
  t.src """
type Config:
  url: str

fn use({c: Config}) -> str:
  return c.url

fn main() -> void:
  let cfg = {url: "x"} Config
  return
"""
  t.emits "type decl and uses mangled", "tuck_Config"
  t.omits "no bare type decl",          "type Config\\*"

  # FIELDS stay bare — they are namespaced by their record and mangling them
  # would only make literals unreadable.
  t.src """
type Point:
  x: int
  y: int

fn main() -> int:
  let p = {x: 1, y: 2} Point
  return p.x
"""
  t.emits "field decl stays bare",   "x\\*: int"
  t.emits "field access stays bare", "p\\.x"
  t.omits "fields are NOT mangled",  "tuck_x"

  # Locals and params shadow: a local named like a global keeps its own name.
  t.src """
fn helper({value: int}) -> int:
  return value

fn main() -> int:
  let value = 7
  return {value: value} helper
"""
  t.emits "params stay bare",          "value: int"
  t.omits "params/locals NOT mangled", "tuck_value"

  # Externs bind a foreign symbol BY NAME, so they must survive verbatim —
  # this is the FFI escape hatch an explicit attribute would extend.
  t.src """
extern:
  fn readFile({path: str}) -> str

fn main() -> void:
  let c = {path: "f"} readFile
  return
"""
  t.emits "extern call verbatim",    "readFile\\("
  t.omits "externs are NOT mangled", "tuck_readFile"
  t.omitsOdin "Odin: externs NOT mangled", "tuck_readFile"

  t.finish()
