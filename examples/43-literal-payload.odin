#+feature dynamic-literals
package main

import tuckˑmodˑsys "./mod_sys"

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
  tuckˑmodˑsys.exit(tuckˑvˑtotal)
}

main :: proc() {
	tuckˑfnˑmain()
}
