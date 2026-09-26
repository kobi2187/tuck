#+feature dynamic-literals
package main

import rt "./tuckrt"

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

main :: proc() {
}
