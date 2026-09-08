{.experimental: "codeReordering".}
import ../../../compiler/tuck_rt

type tuck_ExprNodeKind* = enum Num, Add
type tuck_ExprNode* = object
  case kind*: tuck_ExprNodeKind
  of Num: tuck_num*: tuple[value: int]
  of Add: tuck_add*: tuple[left: int, right: int]

type tuck_Expr* = object
  slots*: seq[tuck_ExprNode]
  root*: int

proc tuck_mkNum*(value: int): tuck_Expr =
  return tuck_Expr(slots: @[tuck_ExprNode(kind: Num, tuck_num: (value: value))], root: 0)

proc tuck_shift*(n: tuck_ExprNode, by: int): tuck_ExprNode =
  (case n.kind
  of Num:
    return n
  of Add:
    return tuck_ExprNode(kind: Add, tuck_add: (left: (n.tuck_add.left + by), right: (n.tuck_add.right + by))))

proc tuck_mkAdd*(left: tuck_Expr, right: tuck_Expr): tuck_Expr =
  var tuck_slots = left.slots
  var tuck_off = 0
  for tuck_s in right.slots:
    if true:
      tuck_slots = push(tuck_slots, tuck_shift(tuck_s, 0))
  return tuck_Expr(slots: tuck_slots, root: 0)

proc tuck_main*(): int =
  var tuck_a = tuck_mkNum(3)
  return (tuckAt(tuck_a.slots, tuck_a.root).tuck_num.value - 3)


when isMainModule:
  quit(tuck_main())
