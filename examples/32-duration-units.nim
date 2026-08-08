import ../compiler/tuck_rt
import sys
import time

proc tuck_asInt*(d: tuck_Milliseconds): int =
  return 42

proc tuck_budget*(d: tuck_Milliseconds): tuple[ok: bool] =
  return (ok: true)

proc tuck_main*(): void =
  var r = tuck_budget(tuck_ms(5))
  var n = tuck_asInt(tuck_ms(42))
  sys.exit(n)

