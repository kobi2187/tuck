#+feature dynamic-literals
package main

import rt "./tuckrt"
import fs "./mod_fs"
import console "./mod_console"

tuckˑfnˑmain :: proc () {
  tuckˑvˑw := fs.writeFile("/tmp/tuck-demo.txt", "hello from tuck")
  if (tuckˑvˑw.status == .Ok) {
      tuckˑvˑr := fs.readFile("/tmp/tuck-demo.txt")
      defer rt.tuckDrop(tuckˑvˑr)
      if (tuckˑvˑr.status == .Ok) {
          console.printLine(tuckˑvˑr.value.content)
          return
      }
  }
  console.printLine("stdlib demo failed")
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
