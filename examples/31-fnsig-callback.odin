#+feature dynamic-literals
package main

import rt "./tuckrt"
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
  defer rt.tuckDrop(tuckˑvˑc.add)
  tuckˑvˑr := tuckˑvˑc.add(40, 2)
  sys.exit(tuckˑvˑr)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
