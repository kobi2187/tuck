{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_fn_processISR*(event: tuck_type_SensorEvent): void
proc tuck_fn_handleUart*(): void

type tuck_type_SafeRPM* = distinct uint16
proc `+`*(a, b: tuck_type_SafeRPM): tuck_type_SafeRPM {.borrow.}
proc `-`*(a, b: tuck_type_SafeRPM): tuck_type_SafeRPM {.borrow.}
proc `*`*(a, b: tuck_type_SafeRPM): tuck_type_SafeRPM {.borrow.}
proc `div`*(a, b: tuck_type_SafeRPM): tuck_type_SafeRPM {.borrow.}
proc `mod`*(a, b: tuck_type_SafeRPM): tuck_type_SafeRPM {.borrow.}
proc `==`*(a, b: tuck_type_SafeRPM): bool {.borrow.}
proc `<`*(a, b: tuck_type_SafeRPM): bool {.borrow.}
proc `<=`*(a, b: tuck_type_SafeRPM): bool {.borrow.}
proc `$`*(a: tuck_type_SafeRPM): string {.borrow.}

type tuck_type_PacketSeq* = distinct uint8
proc `+`*(a, b: tuck_type_PacketSeq): tuck_type_PacketSeq {.borrow.}
proc `-`*(a, b: tuck_type_PacketSeq): tuck_type_PacketSeq {.borrow.}
proc `*`*(a, b: tuck_type_PacketSeq): tuck_type_PacketSeq {.borrow.}
proc `div`*(a, b: tuck_type_PacketSeq): tuck_type_PacketSeq {.borrow.}
proc `mod`*(a, b: tuck_type_PacketSeq): tuck_type_PacketSeq {.borrow.}
proc `==`*(a, b: tuck_type_PacketSeq): bool {.borrow.}
proc `<`*(a, b: tuck_type_PacketSeq): bool {.borrow.}
proc `<=`*(a, b: tuck_type_PacketSeq): bool {.borrow.}
proc `$`*(a: tuck_type_PacketSeq): string {.borrow.}

type tuck_type_ErrorCount* = distinct uint32
proc `+`*(a, b: tuck_type_ErrorCount): tuck_type_ErrorCount {.borrow.}
proc `-`*(a, b: tuck_type_ErrorCount): tuck_type_ErrorCount {.borrow.}
proc `*`*(a, b: tuck_type_ErrorCount): tuck_type_ErrorCount {.borrow.}
proc `div`*(a, b: tuck_type_ErrorCount): tuck_type_ErrorCount {.borrow.}
proc `mod`*(a, b: tuck_type_ErrorCount): tuck_type_ErrorCount {.borrow.}
proc `==`*(a, b: tuck_type_ErrorCount): bool {.borrow.}
proc `<`*(a, b: tuck_type_ErrorCount): bool {.borrow.}
proc `<=`*(a, b: tuck_type_ErrorCount): bool {.borrow.}
proc `$`*(a: tuck_type_ErrorCount): string {.borrow.}

type tuck_type_SensorEvent* = object
  channel*: uint8
  reading*: uint16

var tuck_RCC_CR = cast[ptr uint32](0x40021000)
const tuck_RCC_CR_HSION_SHIFT = 0
const tuck_RCC_CR_HSIRDY_SHIFT = 1
const tuck_RCC_CR_HSITRIM_SHIFT = 3
const tuck_RCC_CR_HSITRIM_WIDTH = 7 - 3 + 1
const tuck_RCC_CR_HSITRIM_MASK = (1'u32 shl tuck_RCC_CR_HSITRIM_WIDTH) - 1
proc tuck_RCC_CR_HSION_get*(): bool {.inline.} =
  (tuck_RCC_CR[] and (1'u32 shl tuck_RCC_CR_HSION_SHIFT)) != 0
proc tuck_RCC_CR_HSION_set*(value: bool) {.inline.} =
  let mask = 1'u32 shl tuck_RCC_CR_HSION_SHIFT
  if value: tuck_RCC_CR[] = tuck_RCC_CR[] or mask
  else: tuck_RCC_CR[] = tuck_RCC_CR[] and not mask
proc tuck_RCC_CR_HSIRDY_get*(): bool {.inline.} =
  (tuck_RCC_CR[] and (1'u32 shl tuck_RCC_CR_HSIRDY_SHIFT)) != 0
proc tuck_RCC_CR_HSITRIM_get*(): uint32 {.inline.} =
  (tuck_RCC_CR[] shr tuck_RCC_CR_HSITRIM_SHIFT) and tuck_RCC_CR_HSITRIM_MASK
proc tuck_RCC_CR_HSITRIM_set*(value: uint32) {.inline.} =
  let shifted = (value and tuck_RCC_CR_HSITRIM_MASK) shl tuck_RCC_CR_HSITRIM_SHIFT
  tuck_RCC_CR[] = (tuck_RCC_CR[] and not (tuck_RCC_CR_HSITRIM_MASK shl tuck_RCC_CR_HSITRIM_SHIFT)) or shifted

proc tuck_fn_processISR*(event: tuck_type_SensorEvent): void =
  discard

var tuck_UartBuffer* = ObjectPool[array[64, uint8], 8]()
proc tuck_fn_handleUart*(): void =
  var tuck_buf = acquire(tuck_UartBuffer)
  if not tuck_buf.ok:
    if true:
      return
  release(tuck_UartBuffer, tuck_buf.value)
  return

