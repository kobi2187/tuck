# compiler/lowering_with.nim
#
# `recv with {f: v}` BECOMES THE CONSTRUCTION IT MEANS.
#
#     return self with {n: self.n + 1}
#     return {n: self.n + 1, items: self.items} Counter
#
# A `with` rebuilds a record of the receiver's own type: the fields the
# payload names take its values, every other field is read out of the
# receiver. Written as a construction, each of those reads is a node of its
# own, so the ownership rules decide it like any other (copied when the
# receiver is still read, or only borrowed; moved at its final use), and a
# field the payload replaces is never read at all. Left as a combinator, the
# receiver was one sink: a copy of the whole of it, whose replaced fields
# were then dropped on the floor, and which no emitter but Nim's could print.
#
# ONLY A PLACE. The receiver is read once per kept field, so it must be a
# place (`self`, `b.inner`) — reading a call's result twice would call it
# twice. Anything else, a `bake` (whose result is not the receiver's type),
# and a generic receiver stay combinators (record_shape).
import ast, ast_ops, ast_query
import resolution
import lowering
from ownership_rules import isPlaceRead

proc fieldRead(res: Resolution, recv: Expr, f: FieldDef): Expr =
  ## `recv.f`, a read of its own; final when the receiver's read was.
  result = res.typed(Expr(span: recv.span, kind: exkField,
                          receiver: res.freshCopy(recv), fieldName: f.name),
                     f.typ)
  fillIdsIn(result)
  if res.isLastUse(recv): res.markLastUse(result)

proc asConstruction(res: Resolution, m: Module, e: Expr) =
  ## `e`, a `with` over a place, rewritten in place into the construction.
  let t = res.typeFor(e.combRecv)
  let fields = getFieldsForType(res, m, t)
  var payload = Expr(span: e.span, kind: exkStruct)
  for f in fields:
    var v: Expr = nil
    for (name, given) in e.combArg.fields.items:
      if name == f.name: v = given
    payload.fields.add (f.name, if v != nil: v else: res.fieldRead(e.combRecv, f))
  let callee = Expr(span: e.span, kind: exkVar, name: t.name)
  let id = e.id
  e[] = Expr(span: e.span, kind: exkCall, callee: callee, args: @[payload])[]
  e.id = id
  fillIdsIn(e)
  discard res.typed(e, t)

proc lowerWith*(res: Resolution, m: Module) =
  ## Every `with` over a place of a declared record or object type.
  for body in m.bodies:
    for e in body.nodes:
      if e.kind != exkCombinator or e.comb != ckWith or e.combArg == nil:
        continue
      let t = res.typeFor(e.combRecv)
      if t == nil or t.kind != tkNamed or not res.isPlaceRead(e.combRecv) or
         getFieldsForType(res, m, t).len == 0:
        continue
      res.asConstruction(m, e)
