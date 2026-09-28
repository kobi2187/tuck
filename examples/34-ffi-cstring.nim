{.experimental: "codeReordering".}
import ../compiler/tuck_rt
export tuck_rt
import ./shim/zlib_shim
export zlib_shim
{.passL: "-lz".}
import sys
import console

proc tuckˑfnˑmain*(): void

proc compressBound*(sourceLen: uint64): uint64 {.importc: "compressBound", header: "zlib.h".}

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑv = zlibVersion()
  tuck_rt.printLine(tuckˑvˑv)
  var tuckˑvˑb = compressBound(1000'u64)
  if (tuckˑvˑb == 1013):
    if true:
      tuck_rt.exit(0)
  tuck_rt.exit(1)

