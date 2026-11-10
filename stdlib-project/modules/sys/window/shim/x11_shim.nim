# Nim impl module for sys.window's X11 backend — twins: x11_shim.odin and
# x11_shim.d. The `Display*` and window id stay in this table; Tuck holds a
# HANDLE and receives input as small integer records [kind, code, x, y]:
# kind 1 key press, 2 key release, 3 button press, 4 button release, 5 motion.
# Needs an X server ($DISPLAY); Xvfb will do.
{.passL: "-lX11".}
import std/os

proc XOpenDisplay(name: cstring): pointer {.importc, cdecl.}
proc XCloseDisplay(d: pointer): cint {.importc, cdecl.}
proc XDefaultScreen(d: pointer): cint {.importc, cdecl.}
proc XRootWindow(d: pointer, s: cint): culong {.importc, cdecl.}
proc XBlackPixel(d: pointer, s: cint): culong {.importc, cdecl.}
proc XCreateSimpleWindow(d: pointer, parent: culong, x, y: cint, w, h, bw: cuint,
                         border, bg: culong): culong {.importc, cdecl.}
proc XStoreName(d: pointer, w: culong, name: cstring): cint {.importc, cdecl.}
proc XSelectInput(d: pointer, w: culong, mask: clong): cint {.importc, cdecl.}
proc XMapWindow(d: pointer, w: culong): cint {.importc, cdecl.}
proc XDestroyWindow(d: pointer, w: culong): cint {.importc, cdecl.}
proc XFlush(d: pointer): cint {.importc, cdecl.}
proc XPending(d: pointer): cint {.importc, cdecl.}
proc XNextEvent(d: pointer, ev: pointer): cint {.importc, cdecl.}
proc XSendEvent(d: pointer, w: culong, prop: cint, mask: clong, ev: pointer): cint {.importc, cdecl.}
proc XSync(d: pointer, discardAll: cint): cint {.importc, cdecl.}

type Win = object
  dpy: pointer
  id: culong
  root: culong
  live: bool

var gWins: seq[Win]

proc valid(h: int): bool = h >= 0 and h < gWins.len and gWins[h].live

proc xOpen*(title: string, w, h: int): int =
  ## A window handle >= 0, or -1 when there is no X server.
  let d = XOpenDisplay(nil)
  if d == nil: return -1
  let s = XDefaultScreen(d)
  let root = XRootWindow(d, s)
  let win = XCreateSimpleWindow(d, root, 0, 0, cuint w, cuint h, 0, 0, XBlackPixel(d, s))
  discard XStoreName(d, win, title.cstring)
  # KeyPress|KeyRelease|ButtonPress|ButtonRelease|PointerMotion
  discard XSelectInput(d, win, clong(1 or 2 or 4 or 8 or 64))
  discard XMapWindow(d, win)
  discard XFlush(d)
  gWins.add Win(dpy: d, id: win, root: root, live: true)
  gWins.len - 1

proc rd(ev: ptr array[24, clong], off: int): int =
  ## A 32-bit int at a byte offset of the event.
  cast[ptr int32](cast[int](ev) + off)[]

proc xPoll*(h, timeoutMs: int): seq[int] =
  ## One input event as [kind, code, x, y], or empty after the timeout.
  if not valid(h): return @[]
  var waited = 0
  while XPending(gWins[h].dpy) == 0:
    if waited >= timeoutMs: return @[]
    sleep(1)
    inc waited
  var ev: array[24, clong]
  while XPending(gWins[h].dpy) > 0:
    discard XNextEvent(gWins[h].dpy, addr ev)
    let t = rd(addr ev, 0)
    case t
    of 2, 3: return @[(if t == 2: 1 else: 2), rd(addr ev, 84), rd(addr ev, 64), rd(addr ev, 68)]
    of 4, 5: return @[(if t == 4: 3 else: 4), rd(addr ev, 84), rd(addr ev, 64), rd(addr ev, 68)]
    of 6: return @[5, 0, rd(addr ev, 64), rd(addr ev, 68)]
    else: discard
  @[]

proc xInject*(h, code: int, down: bool) =
  ## Send a key event to our own window, the way a test or a script drives input.
  if not valid(h): return
  var ev: array[24, clong]
  let p = cast[int](addr ev)
  cast[ptr int32](p + 0)[] = int32(if down: 2 else: 3)
  cast[ptr pointer](p + 24)[] = gWins[h].dpy
  cast[ptr culong](p + 32)[] = gWins[h].id
  cast[ptr culong](p + 40)[] = gWins[h].root
  cast[ptr int32](p + 84)[] = int32 code
  cast[ptr int32](p + 88)[] = 1
  discard XSendEvent(gWins[h].dpy, gWins[h].id, 0, clong(if down: 1 else: 2), addr ev)
  discard XSync(gWins[h].dpy, 0)

proc xPresent*(h: int) =
  if valid(h): discard XFlush(gWins[h].dpy)

proc xClose*(h: int) =
  if not valid(h): return
  discard XDestroyWindow(gWins[h].dpy, gWins[h].id)
  discard XCloseDisplay(gWins[h].dpy)
  gWins[h].live = false
