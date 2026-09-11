#+feature dynamic-literals
package tuck_seq

import rt "../tuckrt"

at :: proc(items: [dynamic]$T, index: int) -> T {
	return rt.at(items, index)
}

setAt :: proc(items: [dynamic]$T, index: int, value: T) {
	rt.setAt(items, index, value)
}

push :: proc(items: [dynamic]$T, value: T) -> [dynamic]T {
	return rt.push(items, value)
}

count :: proc(items: [dynamic]$T) -> int {
	return rt.count(items)
}

len :: proc(items: $T) -> int {
	return rt.getLength(items)
}


