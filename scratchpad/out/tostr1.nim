import ../../compiler/tuck_rt
import io
import str

proc main*(): int =
  if true:
    var n = 42
    var s = n.toStr
    io.printLine(s)
    return 0

