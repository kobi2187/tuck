#+feature dynamic-literals
package main

import rt "./tuckrt"
import tuckˑmodˑconsole "./mod_console"
import tuckˑmodˑsys "./mod_sys"
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
  defer rt.tuckDrop(tuckˑvˑv)
  tuckˑmodˑconsole.printLine(tuckˑvˑv)
  tuckˑvˑb := compressBound(u64(1000))
  if (tuckˑvˑb == u64(1013)) {
      tuckˑmodˑsys.exit(0)
  }
  tuckˑmodˑsys.exit(1)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
