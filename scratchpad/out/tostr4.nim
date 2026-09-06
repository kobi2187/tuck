import ../../compiler/tuck_rt
import io
import str

proc main*(): int =
  if true:
    var n = 42
    io.printLine((n.toStr + " bottles"))
    return 0

