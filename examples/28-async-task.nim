{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuckˑfnˑstepIo*(n: int): tuple[v: int]
proc tuckˑfnˑmain*(): int

proc tuckˑfnˑstepIo*(n: int): tuple[v: int] =
  return (v: n)

proc tuckˑtaskˑcompute*(base: int): tuple[r: int] =
  var tuckˑvˑa = (tuckYield(); tuckˑfnˑstepIo(base))
  var tuckˑvˑb = (tuckYield(); tuckˑfnˑstepIo(base))
  return (r: (tuckˑvˑa.v + tuckˑvˑb.v))

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑres = (let tuckSlot0 = newAsyncResult[tuple[r: int]](); spawnResult(tuckSlot0, proc(): tuple[r: int] {.closure, gcsafe.} = ({.cast(gcsafe).}: tuckˑtaskˑcompute(21))); awaitResult(tuckSlot0))
  return tuckˑvˑres.r

