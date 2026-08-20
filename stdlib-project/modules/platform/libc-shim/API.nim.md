# platform.libc-shim — Nim API

## Purpose
The short list of things a board-support package promises: somewhere to write bytes, somewhere to read them, what time it is, and one arena at startup. Anything above this tier that asks for something the board hasn't got gets a clear "unsupported" instead of a linker error.

## Protocols implemented
`Shim` is `Streamable` (`read`/`write` in their exact table sense, with an `Fd` locator) and `Gettable` for capabilities (`has`). Everything else is a domain verb.

## The API

```nim
type
  Fd* = distinct int32
const
  consoleOut* = Fd(1)      ## named, so nobody types a bare `1` and hopes
  consoleIn*  = Fd(0)
  consoleErr* = Fd(2)

type
  Ability* = enum Writing, Reading, WallClock, Console, BootArena
  Unsupported* = ref object of Failure
    ## core.error's type. This board genuinely has no backing for that call — not
    ## "not implemented yet". `retryable` is always false: trying again won't help.
  NotReady* = ref object of Failure    ## would block; try again later

  Shim* = concept s
    write(s, Fd, Bytes): Count
    read(s, Fd, var openArray[byte]): Count
    has(s, Ability): bool

proc has*(s: Shim, ability: Ability): bool
  ## Ask before you call, instead of catching afterwards. `if shim.has(Console)`
  ## is the friendly path; the raise is there for code that would rather branch late.
proc write*(s: var Shim, fd: Fd, bytes: Bytes): Count      ## raises `Unsupported`
proc tryWrite*(s: var Shim, fd: Fd, bytes: Bytes): Option[Count]
proc read*(s: var Shim, fd: Fd, into: var openArray[byte]): Count
proc tryRead*(s: var Shim, fd: Fd, into: var openArray[byte]): Option[Count]
proc close*(s: var Shim, fd: Fd)                           ## idempotent, as always

proc sinceBoot*(s: Shim): Duration
  ## Monotonic, never goes backwards, does not wrap within the device's life.
proc now*(s: Shim): Option[SystemTime]
  ## Wall-clock. `none` when there is no RTC or backup battery — absence, not failure.
proc isConsole*(s: Shim, fd: Fd): bool
  ## Honest `false` on a headless build; `true` only where a real UART is attached.

proc takeBootArena*(s: var Shim): Option[Arena]
  ## One fixed arena, once, at startup. `none` on the second call, and `none` on a
  ## board that reserves no RAM for one. It never grows and never fails later.

const nullShim*: NullShim
  ## A complete, do-nothing implementation: every `has` is false, every read/write
  ## raises `Unsupported`, `now` is `none`. Bring a new board up against this and
  ## replace one method at a time.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `_sbrk(n)` | `takeBootArena()` | The single biggest change in this module. An open-ended, repeatable "grow the heap" cannot exist below `std`; a bounded handoff that happens once can, and the name says both. |
| `FileDesc` (bare int) | `Fd` + `consoleOut`/`consoleIn`/`consoleErr` | Still a distinct integer, but nobody has to remember that 2 is stderr. |
| `ShimError::Unsupported` | `Unsupported` (a `Failure`) + `has(s, ability)` | Nim raises, so the error enum collapses per PROTOCOLS' rule — but a raise you are *expected* to hit is unfriendly, so `has` gives you the same answer before you call. |
| `ShimError::WouldBlock` | `NotReady` | "Would block" describes what the OS would have done; "not ready" describes the situation you are in. |
| `monotonic_now()` | `sinceBoot()` | Says what the number *is*. `sinceBoot() > 5.minutes` reads correctly with no comment. |
| `wall_clock_now()` | `now()` | The short word for the common question, and `Option` already carries "there is no clock here". |
| `isatty(fd)` | `isConsole(s, fd)` | A 1970s abbreviation for "is there a person at the other end". |
| `NullShim` struct | `nullShim` const | It has no state, so it is a value, not a type you instantiate. |

## In use — embedded-sensor-node

```nim
main:
  var arena = shim.takeBootArena().orRaise("board reserved no RAM for an arena")
  var samples = newRing[int16](256, memory = arena)   # the only allocator this firmware has

  if shim.has(Console):                               # headless final build: skipped entirely
    discard shim.tryWrite(consoleOut, "sensor node up\n".toBytes())

  let stamp = shim.sinceBoot()                        # flash log timestamps: monotonic is enough
  shim.now().ifSome(t): flashLog.setWallClock(t)      # only if this board has an RTC
```

## Vocabulary exceptions
`sinceBoot`, `now`, `isConsole` and `takeBootArena` are domain verbs — clocks and startup handoffs have no structural analogue. `take` is borrowed deliberately from `alloc.allocator`'s `take`/`give` pair rather than invented, so "take" means "hand me raw memory" in both places. `read`, `write`, `close` and `has` are structural and unchanged.

## Honest limits
- **`Unsupported` is a normal answer, not a bug.** A build with no filesystem and no UART must still link and run. That is this module's entire reason for existing, and it is why `has` exists alongside the raise: the friendly path is a boolean check, the raise is the backstop for callers who did not check.
- **`Fd` as a distinct integer is a bet on familiarity over safety.** A structured handle would catch "wrote to a closed fd" at compile time; a single-UART, no-filesystem board does not have enough descriptors in play to say which is right. Named as unresolved rather than settled.
- No vendor escape hatch is needed here, and that is not a claim of cleverness — these calls are coarse enough that a board's UART or RTC register access never has to show through the signature.

**Nim-specific:** `Shim` is a `concept`, so a board-support package satisfies it structurally — no inheritance declaration, no vtable, no runtime dispatch, and the whole shim usually inlines away. Two consequences worth stating. First, `--os:standalone` means Nim's own `echo`, `stdout` and `writeFile` do not exist; `write(shim, consoleOut, ...)` is not a wrapper around them, it is the bottom. Second, this module is where `alloc.allocator`'s freestanding rule is satisfied in practice: `defaultMemory()` is a compile error on this target, so `takeBootArena` is the concrete origin of the one `Arena` that every collection in the firmware is passed with `memory = arena`.
