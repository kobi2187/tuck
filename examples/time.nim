{.experimental: "codeReordering".}
import ../compiler/tuck_rt
export tuck_rt

proc tuckˑfnˑms*(value: uint32): tuckˑtypeˑMilliseconds
proc tuckˑfnˑus*(value: uint32): tuckˑtypeˑMicroseconds
proc tuckˑfnˑs*(value: uint32): tuckˑtypeˑSeconds

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

type tuckˑtypeˑMicroseconds* = distinct uint32
proc `+`*(a, b: tuckˑtypeˑMicroseconds): tuckˑtypeˑMicroseconds {.borrow.}
proc `-`*(a, b: tuckˑtypeˑMicroseconds): tuckˑtypeˑMicroseconds {.borrow.}
proc `*`*(a, b: tuckˑtypeˑMicroseconds): tuckˑtypeˑMicroseconds {.borrow.}
proc `div`*(a, b: tuckˑtypeˑMicroseconds): tuckˑtypeˑMicroseconds {.borrow.}
proc `mod`*(a, b: tuckˑtypeˑMicroseconds): tuckˑtypeˑMicroseconds {.borrow.}
proc `==`*(a, b: tuckˑtypeˑMicroseconds): bool {.borrow.}
proc `<`*(a, b: tuckˑtypeˑMicroseconds): bool {.borrow.}
proc `<=`*(a, b: tuckˑtypeˑMicroseconds): bool {.borrow.}
proc `$`*(a: tuckˑtypeˑMicroseconds): string {.borrow.}

type tuckˑtypeˑSeconds* = distinct uint32
proc `+`*(a, b: tuckˑtypeˑSeconds): tuckˑtypeˑSeconds {.borrow.}
proc `-`*(a, b: tuckˑtypeˑSeconds): tuckˑtypeˑSeconds {.borrow.}
proc `*`*(a, b: tuckˑtypeˑSeconds): tuckˑtypeˑSeconds {.borrow.}
proc `div`*(a, b: tuckˑtypeˑSeconds): tuckˑtypeˑSeconds {.borrow.}
proc `mod`*(a, b: tuckˑtypeˑSeconds): tuckˑtypeˑSeconds {.borrow.}
proc `==`*(a, b: tuckˑtypeˑSeconds): bool {.borrow.}
proc `<`*(a, b: tuckˑtypeˑSeconds): bool {.borrow.}
proc `<=`*(a, b: tuckˑtypeˑSeconds): bool {.borrow.}
proc `$`*(a: tuckˑtypeˑSeconds): string {.borrow.}

proc tuckˑfnˑms*(value: uint32): tuckˑtypeˑMilliseconds =
  return tuckˑtypeˑMilliseconds(value)

proc tuckˑfnˑus*(value: uint32): tuckˑtypeˑMicroseconds =
  return tuckˑtypeˑMicroseconds(value)

proc tuckˑfnˑs*(value: uint32): tuckˑtypeˑSeconds =
  return tuckˑtypeˑSeconds(value)

