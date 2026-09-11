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

joinStr :: proc(parts: [dynamic]string, sep: string) -> string {
	return rt.joinStr(parts, sep)
}

byteAt :: proc(t: string, index: int) -> u8 {
	return rt.byteAt(t, index)
}

byteCount :: proc(t: string) -> int {
	return rt.byteCount(t)
}

parseFloat :: proc(t: string) -> rt.TuckResult(f64) {
	return rt.parseFloat(t)
}

fromBytes :: proc(bytes: [dynamic]u8) -> string {
	return rt.fromBytes(bytes)
}


