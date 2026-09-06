import ../../compiler/tuck_rt
import io

proc min*[T](payload: T): int =
  stderr.writeLine("TUCK PENDING: min invoked (not implemented)")

proc max*[T](payload: T): int =
  stderr.writeLine("TUCK PENDING: max invoked (not implemented)")

proc clamp*[T](payload: T): int =
  stderr.writeLine("TUCK PENDING: clamp invoked (not implemented)")


proc main*(): void =
  if true:
    var raw = 137
    var bounded = clamp(raw, 0, 100)
    printLine(toStr(bounded))
    printLine(toStr(min(3, 9)))
    printLine(toStr(max(3, 9)))
    return


when isMainModule:
  main()
