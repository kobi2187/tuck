# compiler/lowering_saturating.nim
#
# A `[saturating]` VALUE IS CLAMPED WHERE IT IS STORED (spec 4.1, audit Y8).
#
#     type SafeRPM = u16 [saturating]
#     let a = 60000 SafeRPM
#     let r = a + a            # 65535, not 54464
#
# The spec: "`[saturating]` clamps where a value is stored — construction,
# `let`/`var` init, field mutation — against a wider intermediate", so
# `a + b - c` of three 60000s is 60000 and a transient overshoot never
# corrupts a result. Only the construction (`70000 SafeRPM`) clamped: a `let`
# of a chain wrapped on Nim and Odin, and D did not build it at all.
#
# This pass marks each `+ - *` chain whose value is stored into a saturating
# type (`satStores`); each emitter then computes that chain on a 64-bit
# intermediate which itself saturates (`tuckArith` with the Sat policy) and
# clamps the result to the type once (`tuckSatI`). Exact for every base
# narrower than 64 bits, as the spec promises for u8/u16/u32. A 64-bit base
# has no wider intermediate (the spec's stated ceiling) and is left as it is.
#
# A chain that is NOT stored — compared, passed, returned — is not a site the
# spec names, and is left as it was; that is recorded for a ruling.
import strutils, tables
import ast, ast_ops, ast_query
import resolution

const WideBases = ["u64", "i64", "int", "usize"]
  ## Bases with no wider intermediate: the spec's ceiling.

proc satBaseOf(m: Module, real: ModuleMap, t: Type): string =
  ## The base integer of `t` when it is a `[saturating]` type narrower than 64
  ## bits, here or in an import, else "".
  if t == nil or t.kind != tkNamed: return ""
  let name = t.name.split("::")[^1]
  var base = declSaturatingType(m.findDecl(dkType, name))
  if base == nil:
    for _, other in real:
      base = declSaturatingType(other.findDecl(dkType, name))
      if base != nil: break
  if base == nil or base.kind != tkNamed or base.name in WideBases: return ""
  base.name

proc isChain(e: Expr): bool =
  e != nil and e.kind == exkBinary and e.binOp in {boAdd, boSub, boMul}

proc markStored(res: Resolution, m: Module, real: ModuleMap, v: Expr) =
  ## `v` is stored: marked when it is a chain of a saturating type.
  if not isChain(v): return
  let base = satBaseOf(m, real, res.typeFor(v))
  if base != "": res.markSatStore(v, base)

proc isConstruction(res: Resolution, call: Expr): bool =
  ## Is `call` a type's construction (`70000 SafeRPM`, `{rpm: r} Engine`)?
  ## A construction's type is the type its callee names.
  if call.callee == nil or call.callee.kind != exkVar: return false
  let t = res.typeFor(call)
  t != nil and t.kind == tkNamed and
    t.name.split("::")[^1] == call.callee.name.split("::")[^1]

proc markConstruction(res: Resolution, m: Module, real: ModuleMap, call: Expr) =
  ## The value a construction stores: its argument, or each field of a
  ## record literal.
  if not res.isConstruction(call): return
  for a in call.args:
    if a.kind == exkStruct:
      for f in a.fields: res.markStored(m, real, f.value)
    else:
      res.markStored(m, real, a)

proc lowerSaturatingStores*(res: Resolution, m: Module, real: ModuleMap) =
  ## Every store in this backend's copy of the module (see the header).
  for body in m.bodies:
    for n in nodes(body):
      case n.kind
      of exkAssign: res.markStored(m, real, n.assignVal)
      of exkBracketAssign: res.markStored(m, real, n.brValue)
      of exkCall: res.markConstruction(m, real, n)
      else: discard
