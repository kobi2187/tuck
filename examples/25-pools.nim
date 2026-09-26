{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_fn_admit*(id: uint32): int
proc tuck_fn_drainOnce*(): int
proc tuck_fn_main*(): int

type tuck_type_Session* = object
  clientId*: uint32
  bytesIn*: uint32

type tuck_type_SensorReading* = object
  channel*: uint8
  value*: uint16

var tuck_RxBuffers* = ObjectPool[array[512, uint8], 4]()
var tuck_Sessions* = ObjectPool[tuck_type_Session, 64]()
var tuck_Readings* = ObjectPool[tuck_type_SensorReading, 16]()
proc tuck_fn_admit*(id: uint32): int =
  var tuck_s = acquire(tuck_Sessions)
  if tuck_s.ok:
    if true:
      return 1
  return 0

proc tuck_fn_drainOnce*(): int =
  var tuck_b = acquire(tuck_RxBuffers)
  if tuck_b.ok:
    if true:
      release(tuck_RxBuffers, tuck_b.value)
      return 1
  return 0

proc tuck_fn_main*(): int =
  var tuck_admitted = 0
  tuck_admitted = (tuck_admitted + tuck_fn_admit(1'u32))
  tuck_admitted = (tuck_admitted + tuck_fn_admit(2'u32))
  tuck_admitted = (tuck_admitted + tuck_fn_admit(3'u32))
  var tuck_drained = tuck_fn_drainOnce()
  return (tuck_admitted + tuck_drained)

