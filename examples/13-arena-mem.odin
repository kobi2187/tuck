#+feature dynamic-literals
package main

tuck_ScratchSpace :: struct {
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	if rt.tuckTrackReport() > 0 { os.exit(90) }
}
