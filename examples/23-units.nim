{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuckˑfnˑms*(value: uint32): tuckˑtypeˑMilliseconds
proc tuckˑfnˑdelay*(ms: tuckˑtypeˑMilliseconds): tuple[done: bool]
proc tuckˑfnˑmain*(): void

type tuckˑtypeˑMilliseconds* = distinct uint32
proc `+`*(a, b: tuckˑtypeˑMilliseconds): tuckˑtypeˑMilliseconds {.borrow.}
proc `-`*(a, b: tuckˑtypeˑMilliseconds): tuckˑtypeˑMilliseconds {.borrow.}
proc `*`*(a, b: tuckˑtypeˑMilliseconds): tuckˑtypeˑMilliseconds {.borrow.}
proc `div`*(a, b: tuckˑtypeˑMilliseconds): tuckˑtypeˑMilliseconds {.borrow.}
proc `mod`*(a, b: tuckˑtypeˑMilliseconds): tuckˑtypeˑMilliseconds {.borrow.}
proc `==`*(a, b: tuckˑtypeˑMilliseconds): bool {.borrow.}
proc `<`*(a, b: tuckˑtypeˑMilliseconds): bool {.borrow.}
proc `<=`*(a, b: tuckˑtypeˑMilliseconds): bool {.borrow.}
proc `$`*(a: tuckˑtypeˑMilliseconds): string {.borrow.}

proc tuckˑfnˑms*(value: uint32): tuckˑtypeˑMilliseconds =
  return tuckˑtypeˑMilliseconds(value)

proc tuckˑfnˑdelay*(ms: tuckˑtypeˑMilliseconds): tuple[done: bool] =
  return (done: true)

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑr = tuckˑfnˑdelay(tuckˑfnˑms(5'u32))
  return

