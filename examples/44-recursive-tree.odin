#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuckˑtypeˑExpr_Num :: struct {
	value: int,
}
tuckˑtypeˑExpr_Neg :: struct {
	operand: [dynamic]tuckˑtypeˑExpr,
}
tuckˑtypeˑExpr_Add :: struct {
	left: [dynamic]tuckˑtypeˑExpr,
	right: [dynamic]tuckˑtypeˑExpr,
}
tuckˑtypeˑExpr :: union {tuckˑtypeˑExpr_Num, tuckˑtypeˑExpr_Neg, tuckˑtypeˑExpr_Add}

tuckˑtypeˑExpr_eq :: proc(a, b: tuckˑtypeˑExpr) -> bool {
  if av, aok := a.(tuckˑtypeˑExpr_Num); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑExpr_Num)
    _ = bv
    if !bok { return false }
    if av.value != bv.value { return false }
    return true
  }
  if av, aok := a.(tuckˑtypeˑExpr_Neg); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑExpr_Neg)
    _ = bv
    if !bok { return false }
    if len(av.operand) != len(bv.operand) { return false }
    for i := 0; i < len(av.operand); i += 1 {
      if !tuckˑtypeˑExpr_eq(av.operand[i], bv.operand[i]) { return false }
    }
    return true
  }
  if av, aok := a.(tuckˑtypeˑExpr_Add); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑExpr_Add)
    _ = bv
    if !bok { return false }
    if len(av.left) != len(bv.left) { return false }
    for i := 0; i < len(av.left); i += 1 {
      if !tuckˑtypeˑExpr_eq(av.left[i], bv.left[i]) { return false }
    }
    if len(av.right) != len(bv.right) { return false }
    for i := 0; i < len(av.right); i += 1 {
      if !tuckˑtypeˑExpr_eq(av.right[i], bv.right[i]) { return false }
    }
    return true
  }
  return false
}

tuckˑfnˑeval :: proc (e: tuckˑtypeˑExpr) -> int {
  switch v in e
  {
  case tuckˑtypeˑExpr_Num: return v.value;
  case tuckˑtypeˑExpr_Neg: return (0 - tuckˑfnˑeval(rt.tuckAt(v.operand, 0)));
  case tuckˑtypeˑExpr_Add: return (tuckˑfnˑeval(rt.tuckAt(v.left, 0)) + tuckˑfnˑeval(rt.tuckAt(v.right, 0)));
  }
  return {}
}

tuckˑfnˑdepth :: proc (e: tuckˑtypeˑExpr) -> int {
  switch v in e
  {
  case tuckˑtypeˑExpr_Num: return 1;
  case tuckˑtypeˑExpr_Neg: return (1 + tuckˑfnˑdepth(rt.tuckAt(v.operand, 0)));
  case tuckˑtypeˑExpr_Add:
      tuckˑvˑl := tuckˑfnˑdepth(rt.tuckAt(v.left, 0))
      tuckˑvˑr := tuckˑfnˑdepth(rt.tuckAt(v.right, 0))
      if (tuckˑvˑl > tuckˑvˑr) {
          return (1 + tuckˑvˑl)
      }
      return (1 + tuckˑvˑr)
  }
  return {}
}

tuckˑfnˑmain :: proc () -> int {
  tuckˑvˑthree: tuckˑtypeˑExpr = tuckˑtypeˑExpr_Num{value = 3}
  tuckˑvˑfour: tuckˑtypeˑExpr = tuckˑtypeˑExpr_Num{value = 4}
  tuckˑvˑsum: tuckˑtypeˑExpr = tuckˑtypeˑExpr_Add{left = [dynamic]tuckˑtypeˑExpr{tuckˑvˑthree}, right = [dynamic]tuckˑtypeˑExpr{tuckˑvˑfour}}
  tuckˑvˑneg: tuckˑtypeˑExpr = tuckˑtypeˑExpr_Neg{operand = [dynamic]tuckˑtypeˑExpr{tuckˑvˑsum}}
  tuckˑvˑwhole: tuckˑtypeˑExpr = tuckˑtypeˑExpr_Add{left = [dynamic]tuckˑtypeˑExpr{tuckˑvˑsum}, right = [dynamic]tuckˑtypeˑExpr{tuckˑvˑneg}}
  return ((tuckˑfnˑeval(tuckˑvˑwhole) + tuckˑfnˑdepth(tuckˑvˑwhole)) - 4)
}

main :: proc() {
	mainRc := tuckˑfnˑmain()
	os.exit(mainRc)
}
