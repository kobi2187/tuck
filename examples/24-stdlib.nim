{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import fs
import console

proc tuckˑfnˑmain*(): void

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑw = fs.writeFile("/tmp/tuck-demo.txt", "hello from tuck")
  if tuckˑvˑw.ok:
    if true:
      var tuckˑvˑr = fs.readFile("/tmp/tuck-demo.txt")
      if tuckˑvˑr.ok:
        if true:
          console.printLine(tuckˑvˑr.value.content)
          return
  console.printLine("stdlib demo failed")

