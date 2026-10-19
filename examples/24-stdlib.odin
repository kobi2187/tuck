#+feature dynamic-literals
package main

import rt "./tuckrt"
import tuckˑmodˑconsole "./mod_console"
import tuckˑmodˑfs "./mod_fs"

tuckˑfnˑmain :: proc () {
  tuckˑvˑw := tuckˑmodˑfs.writeFile("/tmp/tuck-demo.txt", "hello from tuck")
  if (tuckˑvˑw.status == .Ok) {
      tuckˑvˑr := tuckˑmodˑfs.readFile("/tmp/tuck-demo.txt")
      defer rt.tuckDrop(tuckˑvˑr)
      if (tuckˑvˑr.status == .Ok) {
          tuckˑmodˑconsole.printLine(tuckˑvˑr.value.content)
          return
      }
  }
  tuckˑmodˑconsole.printLine("stdlib demo failed")
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
