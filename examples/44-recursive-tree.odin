#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuck_Expr_Num :: struct {
	value: int,
}
tuck_Expr_Neg :: struct {
	operand: [dynamic]tuck_Expr,
}
tuck_Expr_Add :: struct {
	left: [dynamic]tuck_Expr,
	right: [dynamic]tuck_Expr,
}
tuck_Expr :: union {tuck_Expr_Num, tuck_Expr_Neg, tuck_Expr_Add}

tuck_Expr_eq :: proc(a, b: tuck_Expr) -> bool {
  if av, aok := a.(tuck_Expr_Num); aok {
    _ = av
    bv, bok := b.(tuck_Expr_Num)
    _ = bv
    if !bok { return false }
    if av.value != bv.value { return false }
    return true
  }
  if av, aok := a.(tuck_Expr_Neg); aok {
    _ = av
    bv, bok := b.(tuck_Expr_Neg)
    _ = bv
    if !bok { return false }
    if len(av.operand) != len(bv.operand) { return false }
    for i := 0; i < len(av.operand); i += 1 {
      if !tuck_Expr_eq(av.operand[i], bv.operand[i]) { return false }
    }
    return true
  }
  if av, aok := a.(tuck_Expr_Add); aok {
    _ = av
    bv, bok := b.(tuck_Expr_Add)
    _ = bv
    if !bok { return false }
    if len(av.left) != len(bv.left) { return false }
    for i := 0; i < len(av.left); i += 1 {
      if !tuck_Expr_eq(av.left[i], bv.left[i]) { return false }
    }
    if len(av.right) != len(bv.right) { return false }
    for i := 0; i < len(av.right); i += 1 {
      if !tuck_Expr_eq(av.right[i], bv.right[i]) { return false }
    }
    return true
  }
  return false
}

tuck_eval :: proc (e: tuck_Expr) -> int {
  switch v in e
  {
  case tuck_Expr_Num: return v.value;
  case tuck_Expr_Neg: return (0 - tuck_eval(rt.tuckAt(v.operand, 0)));
  case tuck_Expr_Add: return (tuck_eval(rt.tuckAt(v.left, 0)) + tuck_eval(rt.tuckAt(v.right, 0)));
  }
  return {}
}

tuck_depth :: proc (e: tuck_Expr) -> int {
  switch v in e
  {
  case tuck_Expr_Num: return 1;
  case tuck_Expr_Neg: return (1 + tuck_depth(rt.tuckAt(v.operand, 0)));
  case tuck_Expr_Add:
      tuck_l := tuck_depth(rt.tuckAt(v.left, 0))
      tuck_r := tuck_depth(rt.tuckAt(v.right, 0))
      if (tuck_l > tuck_r) {
          return (1 + tuck_l)
      }
      return (1 + tuck_r)
  }
  return {}
}

tuck_main :: proc () -> int {
  tuck_three: tuck_Expr = tuck_Expr_Num{value = 3}
  tuck_four: tuck_Expr = tuck_Expr_Num{value = 4}
  tuck_sum: tuck_Expr = tuck_Expr_Add{left = [dynamic]tuck_Expr{tuck_three}, right = [dynamic]tuck_Expr{tuck_four}}
  tuck_neg: tuck_Expr = tuck_Expr_Neg{operand = [dynamic]tuck_Expr{tuck_sum}}
  tuck_whole: tuck_Expr = tuck_Expr_Add{left = [dynamic]tuck_Expr{tuck_sum}, right = [dynamic]tuck_Expr{tuck_neg}}
  return ((tuck_eval(tuck_whole) + tuck_depth(tuck_whole)) - 4)
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
