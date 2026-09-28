#+feature dynamic-literals
package main

import sys "./mod_sys"
import console "./mod_console"
foreign import z "system:z"
import shim "./shim"

zlibVersion :: proc() -> string {
	return shim.zlibVersion()
}


@(default_calling_convention="c")
foreign z {
	compressBound :: proc(sourceLen: u64) -> u64 ---
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑv := zlibVersion()
  console.printLine(tuckˑvˑv)
  tuckˑvˑb := compressBound(u64(1000))
  if (tuckˑvˑb == 1013) {
      sys.exit(0)
  }
  sys.exit(1)
}

main :: proc() {
	tuckˑfnˑmain()
}
