// Odin impl module for sys.window's X11 backend — the twin of x11_shim.nim.
package x11_shim

import "core:c"
import "core:strings"
import "core:time"

foreign import x11 "system:X11"

@(default_calling_convention = "c", private)
foreign x11 {
	XOpenDisplay :: proc(name: cstring) -> rawptr ---
	XCloseDisplay :: proc(d: rawptr) -> c.int ---
	XDefaultScreen :: proc(d: rawptr) -> c.int ---
	XRootWindow :: proc(d: rawptr, s: c.int) -> c.ulong ---
	XBlackPixel :: proc(d: rawptr, s: c.int) -> c.ulong ---
	XCreateSimpleWindow :: proc(d: rawptr, parent: c.ulong, x, y: c.int, w, h, bw: c.uint, border, bg: c.ulong) -> c.ulong ---
	XStoreName :: proc(d: rawptr, w: c.ulong, name: cstring) -> c.int ---
	XSelectInput :: proc(d: rawptr, w: c.ulong, mask: c.long) -> c.int ---
	XMapWindow :: proc(d: rawptr, w: c.ulong) -> c.int ---
	XDestroyWindow :: proc(d: rawptr, w: c.ulong) -> c.int ---
	XFlush :: proc(d: rawptr) -> c.int ---
	XPending :: proc(d: rawptr) -> c.int ---
	XNextEvent :: proc(d: rawptr, ev: rawptr) -> c.int ---
	XSendEvent :: proc(d: rawptr, w: c.ulong, prop: c.int, mask: c.long, ev: rawptr) -> c.int ---
	XSync :: proc(d: rawptr, discard_: c.int) -> c.int ---
}

@(private) Win :: struct {
	dpy:  rawptr,
	id:   c.ulong,
	root: c.ulong,
	live: bool,
}

@(private) gWins: [dynamic]Win

@(private)
valid :: proc(h: int) -> bool { return h >= 0 && h < len(gWins) && gWins[h].live }

// A window handle >= 0, or -1 when there is no X server.
xOpen :: proc(title: string, w: int, h: int) -> int {
	d := XOpenDisplay(nil)
	if d == nil do return -1
	s := XDefaultScreen(d)
	root := XRootWindow(d, s)
	win := XCreateSimpleWindow(d, root, 0, 0, c.uint(w), c.uint(h), 0, 0, XBlackPixel(d, s))
	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	XStoreName(d, win, ctitle)
	XSelectInput(d, win, c.long(1 | 2 | 4 | 8 | 64))
	XMapWindow(d, win)
	XFlush(d)
	append(&gWins, Win{dpy = d, id = win, root = root, live = true})
	return len(gWins) - 1
}

@(private)
rd :: proc(ev: ^[24]c.long, off: int) -> int {
	return int((^i32)(uintptr(rawptr(ev)) + uintptr(off))^)
}

// One input event as [kind, code, x, y], or empty after the timeout.
xPoll :: proc(h: int, timeoutMs: int) -> [dynamic]int {
	out := make([dynamic]int)
	if !valid(h) do return out
	waited := 0
	for XPending(gWins[h].dpy) == 0 {
		if waited >= timeoutMs do return out
		time.sleep(time.Millisecond)
		waited += 1
	}
	ev: [24]c.long
	for XPending(gWins[h].dpy) > 0 {
		XNextEvent(gWins[h].dpy, &ev)
		t := rd(&ev, 0)
		switch t {
		case 2, 3:
			append(&out, t == 2 ? 1 : 2, rd(&ev, 84), rd(&ev, 64), rd(&ev, 68))
			return out
		case 4, 5:
			append(&out, t == 4 ? 3 : 4, rd(&ev, 84), rd(&ev, 64), rd(&ev, 68))
			return out
		case 6:
			append(&out, 5, 0, rd(&ev, 64), rd(&ev, 68))
			return out
		}
	}
	return out
}

// Send a key event to our own window, the way a test or a script drives input.
xInject :: proc(h: int, code: int, down: bool) {
	if !valid(h) do return
	ev: [24]c.long
	p := uintptr(rawptr(&ev))
	(^i32)(p + 0)^ = down ? 2 : 3
	(^rawptr)(p + 24)^ = gWins[h].dpy
	(^c.ulong)(p + 32)^ = gWins[h].id
	(^c.ulong)(p + 40)^ = gWins[h].root
	(^i32)(p + 84)^ = i32(code)
	(^i32)(p + 88)^ = 1
	XSendEvent(gWins[h].dpy, gWins[h].id, 0, down ? 1 : 2, &ev)
	XSync(gWins[h].dpy, 0)
}

xPresent :: proc(h: int) {
	if valid(h) do XFlush(gWins[h].dpy)
}

xClose :: proc(h: int) {
	if !valid(h) do return
	XDestroyWindow(gWins[h].dpy, gWins[h].id)
	XCloseDisplay(gWins[h].dpy)
	gWins[h].live = false
}
