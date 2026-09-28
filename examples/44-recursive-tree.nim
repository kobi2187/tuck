{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc `==`*(a, b: tuckˑtypeˑExpr): bool {.noSideEffect.}

proc tuckˑfnˑeval*(e: sink tuckˑtypeˑExpr): int
proc tuckˑfnˑdepth*(e: sink tuckˑtypeˑExpr): int
proc tuckˑfnˑmain*(): int

type tuckˑtypeˑExprKind* = enum Num, Neg, Add
type tuckˑtypeˑExpr* = object
  case kind*: tuckˑtypeˑExprKind
  of Num: tuckˑvariantˑnum*: tuple[value: int]
  of Neg: tuckˑvariantˑneg*: tuple[operand: seq[tuckˑtypeˑExpr]]
  of Add: tuckˑvariantˑadd*: tuple[left: seq[tuckˑtypeˑExpr], right: seq[tuckˑtypeˑExpr]]

proc `==`*(a, b: tuckˑtypeˑExpr): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Num: a.tuckˑvariantˑnum == b.tuckˑvariantˑnum
  of Neg: a.tuckˑvariantˑneg == b.tuckˑvariantˑneg
  of Add: a.tuckˑvariantˑadd == b.tuckˑvariantˑadd

proc tuckˑfnˑeval*(e: sink tuckˑtypeˑExpr): int =
  (case e.kind
  of Num:
    return e.tuckˑvariantˑnum.value
  of Neg:
    return (0 - tuckˑfnˑeval(tuck_rt.tuckAt(e.tuckˑvariantˑneg.operand, 0)))
  of Add:
    return (tuckˑfnˑeval(tuck_rt.tuckAt(e.tuckˑvariantˑadd.left, 0)) + tuckˑfnˑeval(tuck_rt.tuckAt(e.tuckˑvariantˑadd.right, 0))))

proc tuckˑfnˑdepth*(e: sink tuckˑtypeˑExpr): int =
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
  var tuckˑvˑthree = tuckˑtypeˑExpr(kind: Num, tuckˑvariantˑnum: (value: 3))
  var tuckˑvˑfour = tuckˑtypeˑExpr(kind: Num, tuckˑvariantˑnum: (value: 4))
  var tuckˑvˑsum = tuckˑtypeˑExpr(kind: Add, tuckˑvariantˑadd: (left: @[tuckˑvˑthree], right: @[tuckˑvˑfour]))
  var tuckˑvˑneg = tuckˑtypeˑExpr(kind: Neg, tuckˑvariantˑneg: (operand: @[tuckˑvˑsum]))
  var tuckˑvˑwhole = tuckˑtypeˑExpr(kind: Add, tuckˑvariantˑadd: (left: @[tuckˑvˑsum], right: @[tuckˑvˑneg]))
  return ((tuckˑfnˑeval(tuckˑvˑwhole) + tuckˑfnˑdepth(tuckˑvˑwhole)) - 4)

