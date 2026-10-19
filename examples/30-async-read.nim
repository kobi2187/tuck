{.experimental: "codeReordering".}
import "../compiler/tuck_rt"
export tuck_rt
import time as tuckˑmodˑtime

proc tuckˑfnˑmain*(): int

proc tuckˑtaskˑreadOrGiveUp*(fd: int): tuple[code: int] =
  var tuckˑvˑcode = 0
  if tuckAwaitReadOrTimeout(fd, int(tuckˑfnˑms(100'u32))):
    tuckˑvˑcode = 1
  else:
    tuckˑvˑcode = 2
  return (code: tuckˑvˑcode)

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑsrc = openSource(5)
  var tuckˑvˑr = (let tuckSlot0 = newAsyncResult[tuple[code: int]](); tuckSpawnResultJob(tuckSlot0, tuckˑtaskˑreadOrGiveUp, tuckˑvˑsrc.fd); awaitResult(tuckSlot0))
  return tuckˑvˑr.code

