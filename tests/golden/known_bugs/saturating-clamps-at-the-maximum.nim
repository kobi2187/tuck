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
  var tuck_s = tuck_type_SafeRPM(tuckSat[uint16](uint64(70000)))
  if (tuck_s == tuck_type_SafeRPM(tuckSat[uint16](uint64(65535)))):
    if true:
      return 1
  return 2

