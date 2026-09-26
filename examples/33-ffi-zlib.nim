{.experimental: "codeReordering".}
import ../compiler/tuck_rt
{.passL: "-lz".}
import sys

proc tuck_fn_main*(): void

proc compressBound*(sourceLen: uint64): uint64 {.importc: "compressBound", header: "zlib.h".}

proc tuck_fn_main*(): void =
  var tuck_b = compressBound(1000'u64)
  if (tuck_b == 1013):
    if true:
      tuck_rt.exit(0)
  tuck_rt.exit(1)

