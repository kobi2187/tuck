{.experimental: "codeReordering".}
import "../compiler/tuck_rt"
import fs as tuckˑmodˑfs
import console as tuckˑmodˑconsole

proc tuckˑfnˑmain*(): void

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑw = tuckˑmodˑfs.writeFile("/tmp/tuck-demo.txt", "hello from tuck")
  if tuckˑvˑw.ok:
    if true:
      var tuckˑvˑr = tuckˑmodˑfs.readFile("/tmp/tuck-demo.txt")
      defer: tuckDrop(tuckˑvˑr)
      if tuckˑvˑr.ok:
        if true:
          tuckˑmodˑconsole.printLine(tuckˑvˑr.value.content)
          return
  tuckˑmodˑconsole.printLine("stdlib demo failed")

