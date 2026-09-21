#+feature dynamic-literals
package main

TRec_a_b_op :: struct ($T_a: typeid, $T_b: typeid, $T_op: typeid) {
	a: T_a,
	b: T_b,
	op: T_op,
}

tuck_BinOp :: proc (a: int, b: int) -> int

tuck_Ctx :: struct {
	a: int,
	b: int,
	op: tuck_BinOp,
}

tuck_plus :: proc (a: int, b: int) -> int {
  return (a + b)
}

tuck_applyOperation :: proc (a: int, b: int, op: tuck_BinOp) -> int {
  return op(a, b)
}

tuck_main :: proc () {
  tuck_x := tuck_Ctx{a = 5, b = 10}
  tuck_withOp := TRec_a_b_op(int, int, tuck_BinOp){a = tuck_x.a, b = tuck_x.b, op = tuck_plus}
  tuck_smaller := TRec_a_b_op(int, int, tuck_BinOp){a = tuck_withOp.a, b = 2, op = tuck_withOp.op}
  tuck_r := tuck_applyOperation(tuck_smaller.a, tuck_smaller.b, tuck_smaller.op)
  return
}

main :: proc() {
	tuck_main()
}
