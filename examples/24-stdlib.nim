import ../compiler/tuck_rt
import fs
import console

proc tuck_main*(): void =
  var w = fs.writeFile("/tmp/tuck-demo.txt", "hello from tuck")
  if w.ok:
    if true:
      var r = fs.readFile("/tmp/tuck-demo.txt")
      if r.ok:
        if true:
          console.printLine(r.value.content)
          return
  console.printLine("stdlib demo failed")

