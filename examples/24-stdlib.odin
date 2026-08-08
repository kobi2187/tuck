package main

import fs "./mod_fs"
import console "./mod_console"

tuck_main :: proc () {
  w := fs.writeFile("/tmp/tuck-demo.txt", "hello from tuck")
  if (w.status == .Ok) {
      r := fs.readFile("/tmp/tuck-demo.txt")
      if (r.status == .Ok) {
          console.printLine(r.value.content)
          return
      }
  }
  console.printLine("stdlib demo failed")
}

main :: proc() {
	tuck_main()
}
