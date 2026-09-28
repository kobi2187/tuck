{.experimental: "codeReordering".}
import ../compiler/tuck_rt
{.passL: "-lz".}
import sys

proc tuckˑfnˑmain*(): void

proc compressBound*(sourceLen: uint64): uint64 {.importc: "compressBound", header: "zlib.h".}

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑb = compressBound(1000'u64)
  if (tuckˑvˑb == 1013):
    if true:
      tuck_rt.exit(0)
  tuck_rt.exit(1)

