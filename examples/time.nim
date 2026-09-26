{.experimental: "codeReordering".}
import ../compiler/tuck_rt
export tuck_rt

proc tuck_fn_ms*(value: uint32): tuck_type_Milliseconds
proc tuck_fn_us*(value: uint32): tuck_type_Microseconds
proc tuck_fn_s*(value: uint32): tuck_type_Seconds

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

type tuck_type_Microseconds* = distinct uint32
proc `+`*(a, b: tuck_type_Microseconds): tuck_type_Microseconds {.borrow.}
proc `-`*(a, b: tuck_type_Microseconds): tuck_type_Microseconds {.borrow.}
proc `*`*(a, b: tuck_type_Microseconds): tuck_type_Microseconds {.borrow.}
proc `div`*(a, b: tuck_type_Microseconds): tuck_type_Microseconds {.borrow.}
proc `mod`*(a, b: tuck_type_Microseconds): tuck_type_Microseconds {.borrow.}
proc `==`*(a, b: tuck_type_Microseconds): bool {.borrow.}
proc `<`*(a, b: tuck_type_Microseconds): bool {.borrow.}
proc `<=`*(a, b: tuck_type_Microseconds): bool {.borrow.}
proc `$`*(a: tuck_type_Microseconds): string {.borrow.}

type tuck_type_Seconds* = distinct uint32
proc `+`*(a, b: tuck_type_Seconds): tuck_type_Seconds {.borrow.}
proc `-`*(a, b: tuck_type_Seconds): tuck_type_Seconds {.borrow.}
proc `*`*(a, b: tuck_type_Seconds): tuck_type_Seconds {.borrow.}
proc `div`*(a, b: tuck_type_Seconds): tuck_type_Seconds {.borrow.}
proc `mod`*(a, b: tuck_type_Seconds): tuck_type_Seconds {.borrow.}
proc `==`*(a, b: tuck_type_Seconds): bool {.borrow.}
proc `<`*(a, b: tuck_type_Seconds): bool {.borrow.}
proc `<=`*(a, b: tuck_type_Seconds): bool {.borrow.}
proc `$`*(a: tuck_type_Seconds): string {.borrow.}

proc tuck_fn_ms*(value: uint32): tuck_type_Milliseconds =
  return tuck_type_Milliseconds(value)

proc tuck_fn_us*(value: uint32): tuck_type_Microseconds =
  return tuck_type_Microseconds(value)

proc tuck_fn_s*(value: uint32): tuck_type_Seconds =
  return tuck_type_Seconds(value)

