{.experimental: "codeReordering".}
import ../compiler/tuck_rt
export tuck_rt

type tuck_type_NetError* = enum Refused, AddressInUse, Unreachable, Closed, IoFailed

