#+feature dynamic-literals
package main

import sys "./mod_sys"

tuckˑfnsigˑAdder :: proc (a: int, b: int) -> int

tuckˑtypeˑCalc :: struct {
	add: tuckˑfnsigˑAdder,
}

tuckˑfnˑplus :: proc (a: int, b: int) -> int {
  return (a + b)
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑc := tuckˑtypeˑCalc{add = tuckˑfnˑplus}
  tuckˑvˑr := tuckˑvˑc.add(40, 2)
  sys.exit(tuckˑvˑr)
}

main :: proc() {
	tuckˑfnˑmain()
}
