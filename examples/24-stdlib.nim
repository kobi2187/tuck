{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import fs
import console

proc tuck_fn_main*(): void

proc tuck_fn_main*(): void =
  var tuck_w = fs.writeFile("/tmp/tuck-demo.txt", "hello from tuck")
  if tuck_w.ok:
    if true:
      var tuck_r = fs.readFile("/tmp/tuck-demo.txt")
      if tuck_r.ok:
        if true:
          console.printLine(tuck_r.value.content)
          return
  console.printLine("stdlib demo failed")

