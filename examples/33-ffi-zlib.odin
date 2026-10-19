#+feature dynamic-literals
package main

import tuckˑmodˑsys "./mod_sys"
foreign import z "system:z"

@(default_calling_convention="c")
foreign z {
	compressBound :: proc(sourceLen: u64) -> u64 ---
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑb := compressBound(u64(1000))
  if (tuckˑvˑb == u64(1013)) {
      tuckˑmodˑsys.exit(0)
  }
  tuckˑmodˑsys.exit(1)
}

main :: proc() {
	tuckˑfnˑmain()
}
