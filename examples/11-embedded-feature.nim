{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuckˑfnˑprocessISR*(event: tuckˑtypeˑSensorEvent): void
proc tuckˑfnˑhandleUart*(): void

type tuckˑtypeˑSafeRPM* = distinct uint16
proc `+`*(a, b: tuckˑtypeˑSafeRPM): tuckˑtypeˑSafeRPM {.borrow.}
proc `-`*(a, b: tuckˑtypeˑSafeRPM): tuckˑtypeˑSafeRPM {.borrow.}
proc `*`*(a, b: tuckˑtypeˑSafeRPM): tuckˑtypeˑSafeRPM {.borrow.}
proc `div`*(a, b: tuckˑtypeˑSafeRPM): tuckˑtypeˑSafeRPM {.borrow.}
proc `mod`*(a, b: tuckˑtypeˑSafeRPM): tuckˑtypeˑSafeRPM {.borrow.}
proc `==`*(a, b: tuckˑtypeˑSafeRPM): bool {.borrow.}
proc `<`*(a, b: tuckˑtypeˑSafeRPM): bool {.borrow.}
proc `<=`*(a, b: tuckˑtypeˑSafeRPM): bool {.borrow.}
proc `$`*(a: tuckˑtypeˑSafeRPM): string {.borrow.}

type tuckˑtypeˑPacketSeq* = distinct uint8
proc `+`*(a, b: tuckˑtypeˑPacketSeq): tuckˑtypeˑPacketSeq {.borrow.}
proc `-`*(a, b: tuckˑtypeˑPacketSeq): tuckˑtypeˑPacketSeq {.borrow.}
proc `*`*(a, b: tuckˑtypeˑPacketSeq): tuckˑtypeˑPacketSeq {.borrow.}
proc `div`*(a, b: tuckˑtypeˑPacketSeq): tuckˑtypeˑPacketSeq {.borrow.}
proc `mod`*(a, b: tuckˑtypeˑPacketSeq): tuckˑtypeˑPacketSeq {.borrow.}
proc `==`*(a, b: tuckˑtypeˑPacketSeq): bool {.borrow.}
proc `<`*(a, b: tuckˑtypeˑPacketSeq): bool {.borrow.}
proc `<=`*(a, b: tuckˑtypeˑPacketSeq): bool {.borrow.}
proc `$`*(a: tuckˑtypeˑPacketSeq): string {.borrow.}

type tuckˑtypeˑErrorCount* = distinct uint32
proc `+`*(a, b: tuckˑtypeˑErrorCount): tuckˑtypeˑErrorCount {.borrow.}
proc `-`*(a, b: tuckˑtypeˑErrorCount): tuckˑtypeˑErrorCount {.borrow.}
proc `*`*(a, b: tuckˑtypeˑErrorCount): tuckˑtypeˑErrorCount {.borrow.}
proc `div`*(a, b: tuckˑtypeˑErrorCount): tuckˑtypeˑErrorCount {.borrow.}
proc `mod`*(a, b: tuckˑtypeˑErrorCount): tuckˑtypeˑErrorCount {.borrow.}
proc `==`*(a, b: tuckˑtypeˑErrorCount): bool {.borrow.}
proc `<`*(a, b: tuckˑtypeˑErrorCount): bool {.borrow.}
proc `<=`*(a, b: tuckˑtypeˑErrorCount): bool {.borrow.}
proc `$`*(a: tuckˑtypeˑErrorCount): string {.borrow.}

type tuckˑtypeˑSensorEvent* = object
  channel*: uint8
  reading*: uint16

var tuckˑregisterˑRCC_CR = cast[ptr uint32](0x40021000)
const tuckˑregisterˑRCC_CR_HSION_SHIFT = 0
const tuckˑregisterˑRCC_CR_HSIRDY_SHIFT = 1
const tuckˑregisterˑRCC_CR_HSITRIM_SHIFT = 3
const tuckˑregisterˑRCC_CR_HSITRIM_WIDTH = 7 - 3 + 1
const tuckˑregisterˑRCC_CR_HSITRIM_MASK = (1'u32 shl tuckˑregisterˑRCC_CR_HSITRIM_WIDTH) - 1
proc tuckˑregisterˑRCC_CR_HSION_get*(): bool {.inline.} =
  (tuckˑregisterˑRCC_CR[] and (1'u32 shl tuckˑregisterˑRCC_CR_HSION_SHIFT)) != 0
proc tuckˑregisterˑRCC_CR_HSION_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuckˑregisterˑRCC_CR_HSION_SHIFT
  if value: tuckˑregisterˑRCC_CR[] = tuckˑregisterˑRCC_CR[] or mask
  else: tuckˑregisterˑRCC_CR[] = tuckˑregisterˑRCC_CR[] and not mask
proc tuckˑregisterˑRCC_CR_HSIRDY_get*(): bool {.inline.} =
  (tuckˑregisterˑRCC_CR[] and (1'u32 shl tuckˑregisterˑRCC_CR_HSIRDY_SHIFT)) != 0
proc tuckˑregisterˑRCC_CR_HSITRIM_get*(): uint32 {.inline.} =
  (tuckˑregisterˑRCC_CR[] shr tuckˑregisterˑRCC_CR_HSITRIM_SHIFT) and tuckˑregisterˑRCC_CR_HSITRIM_MASK
proc tuckˑregisterˑRCC_CR_HSITRIM_set*(value: uint32) {.inline.} =
  let shifted = (value and tuckˑregisterˑRCC_CR_HSITRIM_MASK) shl tuckˑregisterˑRCC_CR_HSITRIM_SHIFT
  tuckˑregisterˑRCC_CR[] = (tuckˑregisterˑRCC_CR[] and not (tuckˑregisterˑRCC_CR_HSITRIM_MASK shl tuckˑregisterˑRCC_CR_HSITRIM_SHIFT)) or shifted

proc tuckˑfnˑprocessISR*(event: tuckˑtypeˑSensorEvent): void =
  discard

var tuckˑpoolˑUartBuffer* = ObjectPool[array[64, uint8], 8]()
proc tuckˑfnˑhandleUart*(): void =
  var tuckˑvˑbuf = acquire(tuckˑpoolˑUartBuffer)
  if not tuckˑvˑbuf.ok:
    if true:
      return
  release(tuckˑpoolˑUartBuffer, tuckˑvˑbuf.value)
  return

