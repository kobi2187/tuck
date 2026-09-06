import ../../compiler/tuck_rt
export tuck_rt

type Milliseconds* = distinct uint32
proc `+`*(a, b: Milliseconds): Milliseconds {.borrow.}
proc `-`*(a, b: Milliseconds): Milliseconds {.borrow.}
proc `*`*(a, b: Milliseconds): Milliseconds {.borrow.}
proc `div`*(a, b: Milliseconds): Milliseconds {.borrow.}
proc `mod`*(a, b: Milliseconds): Milliseconds {.borrow.}
proc `==`*(a, b: Milliseconds): bool {.borrow.}
proc `<`*(a, b: Milliseconds): bool {.borrow.}
proc `<=`*(a, b: Milliseconds): bool {.borrow.}
proc `$`*(a: Milliseconds): string {.borrow.}

type Microseconds* = distinct uint32
proc `+`*(a, b: Microseconds): Microseconds {.borrow.}
proc `-`*(a, b: Microseconds): Microseconds {.borrow.}
proc `*`*(a, b: Microseconds): Microseconds {.borrow.}
proc `div`*(a, b: Microseconds): Microseconds {.borrow.}
proc `mod`*(a, b: Microseconds): Microseconds {.borrow.}
proc `==`*(a, b: Microseconds): bool {.borrow.}
proc `<`*(a, b: Microseconds): bool {.borrow.}
proc `<=`*(a, b: Microseconds): bool {.borrow.}
proc `$`*(a: Microseconds): string {.borrow.}

type Seconds* = distinct uint32
proc `+`*(a, b: Seconds): Seconds {.borrow.}
proc `-`*(a, b: Seconds): Seconds {.borrow.}
proc `*`*(a, b: Seconds): Seconds {.borrow.}
proc `div`*(a, b: Seconds): Seconds {.borrow.}
proc `mod`*(a, b: Seconds): Seconds {.borrow.}
proc `==`*(a, b: Seconds): bool {.borrow.}
proc `<`*(a, b: Seconds): bool {.borrow.}
proc `<=`*(a, b: Seconds): bool {.borrow.}
proc `$`*(a: Seconds): string {.borrow.}

proc ms*(value: uint32): Milliseconds =
  if true:
    return Milliseconds(value)

proc us*(value: uint32): Microseconds =
  if true:
    return Microseconds(value)

proc s*(value: uint32): Seconds =
  if true:
    return Seconds(value)

