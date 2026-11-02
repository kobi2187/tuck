package tuckrt

// THE SEQ ARENA — small blocks without the general heap's bookkeeping.
//
// Every Seq, str and sum payload the ownership rules allocate and drop goes
// through the context allocator, which is `malloc`/`free` behind Odin's
// heap_allocator_proc: ~60% of a tree-building program's instructions (callgrind).
// This is the same design as the D runtime's tuck_arena.d: one reserved
// address range cut into a segment per size class, so a block's class is
// `(p - base) / SEG` and no block carries a header; a thread-local free list
// per class, so the hot path takes no lock. Anything the arena does not own
// (big blocks, over-aligned requests, a pointer from before it existed) goes
// to the heap allocator it wraps, and a free is routed by address.
import "base:intrinsics"
import "base:runtime"
import "core:mem"
import "core:sys/linux"

@(private="file") ARENA_SEG :: 256 * 1024 * 1024
@(private="file") ARENA_MAX :: 4096
@(private="file") ARENA_CLASSES :: 24
@(private="file") arenaClassBytes := [ARENA_CLASSES]int{
	16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256,
	320, 384, 448, 512, 640, 768, 896, 1024, 1536, 2048, 3072, 4096}

@(private="file") gArenaBase: uintptr
@(private="file") gArenaBump: [ARENA_CLASSES]uintptr
@(private="file") gArenaLock: [ARENA_CLASSES]i32
@(private="file") gArenaClassOf: [ARENA_MAX / 16 + 1]u8
@(private="file", thread_local) tArenaCache: [ARENA_CLASSES]rawptr

// Reserve the range and fill the class table. A failed reservation leaves the
// arena off: every request then goes to the heap.
tuckArenaInit :: proc "contextless" () {
	when ODIN_OS == .Linux {
		if gArenaBase != 0 do return
		c := 0
		for i in 0 ..< len(gArenaClassOf) {
			for arenaClassBytes[c] < i * 16 do c += 1
			gArenaClassOf[i] = u8(c)
		}
		p, err := linux.mmap(0, uint(ARENA_SEG) * ARENA_CLASSES, {.READ, .WRITE},
			{.PRIVATE, .ANONYMOUS, .NORESERVE})
		if err != .NONE do return
		for i in 0 ..< ARENA_CLASSES {
			gArenaBump[i] = uintptr(p) + uintptr(i * ARENA_SEG)
		}
		gArenaBase = uintptr(p)
	}
}

@(private)
inArena :: #force_inline proc "contextless" (p: rawptr) -> bool {
	return gArenaBase != 0 && uintptr(p) - gArenaBase < uintptr(ARENA_SEG * ARENA_CLASSES)
}

// How many bytes the arena block starting at `p` holds, or 0 when `p` is not
// the start of one.
@(private)
arenaCapacity :: #force_inline proc "contextless" (p: rawptr) -> int {
	if !inArena(p) do return 0
	off := int(uintptr(p) - gArenaBase)
	c := off / ARENA_SEG
	if (off % ARENA_SEG) % arenaClassBytes[c] != 0 do return 0
	return arenaClassBytes[c]
}

@(private)
arenaTake :: proc "contextless" (size: int) -> rawptr {
	c := int(gArenaClassOf[(size + 15) >> 4])
	if p := tArenaCache[c]; p != nil {
		tArenaCache[c] = ([^]rawptr)(p)[0]
		return p
	}
	for {
		_, ok := intrinsics.atomic_compare_exchange_weak_explicit(&gArenaLock[c], 0, 1, .Acquire, .Relaxed)
		if ok do break
	}
	p: rawptr
	if gArenaBump[c] + uintptr(arenaClassBytes[c]) <= gArenaBase + uintptr((c + 1) * ARENA_SEG) {
		p = rawptr(gArenaBump[c])
		gArenaBump[c] += uintptr(arenaClassBytes[c])
	}
	intrinsics.atomic_store_explicit(&gArenaLock[c], 0, .Release)
	return p
}

@(private)
arenaGive :: proc "contextless" (p: rawptr) {
	off := int(uintptr(p) - gArenaBase)
	c := off / ARENA_SEG
	if (off % ARENA_SEG) % arenaClassBytes[c] != 0 do return   // an interior slice: its block's business
	([^]rawptr)(p)[0] = tArenaCache[c]
	tArenaCache[c] = p
}

tuckArenaProc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
                      old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size > 0 && size <= ARENA_MAX && alignment <= 16 && gArenaBase != 0 {
			if p := arenaTake(size); p != nil {
				if mode == .Alloc do mem.zero(p, size)
				return ([^]byte)(p)[:size], nil
			}
		}
		return runtime.heap_allocator_proc(nil, mode, size, alignment, old, old_size, loc)
	case .Free:
		if inArena(old) {
			arenaGive(old)
			return nil, nil
		}
		return runtime.heap_allocator_proc(nil, mode, size, alignment, old, old_size, loc)
	case .Resize, .Resize_Non_Zeroed:
		if old == nil || !inArena(old) {
			if old == nil && size > 0 && size <= ARENA_MAX && alignment <= 16 && gArenaBase != 0 {
				return tuckArenaProc(data, .Alloc if mode == .Resize else .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
			}
			return runtime.heap_allocator_proc(nil, mode, size, alignment, old, old_size, loc)
		}
		capacity := arenaCapacity(old)
		if capacity > 0 && size > 0 && size <= capacity {
			if mode == .Resize && size > old_size do mem.zero(rawptr(uintptr(old) + uintptr(old_size)), size - old_size)
			return ([^]byte)(old)[:size], nil
		}
		fresh, err := tuckArenaProc(data, .Alloc_Non_Zeroed if mode == .Resize_Non_Zeroed else .Alloc, size, alignment, nil, 0, loc)
		if err != nil do return nil, err
		mem.copy(raw_data(fresh), old, min(old_size, size))
		if capacity > 0 do arenaGive(old)
		return fresh, nil
	case .Free_All, .Query_Info:
		return nil, .Mode_Not_Implemented
	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old)
		if set != nil do set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		return nil, nil
	}
	return nil, nil
}

// The context's allocator, when it is the heap or this arena over it: the
// two runtime helpers that look inside heap blocks (str append) ask this.
@(private)
tuckHeapLike :: proc() -> bool {
	p := context.allocator.procedure
	return p == runtime.heap_allocator_proc || p == tuckArenaProc
}
