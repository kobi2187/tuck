{.experimental: "codeReordering".}

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
  var tuck_a = tuck_SafeRPM(tuckSat[uint16](uint64(60000)))
  var tuck_b = tuck_SafeRPM(tuckSat[uint16](uint64(60000)))
  var tuck_c = tuck_SafeRPM(tuckSat[uint16](uint64(60000)))
  var tuck_r = ((tuck_a + tuck_b) - tuck_c)
  if (tuck_r == tuck_SafeRPM(tuckSat[uint16](uint64(60000)))):
    if true:
      return 1
  return 2

