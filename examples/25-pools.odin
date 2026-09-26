#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
foreign import libc "system:c"

tuckˑpoolˑRxBuffers: rt.ObjectPool([512]u8, 4)

tuckˑtypeˑSession :: struct {
	clientId: u32,
	bytesIn: u32,
}

tuckˑpoolˑSessions: rt.ObjectPool(tuckˑtypeˑSession, 64)

tuckˑtypeˑSensorReading :: struct {
	channel: u8,
	value: u16,
}

tuckˑpoolˑReadings: rt.ObjectPool(tuckˑtypeˑSensorReading, 16)

tuckˑfnˑadmit :: proc (id: u32) -> int {
  tuckˑvˑs := rt.tuckPoolAcquire(&tuckˑpoolˑSessions)
  if (tuckˑvˑs.status == .Ok) {
      return 1
  }
  return 0
}

@(default_calling_convention="c")
foreign libc {
	memset :: proc(p: [^]u8, c: int, n: int) ---
}

tuckˑfnˑdrainOnce :: proc () -> int {
  tuckˑvˑb := rt.tuckPoolAcquire(&tuckˑpoolˑRxBuffers)
  if !(tuckˑvˑb.status == .Ok) {
      return 0
  }
  tuckˑvˑdst := rt.tuckPoolAddr(&tuckˑpoolˑRxBuffers, tuckˑvˑb.value)
  memset(tuckˑvˑdst, 1, 512)
  tuckˑvˑrx := rt.tuckPoolRead(&tuckˑpoolˑRxBuffers, tuckˑvˑb.value)
  rt.tuckPoolRelease(&tuckˑpoolˑRxBuffers, tuckˑvˑb.value)
  if !(tuckˑvˑrx.status == .Ok) {
      return 0
  }
  tuckˑvˑbytes := tuckˑvˑrx.value
  if (rt.tuckArrayAt(tuckˑvˑbytes, 511) != 1) {
      return 0
  }
  tuckˑvˑr := rt.tuckPoolAcquire(&tuckˑpoolˑReadings)
  if !(tuckˑvˑr.status == .Ok) {
      return 0
  }
  tuckˑvˑreading := tuckˑtypeˑSensorReading{channel = u8(2), value = u16(700)}
  rt.tuckPoolWrite(&tuckˑpoolˑReadings, tuckˑvˑr.value, tuckˑvˑreading)
  tuckˑvˑback := rt.tuckPoolRead(&tuckˑpoolˑReadings, tuckˑvˑr.value)
  rt.tuckPoolRelease(&tuckˑpoolˑReadings, tuckˑvˑr.value)
  if (tuckˑvˑback.status == .Ok) {
      return 1
  }
  return 0
}

tuckˑfnˑmain :: proc () -> int {
  tuckˑvˑadmitted := 0
  tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(u32(1)))
  tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(u32(2)))
  tuckˑvˑadmitted = (tuckˑvˑadmitted + tuckˑfnˑadmit(u32(3)))
  tuckˑvˑdrained := tuckˑfnˑdrainOnce()
  return (tuckˑvˑadmitted + tuckˑvˑdrained)
}

main :: proc() {
	mainRc := tuckˑfnˑmain()
	os.exit(mainRc)
}
