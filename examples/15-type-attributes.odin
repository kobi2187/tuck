#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"

TRec_value :: struct ($T_value: typeid) {
	value: T_value,
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

drain_tuck_UartDriver :: proc() -> bool { return false }

tuck_readSensor :: proc(payload: $T) -> rt.TuckResult(TRec_value(u16)) {
	fmt.println("TUCK PENDING: tuck_readSensor invoked (not implemented)")
	return {}
}

main :: proc() {
}
