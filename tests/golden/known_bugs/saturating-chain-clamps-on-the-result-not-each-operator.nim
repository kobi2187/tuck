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
  var tuckˑvˑa = tuckˑtypeˑSafeRPM(tuckSat[uint16](uint64(60000)))
  var tuckˑvˑb = tuckˑtypeˑSafeRPM(tuckSat[uint16](uint64(60000)))
  var tuckˑvˑc = tuckˑtypeˑSafeRPM(tuckSat[uint16](uint64(60000)))
  var tuckˑvˑr = ((tuckˑvˑa + tuckˑvˑb) - tuckˑvˑc)
  if (tuckˑvˑr == tuckˑtypeˑSafeRPM(tuckSat[uint16](uint64(60000)))):
    if true:
      return 1
  return 2

