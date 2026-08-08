import ../compiler/tuck_rt

type tuck_SafeRPM* = distinct uint16
proc `+`*(a, b: tuck_SafeRPM): tuck_SafeRPM {.borrow.}
proc `-`*(a, b: tuck_SafeRPM): tuck_SafeRPM {.borrow.}
proc `*`*(a, b: tuck_SafeRPM): tuck_SafeRPM {.borrow.}
proc `div`*(a, b: tuck_SafeRPM): tuck_SafeRPM {.borrow.}
proc `mod`*(a, b: tuck_SafeRPM): tuck_SafeRPM {.borrow.}
proc `==`*(a, b: tuck_SafeRPM): bool {.borrow.}
proc `<`*(a, b: tuck_SafeRPM): bool {.borrow.}
proc `<=`*(a, b: tuck_SafeRPM): bool {.borrow.}
proc `$`*(a: tuck_SafeRPM): string {.borrow.}

proc tuck_main*(): int =
  var over = tuck_SafeRPM(tuckSat[uint16](uint64(70000)))
  var ok = tuck_SafeRPM(tuckSat[uint16](uint64(1200)))
  if (over == tuck_SafeRPM(tuckSat[uint16](uint64(65535)))):
    if true:
      if (ok == tuck_SafeRPM(tuckSat[uint16](uint64(1200)))):
        if true:
          return 0
      return 2
  return 1

