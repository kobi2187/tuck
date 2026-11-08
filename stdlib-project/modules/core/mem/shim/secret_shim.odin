// Odin impl module for core.mem's secret buffers — the twin of secret_shim.nim.
package secret_shim

import "core:sys/linux"
import "base:runtime"

foreign import libc "system:c"

@(default_calling_convention = "c", private)
foreign libc {
	explicit_bzero :: proc(p: rawptr, n: uint) ---
	mlock :: proc(p: rawptr, n: uint) -> i32 ---
	munlock :: proc(p: rawptr, n: uint) -> i32 ---
	calloc :: proc(n, size: uint) -> rawptr ---
	free :: proc(p: rawptr) ---
}

@(private) Secret :: struct {
	data: [^]u8,
	len:  int,
	live: bool,
}

@(private) gSecrets: [dynamic]Secret

@(private)
valid :: proc(h: int) -> bool { return h >= 0 && h < len(gSecrets) && gSecrets[h].live }

// A zeroed, locked buffer of n bytes; its handle.
secretNew :: proc(n: int) -> int {
	size := uint(max(n, 1))
	p := cast([^]u8)calloc(size, 1)
	mlock(p, size)
	append(&gSecrets, Secret{data = p, len = n, live = true})
	return len(gSecrets) - 1
}

secretLen :: proc(h: int) -> int {
	if !valid(h) do return 0
	return gSecrets[h].len
}

secretSet :: proc(h: int, i: int, v: int) {
	if !valid(h) || i < 0 || i >= gSecrets[h].len do return
	gSecrets[h].data[i] = u8(v & 255)
}

secretGet :: proc(h: int, i: int) -> int {
	if !valid(h) || i < 0 || i >= gSecrets[h].len do return 0
	return int(gSecrets[h].data[i])
}

// Overwrite (unremovably), unlock, free. The handle is dead afterwards.
secretWipe :: proc(h: int) {
	if !valid(h) do return
	size := uint(max(gSecrets[h].len, 1))
	explicit_bzero(gSecrets[h].data, size)
	munlock(gSecrets[h].data, size)
	free(gSecrets[h].data)
	gSecrets[h].live = false
	gSecrets[h].len = 0
}
