{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuckˑfnˑadmit*(id: uint32): int
proc tuckˑfnˑdrainOnce*(): int
proc tuckˑfnˑmain*(): int

type tuckˑtypeˑSession* = object
  clientId*: uint32
  bytesIn*: uint32

type tuckˑtypeˑSensorReading* = object
  channel*: uint8
  value*: uint16

var tuckˑpoolˑRxBuffers* = ObjectPool[array[512, uint8], 4]()
var tuckˑpoolˑSessions* = ObjectPool[tuckˑtypeˑSession, 64]()
var tuckˑpoolˑReadings* = ObjectPool[tuckˑtypeˑSensorReading, 16]()
proc tuckˑfnˑadmit*(id: uint32): int =
  var tuckˑvˑs = tuckPoolAcquire(tuckˑpoolˑSessions)
  if tuckˑvˑs.ok:
    if true:
      return 1
  return 0

proc memset*(p: ptr UncheckedArray[uint8], c: int, n: int): void {.importc: "memset", header: "string.h".}

proc tuckˑfnˑdrainOnce*(): int =
  var tuckˑvˑb = tuckPoolAcquire(tuckˑpoolˑRxBuffers)
  if not tuckˑvˑb.ok:
    if true:
      return 0
  var tuckˑvˑdst = tuckPoolAddr(tuckˑpoolˑRxBuffers, tuckˑvˑb.value)
  memset(tuckˑvˑdst, 1, 512)
  var tuckˑvˑrx = tuckPoolRead(tuckˑpoolˑRxBuffers, tuckˑvˑb.value)
  tuckPoolRelease(tuckˑpoolˑRxBuffers, tuckˑvˑb.value)
  if not tuckˑvˑrx.ok:
    if true:
      return 0
  var tuckˑvˑbytes = tuckˑvˑrx.value
  if (tuck_rt.tuckArrayAt(tuckˑvˑbytes, 511) != 1):
    if true:
      return 0
  var tuckˑvˑr = tuckPoolAcquire(tuckˑpoolˑReadings)
  if not tuckˑvˑr.ok:
    if true:
      return 0
  var tuckˑvˑreading = tuckˑtypeˑSensorReading(channel: 2'u8, value: 700'u16)
  tuckPoolWrite(tuckˑpoolˑReadings, tuckˑvˑr.value, tuckˑvˑreading)
  var tuckˑvˑback = tuckPoolRead(tuckˑpoolˑReadings, tuckˑvˑr.value)
  tuckPoolRelease(tuckˑpoolˑReadings, tuckˑvˑr.value)
  if tuckˑvˑback.ok:
    if true:
      return 1
  return 0

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑadmitted = 0
  tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(1'u32))
  tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(2'u32))
  tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(3'u32))
  var tuckˑvˑdrained = tuckˑfnˑdrainOnce()
  return (tuckˑvˑadmitted + tuckˑvˑdrained)

