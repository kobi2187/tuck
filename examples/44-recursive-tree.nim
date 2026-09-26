{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc `==`*(a, b: tuck_type_Expr): bool {.noSideEffect.}

proc tuck_fn_eval*(e: sink tuck_type_Expr): int
proc tuck_fn_depth*(e: sink tuck_type_Expr): int
proc tuck_fn_main*(): int

type tuck_type_ExprKind* = enum Num, Neg, Add
type tuck_type_Expr* = object
  case kind*: tuck_type_ExprKind
  of Num: tuck_num*: tuple[value: int]
  of Neg: tuck_neg*: tuple[operand: seq[tuck_type_Expr]]
  of Add: tuck_add*: tuple[left: seq[tuck_type_Expr], right: seq[tuck_type_Expr]]

proc `==`*(a, b: tuck_type_Expr): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Num: a.tuck_num == b.tuck_num
  of Neg: a.tuck_neg == b.tuck_neg
  of Add: a.tuck_add == b.tuck_add

proc tuck_fn_eval*(e: sink tuck_type_Expr): int =
  (case e.kind
  of Num:
    return e.tuck_num.value
  of Neg:
    return (0 - tuck_fn_eval(tuck_rt.tuckAt(e.tuck_neg.operand, 0)))
  of Add:
    return (tuck_fn_eval(tuck_rt.tuckAt(e.tuck_add.left, 0)) + tuck_fn_eval(tuck_rt.tuckAt(e.tuck_add.right, 0))))

proc tuck_fn_depth*(e: sink tuck_type_Expr): int =
  (case e.kind
  of Num:
    return 1
  of Neg:
    return (1 + tuck_fn_depth(tuck_rt.tuckAt(e.tuck_neg.operand, 0)))
  of Add:
    if true:
      var tuck_l = tuck_fn_depth(tuck_rt.tuckAt(e.tuck_add.left, 0))
      var tuck_r = tuck_fn_depth(tuck_rt.tuckAt(e.tuck_add.right, 0))
      if (tuck_l > tuck_r):
        if true:
          return (1 + tuck_l)
      return (1 + tuck_r))

proc tuck_fn_main*(): int =
  var tuck_three = tuck_type_Expr(kind: Num, tuck_num: (value: 3))
  var tuck_four = tuck_type_Expr(kind: Num, tuck_num: (value: 4))
  var tuck_sum = tuck_type_Expr(kind: Add, tuck_add: (left: @[tuck_three], right: @[tuck_four]))
  var tuck_neg = tuck_type_Expr(kind: Neg, tuck_neg: (operand: @[tuck_sum]))
  var tuck_whole = tuck_type_Expr(kind: Add, tuck_add: (left: @[tuck_sum], right: @[tuck_neg]))
  return ((tuck_fn_eval(tuck_whole) + tuck_fn_depth(tuck_whole)) - 4)

