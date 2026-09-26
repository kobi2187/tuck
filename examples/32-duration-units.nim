{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import sys
import time

proc tuck_fn_asInt*(d: tuck_type_Milliseconds): int
proc tuck_fn_budget*(d: tuck_type_Milliseconds): tuple[ok: bool]
proc tuck_fn_main*(): void

proc tuck_fn_asInt*(d: tuck_type_Milliseconds): int =
  return 42

proc tuck_fn_budget*(d: tuck_type_Milliseconds): tuple[ok: bool] =
  return (ok: true)

proc tuck_fn_main*(): void =
  var tuck_r = tuck_fn_budget(tuck_fn_ms(5'u32))
  var tuck_n = tuck_fn_asInt(tuck_fn_ms(42'u32))
  sys.exit(tuck_n)

