{.experimental: "codeReordering".}
import ../compiler/tuck_rt
export tuck_rt
import ./shim/zlib_shim
export zlib_shim
{.passL: "-lz".}
import sys
import console

proc compressBound*(sourceLen: uint64): uint64 {.importc: "compressBound", header: "zlib.h".}

proc tuck_main*(): void =
  var v = zlibVersion()
  tuck_rt.printLine(v)
  var b = compressBound(1000)
  if (b == 1013):
    if true:
      tuck_rt.exit(0)
  tuck_rt.exit(1)

