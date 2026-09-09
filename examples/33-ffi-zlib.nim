{.experimental: "codeReordering".}
import ../compiler/tuck_rt
{.passL: "-lz".}
import sys

proc tuck_main*(): void

proc compressBound*(sourceLen: uint64): uint64 {.importc: "compressBound", header: "zlib.h".}

proc tuck_main*(): void =
  var tuck_b = compressBound(1000)
  if (tuck_b == 1013):
    if true:
      tuck_rt.exit(0)
  tuck_rt.exit(1)

