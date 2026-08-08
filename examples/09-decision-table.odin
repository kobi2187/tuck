package main

tuck_Priority :: enum { high, low }

tuck_SizeClass :: enum { big, small }

tuck_Action :: enum { QueueSecure, QueueFast, QueueImmediate, QueueDefer }

tuck_classifyPacket :: proc(priority: tuck_Priority, size: tuck_SizeClass, encrypted: bool) -> tuck_Action {
	switch int(priority) * 4 + int(size) * 2 + (encrypted ? 1 : 0) {   // packed decision key
	case 0: return tuck_Action.QueueFast
	case 1: return tuck_Action.QueueSecure
	case 2, 3: return tuck_Action.QueueImmediate
	case: return tuck_Action.QueueDefer
	}
}

main :: proc() {
}
