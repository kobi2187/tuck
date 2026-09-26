#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

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
  tuckˑvˑs := rt.acquire(&tuckˑpoolˑSessions)
  if (tuckˑvˑs.status == .Ok) {
      return 1
  }
  return 0
}

tuckˑfnˑdrainOnce :: proc () -> int {
  tuckˑvˑb := rt.acquire(&tuckˑpoolˑRxBuffers)
  if (tuckˑvˑb.status == .Ok) {
      rt.release(&tuckˑpoolˑRxBuffers, tuckˑvˑb.value)
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
