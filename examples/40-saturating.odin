package main

import "core:os"
import rt "./tuckrt"

tuck_SafeRPM :: distinct u16

tuck_main :: proc () -> int {
  tuck_over := tuck_SafeRPM(rt.tuckSat(u16, u64(70000)))
  tuck_ok := tuck_SafeRPM(rt.tuckSat(u16, u64(1200)))
  if (tuck_over == tuck_SafeRPM(rt.tuckSat(u16, u64(65535)))) {
      if (tuck_ok == tuck_SafeRPM(rt.tuckSat(u16, u64(1200)))) {
          return 0
      }
      return 2
  }
  return 1
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
