# sys.window — Nim API

## Purpose
Ask the OS for a window or rendering surface, find out what the user did to
it, and hand the pixels or the native handle to whatever draws them — one
level below every GUI toolkit and every game engine, the SDL2/GLFW/raylib
altitude, not the Qt/GTK one. No layout, no widgets, no retained scene graph:
create a surface, poll input, present a frame.

*New in this pass — not yet validated by an app in `INDEX.md`'s set.*
`DOMAINS.md`'s cross-domain synthesis found desktop, game, and mobile each
hit this same absence independently; this module answers all three, once,
rather than three times. Recommended rung: **A** — ships with the compiler,
same as every other `sys` module, because the primitive shape (open a
surface, receive events, present a frame) is decades-stable even though the
OS calls underneath it vary per platform.

## Protocols implemented
`Surface` is `Resource` + `Messenger[InputEvent]` — receiving an input event
is exactly PROTOCOLS' "hand off a message," and polling is `receive` with a
zero timeout rather than a new verb. `pixels`, `present` and `handle` are
domain verbs; a framebuffer has no structural analogue, the same reasoning
`sys.net` already gives for socket options.

## The API

```nim
type
  Surface* = object           ## Resource + Messenger[InputEvent]
  OsHandle* = distinct pointer ## opaque native window handle — HWND, NSWindow*, ANativeWindow*

  EventKind* = enum
    ekKey, ekMouseMove, ekMouseButton, ekTouch, ekResize, ekFocus, ekClose

  KeyCode* = distinct int32   ## OS scancode, not a decoded character — std.i18n's job if text is wanted
  MouseButton* = enum mbLeft, mbRight, mbMiddle

  InputEvent* = object
    case kind*: EventKind
    of ekKey:         key*: KeyCode; pressed*: bool
    of ekMouseMove:    x*, y*: float32
    of ekMouseButton:  button*: MouseButton; pressed*: bool
    of ekTouch:        touchId*: int; x*, y*: float32; pressed*: bool
    of ekResize:       width*, height*: int
    of ekFocus:        gained*: bool
    of ekClose:        discard

proc newSurface*(title: string; width, height: int; resizable = true): Surface
proc trySurface*(title: string; width, height: int; resizable = true): Option[Surface]
  ## Absent rather than a raise where no display server is reachable at all
  ## (a headless CI box) — the one place this module expects that failure
  ## mode to be routine rather than exceptional.

proc close*(s: var Surface)                 ## Resource: idempotent, like every close in this library
proc isOpen*(s: Surface): bool
proc size*(s: Surface): (int, int)

proc receive*(s: var Surface; timeout = 0.seconds): Option[InputEvent]
  ## `timeout = 0.seconds` IS the poll — "what happened since I last asked,"
  ## nothing if nothing did. `Forever` blocks until the next event, for a
  ## thread whose only job is reading input. One verb serves both shapes.

proc pixels*(s: var Surface): var openArray[byte]
  ## The CPU framebuffer, row-major, RGBA8. Writing into it and calling
  ## `present` is the whole software-rendering path — no format negotiation,
  ## no swapchain to configure.
proc present*(s: var Surface)
  ## Pushes `pixels` (or, on a handle-based GPU path, the last submitted
  ## frame) to the screen. Named for what it does, not for the mechanism
  ## underneath — "flip," "swap" and "blit" are three names for the same act
  ## across three APIs this module deliberately doesn't pick a side on.

proc handle*(s: Surface): OsHandle
  ## The raw native window handle, for a GPU context (OpenGL/Vulkan/Metal)
  ## created through `sys.ffi` — the same escape-hatch shape `sys.net::handle`
  ## already uses for `std.async`'s reactor. Nothing in `sys` calls this;
  ## it exists so higher layers can.
```

## Friendly-naming notes

| Precedent (SDL2/GLFW) | Nim name | Why |
|---|---|---|
| `SDL_CreateWindow` | `newSurface(title, width, height)` | one constructor; `resizable` is a named option, not a flags bitmask |
| `SDL_PollEvent` / `SDL_WaitEvent` | `receive(s, timeout =)` | two SDL functions for "poll" and "block" collapse into one verb with a timeout, same resolution `sys.fs::Watcher` already uses |
| `SDL_Event` tagged union | `InputEvent` case object | same shape, Nim's native discriminated union instead of a C union + `type` tag field |
| `glfwSwapBuffers` / `SDL_RenderPresent` | `present(s)` | one word instead of two APIs' two words for the same act |
| `SDL_GetWindowWMInfo` | `handle(s)` | same escape-hatch purpose, same name `sys.net` already uses for its raw fd |
| `SDL_LockSurface` / `UnlockSurface` | `pixels(s)` returns `var openArray[byte]` directly | Nim's `var` return *is* the lock; there is nothing to unlock separately |

## In use

```nim
# a game's fixed-timestep loop (per DOMAINS.md's game persona)
var win = newSurface("asteroids", 800, 600)
while win.isOpen():
  while (let ev = win.receive(); ev.isSome):
    ev.get().ifSome(e):
      if e.kind == ekClose: win.close()
      elif e.kind == ekKey: handleInput(e.key, e.pressed)
  step(world, fixedDt)
  world.draw(win.pixels())
  win.present()

# a desktop app: draw nothing itself, just host a GPU context via sys.ffi
var win = newSurface("dashboard", 1024, 768)
let ctx = glCreateContext(win.handle())      # sys.ffi call into the platform's GL loader
```

## Vocabulary exceptions
- **`pixels`, `present` and `handle` are domain verbs**, per PROTOCOLS' rule
  that a structural word is used only where the structural meaning actually
  holds — a framebuffer is not a `Collection`, and forcing `list`/`get` onto
  raw pixel bytes would teach the wrong lesson about what those verbs mean
  elsewhere.
- **`Surface` is a `Messenger` with `receive` but no `send`.** Nothing is
  ever sent to a window; the half-protocol is named rather than filled with
  a raising stub, the same resolution `std.log` already uses for `Log`.
- **Left unresolved, on purpose.** Multi-window management (which surface is
  focused, z-order) has no answer here — no app or domain persona in this
  project's validation set needs more than one surface at a time, so nothing
  is speculatively added. GPU context *creation itself* stays entirely out
  of this module's scope; `handle()` is the whole answer, and everything
  past it is `sys.ffi` plus a graphics-API binding, deliberately left there
  rather than reinvented.
