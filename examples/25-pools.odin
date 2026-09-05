package main

import "core:os"
import rt "./tuckrt"

tuck_RxBuffers: rt.ObjectPool([512]u8, 4)

tuck_Session :: struct {
	clientId: u32,
	bytesIn: u32,
}

tuck_Sessions: rt.ObjectPool(tuck_Session, 64)

tuck_SensorReading :: struct {
	channel: u8,
	value: u16,
}

tuck_Readings: rt.ObjectPool(tuck_SensorReading, 16)

tuck_admit :: proc (id: u32) -> int {
  tuck_s := rt.acquire(&tuck_Sessions)
  if (tuck_s.status == .Ok) {
      return 1
  }
  return 0
}

tuck_drainOnce :: proc () -> int {
  tuck_b := rt.acquire(&tuck_RxBuffers)
  if (tuck_b.status == .Ok) {
      rt.release(&tuck_RxBuffers, tuck_b.value)
      return 1
  }
  return 0
}

tuck_main :: proc () -> int {
  tuck_admitted := 0
  tuck_admitted = (tuck_admitted + tuck_admit(1))
  tuck_admitted = (tuck_admitted + tuck_admit(2))
  tuck_admitted = (tuck_admitted + tuck_admit(3))
  tuck_drained := tuck_drainOnce()
  return (tuck_admitted + tuck_drained)
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
