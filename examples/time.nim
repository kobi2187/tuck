{.experimental: "codeReordering".}
import ../compiler/tuck_rt
export tuck_rt

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

type tuck_Microseconds* = distinct uint32
proc `+`*(a, b: tuck_Microseconds): tuck_Microseconds {.borrow.}
proc `-`*(a, b: tuck_Microseconds): tuck_Microseconds {.borrow.}
proc `*`*(a, b: tuck_Microseconds): tuck_Microseconds {.borrow.}
proc `div`*(a, b: tuck_Microseconds): tuck_Microseconds {.borrow.}
proc `mod`*(a, b: tuck_Microseconds): tuck_Microseconds {.borrow.}
proc `==`*(a, b: tuck_Microseconds): bool {.borrow.}
proc `<`*(a, b: tuck_Microseconds): bool {.borrow.}
proc `<=`*(a, b: tuck_Microseconds): bool {.borrow.}
proc `$`*(a: tuck_Microseconds): string {.borrow.}

type tuck_Seconds* = distinct uint32
proc `+`*(a, b: tuck_Seconds): tuck_Seconds {.borrow.}
proc `-`*(a, b: tuck_Seconds): tuck_Seconds {.borrow.}
proc `*`*(a, b: tuck_Seconds): tuck_Seconds {.borrow.}
proc `div`*(a, b: tuck_Seconds): tuck_Seconds {.borrow.}
proc `mod`*(a, b: tuck_Seconds): tuck_Seconds {.borrow.}
proc `==`*(a, b: tuck_Seconds): bool {.borrow.}
proc `<`*(a, b: tuck_Seconds): bool {.borrow.}
proc `<=`*(a, b: tuck_Seconds): bool {.borrow.}
proc `$`*(a: tuck_Seconds): string {.borrow.}

proc tuck_ms*(value: uint32): tuck_Milliseconds =
  return tuck_Milliseconds(value)

proc tuck_us*(value: uint32): tuck_Microseconds =
  return tuck_Microseconds(value)

proc tuck_s*(value: uint32): tuck_Seconds =
  return tuck_Seconds(value)

