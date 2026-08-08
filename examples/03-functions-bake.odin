package main

TRec_a_b_643C :: struct {
	a: int,
	b: int,
}

TRec_a_b_op_2344 :: struct {
	a: int,
	b: int,
	op: proc(int, int) -> int,
}

tuck_BinOp :: proc (a: int, b: int) -> int

tuck_plus :: proc (a: int, b: int) -> int {
  return (a + b)
}

tuck_applyOperation :: proc (a: int, b: int, op: tuck_BinOp) -> int {
  return op(a, b)
}

tuck_main :: proc () {
  x := TRec_a_b_643C{a = 5, b = 10}
  withOp := TRec_a_b_op_2344{a = x.a, b = x.b, op = tuck_plus}
  smaller := TRec_a_b_op_2344{a = withOp.a, b = 2, op = withOp.op}
  r := tuck_applyOperation(smaller.a, smaller.b, smaller.op)
  return
}

main :: proc() {
	tuck_main()
}
