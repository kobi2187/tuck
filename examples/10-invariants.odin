package main

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

main :: proc() {
}
