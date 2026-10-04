{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuckˑfnˑhandle*(len: int): int
proc tuckˑfnˑmain*(): int

type tuckˑtypeˑEthernetFrame* = object
  len*: int
  bytes*: array[128, uint8]

type tuckˑtypeˑHeader* = object
  len*: int
  frame*: SlabRef

var tuckˑarenaˑScratchSpace* = ArenaBudget(size: 2048)
proc tuckˑarenaˑScratchSpace_reset*() =
  tuckSlabReset(tuckˑslabˑScratchSpace_EthernetFrame)
  tuckSlabReset(tuckˑslabˑScratchSpace_Header)
  tuckˑarenaˑScratchSpace.used = 0
var tuckˑslabˑScratchSpace_EthernetFrame* = SlabChunked[tuckˑtypeˑEthernetFrame](name: "ScratchSpace")
var tuckˑslabˑScratchSpace_Header* = SlabChunked[tuckˑtypeˑHeader](name: "ScratchSpace")
proc tuckˑfnˑhandle*(len: int): int =
  var tuckˑvˑraw: array[128, uint8] = default(array[128, uint8])
  var tuckˑvˑf = tuckˑtypeˑEthernetFrame(len: len, bytes: tuckˑvˑraw)
  var tuckˑvˑfr = tuckArenaNew(tuckˑslabˑScratchSpace_EthernetFrame, tuckˑarenaˑScratchSpace, 144, tuckˑvˑf)
  if not tuckˑvˑfr.ok:
    if true:
      return 0
  var tuckˑvˑh = tuckˑtypeˑHeader(len: len, frame: tuckˑvˑfr.value)
  var tuckˑvˑhr = tuckArenaNew(tuckˑslabˑScratchSpace_Header, tuckˑarenaˑScratchSpace, 24, tuckˑvˑh)
  if not tuckˑvˑhr.ok:
    if true:
      return 0
  tuckSlabCell(tuckˑslabˑScratchSpace_EthernetFrame, tuckSlabCell(tuckˑslabˑScratchSpace_Header, tuckˑvˑhr.value).value.frame).value.len = (tuckSlabCell(tuckˑslabˑScratchSpace_EthernetFrame, tuckSlabCell(tuckˑslabˑScratchSpace_Header, tuckˑvˑhr.value).value.frame).value.len + 1)
  return tuckSlabCell(tuckˑslabˑScratchSpace_EthernetFrame, tuckSlabCell(tuckˑslabˑScratchSpace_Header, tuckˑvˑhr.value).value.frame).value.len

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑhandled = 0
  var tuckˑvˑi = 0
  while (tuckˑvˑi < 5):
    if true:
      tuckˑvˑhandled = (tuckˑvˑhandled + tuckˑfnˑhandle(10))
      tuckˑvˑi = (tuckˑvˑi + 1)
  tuckˑarenaˑScratchSpace_reset()
  return tuckˑvˑhandled

