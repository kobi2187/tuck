import ../compiler/tuck_rt

proc tuck_get*[T](payload: T): TuckResult[tuple[body: string]] =
  stderr.writeLine("TUCK PENDING: tuck_get invoked (not implemented)")


