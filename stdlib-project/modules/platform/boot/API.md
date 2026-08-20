# platform.boot

## Purpose
Linker-script conventions, typed memory-region descriptors (flash/RAM/MMIO), and the reset/init handler contract that gets a microcontroller from power-on to a running `main()` with statics initialized and no undefined behavior.

## Design lineage
Modeled on the Rust `cortex-m-rt` crate — which generates the vector table, reset handler, and `.data`/`.bss` initialization from a declarative `memory.x` linker-script plus a small `#[entry]` macro, replacing hand-written assembly crt0 — with newlib/picolibc's `crt0` startup conventions as the second precedent for the *contract* (what must be true before `main` runs: stack pointer set, statics copied/zeroed) independent of any specific vendor's startup file.

## Proposed API
```
// Declarative memory layout — one source of truth, consumed by both the
// linker and (via a build-time codegen step) by Rust-like typed region handles:
struct MemoryRegion {
    name: &'static str,
    origin: u32,
    length: u32,
    kind: RegionKind,   // Flash | Ram | Mmio | PersistentRam
}

const MEMORY_MAP: &[MemoryRegion] = &[
    MemoryRegion { name: "FLASH_CODE", origin: 0x0800_0000, length: 192 * 1024, kind: RegionKind::Flash },
    MemoryRegion { name: "FLASH_LOG",  origin: 0x0803_0000, length: 64 * 1024,  kind: RegionKind::Flash },
    MemoryRegion { name: "RAM",        origin: 0x2000_0000, length: 64 * 1024,  kind: RegionKind::Ram },
    // Battery/capacitor-backed domain (e.g. the RTC's backing registers and a small
    // scratch region for state that must NOT be reinitialized on every reset):
    MemoryRegion { name: "BACKUP_RAM", origin: 0x4002_4000, length: 128,        kind: RegionKind::PersistentRam },
];

// A region of kind PersistentRam is excluded from step 3 below by construction —
// the linker-script codegen step that consumes MEMORY_MAP places no .bss (and no
// .data load record) inside a PersistentRam region at all, so there is no runtime
// check to forget: statics backed by this region simply aren't touched by init.
trait PersistentRegion {
    fn is_initialized(&self) -> bool;   // reads a sentinel/magic value this region's
                                          // owner previously wrote — the only reliable
                                          // way to tell "first-ever power-up" from
                                          // "warm reset, backup domain intact"
    fn mark_initialized(&mut self);
}

// The reset handler contract — implemented once per architecture, not per board:
fn reset_handler() -> ! {
    // 1. set stack pointer (done by hardware on Cortex-M via vector table)
    // 2. copy .data from flash to RAM (PersistentRam regions carry no .data record —
    //    their contents are whatever the hardware retained, not flash-supplied)
    // 3. zero .bss (PersistentRam regions are excluded from .bss placement entirely,
    //    a build-time linker-script guarantee, not a runtime skip-list)
    // 4. call pre_init() hooks (board-specific, opt-in, run before statics are valid)
    // 5. call rust_main()
}

trait PreInit {
    fn pre_init();   // runs before statics initialized — no globals, no allocator
}

// Application entry point — signature enforced at compile time, never returns:
fn entry(main: fn() -> !);

// Panic/fault handler contract — must not allocate, must not assume std is present:
trait FaultHandler {
    fn on_hard_fault(frame: &ExceptionFrame) -> !;
}

fn arena_from_region(region: &MemoryRegion) -> FixedArena;
// Hands a compile-time-sized memory region to alloc.allocator as a fixed arena —
// the boot tier's only sanctioned bridge into alloc.
```

## Key design decisions
- **Revision (embedded-display-node): `RegionKind` gains a `PersistentRam` variant, and a `PersistentRegion` trait is added, because the original model implicitly assumed every reset reinitializes everything.** The three original variants (`Flash`, `Ram`, `Mmio`) cover the sensor node completely: `Flash` is read-only-at-runtime code/log storage, `Ram` is always-reinitialized working memory, and `Mmio` is live peripheral register space that reset never zeroes because it isn't backed by `.data`/`.bss` in the first place. That third category (`Mmio`) is *why* this gap stayed hidden for one whole application: the RTC's own counter registers, being `Mmio`, already survive a reset under the existing model with no change needed — a superficial reading could stop there and conclude "persistence is already handled." embedded-display-node's actual requirement goes further: application-level state *about* the RTC — specifically, a flag distinguishing "first-ever power-up, the RTC has never been set and needs a default/user-provided time" from "warm reset or wake-from-sleep, the RTC is already running correctly, do not touch it" — cannot live in ordinary `Ram`, because step 3 of `reset_handler` unconditionally zeroes all `.bss`, which would silently clear that flag on every reset and cause the firmware to re-stomp the real time with a compile-time default each time it restarts. That is a genuine correctness bug, not a hypothetical one, and it is exactly the class of bug backup-battery-RAM designs hit in practice. `PersistentRam` (a region the linker-script codegen step excludes from `.bss`/`.data` placement entirely, not a runtime "please don't touch this" convention someone can forget) plus `PersistentRegion::is_initialized()`/`mark_initialized()` (an explicit, typed idiom for the cold-vs-warm decision, since "the memory wasn't zeroed" alone is necessary but not sufficient — a truly fresh, uninitialized backup domain has *unpredictable* contents, not zeroed contents, so the sentinel check is load-bearing) is the concrete fix. This composes directly with `platform.power`'s revised `WakeReason::PowerOnReset`: that tells you *how* the device reset, `is_initialized()` tells you what the persisted state itself claims about its own validity, and application code needs both, not one alone (a `PowerOnReset` with a backup battery already installed from a prior device deployment is a warm case for the RTC even though it's a cold case for power).
- **`MEMORY_MAP` is a single typed source of truth consumed by both the linker script generator and application code**, rather than the traditional split where `memory.x`/the linker script is hand-maintained separately from any C header describing the same addresses — the two drifting apart (a classic embedded bug: linker script says one flash size, header says another) is closed by construction, at the cost of requiring a small build-time codegen step this design accepts as necessary tooling investment.
- **`PreInit::pre_init()` runs before statics are initialized and is explicitly forbidden from touching globals or allocating** — this is the direct, honest acknowledgment that *some* board-specific setup (external SRAM enable, clock source selection needed before RAM is even reliable) genuinely cannot wait until `main()`, matching Part V's general position for this tier: rather than pretend `reset_handler` is fully vendor-neutral, the design names the one hook where vendor-specific code is expected and bounds what it may do.
- **`FaultHandler` is a required trait, not an optional weak symbol silently defaulting to an infinite loop** — every board-support package must provide one, because a silent default fault handler on a battery-powered field device (like the sensor node) turns a debuggable hard fault into a device that simply stops advertising over BLE with no diagnostic trace, which is worse than a documented compile error demanding the implementation be provided.
- **`arena_from_region` is the only path from `platform.boot` into `alloc.allocator`**, converting a *named, statically-sized* memory region into a fixed arena — this directly enforces Principle 2 for the whole tier: there is no path to a general-purpose heap through this module, only ever a compile-time-sized region carved out of the memory map.

## Validated by applications
The embedded-sensor-node's "documented memory layout (flash for code+log, RAM for buffers)" requirement is precisely what `MEMORY_MAP` exists to make explicit rather than implicit: the flash log region (`FLASH_LOG`, wear-conscious ring buffer) must be a named, sized, address-stable region distinct from `FLASH_CODE` so the ring-buffer write logic (in application code, protected by `platform.interrupt`) can compute sector-rotation offsets against a compile-time constant rather than a magic address baked into a linker script no application code can see. A naive first design — following `cortex-m-rt` exactly, which only distinguishes FLASH and RAM as linker-script regions with no typed application-visible handle — would have been insufficient here, because the app needs to reason about the log region's *size* (to compute wear-leveling rotation) from within Rust-like code, not just from the linker script; `MemoryRegion` as a typed, queryable constant is the fix. The app's reset/init sequence (get from power-on to the sampling loop) is a case where `PreInit` is exercised lightly — the SHT4x sensor and onboard flash need no exotic pre-RAM setup — so this module does not need a heavy vendor escape hatch for *this* device, but the hook exists and is documented as expected-to-be-used specifically because the report's own framing (Part V) predicts the next device won't be so simple.

embedded-display-node is, per its own stated design intent, "the single best test yet of `platform.boot`'s promise that 'init happens once' actually holds when part of the hardware state is intentionally not reset" — and the honest finding is that the promise did *not* hold as originally specified; see the revision above. Where the sensor node validated that `MEMORY_MAP` needs to be a typed, application-visible source of truth for region *size* (to compute flash-log wear-leveling rotation), embedded-display-node validates a different, sharper claim: that the model needs to distinguish region *reset behavior*, not just region *kind* in the Flash/Ram/Mmio sense. The original three-way split conflates "is this hardware that survives reset because it's a live peripheral register" (`Mmio`, already true for the RTC counter itself) with "is this memory that survives reset because it's battery-backed" (the new `PersistentRam` case, needed for *application* state about the RTC) — those turn out to be different concerns that only a second device with an actual backup domain would expose, since the sensor node has no battery-backed RAM at all and every one of its `Ram`-kind statics is correctly reinitialized every boot. The fix is additive (a new `RegionKind` variant plus a small trait), not a rework of the existing `Flash`/`Ram`/`Mmio` handling, which the sensor node's validation of those three continues to hold.

## Open questions / risks
Whether `MEMORY_MAP` as a single flat list scales to devices with multiple flash banks, external QSPI-mapped flash, or non-contiguous RAM (common on larger Cortex-M4/M7 parts with tightly-coupled memory) is untested by this app, which has a simple single-flash-bank, single-RAM-bank layout; a more complex device may need `RegionKind` to grow variants faster than this design anticipates.

`PersistentRegion::is_initialized()`'s sentinel-value approach is itself an unresolved risk, not a fully closed gap: on a device where the backup domain has genuinely never been powered (brand new backup battery, never inserted before), the region's contents are undefined bit patterns, not zero — there is a small, real, non-zero probability that undefined memory happens to match the sentinel value and `is_initialized()` reports true when it should report false, silently trusting garbage as if it were a previously-configured RTC. A production design would need a stronger check (a CRC over the region, or a magic value chosen specifically to be astronomically unlikely by chance, or a redundant pair of sentinels) — this design names the mechanism's existence and shape but has not hardened the sentinel scheme itself, which is exactly the kind of detail an analysis-only exercise like this one is prone to underweight relative to an implementation that would hit it on first power-up.
