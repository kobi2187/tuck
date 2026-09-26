#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"

TRec_value :: struct ($T_value: typeid) {
	value: T_value,
}

tuckˑtypeˑEthernetFrame :: struct {
	dst: [6]u8,
	src: [6]u8,
	ethertype: u16,
}

tuckˑtypeˑTemperature :: struct {
	celsius: f32,
}
validate_tuckˑtypeˑTemperature :: proc(self: tuckˑtypeˑTemperature) {
	when !#config(tuckNoInvariants, false) {
		if !((self.celsius >= -273.15)) {
			rt.tuckInvariantFailed("(self.celsius >= -273.15)", "tuckˑtypeˑTemperature")
		}
	}
}
__validated_tuckˑtypeˑTemperature :: proc(v: tuckˑtypeˑTemperature) -> tuckˑtypeˑTemperature {
	validate_tuckˑtypeˑTemperature(v)
	return v
}

tuckˑactorˑUartDriver :: struct {
}

tuckˑactorˑUartDriverSingleton: tuckˑactorˑUartDriver

drain_tuckˑactorˑUartDriver :: proc() -> bool { return false }

tuckˑfnˑreadSensor :: proc(payload: $T) -> rt.TuckResult(TRec_value(u16)) {
	fmt.println("TUCK PENDING: readSensor invoked (not implemented)")
	return {}
}

main :: proc() {
}
