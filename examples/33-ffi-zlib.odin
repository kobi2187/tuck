#+feature dynamic-literals
package main

import sys "./mod_sys"
foreign import z "system:z"

@(default_calling_convention="c")
foreign z {
	compressBound :: proc(sourceLen: u64) -> u64 ---
}

tuck_main :: proc () {
  tuck_b := compressBound(u64(1000))
  if (tuck_b == 1013) {
      sys.exit(0)
  }
  sys.exit(1)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_main()
	if rt.tuckTrackReport() > 0 { os.exit(90) }
}
