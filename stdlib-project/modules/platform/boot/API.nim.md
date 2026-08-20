# platform.boot — Nim API

## Purpose
One typed description of where memory is, consumed by both the linker script and your code, plus the contract that gets the chip from power-on to your `main` with statics ready and nothing undefined.

## Protocols implemented
The memory map is a `Collection` of `Region`s (`list`, `count`) and `Gettable` by name — so `find`, `has` and `first` come free from PROTOCOLS' derived bundle. Everything else is a domain verb.

## The API

```nim
type
  RegionKind* = enum
    Flash        ## read-only at runtime: code, and log partitions
    Ram          ## working memory; zeroed or loaded on every reset
    Registers    ## live peripheral space — reset never touched it anyway
    Kept         ## battery/capacitor-backed. The linker places **no** .bss and **no**
                 ## .data record here, so there is no runtime skip-list to forget.

  Region* = object
    name*: string          ## compile-time only — this object never exists at runtime
    origin*, length*: uint32
    kind*: RegionKind

const memoryMap*: seq[Region] = @[
  Region(name: "FLASH_CODE", origin: 0x0800_0000'u32, length: 192 * 1024, kind: Flash),
  Region(name: "FLASH_LOG",  origin: 0x0803_0000'u32, length:  64 * 1024, kind: Flash),
  Region(name: "RAM",        origin: 0x2000_0000'u32, length:  64 * 1024, kind: Ram),
  Region(name: "BACKUP",     origin: 0x4002_4000'u32, length:       128,  kind: Kept)]
  ## The one source of truth. `nim c` emits the linker script from this same constant,
  ## so the script and the code cannot drift apart.

iterator list*(m: static seq[Region]): Region       ## the Collection primitive
proc get*(m: static seq[Region], name: static string): Option[Region]
  ## Compile-time lookup: `memoryMap.get("FLASH_LOG").orRaise(...)` folds to a constant,
  ## and a typo'd name is a compile error, not a wild address.

proc arenaFor*(r: static Region): Arena
  ## The only path from boot into alloc.allocator: a named, statically sized region
  ## becomes a fixed `Arena`. There is no route to a general heap through this module.

type Persistent*[T] = object       ## a value living in a `Kept` region
proc isReady*[T](p: Persistent[T]): bool
  ## Reads the sentinel this region's owner previously wrote. The only way to tell
  ## "first-ever power-up" from "warm reset, backup domain intact".
proc markReady*[T](p: var Persistent[T])
proc get*[T](p: Persistent[T]): Option[T]     ## `none` until `markReady` has been called
proc set*[T](p: var Persistent[T], value: T)  ## write it; call `markReady` once it's valid

template onPreInit*(body: untyped)
  ## Runs before statics are valid. No globals, no allocator, no raising calls —
  ## enforced as `{.raises: [].}`. External SRAM enable and clock setup live here.
template main*(body: untyped)
  ## The entry point. Expands to `{.exportc: "main", noreturn.}`; falling off the end
  ## is a compile error, not a jump into whatever follows in flash.
proc onHardFault*(frame: FaultFrame) {.exportc, noreturn.}
  ## Every board-support package must define one. There is no weak default that
  ## silently spins forever.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `RegionKind::Mmio` | `Registers` | "MMIO" is an acronym you have to expand; "registers" is what is actually there. |
| `RegionKind::PersistentRam` | `Kept` | One short word for the property that matters: reset leaves it alone. It also reads correctly in the linker-script comment it generates. |
| `MemoryRegion` | `Region` | The module is `boot` and the constant is `memoryMap`; "Memory" twice added nothing. |
| `MEMORY_MAP` | `memoryMap` | Nim's own casing. Still a `const`, still compile-time-folded. |
| `PersistentRegion` trait | `Persistent[T]` | A value you hold, not a trait a region implements — so `settings.get()` is the ordinary `Option` idiom instead of a second ceremony. |
| `is_initialized` / `mark_initialized` | `isReady` / `markReady` | Shorter, and matches `isOpen`/`isRunning` across the library. |
| `pre_init()` trait method | `onPreInit:` block | Written where it runs; no trait to implement, no second file. |
| `entry(main)` | `main:` block | The scariest signature in the Rust design (`fn() -> !` passed to a function) becomes a block you put your program in. |
| `arena_from_region` | `arenaFor(region)` | Reads as "an arena for this region", target last because the region *is* the argument. |

## In use — embedded-sensor-node and display-node

```nim
main:
  const logRegion = memoryMap.get("FLASH_LOG").orRaise("board has no log partition")
  var scratch = arenaFor(memoryMap.get("RAM").orRaise("no RAM?"))

  if not rtcState.isReady():          # first-ever power-up: the backup RAM is garbage
    rtcState.set(defaultClock)
    rtcState.markReady()
  while true:
    sample().ifSome(r): flashRing.append(r, region = logRegion)
    discard power.enterSleep(Deep, [wakeOn(30.seconds)])
```

## Vocabulary exceptions
`arenaFor`, `isReady`, `markReady`, `onPreInit` and `main` are domain verbs; startup is control flow, and the structural table describes operations on values. `get(memoryMap, name)` and `get(persistent)` are the ordinary `Gettable` verb — the second is keyless, the same deliberate stretch `platform.hal`'s `GpioPin` makes and for the same reason (there is exactly one thing in there).

## Honest limits
- **The sentinel can lie.** A backup domain that has genuinely never been powered holds *undefined* bits, not zeroed ones — so there is a small but real chance the garbage matches the sentinel and `isReady()` returns true over nonsense, silently trusting a random number as a previously configured clock. A production design wants a CRC over the region, or a redundant pair of sentinels, or a magic value chosen to be astronomically unlikely. This design names the mechanism and has **not** hardened it.
- **A flat `memoryMap` may not scale.** Multiple flash banks, external QSPI-mapped flash and non-contiguous or tightly-coupled RAM are common on larger parts, and `RegionKind` could grow variants faster than this shape anticipates.
- `onPreInit` is the named, bounded place vendor-specific code is expected — bounded, not eliminated. Pretending the reset path is fully vendor-neutral would be the dishonest option.

**Nim-specific:** `memoryMap` is a `const seq[Region]` with `string` names, which looks impossible on a target with neither `seq` nor `string` — and is fine, because it is only ever touched by `static`/`const` code running in the compiler's VM. `get` on it folds to a `uint32` before code generation; not one byte of the table reaches the device. Linker symbols (`_sdata`, `_ebss`, the vector table) come in as `{.importc, nodecl.}` and the reset handler goes out as `{.exportc.}`, so the same file describes both ends of the link.
