{.experimental: "codeReordering".}
import ../compiler/tuck_rt

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
  var tuckˑvˑover = tuckˑtypeˑSafeRPM(tuckSat[uint16](uint64(70000)))
  var tuckˑvˑok = tuckˑtypeˑSafeRPM(tuckSat[uint16](uint64(1200)))
  if (tuckˑvˑover == tuckˑtypeˑSafeRPM(tuckSat[uint16](uint64(65535)))):
    if true:
      if (tuckˑvˑok == tuckˑtypeˑSafeRPM(tuckSat[uint16](uint64(1200)))):
        if true:
          return 0
      return 2
  return 1

