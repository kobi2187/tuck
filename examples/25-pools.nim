import ../compiler/tuck_rt

type tuck_Session* = object
  clientId*: uint32
  bytesIn*: uint32

type tuck_SensorReading* = object
  channel*: uint8
  value*: uint16

var tuck_RxBuffers* = ObjectPool[array[512, uint8], 4]()
var tuck_Sessions* = ObjectPool[tuck_Session, 64]()
var tuck_Readings* = ObjectPool[tuck_SensorReading, 16]()
proc tuck_admit*(id: uint32): int =
  var s = acquire(tuck_Sessions)
  if s.ok:
    if true:
      return 1
  return 0

proc tuck_drainOnce*(): int =
  var b = acquire(tuck_RxBuffers)
  if b.ok:
    if true:
      release(tuck_RxBuffers, b.value)
      return 1
  return 0

proc tuck_main*(): int =
  var admitted = 0
  admitted = (admitted + tuck_admit(1))
  admitted = (admitted + tuck_admit(2))
  admitted = (admitted + tuck_admit(3))
  var drained = tuck_drainOnce()
  return (admitted + drained)

