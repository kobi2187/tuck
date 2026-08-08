package main

import rt "./tuckrt"

TRec_value_638E :: struct {
	value: u16,
}

tuck_EthernetFrame :: struct {
	dst: [6]u8,
	src: [6]u8,
	ethertype: u16,
}

tuck_Temperature :: struct {
	celsius: f32,
}
validate_tuck_Temperature :: proc(self: tuck_Temperature) {
	assert((self.celsius >= -273.15))
}
__validated_tuck_Temperature :: proc(v: tuck_Temperature) -> tuck_Temperature {
	validate_tuck_Temperature(v)
	return v
}

tuck_UartDriver :: struct {
}

tuck_UartDriverSingleton: tuck_UartDriver

drain_tuck_UartDriver :: proc() {
	for { rt.coroYield() }
}

tuck_readSensor :: proc (port: u8) -> rt.TuckResult(TRec_value_638E) {

  return {}
}

main :: proc() {
	rt.tuckAsyncInit()
	rt.tuckStartActor(drain_tuck_UartDriver)
}
