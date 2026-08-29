{.experimental: "codeReordering".}
import ../compiler/tuck_rt
export tuck_rt
import time

proc tuck_readOrGiveUp*(fd: int): tuple[code: int] =
  if tuckAwaitReadOrTimeout(fd, int(tuck_ms(100))):
    return (code: 1)
  else:
    return (code: 2)

proc tuck_main*(): int =
  var src = openSource(5)
  var r = (let tuckSlot0 = newAsyncResult[tuple[code: int]](); spawnResult(tuckSlot0, proc(): tuple[code: int] {.closure, gcsafe.} = ({.cast(gcsafe).}: tuck_readOrGiveUp(src.fd))); awaitResult(tuckSlot0))
  return r.code

