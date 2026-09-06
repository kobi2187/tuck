import ../../compiler/tuck_rt
import io

proc repeated*[T](payload: T): string =
  stderr.writeLine("TUCK PENDING: repeated invoked (not implemented)")


proc main*(): void =
  if true:
    for i in (1 .. 5):
      if true:
        var bar = repeated("*", i)
        printLine(bar)
    return


when isMainModule:
  main()
