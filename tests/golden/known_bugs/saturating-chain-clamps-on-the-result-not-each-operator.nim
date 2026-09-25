{.experimental: "codeReordering".}

proc tuck_fn_main*(): int

type tuck_type_SafeRPM* = distinct uint16
proc `+`*(a, b: tuck_type_SafeRPM): tuck_type_SafeRPM {.borrow.}
proc `-`*(a, b: tuck_type_SafeRPM): tuck_type_SafeRPM {.borrow.}
proc `*`*(a, b: tuck_type_SafeRPM): tuck_type_SafeRPM {.borrow.}
proc `div`*(a, b: tuck_type_SafeRPM): tuck_type_SafeRPM {.borrow.}
proc `mod`*(a, b: tuck_type_SafeRPM): tuck_type_SafeRPM {.borrow.}
proc `==`*(a, b: tuck_type_SafeRPM): bool {.borrow.}
proc `<`*(a, b: tuck_type_SafeRPM): bool {.borrow.}
proc `<=`*(a, b: tuck_type_SafeRPM): bool {.borrow.}
proc `$`*(a: tuck_type_SafeRPM): string {.borrow.}

proc tuck_fn_main*(): int =
  var tuck_a = tuck_type_SafeRPM(tuckSat[uint16](uint64(60000)))
  var tuck_b = tuck_type_SafeRPM(tuckSat[uint16](uint64(60000)))
  var tuck_c = tuck_type_SafeRPM(tuckSat[uint16](uint64(60000)))
  var tuck_r = ((tuck_a + tuck_b) - tuck_c)
  if (tuck_r == tuck_type_SafeRPM(tuckSat[uint16](uint64(60000)))):
    if true:
      return 1
  return 2

