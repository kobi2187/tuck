{.experimental: "codeReordering".}
import "../compiler/tuck_rt"

type tuckˑtypeˑHttpError* = enum Unreachable, BadStatus

proc tuckˑfnˑget*[T0](p0: T0): TuckResult[tuple[body: string]] =
  stderr.writeLine("TUCK PENDING: get invoked (not implemented)")


