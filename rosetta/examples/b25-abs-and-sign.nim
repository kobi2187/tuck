import ../../compiler/tuck_rt
import io

proc abs*[T](payload: T): int =
  stderr.writeLine("TUCK PENDING: abs invoked (not implemented)")

proc sign*[T](payload: T): int =
  stderr.writeLine("TUCK PENDING: sign invoked (not implemented)")


proc main*(): void =
  if true:
    var n = -14
    printLine(toStr(abs(n)))
    printLine(toStr(sign(n)))
    return


when isMainModule:
  main()
