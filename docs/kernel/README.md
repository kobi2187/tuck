# Tuck in an operating-system kernel

`tuck build --target:linux-kmod` builds a Linux kernel module (`.ko`);
`tuck build --target:windows-kmd` builds a Windows kernel-mode driver
(`.sys`). The same Tuck source builds for both, and for a board.

```sh
./tuck b driver.tuck --target:linux-kmod -o:out    # out/driver.ko
./tuck b driver.tuck --target:windows-kmd -o:out   # out/driver.sys
tools/kernel/linux-run.sh out/driver.ko            # load it under QEMU
TUCK_KMOD_EXERCISE='cat /dev/tuckcount' tools/kernel/linux-run.sh out/tuckcount.ko
```

## The program

```tuck
import console

fn main() -> int:              # the module's init: 0 loads it
  {text: "loaded"} console::printLine
  return 0

fn unload() [io]:              # optional: runs at rmmod / DriverUnload
  {text: "unloaded"} console::printLine
```

- **`main` is the init.** 0 loads the module. A negative value refuses, and
  is passed to the kernel as its error: a `-errno` on Linux, an `NTSTATUS`
  on Windows (their failures have the high bit set). A positive value
  refuses with `-EINVAL` / `STATUS_UNSUCCESSFUL`.
- **`unload`, when declared, is the exit.**
- **`console::printLine` is the kernel log:** `printk(KERN_INFO)` on Linux,
  `DbgPrint` on Windows (DbgView, WinDbg).
- **`--target:linux-kmod` / `windows-kmd` also select `when target:`
  blocks**, as any `--target:NAME` does, so one driver can keep its
  per-OS parts side by side.
- **The kernel's own facilities come through `extern [c]`.** A header of
  plain prototypes (no kernel include) is what the Tuck side sees. A C file
  beside it, `lib: "x.c"`, includes the kernel headers and is compiled by
  the kernel's build (kbuild, or the DDK headers with mingw-w64), not by
  Nim. C calls back into Tuck through a C-callback `fnsig`.
  `tests/kernel/chardev/` is a complete example: a misc character device
  whose every read is answered by a Tuck function.

## How it is built

```
  driver.tuck --(tuck)--> Nim --(nim, kernel C flags)--> objects --(ld -r)--> tuck_nim.o
                                                                               |
  platforms/<target>/tuck_kglue.c  (the only file with kernel headers) ------+--> kbuild / mingw-w64
  your extern C (lib: "x.c")       (kernel headers allowed)            ------+        |
                                                                                 driver.ko / .sys
```

The program is compiled as for a board: freestanding, no memory manager,
the stackless scheduler. It targets x86-64 with the kernel's C flags (no
SSE/x87, no red zone, the kernel code model, retpolines on Linux). It never
includes a kernel header. Everything it needs from the kernel crosses one
contract, `platforms/tuck_platform.h`:

| The program needs | Linux glue | Windows glue |
|---|---|---|
| `malloc`, `calloc`, `realloc`, `free` | `kmalloc` / `krealloc` / `kfree`, `GFP_ATOMIC` where sleeping is not allowed | non-paged pool, tagged `Tuck` |
| `tuck_board_puts` (console, diagnostics) | `printk` | `DbgPrint` |
| `tuck_fatal` (a failed runtime check) | `BUG()`: the calling task oopses, the kernel goes on | `KeBugCheckEx(0x54554B43)` |
| `tuck_irq_save` / `restore` (`critical:`) | interrupts off **and** one module-wide spinlock, nesting counted per CPU | `HIGH_LEVEL` IRQL **and** an interlocked owner word, nesting counted |
| `tuck_mem_barrier`, `tuck_idle` | `smp_mb`, `usleep_range` | `mfence`, `KeDelayExecutionThread` |

`critical:` is a spinlock because masking interrupts on one core protects
nothing on a multi-core machine. Priority ceilings (bare-metal 2.4) do not
apply in a kernel.

## What a kernel module may not contain

Each refusal fires at the source line, instead of as a C compiler or loader
error later (`compiler/kernel_rules.nim`).

| Code | Refused | Instead |
|---|---|---|
| TK-KN01 | `f32`, `f64`, float literals | integers or fixed point: a kernel does not save FPU state |
| TK-KN02 | `buffer`, `register NAME at ADDR` | a physical address means nothing in virtual memory: `ioremap` / `MmMapIoSpace`, the DMA API, behind an extern |
| TK-KN03 | `bind` | there is no vector table: `request_irq` / `IoConnectInterruptEx`, behind an extern |

The standard library is not judged line by line, because Nim emits only
what is used. A program that uses a float routine from `std/` fails at C
compile time instead.

## What is proven, and how

`tests/suites/kernel_targets.nim` covers all of these. Each part SKIPs when
its tools are absent.

| | Evidence |
|---|---|
| Rules | TK-KN01..03 refuse |
| Linux, loaded | Ubuntu's 6.8 kernel under QEMU with two CPUs. `hello_kmod`: init prints, `unload` runs at rmmod. `tuckcount`: `/dev/tuckcount` answers three reads 1, 4, 9 from a Tuck function. `kruntime`: a growing `Seq`, nested `critical:`, a pool, a slab and an error result all work |
| Windows, built | `hello_kmod.sys` and `wincount.sys` (a WDM device with its C half): native subsystem, entered at `DriverEntry`, imports only `ntoskrnl.exe`, exports nothing |

To run the Linux part you need kernel headers with a matching readable
image, `qemu-system-x86_64`, a static `busybox` and `cpio`. The Windows part
needs `gcc-mingw-w64-x86-64`.

## Not built, or not proven

- **Loading on Windows.** Nothing here can run Windows. The `.sys` files
  are checked structurally only. A real load also needs the driver signed
  (test-signing mode for development). GNU ld does not write a PE checksum,
  which some loaders require; `editbin /release` or the WDK's toolchain
  sets one.
- **The WDK's own toolchain** (MSVC, KMDF). The glue is plain WDM C and
  should build with `cl.exe` unchanged; it has not been tried.
- **Other architectures.** x86-64 only (arm64 kernels: the flags and the
  Windows glue's IRQL calls differ).
- **Typed kernel APIs.** Tuck sees the kernel only through the externs you
  write. Nothing yet stops passing a user-space pointer where kernel memory
  is meant (`copy_from_user` / `ProbeForRead` as a type), checks IRQL rules
  (paged memory at `DISPATCH_LEVEL`), or generates bindings from kernel
  headers (bindgen's job).
- **Registers relative to a mapped base.** This is the D12 ruling (a
  register layout, with the instance address known only at run time). Once
  built, a driver can read a mapped device through `register` blocks
  instead of externs.
- **Actors and tasks on kernel threads.** They run on the stackless
  scheduler inside whatever thread calls into the module. Mapping actors to
  workqueues / DPCs is not done.

## Decisions made provisionally, for the owner

These were needed to build anything at all. Each one is easy to change.

1. **`main` is the init and `unload` is the exit,** rather than new syntax
   (`module:` blocks, `on load`).
2. **`critical:` is one module-wide lock.** It is correct and simple. A
   per-resource lock (the ceiling analysis, per shared state) would let
   unrelated sections run in parallel.
3. **A failed runtime check crashes the caller** (`BUG()`; a bug check on
   Windows). A driver could instead return an error from the entry point
   it is in. That needs every check to unwind to one.
4. **Floats are refused outright** (TK-KN01). The alternative is a
   `kernel_fpu_begin` / `KeSaveExtendedProcessorState` region construct.
