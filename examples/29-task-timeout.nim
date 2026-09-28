{.experimental: "codeReordering".}
import ../compiler/tuck_rt
export tuck_rt
import time

proc tuckˑfnˑmain*(): int

proc tuckˑtaskˑreadOrGiveUp*(fd: int): tuple[code: int] =
  if tuckAwaitReadOrTimeout(fd, int(tuckˑfnˑms(30'u32))):
    return (code: 1)
  else:
    return (code: 2)

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑsrc = openSource(500)
  var tuckˑvˑr = (let tuckSlot0 = newAsyncResult[tuple[code: int]](); spawnResult(tuckSlot0, proc(): tuple[code: int] {.closure, gcsafe.} = ({.cast(gcsafe).}: tuckˑtaskˑreadOrGiveUp(tuckˑvˑsrc.fd))); awaitResult(tuckSlot0))
  return tuckˑvˑr.code

