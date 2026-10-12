# compiler/lowering_combinator.nim
#
# A RECORD COMBINATOR BECOMES THE CONSTRUCTION IT MEANS.
#
#     return self with {n: self.n + 1}
#     return {n: self.n + 1, items: self.items} Counter
#
#     let track = ext alias(trackId -> id, title -> name)
#     let track = {id: ext.trackId, name: ext.title}
#
# `with`, `bake`, `alias` and `merge` all build a record out of the fields of
# their receivers (record_shape says which, in what order, and through which
# constructor). Written as a construction, each of those reads is a node of
# its own, so the ownership rules decide it like any other: copied when its
# receiver is still read, moved at its last read, a field the payload replaces
# never read at all. Left as a combinator, the receiver was one sink: a copy
# of the whole of it, whose replaced fields were then dropped on the floor,
# and which was read once per field with every read a move.
#
# ONLY PLACES. A receiver is read once per field it contributes, so it must be
# a place (`self`, `b.inner`) — reading a call's result twice would call it
# twice. A combinator with any other receiver, one that builds nothing
# (record_shape's pass-through), and a generic one stay combinators.
import ast, ast_ops, ast_query
import resolution
import lowering
import record_shape
from ownership_rules import isPlaceRead

proc fieldRead(res: Resolution, m: Module, recv: Expr, name: string): Expr =
  ## `recv.name`, a read of its own; final when the receiver's read was.
  var ft: Type = nil
  for f in getFieldsForType(res, m, res.typeFor(recv)):
    if f.name == name: ft = f.typ
  result = res.typed(Expr(span: recv.span, kind: exkField,
                          receiver: res.freshCopy(recv), fieldName: name), ft)
  fillIdsIn(result)
  if res.isLastUse(recv): res.markLastUse(result)

proc buildable(res: Resolution, m: Module, s: RecordShape): bool =
  ## Can this shape be written as a construction in the tree?
  result = true
  if s.ctor == ckPassThrough: return false
  if s.ctor == ckNamedType and (s.namedType == nil or
                                s.namedType.kind != tkNamed): return false
  for f in s.fields:
    if f.src == vsProject:
      let t = res.typeFor(f.fromExpr)
      if t == nil or not res.isPlaceRead(f.fromExpr) or
         getFieldsForType(res, m, t).len == 0:
        return false

proc asConstruction(res: Resolution, m: Module, e: Expr, s: RecordShape) =
  ## `e`, a combinator over places, rewritten in place into the construction.
  let t = res.typeFor(e)
  var payload = Expr(span: e.span, kind: exkStruct)
  for f in s.fields:
    payload.fields.add (f.name, case f.src
                                of vsExpr: f.value
                                of vsProject: res.fieldRead(m, f.fromExpr,
                                                            f.fromField))
  let id = e.id
  case s.ctor
  of ckNamedType:
    let callee = Expr(span: e.span, kind: exkVar, name: s.typeName)
    e[] = Expr(span: e.span, kind: exkCall, callee: callee, args: @[payload])[]
  of ckStructural:
    e[] = payload[]
  of ckPassThrough: return
  e.id = id
  fillIdsIn(e)
  discard res.typed(e, t)

proc lowerCombinators*(res: Resolution, m: Module) =
  ## Every record combinator whose receivers are places.
  for body in m.bodies:
    for e in body.nodes:
      if e.kind != exkCombinator or e.combArg == nil or e.combRecv == nil:
        continue
      if res.typeFor(e) == nil: continue
      let s = shapeOf(m, res, e)
      if res.buildable(m, s): res.asConstruction(m, e, s)
