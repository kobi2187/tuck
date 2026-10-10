#+feature dynamic-literals
package main

import rt "./tuckrt"
import sys "./mod_sys"
import console "./mod_console"
foreign import z "system:z"
import shim "./shim"

tuckG_0_copy :: proc(value: $G) -> G {
	return rt.tuckStrOwned(value)
}
tuckG_0_drop :: proc(value: $G) {
	delete(value)
}
tuckG_0_reset :: proc(value: ^$G) { tuckG_0_drop(value^); value^ = {} }


zlibVersion :: proc() -> string {
	return shim.zlibVersion()
}


@(default_calling_convention="c")
foreign z {
	compressBound :: proc(sourceLen: u64) -> u64 ---
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑv := zlibVersion()
  defer tuckG_0_drop(tuckˑvˑv)
  console.printLine(tuckˑvˑv)
  tuckˑvˑb := compressBound(u64(1000))
  if (tuckˑvˑb == 1013) {
      sys.exit(0)
  }
  sys.exit(1)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
