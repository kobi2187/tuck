// Odin impl module for sys.ble's Linux HCI scanner — the twin of hci_shim.nim.
package hci_shim

import "core:c"
import "core:sys/linux"

foreign import bt "system:bluetooth"
foreign import libc "system:c"

@(default_calling_convention = "c", private)
foreign bt {
	hci_open_dev :: proc(dev: c.int) -> c.int ---
	hci_le_set_scan_parameters :: proc(dd: c.int, kind: u8, interval, window: u16, own: u8, filter: u8, to: c.int) -> c.int ---
	hci_le_set_scan_enable :: proc(dd: c.int, enable: u8, filterDup: u8, to: c.int) -> c.int ---
	hci_close_dev :: proc(dd: c.int) -> c.int ---
}

@(default_calling_convention = "c", private)
foreign libc {
	setsockopt :: proc(fd: c.int, level: c.int, name: c.int, val: rawptr, len: c.uint) -> c.int ---
	poll :: proc(fds: rawptr, n: c.ulong, to: c.int) -> c.int ---
	read :: proc(fd: c.int, buf: rawptr, n: c.size_t) -> c.ssize_t ---
	__errno_location :: proc() -> ^c.int ---
}

@(private) PollFd :: struct #packed { fd: c.int, events: i16, revents: i16 }

@(private) gSocks: [dynamic]c.int

@(private)
valid :: proc(h: int) -> bool { return h >= 0 && h < len(gSocks) && gSocks[h] >= 0 }

// A scanner handle >= 0; -1 no such adapter; -2 not permitted / refused.
hciOpen :: proc(adapter: int) -> int {
	dd := hci_open_dev(c.int(adapter))
	if dd < 0 {
		e := __errno_location()^
		return (e == 1 || e == 13) ? -2 : -1
	}
	if hci_le_set_scan_parameters(dd, 0, 0x0010, 0x0010, 0, 0, 1000) < 0 ||
	   hci_le_set_scan_enable(dd, 1, 0, 1000) < 0 {
		hci_close_dev(dd)
		return -2
	}
	filter: [16]u8
	filter[0] = 1 << 4
	filter[8 + 3] = 1 << (62 - 32 - 24)
	setsockopt(dd, 0, 2, &filter[0], 14)
	append(&gSocks, dd)
	return len(gSocks) - 1
}

// One packet, or empty after the timeout.
hciRead :: proc(h: int, timeoutMs: int) -> [dynamic]u8 {
	out := make([dynamic]u8)
	if !valid(h) do return out
	p := PollFd{fd = gSocks[h], events = 1}
	if poll(&p, 1, c.int(timeoutMs)) <= 0 do return out
	buf: [260]u8
	n := int(read(gSocks[h], &buf[0], 260))
	if n <= 0 do return out
	for i in 0 ..< n do append(&out, buf[i])
	return out
}

hciClose :: proc(h: int) {
	if !valid(h) do return
	hci_le_set_scan_enable(gSocks[h], 0, 0, 1000)
	hci_close_dev(gSocks[h])
	gSocks[h] = -1
}
