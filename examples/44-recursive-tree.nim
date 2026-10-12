{.experimental: "codeReordering".}
import "../compiler/tuck_rt"

proc `==`*(a, b: tuckˑtypeˑExpr): bool {.noSideEffect.}
proc tuckDrop*(x: var tuckˑtypeˑExpr)

proc tuckˑfnˑeval*(e: tuckˑtypeˑExpr): int
proc tuckˑfnˑdepth*(e: tuckˑtypeˑExpr): int
proc tuckˑfnˑmain*(): int

type
  tuckˑtypeˑExprKind* = enum Num, Neg, Add
  tuckˑtypeˑExpr_Num* = object
    value*: int
  tuckˑtypeˑExpr_Neg* = object
    operand*: seq[tuckˑtypeˑExpr]
  tuckˑtypeˑExpr_Add* = object
    left*: seq[tuckˑtypeˑExpr]
    right*: seq[tuckˑtypeˑExpr]
  tuckˑtypeˑExpr* = object
    case kind*: tuckˑtypeˑExprKind
    of Num: tuckˑvariantˑnum*: tuckˑtypeˑExpr_Num
    of Neg: tuckˑvariantˑneg*: tuckˑtypeˑExpr_Neg
    of Add: tuckˑvariantˑadd*: tuckˑtypeˑExpr_Add

proc `==`*(a, b: tuckˑtypeˑExpr): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Num: a.tuckˑvariantˑnum == b.tuckˑvariantˑnum
  of Neg: a.tuckˑvariantˑneg == b.tuckˑvariantˑneg
  of Add: a.tuckˑvariantˑadd == b.tuckˑvariantˑadd

proc tuckDrop*(x: var tuckˑtypeˑExpr) =
  case x.kind
  of Num: tuckDrop(x.tuckˑvariantˑnum)
  of Neg: tuckDrop(x.tuckˑvariantˑneg)
  of Add: tuckDrop(x.tuckˑvariantˑadd)

proc tuckˑfnˑeval*(e: tuckˑtypeˑExpr): int =
  (case e.kind
  of Num:
    return e.tuckˑvariantˑnum.value
  of Neg:
    return (0 - tuckˑfnˑeval(tuck_rt.tuckAt(e.tuckˑvariantˑneg.operand, 0)))
  of Add:
    return (tuckˑfnˑeval(tuck_rt.tuckAt(e.tuckˑvariantˑadd.left, 0)) + tuckˑfnˑeval(tuck_rt.tuckAt(e.tuckˑvariantˑadd.right, 0))))

proc tuckˑfnˑdepth*(e: tuckˑtypeˑExpr): int =
  (case e.kind
  of Num:
    return 1
  of Neg:
    return (1 + tuckˑfnˑdepth(tuck_rt.tuckAt(e.tuckˑvariantˑneg.operand, 0)))
  of Add:
    if true:
      var tuckˑvˑl = tuckˑfnˑdepth(tuck_rt.tuckAt(e.tuckˑvariantˑadd.left, 0))
      var tuckˑvˑr = tuckˑfnˑdepth(tuck_rt.tuckAt(e.tuckˑvariantˑadd.right, 0))
      if (tuckˑvˑl > tuckˑvˑr):
        if true:
          return (1 + tuckˑvˑl)
      return (1 + tuckˑvˑr))

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑthree = tuckˑtypeˑExpr(kind: Num, tuckˑvariantˑnum: tuckˑtypeˑExpr_Num(value: 3))
  var tuckˑvˑfour = tuckˑtypeˑExpr(kind: Num, tuckˑvariantˑnum: tuckˑtypeˑExpr_Num(value: 4))
  var tuckˑvˑsum = tuckˑtypeˑExpr(kind: Add, tuckˑvariantˑadd: tuckˑtypeˑExpr_Add(left: @[tuckMove(tuckˑvˑthree)], right: @[tuckMove(tuckˑvˑfour)]))
  var tuckˑvˑneg = tuckˑtypeˑExpr(kind: Neg, tuckˑvariantˑneg: tuckˑtypeˑExpr_Neg(operand: @[tuckCopy(tuckˑvˑsum)]))
  var tuckˑvˑwhole = tuckˑtypeˑExpr(kind: Add, tuckˑvariantˑadd: tuckˑtypeˑExpr_Add(left: @[tuckMove(tuckˑvˑsum)], right: @[tuckMove(tuckˑvˑneg)]))
  defer: tuckDrop(tuckˑvˑwhole)
  return ((tuckˑfnˑeval(tuckˑvˑwhole) + tuckˑfnˑdepth(tuckˑvˑwhole)) - 4)

