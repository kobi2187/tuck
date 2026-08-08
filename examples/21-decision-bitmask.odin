package main

tuck_Priority :: enum { High, Low }

tuck_route :: proc(priority: tuck_Priority, encrypted: bool) -> int {
	switch int(priority) * 2 + (encrypted ? 1 : 0) {   // packed decision key
	case 0: return 2
	case 1: return 1
	case: return 3
	}
}

main :: proc() {
}
