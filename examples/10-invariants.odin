#+feature dynamic-literals
package main

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

main :: proc() {
}
