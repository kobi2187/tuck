# platform.libc-shim

## Purpose
The small, explicit set of syscall stubs a board-support package implements — write, read, monotonic/wall clock, and a compile-time-sized arena handoff in place of `_sbrk` — so anything above this module that expects OS-level I/O degrades to a documented "unsupported" error instead of failing to link.

## Design lineage
Modeled directly on newlib/picolibc's syscall stub contract (`_sbrk`, `_write`, `_read`, `_close`, `_fstat`, `_isatty`, …), named explicitly in Part IV as the pattern this module carries forward, and in Part I as "the pattern worth keeping" from the whole embedded-toolkit survey. The key adaptation: `_sbrk` (open-ended heap growth) is replaced with a bounded arena handoff, because Principle 2 forbids a general-purpose heap below `std`, which newlib/picolibc — general C libraries with no such constraint — do not forbid.

## Proposed API
```
// The full required surface — a board-support package (BSP) must provide an
// implementation of this trait for anything above platform to link at all:
trait LibcShim {
    fn write(&mut self, fd: FileDesc, bytes: &[u8]) -> Result<usize, ShimError>;
    fn read(&mut self, fd: FileDesc, buf: &mut [u8]) -> Result<usize, ShimError>;
    fn close(&mut self, fd: FileDesc) -> Result<(), ShimError>;

    fn monotonic_now(&self) -> Duration;      // since boot, never wraps within device lifetime
    fn wall_clock_now(&self) -> Option<SystemTime>;   // None if no RTC battery/backup domain present

    // Replaces _sbrk: hands out a single fixed-size arena once, at startup —
    // never grows, never fails partway through a program's life.
    fn take_boot_arena(&mut self) -> Option<FixedArena>;

    fn isatty(&self, fd: FileDesc) -> bool;   // always false on this tier unless a real UART console exists
}

enum ShimError {
    Unsupported,   // this BSP legitimately has no backing for this call (e.g. no filesystem)
    HardwareFault(HalErrorCode),
    WouldBlock,
}

// Default no-op implementation any BSP can start from and override selectively —
// every method returns ShimError::Unsupported rather than panicking or looping:
struct NullShim;
impl LibcShim for NullShim { /* all methods -> Err(ShimError::Unsupported) or None */ }
```

## Key design decisions
- **`take_boot_arena` returns a bounded `FixedArena` exactly once, rather than mirroring `_sbrk`'s open-ended "grow the heap by N bytes, repeatable, can fail"** — this is the one deliberate, principled deviation from the newlib/picolibc model named in the lineage: an unbounded, repeatedly-callable `_sbrk` is fundamentally incompatible with Principle 2's "compile-time-sized arenas... never a general-purpose heap" for this tier, so the shim contract is redesigned around a single handoff rather than patched with a size cap on top of an inherently open-ended API.
- **`ShimError::Unsupported` is a first-class, expected return value, not a fallback for "not yet implemented"** — this is the module's entire reason for existing per the report's framing: higher tiers (`sys.io` calling through to `write`) must treat `Unsupported` as a normal, handleable `Result::Err`, so a build that has no filesystem or no UART still links and runs, degrading gracefully instead of hitting an undefined-reference linker error the way a missing `_write` does in raw newlib.
- **`NullShim` ships as a provided, zero-effort starting point that answers `Unsupported`/`None` everywhere** rather than requiring every new BSP to hand-write all six methods before anything compiles — lowering the bar to bring up a new board while keeping the "must implement or explicitly opt into the null default" contract explicit rather than silently absent.
- **`monotonic_now`/`wall_clock_now` are split, matching `sys.time`'s Tier 2 convention** (`Instant` strictly separate from `SystemTime`) even at this low a tier — deliberately kept consistent with Principle 4 (one coherent idiom per cross-cutting concern) rather than inventing a simpler, single-clock shim for embedded, since the sensor node's flash log timestamps and BLE advertising interval both need monotonic time and neither strictly needs wall-clock time, a distinction worth preserving down here.

## Validated by applications
The embedded-sensor-node's "whatever minimal libc surface (if any) the build depends on" line item, per the app's own module table, understates how load-bearing this module actually is: the app's design explicitly runs `core` + `alloc` + `platform` with `sys`/`std` skipped entirely, meaning any code path that *would* reach for `sys.io`'s file abstraction (for example, a debug-log line written during development) needs somewhere to land — `LibcShim::write` targeting a UART fd is that landing spot, and `Unsupported` is the correct, honest answer for a `read` call on this app's fully headless, no-console final build. `take_boot_arena` is where this module is most directly exercised: the app's own module table names `alloc.allocator` as "if used at all, a fixed arena sized at compile time," and that arena has to originate somewhere concrete at boot — `take_boot_arena` handing out exactly one `FixedArena` sized from `platform.boot`'s `MEMORY_MAP` RAM region is the connective tissue between `boot`'s memory-region descriptors and `alloc`'s allocator contract, a dependency this app made visible that a design considering `libc-shim` in isolation might have missed. On Part V: this module needs no vendor escape hatch for this app at all — `write`/`read`/`close`/clock queries are about as vendor-neutral as anything in this tier gets, since the shim methods are deliberately coarse-grained enough that a BSP's internal UART or RTC register access never needs to leak through the trait signature itself.

## Open questions / risks
Whether `FileDesc` should be a bare integer (matching POSIX/newlib convention exactly, for maximum familiarity) or a more structured, checked handle type (catching "wrote to a closed fd" at compile time) is unresolved; the app's single-UART, no-filesystem build doesn't have enough file descriptors in play to stress-test either choice.
