#+feature dynamic-literals
package tuck_str

import rt "../tuckrt"

toStr :: proc(value: $T) -> string {
	return rt.toStr(value)
}

charAt :: proc(s: string, index: int) -> string {
	return rt.charAt(s, index)
}

containsChar :: proc(s: string, ch: string) -> bool {
	return rt.containsChar(s, ch)
}

splitLines :: proc(s: string) -> [dynamic]string {
	return rt.splitLines(s)
}

ord :: proc(ch: string) -> int {
	return rt.ord(ch)
}


