{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_fn_ms*(value: uint32): tuck_type_Milliseconds
proc tuck_fn_delay*(ms: tuck_type_Milliseconds): tuple[done: bool]
proc tuck_fn_main*(): void

type tuck_type_Milliseconds* = distinct uint32
proc `+`*(a, b: tuck_type_Milliseconds): tuck_type_Milliseconds {.borrow.}
proc `-`*(a, b: tuck_type_Milliseconds): tuck_type_Milliseconds {.borrow.}
proc `*`*(a, b: tuck_type_Milliseconds): tuck_type_Milliseconds {.borrow.}
proc `div`*(a, b: tuck_type_Milliseconds): tuck_type_Milliseconds {.borrow.}
proc `mod`*(a, b: tuck_type_Milliseconds): tuck_type_Milliseconds {.borrow.}
proc `==`*(a, b: tuck_type_Milliseconds): bool {.borrow.}
proc `<`*(a, b: tuck_type_Milliseconds): bool {.borrow.}
proc `<=`*(a, b: tuck_type_Milliseconds): bool {.borrow.}
proc `$`*(a: tuck_type_Milliseconds): string {.borrow.}

proc tuck_fn_ms*(value: uint32): tuck_type_Milliseconds =
  return tuck_type_Milliseconds(value)

proc tuck_fn_delay*(ms: tuck_type_Milliseconds): tuple[done: bool] =
  return (done: true)

proc tuck_fn_main*(): void =
  var tuck_r = tuck_fn_delay(tuck_fn_ms(5'u32))
  return

