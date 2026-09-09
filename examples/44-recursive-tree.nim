{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc `==`*(a, b: tuck_Expr): bool {.noSideEffect.}

proc tuck_eval*(e: tuck_Expr): int
proc tuck_depth*(e: tuck_Expr): int
proc tuck_main*(): int

type tuck_ExprKind* = enum Num, Neg, Add
type tuck_Expr* = object
  case kind*: tuck_ExprKind
  of Num: tuck_num*: tuple[value: int]
  of Neg: tuck_neg*: tuple[operand: seq[tuck_Expr]]
  of Add: tuck_add*: tuple[left: seq[tuck_Expr], right: seq[tuck_Expr]]

proc `==`*(a, b: tuck_Expr): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Num: a.tuck_num == b.tuck_num
  of Neg: a.tuck_neg == b.tuck_neg
  of Add: a.tuck_add == b.tuck_add

proc tuck_eval*(e: tuck_Expr): int =
  (case e.kind
  of Num:
    return e.tuck_num.value
  of Neg:
    return (0 - tuck_eval(tuckAt(e.tuck_neg.operand, 0)))
  of Add:
    return (tuck_eval(tuckAt(e.tuck_add.left, 0)) + tuck_eval(tuckAt(e.tuck_add.right, 0))))

proc tuck_depth*(e: tuck_Expr): int =
  (case e.kind
  of Num:
    return 1
  of Neg:
    return (1 + tuck_depth(tuckAt(e.tuck_neg.operand, 0)))
  of Add:
    if true:
      var tuck_l = tuck_depth(tuckAt(e.tuck_add.left, 0))
      var tuck_r = tuck_depth(tuckAt(e.tuck_add.right, 0))
      if (tuck_l > tuck_r):
        if true:
          return (1 + tuck_l)
      return (1 + tuck_r))

proc tuck_main*(): int =
  var tuck_three = tuck_Expr(kind: Num, tuck_num: (value: 3))
  var tuck_four = tuck_Expr(kind: Num, tuck_num: (value: 4))
  var tuck_sum = tuck_Expr(kind: Add, tuck_add: (left: @[tuck_three], right: @[tuck_four]))
  var tuck_neg = tuck_Expr(kind: Neg, tuck_neg: (operand: @[tuck_sum]))
  var tuck_whole = tuck_Expr(kind: Add, tuck_add: (left: @[tuck_sum], right: @[tuck_neg]))
  return ((tuck_eval(tuck_whole) + tuck_depth(tuck_whole)) - 4)

