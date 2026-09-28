#+feature dynamic-literals
package main

TRec_a_b_op :: struct ($T_a: typeid, $T_b: typeid, $T_op: typeid) {
	a: T_a,
	b: T_b,
	op: T_op,
}

tuckˑfnsigˑBinOp :: proc (a: int, b: int) -> int

tuckˑtypeˑCtx :: struct {
	a: int,
	b: int,
	op: tuckˑfnsigˑBinOp,
}

tuckˑfnˑplus :: proc (a: int, b: int) -> int {
  return (a + b)
}

tuckˑfnˑapplyOperation :: proc (a: int, b: int, op: tuckˑfnsigˑBinOp) -> int {
  return op(a, b)
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑx := tuckˑtypeˑCtx{a = 5, b = 10}
  tuckˑvˑwithOp := TRec_a_b_op(int, int, tuckˑfnsigˑBinOp){a = tuckˑvˑx.a, b = tuckˑvˑx.b, op = tuckˑfnˑplus}
  tuckˑvˑsmaller := TRec_a_b_op(int, int, tuckˑfnsigˑBinOp){a = tuckˑvˑwithOp.a, b = 2, op = tuckˑvˑwithOp.op}
  tuckˑvˑr := tuckˑfnˑapplyOperation(tuckˑvˑsmaller.a, tuckˑvˑsmaller.b, tuckˑvˑsmaller.op)
  return
}

main :: proc() {
	tuckˑfnˑmain()
}
