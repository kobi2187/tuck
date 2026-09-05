package main

import fs "./mod_fs"
import console "./mod_console"

tuck_main :: proc () {
  tuck_w := fs.writeFile("/tmp/tuck-demo.txt", "hello from tuck")
  if (tuck_w.status == .Ok) {
      tuck_r := fs.readFile("/tmp/tuck-demo.txt")
      if (tuck_r.status == .Ok) {
          console.printLine(tuck_r.value.content)
          return
      }
  }
  console.printLine("stdlib demo failed")
}

main :: proc() {
	tuck_main()
}
