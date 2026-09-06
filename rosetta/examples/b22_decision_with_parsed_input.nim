import ../../compiler/tuck_rt
import io

proc parseInt*[T](payload: T): int =
  stderr.writeLine("TUCK PENDING: parseInt invoked (not implemented)")


proc main*(): void =
  if true:
    var raw = "42"
    var n = parseInt(raw)
    if ((n mod 2) == 0):
      if true:
        printLine("even")
    else:
      if true:
        printLine("odd")
    return


when isMainModule:
  main()
