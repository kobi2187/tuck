{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuck_type_HttpError* = enum Unreachable, BadStatus

proc tuck_fn_get*[T](payload: T): TuckResult[tuple[body: string]] =
  stderr.writeLine("TUCK PENDING: tuck_fn_get invoked (not implemented)")


