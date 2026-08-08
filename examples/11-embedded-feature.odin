package main

import rt "./tuckrt"

tuck_SafeRPM :: distinct u16

tuck_PacketSeq :: distinct u8

tuck_ErrorCount :: distinct u32

tuck_SensorEvent :: struct {
	channel: u8,
	reading: u16,
}

tuck_RCC_CR := cast(^u32)(uintptr(0x40021000))
tuck_RCC_CR_HSION_SHIFT :: 0
tuck_RCC_CR_HSIRDY_SHIFT :: 1
tuck_RCC_CR_HSITRIM_SHIFT :: 3
tuck_RCC_CR_HSITRIM_WIDTH :: 7 - 3 + 1
tuck_RCC_CR_HSITRIM_MASK :: u32(1 << u32(tuck_RCC_CR_HSITRIM_WIDTH)) - 1
tuck_RCC_CR_HSION_get :: proc() -> bool {
	return (tuck_RCC_CR^ & (u32(1) << u32(tuck_RCC_CR_HSION_SHIFT))) != 0
}
tuck_RCC_CR_HSION_set :: proc(on: bool) {
	mask := u32(1) << u32(tuck_RCC_CR_HSION_SHIFT)
	if on { tuck_RCC_CR^ |= mask } else { tuck_RCC_CR^ &~= mask }
}
tuck_RCC_CR_HSIRDY_get :: proc() -> bool {
	return (tuck_RCC_CR^ & (u32(1) << u32(tuck_RCC_CR_HSIRDY_SHIFT))) != 0
}
tuck_RCC_CR_HSITRIM_get :: proc() -> u32 {
	return (tuck_RCC_CR^ >> u32(tuck_RCC_CR_HSITRIM_SHIFT)) & tuck_RCC_CR_HSITRIM_MASK
}
tuck_RCC_CR_HSITRIM_set :: proc(value: u32) {
	shifted := (value & tuck_RCC_CR_HSITRIM_MASK) << u32(tuck_RCC_CR_HSITRIM_SHIFT)
	tuck_RCC_CR^ = (tuck_RCC_CR^ &~ (tuck_RCC_CR_HSITRIM_MASK << u32(tuck_RCC_CR_HSITRIM_SHIFT))) | shifted
}

tuck_processISR :: proc (event: tuck_SensorEvent) {

}

tuck_UartBuffer: rt.ObjectPool([64]u8, 8)

tuck_handleUart :: proc () {
  buf := rt.acquire(&tuck_UartBuffer)
  if !(buf.status == .Ok) {
      return
  }
  rt.release(&tuck_UartBuffer, buf.value)
  return
}

main :: proc() {
}
