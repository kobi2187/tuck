import ../compiler/tuck_rt

type tuck_Milliseconds* = distinct uint32
proc `+`*(a, b: tuck_Milliseconds): tuck_Milliseconds {.borrow.}
proc `-`*(a, b: tuck_Milliseconds): tuck_Milliseconds {.borrow.}
proc `*`*(a, b: tuck_Milliseconds): tuck_Milliseconds {.borrow.}
proc `div`*(a, b: tuck_Milliseconds): tuck_Milliseconds {.borrow.}
proc `mod`*(a, b: tuck_Milliseconds): tuck_Milliseconds {.borrow.}
proc `==`*(a, b: tuck_Milliseconds): bool {.borrow.}
proc `<`*(a, b: tuck_Milliseconds): bool {.borrow.}
proc `<=`*(a, b: tuck_Milliseconds): bool {.borrow.}
proc `$`*(a: tuck_Milliseconds): string {.borrow.}

proc tuck_ms*(value: uint32): tuck_Milliseconds =
  return tuck_Milliseconds(value)

proc tuck_delay*(ms: tuck_Milliseconds): tuple[done: bool] =
  return (done: true)

proc tuck_main*(): void =
  var r = tuck_delay(tuck_ms(5))
  return

