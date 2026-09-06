import ../../compiler/tuck_rt
import io
import str

proc main*(): int =
  if true:
    var name = "tuck"
    io.printLine(tuckConcat("hello, ", name))
    return 0

