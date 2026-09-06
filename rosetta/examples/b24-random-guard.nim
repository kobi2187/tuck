import ../../compiler/tuck_rt
import io

proc randomBool*(): bool =
  stderr.writeLine("TUCK PENDING: randomBool invoked (not implemented)")


proc main*(): void =
  if true:
    var flips = 0
    while (flips < 1000):
      if true:
        flips = (flips + 1)
        if randomBool():
          if true:
            break
    printLine(toStr(flips))
    return


when isMainModule:
  main()
