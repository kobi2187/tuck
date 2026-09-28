{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import sys
import time

proc tuckˑfnˑasInt*(d: tuckˑtypeˑMilliseconds): int
proc tuckˑfnˑbudget*(d: tuckˑtypeˑMilliseconds): tuple[ok: bool]
proc tuckˑfnˑmain*(): void

proc tuckˑfnˑasInt*(d: tuckˑtypeˑMilliseconds): int =
  return 42

proc tuckˑfnˑbudget*(d: tuckˑtypeˑMilliseconds): tuple[ok: bool] =
  return (ok: true)

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑr = tuckˑfnˑbudget(tuckˑfnˑms(5'u32))
  var tuckˑvˑn = tuckˑfnˑasInt(tuckˑfnˑms(42'u32))
  sys.exit(tuckˑvˑn)

