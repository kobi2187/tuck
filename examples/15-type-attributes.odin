#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"

TRec_value :: struct ($T_value: typeid) {
	value: T_value,
}

tuck_type_EthernetFrame :: struct {
	dst: [6]u8,
	src: [6]u8,
	ethertype: u16,
}

tuck_type_Temperature :: struct {
	celsius: f32,
}
validate_tuck_type_Temperature :: proc(self: tuck_type_Temperature) {
	assert((self.celsius >= -273.15))
}
__validated_tuck_type_Temperature :: proc(v: tuck_type_Temperature) -> tuck_type_Temperature {
	validate_tuck_type_Temperature(v)
	return v
}

tuck_type_UartDriver :: struct {
}

tuck_type_UartDriverSingleton: tuck_type_UartDriver

drain_tuck_type_UartDriver :: proc() -> bool { return false }

tuck_fn_readSensor :: proc(payload: $T) -> rt.TuckResult(TRec_value(u16)) {
	fmt.println("TUCK PENDING: tuck_fn_readSensor invoked (not implemented)")
	return {}
}

main :: proc() {
}
