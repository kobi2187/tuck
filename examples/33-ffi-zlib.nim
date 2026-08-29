{.experimental: "codeReordering".}
import ../compiler/tuck_rt
{.passL: "-lz".}
import sys

proc compressBound*(sourceLen: uint64): uint64 {.importc: "compressBound", header: "zlib.h".}

proc tuck_main*(): void =
  var b = compressBound(1000)
  if (b == 1013):
    if true:
      exit(0)
  exit(1)

