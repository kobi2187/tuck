{.experimental: "codeReordering".}

proc tuckˑfnˑmain*(): int

type tuckˑtypeˑSafeRPM* = distinct uint16
proc `+`*(a, b: tuckˑtypeˑSafeRPM): tuckˑtypeˑSafeRPM {.borrow.}
proc `-`*(a, b: tuckˑtypeˑSafeRPM): tuckˑtypeˑSafeRPM {.borrow.}
proc `*`*(a, b: tuckˑtypeˑSafeRPM): tuckˑtypeˑSafeRPM {.borrow.}
proc `div`*(a, b: tuckˑtypeˑSafeRPM): tuckˑtypeˑSafeRPM {.borrow.}
proc `mod`*(a, b: tuckˑtypeˑSafeRPM): tuckˑtypeˑSafeRPM {.borrow.}
proc `==`*(a, b: tuckˑtypeˑSafeRPM): bool {.borrow.}
proc `<`*(a, b: tuckˑtypeˑSafeRPM): bool {.borrow.}
proc `<=`*(a, b: tuckˑtypeˑSafeRPM): bool {.borrow.}
proc `$`*(a: tuckˑtypeˑSafeRPM): string {.borrow.}

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑs = tuckˑtypeˑSafeRPM(tuckSat[uint16](uint64(70000)))
  if (tuckˑvˑs == tuckˑtypeˑSafeRPM(tuckSat[uint16](uint64(65535)))):
    if true:
      return 1
  return 2

