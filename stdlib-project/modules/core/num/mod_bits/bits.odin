#+feature dynamic-literals
package tuck_bits

import rt "../tuckrt"

bitAnd :: proc(a: u64, b: u64) -> u64 {
	return rt.bitAnd(a, b)
}

bitOr :: proc(a: u64, b: u64) -> u64 {
	return rt.bitOr(a, b)
}

bitXor :: proc(a: u64, b: u64) -> u64 {
	return rt.bitXor(a, b)
}

bitNot :: proc(a: u64) -> u64 {
	return rt.bitNot(a)
}

shiftLeft :: proc(a: u64, by: int) -> u64 {
	return rt.shiftLeft(a, by)
}

shiftRight :: proc(a: u64, by: int) -> u64 {
	return rt.shiftRight(a, by)
}


