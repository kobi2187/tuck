// Odin impl module for stdlib-project sys.mmap — the twin of mmap_shim.nim.
//
// Same contract: the mapping's address stays here, a HANDLE crosses, and every
// operation on the mapped bytes runs in this file. Only `mapCopy` hands bytes
// over, and only the window asked for.
package mmap_shim

import "core:strings"
import "core:sys/linux"

@(private)
Mapping :: struct {
	base: [^]u8,
	size: int,
	live: bool,
}

@(private) gMaps: [dynamic]Mapping

// -1 not found, -2 access denied, -3 anything else.
@(private)
errnoCode :: proc(e: linux.Errno) -> int {
	#partial switch e {
	case .ENOENT, .ENOTDIR: return -1
	case .EACCES, .EPERM:   return -2
	}
	return -3
}

@(private)
valid :: proc(handle: int) -> bool {
	return handle >= 0 && handle < len(gMaps) && gMaps[handle].live
}

// A read-only, private mapping of the whole file: a handle >= 0, or a negative
// code. An empty file maps to no memory (mmap refuses a zero length).
mapOpen :: proc(path: string) -> int {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, oerr := linux.open(cpath, {})
	if oerr != .NONE do return errnoCode(oerr)
	defer linux.close(fd)
	st: linux.Stat
	if serr := linux.fstat(fd, &st); serr != .NONE do return errnoCode(serr)
	size := int(st.size)
	base: rawptr = nil
	if size > 0 {
		p, merr := linux.mmap(0, uint(size), {.READ}, {.PRIVATE}, fd, 0)
		if merr != .NONE do return errnoCode(merr)
		base = p
	}
	append(&gMaps, Mapping{base = cast([^]u8)base, size = size, live = true})
	return len(gMaps) - 1
}

mapSize :: proc(handle: int) -> int {
	if !valid(handle) do return -1
	return gMaps[handle].size
}

mapClose :: proc(handle: int) {
	if !valid(handle) do return
	if gMaps[handle].size > 0 do linux.munmap(gMaps[handle].base, uint(gMaps[handle].size))
	gMaps[handle].live = false
}

// The byte at `at`, or -1 outside the mapping.
mapByte :: proc(handle: int, at: int) -> int {
	if !valid(handle) || at < 0 || at >= gMaps[handle].size do return -1
	return int(gMaps[handle].base[at])
}

// The first offset >= `start` where `what` begins, or -1.
mapFind :: proc(handle: int, what: string, start: int) -> int {
	if !valid(handle) || len(what) == 0 do return -1
	m := gMaps[handle]
	for i := max(start, 0); i + len(what) <= m.size; i += 1 {
		if m.base[i] != what[0] do continue
		k := 1
		for k < len(what) && m.base[i + k] == what[k] do k += 1
		if k == len(what) do return i
	}
	return -1
}

// How many bytes equal `value`.
mapCount :: proc(handle: int, value: int) -> int {
	if !valid(handle) do return 0
	m := gMaps[handle]
	n := 0
	for i in 0 ..< m.size {
		if int(m.base[i]) == value do n += 1
	}
	return n
}

// How many bytes in [start, start + n) equal `value`, clamped.
mapCountRange :: proc(handle: int, value: int, start: int, n: int) -> int {
	if !valid(handle) do return 0
	m := gMaps[handle]
	c := 0
	for i := max(start, 0); i < min(start + n, m.size); i += 1 {
		if int(m.base[i]) == value do c += 1
	}
	return c
}

// A copy of [start, start + n), clamped to the mapping.
mapCopy :: proc(handle: int, start: int, n: int) -> [dynamic]u8 {
	out := make([dynamic]u8)
	if !valid(handle) do return out
	m := gMaps[handle]
	a := max(start, 0)
	b := min(start + n, m.size)
	for i := a; i < b; i += 1 do append(&out, m.base[i])
	return out
}
