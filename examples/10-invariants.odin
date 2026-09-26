#+feature dynamic-literals
package main

tuckˑtypeˑTemperature :: struct {
	celsius: f32,
}
validate_tuckˑtypeˑTemperature :: proc(self: tuckˑtypeˑTemperature) {
	assert((self.celsius >= -273.15))
}
__validated_tuckˑtypeˑTemperature :: proc(v: tuckˑtypeˑTemperature) -> tuckˑtypeˑTemperature {
	validate_tuckˑtypeˑTemperature(v)
	return v
}

main :: proc() {
}
