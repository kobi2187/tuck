## Interface dispatch, end to end (spec §5.3).
##
## An interface value is two words: a reference to the data and a reference to
## that concrete type's function table. Both are filled where the compiler still
## knows the concrete type — at the wrap site — so nothing is resolved at run
## time. No object header, no runtime type, no hierarchy, no name lookup.
##
## The tables are emitted on DEMAND: only the (object, interface) pairs some
## wrap site actually asked for. A `satisfies` nobody passes as costs the
## conformance check and nothing else.

import ../harness

proc run*(t: var T) =
  # --- the shape of the emission --------------------------------------------

  t.src """
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  satisfies Animal
  name: str

  fn noise({self: Dog}) -> int:
    return 1

fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  return {a: d} hear
"""
  t.okCheck "the program checks"
  t.emits "a tag enum for the interface",       "AnimalTag"
  t.emits "the value is a variant over its types", "case tag"
  t.emits "the payload is the object itself",   "tuckˑobjectˑDogVal"
  t.emits "dispatch is a case on the tag",      "case .*\\.tag"
  t.omits "no function table",                  "AnimalVT"
  t.omits "no thunks",                          "Animal_tuckˑobjectˑDogˑnoise"
  t.runs  "and the program runs",               1

  # Both backends, or it is not a feature. The parity commitment is explicit in
  # codegen.nim's header: share the logic, never share the syntax.
  t.emitsOdin "Odin: a tag enum",          "AnimalTag"
  t.emitsOdin "Odin: a variant struct",    "tag: AnimalTag"
  t.emitsOdin "Odin: dispatch switches",   "switch v\\.tag"
  t.omitsOdin "Odin: no function table",   "AnimalVT"

  # --- dispatch actually selects per object ---------------------------------

  # 1 + 41 = 42, reachable only if each element carried its own table. Either
  # impl alone gives 2 or 82.
  t.src """
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  satisfies Animal
  name: str
  fn noise({self: Dog}) -> int:
    return 1

object Cat:
  satisfies Animal
  lives: int
  fn noise({self: Cat}) -> int:
    return 41

fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return ({a: d} hear) + ({a: c} hear)
"""
  t.okCheck "two objects, one interface parameter"
  t.runs     "each dispatches to its own implementation",  42
  t.emits    "a branch for Dog",  "Animal_is_tuckˑobjectˑDog"
  t.emits    "a branch for Cat",  "Animal_is_tuckˑobjectˑCat"

  # Every satisfying type is a branch of the variant, whether or not a program
  # wraps one — the type has to hold any of them. That replaces the old
  # demand-driven table emission, which existed because a table per (object,
  # interface) pair was only needed where a wrap actually happened.
  t.src """
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  satisfies Animal
  name: str
  fn noise({self: Dog}) -> int:
    return 1

object Ghost:
  satisfies Animal
  n: int
  fn noise({self: Ghost}) -> int:
    return 99

fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  return {a: d} hear
"""
  t.okCheck "an object may satisfy without ever being wrapped"
  t.emits    "it is still a branch of the variant",  "tuckˑobjectˑGhostVal"
  t.runs     "and the program runs",                 1

  # A method with payload beyond `self` must splat that payload positionally
  # at the call site, matching the concrete implementer's exploded params —
  # not pack it into one Nim tuple, which the implementer never declared.
  t.src """
import console

interface Codec:
  fn encode({self: Self, key: str, val: str}) -> str

object A:
  satisfies Codec
  n: int
  fn encode({self: A, key: str, val: str}) -> str:
    return key + "=" + val

object B:
  satisfies Codec
  n: int
  fn encode({self: B, key: str, val: str}) -> str:
    return key + ":" + val

fn run({c: Codec, key: str, val: str}) -> str:
  return c.encode {key: key, val: val}

fn main() -> int:
  var a = {n: 1} A
  let line1 = {c: a, key: "k", val: "v"} run
  {text: line1} printLine
  return 0
"""
  t.okCheck  "interface method with payload beyond self checks"
  t.omits    "payload is not packed into one tuple", "encode\\(tmp, \\(key:"
  t.emits    "payload is splatted positionally",     "encode\\(tmp, key, val\\)"
  t.outputs  "and dispatches correctly with the right args", "k=v"

  # --- lowered once, printed three ways (ROADMAP M4.4) ----------------------
  # #40: Odin's dispatch closure was typed `-> int` whatever the member
  # returned, so a member returning `str` did not compile on Odin alone. The
  # call is lowered to an exkIfaceCall carrying its own type.
  t.src """
interface Animal:
  fn name({self: Self}) -> str

object Dog:
  satisfies Animal
  tag: str

  fn name({self: Dog}) -> str:
    return self.tag

fn hear({a: Animal}) -> int:
  return a.name.len

fn main() -> int:
  var d = {tag: "rex"} Dog
  return {a: d} hear
"""
  t.hostRuns "a member returning str dispatches on every backend (#40)", 3
  # A void member, with a param, as a statement: the closure has no result
  # and each arm passes the payload's field positionally.
  t.src """
import console

interface Speaker:
  fn speak({self: Self, times: int}) -> void [io]

object Dog:
  satisfies Speaker
  name: str

  fn speak({self: Dog, times: int}) -> void [io]:
    for i in 0 ..< times:
      {text: self.name} console::printLine

fn talk({s: Speaker}) -> void [io]:
  s.speak {times: 2}

fn main() -> int [io]:
  var d = {name: "rex"} Dog
  {s: d} talk
  return 0
"""
  t.hostRuns "a void member with a param dispatches as a statement", 0, "rex\nrex"

  # A TOP-LEVEL `satisfies Obj: Iface` is folded into the object's own list
  # before conformance (typecheck_conformance.applySatisfiesDecls), so each
  # backend's satisfier set already includes it and there is nothing left
  # to emit. D refused the declaration outright ("top-level satisfies (M4)")
  # while Nim and Odin built and ran the same program.
  t.src """
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  name: str
  fn noise({self: Dog}) -> int:
    return 4

satisfies Dog: Animal

fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  return {a: d} hear
"""
  t.hostRuns "a top-level satisfies dispatches on every backend", 4

  t.finish()
