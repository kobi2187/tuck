{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_stepIo*(n: int): tuple[v: int] =
  return (v: n)

proc tuck_compute*(base: int): tuple[r: int] =
  var a = (tuckYield(); tuck_stepIo(base))
  var b = (tuckYield(); tuck_stepIo(base))
  return (r: (a.v + b.v))

proc tuck_main*(): int =
  var res = (let tuckSlot0 = newAsyncResult[tuple[r: int]](); spawnResult(tuckSlot0, proc(): tuple[r: int] {.closure, gcsafe.} = ({.cast(gcsafe).}: tuck_compute(21))); awaitResult(tuckSlot0))
  return res.r

