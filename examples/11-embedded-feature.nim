import ../compiler/tuck_rt

type tuck_SafeRPM* = distinct uint16
proc `+`*(a, b: tuck_SafeRPM): tuck_SafeRPM {.borrow.}
proc `-`*(a, b: tuck_SafeRPM): tuck_SafeRPM {.borrow.}
proc `*`*(a, b: tuck_SafeRPM): tuck_SafeRPM {.borrow.}
proc `div`*(a, b: tuck_SafeRPM): tuck_SafeRPM {.borrow.}
proc `mod`*(a, b: tuck_SafeRPM): tuck_SafeRPM {.borrow.}
proc `==`*(a, b: tuck_SafeRPM): bool {.borrow.}
proc `<`*(a, b: tuck_SafeRPM): bool {.borrow.}
proc `<=`*(a, b: tuck_SafeRPM): bool {.borrow.}
proc `$`*(a: tuck_SafeRPM): string {.borrow.}

type tuck_PacketSeq* = distinct uint8
proc `+`*(a, b: tuck_PacketSeq): tuck_PacketSeq {.borrow.}
proc `-`*(a, b: tuck_PacketSeq): tuck_PacketSeq {.borrow.}
proc `*`*(a, b: tuck_PacketSeq): tuck_PacketSeq {.borrow.}
proc `div`*(a, b: tuck_PacketSeq): tuck_PacketSeq {.borrow.}
proc `mod`*(a, b: tuck_PacketSeq): tuck_PacketSeq {.borrow.}
proc `==`*(a, b: tuck_PacketSeq): bool {.borrow.}
proc `<`*(a, b: tuck_PacketSeq): bool {.borrow.}
proc `<=`*(a, b: tuck_PacketSeq): bool {.borrow.}
proc `$`*(a: tuck_PacketSeq): string {.borrow.}

type tuck_ErrorCount* = distinct uint32
proc `+`*(a, b: tuck_ErrorCount): tuck_ErrorCount {.borrow.}
proc `-`*(a, b: tuck_ErrorCount): tuck_ErrorCount {.borrow.}
proc `*`*(a, b: tuck_ErrorCount): tuck_ErrorCount {.borrow.}
proc `div`*(a, b: tuck_ErrorCount): tuck_ErrorCount {.borrow.}
proc `mod`*(a, b: tuck_ErrorCount): tuck_ErrorCount {.borrow.}
proc `==`*(a, b: tuck_ErrorCount): bool {.borrow.}
proc `<`*(a, b: tuck_ErrorCount): bool {.borrow.}
proc `<=`*(a, b: tuck_ErrorCount): bool {.borrow.}
proc `$`*(a: tuck_ErrorCount): string {.borrow.}

type tuck_SensorEvent* = object
  channel*: uint8
  reading*: uint16

registerMMIO(tuck_RCC_CR, 0x40021000):
  HSION: bit(0, ReadWrite)
  HSIRDY: bit(1, ReadOnly)
  HSITRIM: bit(3..7, ReadWrite)

proc tuck_processISR*(event: tuck_SensorEvent): void =
  discard

var tuck_UartBuffer* = ObjectPool[array[64, uint8], 8]()
proc tuck_handleUart*(): void =
  var buf = acquire(tuck_UartBuffer)
  if not buf.ok:
    if true:
      return
  release(tuck_UartBuffer, buf.value)
  return

