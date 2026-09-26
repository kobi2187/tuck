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
  var tuckˑvˑs = acquire(tuckˑpoolˑSessions)
  if tuckˑvˑs.ok:
    if true:
      return 1
  return 0

proc tuckˑfnˑdrainOnce*(): int =
  var tuckˑvˑb = acquire(tuckˑpoolˑRxBuffers)
  if tuckˑvˑb.ok:
    if true:
      release(tuckˑpoolˑRxBuffers, tuckˑvˑb.value)
      return 1
  return 0

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑadmitted = 0
  tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(1'u32))
  tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(2'u32))
  tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(3'u32))
  var tuckˑvˑdrained = tuckˑfnˑdrainOnce()
  return (tuckˑvˑadmitted + tuckˑvˑdrained)

