#+feature dynamic-literals
package main

import rt "./tuckrt"

tuckˑtypeˑSafeRPM :: distinct u16

tuckˑtypeˑPacketSeq :: distinct u8

tuckˑtypeˑErrorCount :: distinct u32

tuckˑtypeˑSensorEvent :: struct {
	channel: u8,
	reading: u16,
}

tuckˑregisterˑRCC_CR := cast(^u32)(uintptr(0x40021000))
tuckˑregisterˑRCC_CR_HSION_SHIFT :: 0
tuckˑregisterˑRCC_CR_HSIRDY_SHIFT :: 1
tuckˑregisterˑRCC_CR_HSITRIM_SHIFT :: 3
tuckˑregisterˑRCC_CR_HSITRIM_WIDTH :: 7 - 3 + 1
tuckˑregisterˑRCC_CR_HSITRIM_MASK :: u32(1 << u32(tuckˑregisterˑRCC_CR_HSITRIM_WIDTH)) - 1
tuckˑregisterˑRCC_CR_HSION_get :: proc() -> bool {
	return (tuckˑregisterˑRCC_CR^ & (u32(1) << u32(tuckˑregisterˑRCC_CR_HSION_SHIFT))) != 0
}
tuckˑregisterˑRCC_CR_HSION_set :: proc(on: bool) {
	mask := u32(1) << u32(tuckˑregisterˑRCC_CR_HSION_SHIFT)
	if on { tuckˑregisterˑRCC_CR^ |= mask } else { tuckˑregisterˑRCC_CR^ &~= mask }
}
tuckˑregisterˑRCC_CR_HSIRDY_get :: proc() -> bool {
	return (tuckˑregisterˑRCC_CR^ & (u32(1) << u32(tuckˑregisterˑRCC_CR_HSIRDY_SHIFT))) != 0
}
tuckˑregisterˑRCC_CR_HSITRIM_get :: proc() -> u32 {
	return (tuckˑregisterˑRCC_CR^ >> u32(tuckˑregisterˑRCC_CR_HSITRIM_SHIFT)) & tuckˑregisterˑRCC_CR_HSITRIM_MASK
}
tuckˑregisterˑRCC_CR_HSITRIM_set :: proc(value: u32) {
	shifted := (value & tuckˑregisterˑRCC_CR_HSITRIM_MASK) << u32(tuckˑregisterˑRCC_CR_HSITRIM_SHIFT)
	tuckˑregisterˑRCC_CR^ = (tuckˑregisterˑRCC_CR^ &~ (tuckˑregisterˑRCC_CR_HSITRIM_MASK << u32(tuckˑregisterˑRCC_CR_HSITRIM_SHIFT))) | shifted
}

tuckˑfnˑprocessISR :: proc (event: tuckˑtypeˑSensorEvent) {

}

tuckˑpoolˑUartBuffer: rt.ObjectPool([64]u8, 8)

tuckˑfnˑhandleUart :: proc () {
  tuckˑvˑbuf := rt.acquire(&tuckˑpoolˑUartBuffer)
  if !(tuckˑvˑbuf.status == .Ok) {
      return
  }
  rt.release(&tuckˑpoolˑUartBuffer, tuckˑvˑbuf.value)
  return
}

main :: proc() {
}
