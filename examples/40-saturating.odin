#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuckˑtypeˑSafeRPM :: distinct u16

tuckˑfnˑmain :: proc () -> int {
  tuckˑvˑover := tuckˑtypeˑSafeRPM(rt.tuckSat(u16, u64(70000)))
  tuckˑvˑok := tuckˑtypeˑSafeRPM(rt.tuckSat(u16, u64(1200)))
  if (tuckˑvˑover == tuckˑtypeˑSafeRPM(rt.tuckSat(u16, u64(65535)))) {
      if (tuckˑvˑok == tuckˑtypeˑSafeRPM(rt.tuckSat(u16, u64(1200)))) {
          return 0
      }
      return 2
  }
  return 1
}

main :: proc() {
	mainRc := tuckˑfnˑmain()
	os.exit(mainRc)
}
