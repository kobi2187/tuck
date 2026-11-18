#+feature dynamic-literals
package main

import rt "./tuckrt"
import tuckˑmodˑsys "./mod_sys"

tuckˑfnˑmain :: proc () {
  tuckˑvˑq := rt.tuckDivI(int(7), int(2), "int")
  tuckˑvˑr := (7.0 / 2.0)
  tuckˑvˑbudget := 100
  tuckˑvˑbudget = rt.tuckDivI(int(tuckˑvˑbudget), int(8), "int")
  if (tuckˑvˑq == 3) {
      if (tuckˑvˑbudget == 12) {
          if (tuckˑvˑr > 3.4) {
              tuckˑmodˑsys.exit(0)
          }
      }
  }
  tuckˑmodˑsys.exit(1)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
