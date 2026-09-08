#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuck_ExprNode_Num :: struct {
	value: int,
}
tuck_ExprNode_Add :: struct {
	left: int,
	right: int,
}
tuck_ExprNode :: union {tuck_ExprNode_Num, tuck_ExprNode_Add}

tuck_Expr :: struct {
	slots: [dynamic]tuck_ExprNode,
	root: int,
}

tuck_mkNum :: proc (value: int) -> tuck_Expr {
  return tuck_Expr{slots = [dynamic]tuck_ExprNode{tuck_ExprNode_Num{value = value}}, root = 0}
}

tuck_shift :: proc (n: tuck_ExprNode, by: int) -> tuck_ExprNode {
  switch v in n
  {
  case tuck_ExprNode_Num: return n;
  case tuck_ExprNode_Add: return tuck_ExprNode_Add{left = (v.left + by), right = (v.right + by)};
  }
  return {}
}

tuck_mkAdd :: proc (left: tuck_Expr, right: tuck_Expr) -> tuck_Expr {
  tuck_slots := rt.tuckSeqCopy(left.slots)
  tuck_off := 0
  for tuck_s in right.slots {
      tuck_slots = rt.push(tuck_slots, tuck_shift(tuck_s, 0))
  }
  return tuck_Expr{slots = tuck_slots, root = 0}
}

tuck_main :: proc () -> int {
  tuck_a := tuck_mkNum(3); tuck_a.slots = rt.tuckSeqCopy(tuck_a.slots)
  return (rt.tuckAt(tuck_a.slots, tuck_a.root).(tuck_ExprNode_Num).value - 3)
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
