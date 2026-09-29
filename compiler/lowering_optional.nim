# compiler/lowering_optional.nim
#
# A `?T` PLACE THAT IS GIVEN A PLAIN `T` (R8, ruled 2026-09-28).
#
#     actor Box:
#       last: int?              # no initialiser: starts absent
#       on put({v: int}):
#         last = v              # an int stored into an int?
#
# Every actor field has an initialiser or is `T?` (TK-TY35). Two things made
# the `T?` half of that rule unusable, on every backend:
#
# - a plain `T` assigned into a `?T` place was emitted bare, and each host
#   refused `int` where its result carrier was expected. A `return` has
#   always been wrapped (each backend's genReturn); an assignment never was.
#   It is now an exkWrapOk around the value.
# - a `T?` field with no initialiser started at the carrier's ZERO value,
#   and the status enum's first member is Ok, so it started present,
#   holding zero. It now starts as an exkAbsent.
#
# The checker already accepted both, and still decides what is legal; this
# only prints what it accepted.
import ast, ast_ops, ast_query
import resolution

proc optOf(res: Resolution, t: Type, inner: Type, e: Expr,
           kind: ExprKind): Expr =
  ## A `?T` node of `kind` holding `e` (nil when absent), typed `t`.
  result = if kind == exkWrapOk:
             Expr(span: e.span, kind: exkWrapOk, optValue: e, optInner: inner)
           else:
             Expr(span: t.span, kind: exkAbsent, optInner: inner)
  discard res.typed(result, t)

proc wrapIfPlain(res: Resolution, place: Type, v: Expr): Expr =
  ## `v` as the `?T` that `place` holds: wrapped when it is a plain `T`,
  ## untouched when it is already a carrier (or its type is unknown).
  if v == nil or not absenceIsDeclared(place): return v
  let vt = res.typeFor(v)
  if vt == nil or isWrappedType(vt) or v.kind in {exkWrapOk, exkAbsent}:
    return v
  res.optOf(place, place.args[0], v, exkWrapOk)

proc lowerAssigns(res: Resolution, body: Expr) =
  ## Every assignment in `body` whose target is a `?T` place.
  for n in nodes(body):
    if n.kind == exkAssign and n.target != nil:
      n.assignVal = res.wrapIfPlain(res.typeFor(n.target), n.assignVal)

proc lowerMarkedValues(res: Resolution, body: Expr) =
  ## Every payload field, construction field and positional argument the
  ## checker accepted as a plain `T` into a `?T` place (optWraps).
  for n in nodes(body):
    if n.kind == exkStruct:
      for f in n.fields.mitems:
        f.value = res.wrapIfPlain(res.optWrapOf(f.value), f.value)
    elif n.kind == exkCall:
      for a in n.args.mitems:
        a = res.wrapIfPlain(res.optWrapOf(a), a)

proc lowerActorFields(res: Resolution, d: Decl) =
  ## A `T?` field starts absent, or holds its initialiser wrapped.
  for f in d.actorFields.mitems:
    if not absenceIsDeclared(f.typ): continue
    f.default = if f.default == nil: res.optOf(f.typ, f.typ.args[0], nil, exkAbsent)
                else: res.wrapIfPlain(f.typ, f.default)

proc lowerOptionals*(res: Resolution, m: Module) =
  ## Every body and actor field of this backend's copy of the module.
  for body in m.bodies:
    res.lowerAssigns(body)
    res.lowerMarkedValues(body)
  for d in m.allDecls:
    if d.kind == dkActor: res.lowerActorFields(d)
