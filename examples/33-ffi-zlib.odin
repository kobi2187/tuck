package main

import sys "./mod_sys"
foreign import z "system:z"

@(default_calling_convention="c")
foreign z {
	compressBound :: proc(sourceLen: u64) -> u64 ---
}

tuck_main :: proc () {
  b := compressBound(1000)
  if (b == 1013) {
      sys.exit(0)
  }
  sys.exit(1)
}

main :: proc() {
	tuck_main()
}
