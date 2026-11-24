## The bare-metal runtime's failure paths, pinned under QEMU.
##
## Each case was a silent wrong answer before it was a test: a `critical:`
## that re-enabled interrupts inside an outer block or after an early
## `return`; an out-of-bounds index and an exhausted frame heap that spun in a
## `while true` the QEMU loop read as a clean run; an ISR slot that overwrote
## an untaken value. The text cases need no toolchain. The QEMU cases SKIP
## cleanly when QEMU, the ARM toolchain or the vendored picolibc is absent.

import std/[os, strutils]
import ../harness

proc metal(t: var T, name, stage, slot: string, wantRc: int,
           wants: seq[string], extra: seq[string] = @[], board = "",
           input = "") =
  ## Boot `tests/metal/<stage>.tuck` under QEMU via `tuck sim` and
  ## assert the exit status and every text in `wants`. `extra` is passed to
  ## `tuck sim`; `board` picks a board other than the default; `input` is
  ## typed on the board's serial port (printf `%b` escapes).
  let exe = t.root / "tuck"
  let src = t.root / "tests" / "metal" / (stage & ".tuck")
  var argv = @["env", "TUCK_OUT_DIR=" & getTempDir() / ("tuck-metal-" & slot),
               "TUCK_SKIP_TUCK_BUILD=1"]
  if board != "": argv.add "TUCK_BOARD=" & board
  if input != "": argv.add "TUCK_SIM_INPUT=" & input
  argv.add @[exe, "sim", src, "--tick:4"] & extra
  let idx = t.needCmd(argv, vRun)
  let metalReady = findExe("qemu-system-arm") != "" and
                   findExe("arm-none-eabi-gcc") != "" and
                   dirExists(t.root / "build" / "picolibc" / "install")
  if t.phase == pCollect:
    if not metalReady: t.work[idx].skipped = true
    return
  if t.skippedCmd(idx): t.skip name; return
  let (rc, text) = t.resultOf(idx)
  var missing: seq[string]
  for w in wants:
    if not text.contains(w): missing.add w
  if rc == wantRc and missing.len == 0:
    t.ok name
  else:
    t.no name, "expected rc=" & $wantRc & " and " & $missing & ", got rc=" &
      $rc & ": " & text

proc run*(t: var T) =
  # --- the lowering, as text: no toolchain ---------------------------------
  t.src """
register FLAG at 0x20000100:
  VALUE: bits 0..7 [read, write]

fn early({x: int}) -> int:
  critical:
    if x > 0:
      return 1
    FLAG.VALUE = 3
  return 0

fn main() -> int:
  return {x: 1} early
"""
  t.emits "Nim: critical: saves the mask it found", "= tuckCriticalEnter\\(\\)"
  t.emits "Nim: the restore is in a finally, so an early return runs it",
          "finally:\\s+tuckCriticalExit\\(tuckCs"
  t.emitsOdin "Odin: the restore is a defer", "defer rt.tuckCriticalExit\\(tuckCs"
  t.emitsD "D: the restore is a scope\\(exit\\)", "scope\\(exit\\) rt.tuckCriticalExit\\(tuckCs"

  # --- under QEMU --------------------------------------------------------
  t.metal "nested critical: keeps interrupts masked; an early return unmasks",
          "critical_nest", "nest", 0, @["NEST_OK"]
  t.metal "a second ISR post to a full slot is dropped and counted",
          "isr_overrun", "overrun", 0, @["OVERRUN_OK"]
  t.metal "an out-of-bounds index panics and names the Tuck line",
          "panic_bounds", "bounds", 1,
          @["PANIC: index out of bounds", "panic_bounds.tuck:9",
            "A runtime check failed"]
  t.metal "an exhausted frame heap panics instead of losing tasks",
          "panic_frame_heap", "heap", 1,
          @["PANIC: tuck frame heap exhausted"]
  t.metal "main's return value is the QEMU exit status",
          "exit_code", "exit", 3, @["qemu exit: 3"]

  # A program's failure is its exit status, and test state lives in the
  # boards' reserved RAM scratch: on stm32vldiscovery 0x40000000 is TIM2,
  # and irq_marker read back a value it never wrote (and still exited 0).
  t.metal("irq_marker passes on the STM32 board (scratch in reserved RAM)",
          "irq_marker", "irq-stm32", 0, @["IRQ_MARKER_OK"],
          board = "stm32vldiscovery")
  t.metal("a delivered interrupt sets the LED", "fault_isr_drop", "isr-plain",
          0, @["FAULT_SAFE_OK"])
  t.metal("a dropped interrupt leaves the safe state", "fault_isr_drop",
          "isr-drop", 0, @["FAULT_SAFE_OK"], extra = @["--fault:isr-drop"])

  # Actors on metal (bare-metal roadmap 2.0): a ring mailbox per actor and a
  # frame on the stackless scheduler; until 2026-11-23 no actor built for a
  # board at all (`Mailbox` undeclared, then `newObj`, `newSeq`).
  for board in ["lm3s6965evb", "stm32vldiscovery"]:
    t.metal("an actor receives its messages on " & board, "actor_mailbox",
            "actor-" & board, 0,
            @["STATE l0=true l1=true", "STATE l0=false l1=true"], board = board)
    t.metal("a full ring waits, and an actor sends to another, on " & board,
            "actor_ring", "ring-" & board, 0, @["ACTOR_RING_OK"], board = board)
  # `bind` (bare-metal roadmap 2.2): a pended NVIC line taken through the
  # generated vector table, its events delivered after the interrupt; a
  # SysTick event loop that sleeps (WFI) between ticks, on both boards.
  t.metal("a bound line: 5 interrupts, a stream of 2 drops 3, a signal merges 5",
          "bind_irq", "bind-irq", 0, @["BIND_OK"], board = "stm32vldiscovery")
  for board in ["lm3s6965evb", "stm32vldiscovery"]:
    t.metal("SysTick drives an event loop that sleeps between ticks on " & board,
            "bind_systick", "systick-" & board, 0, @["BEAT_OK"], board = board)
  t.metal("a line the board does not have is refused with its list (TK-BD06)",
          "bind_irq", "bind-unknown", 1,
          @["TK-BD06", "has no interrupt line 'EXTI0'", "GPIOA"],
          board = "lm3s6965evb")
  # A UART receive interrupt (bare-metal roadmap 2.3): bytes typed on QEMU's
  # serial port reach an actor through `bind UART0`. With nothing typed the
  # program is still waiting when the window closes: 124, never a pass.
  t.metal("bytes typed on the serial port reach an actor via the UART0 line",
          "uart_rx", "uart-rx", 0, @["UART_RX_OK"], board = "lm3s6965evb",
          input = "hello\\n")
  t.metal("with nothing typed the UART program is still waiting (124)",
          "uart_rx", "uart-rx-idle", 124, @["qemu exit: 124"],
          board = "lm3s6965evb")
  # DMA buffers (bare-metal roadmap 2.0a): an `at` buffer IS the memory at
  # its address (a `register` at the same address reads what was stored), a
  # placed one lands word-aligned in RAM, and the heap is carved around them.
  t.metal("a buffer's .address is its memory; a register there reads it",
          "buffer_dma", "buffer-dma", 0, @["BUFFER_OK"], board = "lm3s6965evb")
  t.metal("an `at` buffer in the stack reserve fails the link, saying so",
          "buffer_stack", "buffer-stack", 1,
          @["a `buffer ... at` address overlaps the stack reserve"],
          board = "lm3s6965evb")
  # Pools on metal (2026-11-24): `Pool.address {h}` is a cell's address as
  # a number for a DMA register; and a pool builds for a board at all now
  # (its misuse check wrote to stderr, which a board has none of).
  for board in ["lm3s6965evb", "stm32vldiscovery"]:
    t.metal("pool cells are DMA targets: aligned RAM addresses on " & board,
            "pool_dma", "pool-dma-" & board, 0, @["POOL_DMA_OK"], board = board)
  # The memory examples run on a board with their host exit codes (cli_smoke
  # pins the same numbers): until 2026-11-24 a chunked slab took a 64 KiB
  # chunk from the 2 KB frame heap and the slab and arena programs panicked.
  for (ex, rc) in [("48-slab-references", 0), ("13-arena-mem", 55),
                   ("25-pools", 4)]:
    t.metal("examples/" & ex & " runs on a board, exit " & $rc,
            "../../examples/" & ex, "ex-" & ex, rc, @["qemu exit: " & $rc],
            board = "lm3s6965evb")
  t.metal("a stale pool handle panics on metal, naming the pool check",
          "pool_stale", "pool-stale", 1,
          @["PANIC: TUCK POOL: read of slot 0, which nobody holds"],
          board = "lm3s6965evb")
  # The device programs build for a board and fail CLEANLY with no device on
  # the bus: QEMU models no DS3231 or SD card, so each bounded wait times out
  # and main returns 1, rather than hanging (124) or faulting.
  t.metal("the irrigation controller boots; no RTC on the bus is exit 1",
          "devices/irrigation/irrigation", "irrigation", 1, @["qemu exit: 1"],
          board = "stm32vldiscovery")
  t.metal("the MP3 recorder boots; no SD card is exit 1",
          "devices/recorder/recorder", "recorder", 1, @["qemu exit: 1"],
          board = "stm32vldiscovery")

  # `--board:NAME` (roadmap 0.1) is judged before anything is built.
  t.src "fn main() -> int:\n  return 0\n"
  block:
    let bad = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck", "--board:nope"])
    let stackful = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck",
                               "--board:lm3s6965evb", "--concurrency:stackful"])
    if t.phase != pCollect:
      let (rc1, out1) = t.resultOf(bad)
      if rc1 != 0 and "available: lm3s6965evb, stm32vldiscovery" in out1:
        t.ok "an unknown --board is refused, naming the boards"
      else: t.no "an unknown --board is refused, naming the boards", out1
      let (rc2, out2) = t.resultOf(stackful)
      if rc2 != 0 and "bare metal is stackless" in out2:
        t.ok "--board refuses --concurrency:stackful"
      else: t.no "--board refuses --concurrency:stackful", out2

  # T16, metal half: gdb stops at a Tuck line on the ARM target. SKIPs
  # without an ARM-capable gdb, like the host-gdb case in crash_decode.
  block:
    let name = "gdb breaks at a .tuck line on the QEMU target"
    let script = t.root / "tools" / "metal" / "gdb-run.sh"
    let idx = t.needCmd(@["env", "TUCK_SKIP_TUCK_BUILD=1",
                          "TUCK_OUT_DIR=" & getTempDir() / "tuck-metal-gdb",
                          script, "task_await", "10", "3411"], vRun)
    let ready = findExe("qemu-system-arm") != "" and
                findExe("arm-none-eabi-gcc") != "" and
                (findExe("gdb-multiarch") != "" or findExe("arm-none-eabi-gdb") != "")
    if t.phase == pCollect:
      if not ready: t.work[idx].skipped = true
    elif t.skippedCmd(idx): t.skip name
    else:
      let (rc, text) = t.resultOf(idx)
      if rc == 0 and text.contains("task_await.tuck:10"): t.ok name
      else: t.no name, "rc=" & $rc & ": " & text

  t.finish()
