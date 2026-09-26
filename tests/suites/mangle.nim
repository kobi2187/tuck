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
  t.emits "fn decl mangled",        "proc tuckˑfnˑhelper"
  t.emits "fn call site mangled",   "tuckˑfnˑhelper\\("
  t.omits "no bare fn decl",        "proc helper"
  # Idempotence: each backend lowers its own deepCopy, and a pass that
  # double-prefixed would produce tuck_tuck_helper on the second run.
  t.omits "no double prefix",       r"tuckˑ[a-z]+ˑtuckˑ"
  # Mangling is a whole-program pass that runs BEFORE either backend, so the two
  # cannot diverge by construction — but nothing said so, and the interface work
  # showed how quietly a backend can fall behind when only one is asserted.
  t.emitsOdin "Odin: fn decl mangled",      "tuckˑfnˑhelper :: proc"
  t.emitsOdin "Odin: fn call site mangled", "tuckˑfnˑhelper\\("
  t.omitsOdin "Odin: no double prefix",     r"tuckˑ[a-z]+ˑtuckˑ"

  # The whole point: a user fn named like a runtime proc must not collide.
  t.src """
fn ready() -> bool:
  return true

fn main() -> int:
  if ready:
    return 1
  return 0
"""
  t.emits "fn named 'ready' is safe",  "proc tuckˑfnˑready"
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
  t.emits "type decl and uses mangled", "tuckˑtypeˑConfig"
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
  t.omits "fields are NOT mangled",  "tuckˑvˑx"

  # PARAMS stay bare — a param name is a contract, not a free identifier: it
  # is the payload field a caller binds by name, it becomes an envelope
  # struct's field for a task or actor handler, and `self` is matched
  # literally by every backend. LOCALS carry no second meaning, so they are
  # mangled like everything else the compiler emits — `var out = ""` is legal
  # Tuck and a syntax error in Nim, and scope never protected a local from
  # the BACKEND's own names.
  t.src """
fn helper({value: int}) -> int:
  return value

fn main() -> int:
  let value = 7
  return {value: value} helper
"""
  t.emits "params stay bare",              "value: int"
  t.emits "a local IS mangled",            "tuckˑvˑvalue = 7"
  t.emits "...and its references follow",  r"helper\(tuckˑvˑvalue\)"

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
  t.omits "externs are NOT mangled", r"tuckˑ\w*readFile"
  t.omitsOdin "Odin: externs NOT mangled", "tuckˑfnˑreadFile"

  # --- every name says exactly what it is: tuckˑ<kind>ˑ<name> -------------
  #
  # With `_` between the parts, Nim — which ignores `_` and case after the
  # first letter — folded names of different kinds into one: `fn sigHandler`
  # and `fnsig Handler`, a local `typeName` and `type Name`. The separator is
  # `ˑ` now, a letter to every host and outside the ASCII a Tuck name is
  # written in (name_prefix.nim), so each pair below is two identifiers.
  t.src """
import scheduler

const LIMIT = 3

type Name:
  qty: int

object Dog:
  n: int

  fn noise() -> int:
    return self.n

actor Tally [queue: 4]:
  hits: int = 0
  on put({v: int}):
    hits += v

fnsig Handler = {x: int} -> int

pool Cells = Name [count: 2]

fn sigHandler({x: int}) -> int:
  return x

fn ready() -> bool:
  return Tally.hits > 0

task work({a: int}) -> {r: int}:
  return {r: a}

fn main() -> int [io]:
  let typeName = {qty: 4} Name
  let d = {n: 2} Dog
  let at = 1
  let xs = [1, 2, 3]
  Tally send put {v: 1}
  Tally.waitUntil {pred: :ready}
  let w = {a: 1} work
  return typeName.qty + d.noise + xs[at] + LIMIT + w.r + ({x: 0} sigHandler) - 9
"""
  t.emits "a fn is spelled as a fn",          r"proc tuckˑfnˑsigHandler\*"
  t.emits "a fnsig as a fnsig",               r"type tuckˑfnsigˑHandler\*"
  t.emits "a type as a type",                 r"type tuckˑtypeˑName\*"
  t.emits "an object as an object",           r"type tuckˑobjectˑDog\*"
  t.emits "an actor as an actor",             r"type tuckˑactorˑTally\*"
  t.emits "a task as a task",                 r"proc tuckˑtaskˑwork\*"
  t.emits "a const as a const",               r"const tuckˑconstˑLIMIT"
  t.emits "a pool as a pool",                 r"var tuckˑpoolˑCells\*"
  t.emits "a local as a local",               r"var tuckˑvˑtypeName = "
  t.emits "...even one named like an intrinsic", r"tuckˑvˑat = 1"
  t.hostRuns "names that used to fold together are distinct everywhere", 3

  t.finish()
