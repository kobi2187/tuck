#+feature dynamic-literals
package main

import sys "./mod_sys"

tuckˑfnˑdouble :: proc (value: int) -> int {
  return (value * 2)
}

tuckˑfnˑaddTen :: proc (value: int) -> int {
  return (value + 10)
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑa := tuckˑfnˑdouble(5)
  tuckˑvˑb := tuckˑfnˑaddTen(tuckˑfnˑdouble(10))
  tuckˑvˑtotal := (tuckˑvˑa + tuckˑvˑb)
  sys.exit(tuckˑvˑtotal)
}

main :: proc() {
	tuckˑfnˑmain()
}
