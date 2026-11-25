## Tuck as an operating-system kernel module (docs/kernel/README.md):
## `--target:linux-kmod` builds a .ko, `--target:windows-kmd` a .sys.
##
## Three layers, each SKIPping when its tools are absent:
##   * the kernel rules (TK-KN01..03), which need nothing but `tuck`;
##     (`--target:NAME` also selects `when target:` blocks; any other NAME
##     keeps only that meaning, so there is no "unknown target" to refuse)
##   * Linux: build with kbuild against the installed headers, then load the
##     module under QEMU (the distribution kernel, a busybox initramfs) and
##     read what it printed and what its device answered;
##   * Windows: build with mingw-w64 against its DDK headers and check the
##     image is a native-subsystem driver entered at DriverEntry. Loading it
##     needs Windows, which this suite cannot have.

import std/[os, strutils]
import ../harness

const Kdir = currentSourcePath().parentDir / ".." / "kernel"

proc kernelSays(t: var T, name, target, pattern: string) =
  ## `tuck ch --target:T` refuses the snippet with `pattern`.
  let idx = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck", "--target:" & target])
  if t.phase == pCollect: return
  let (rc, text) = resultOf(t, idx)
  if rc != 0 and text.contains(pattern): t.ok name
  else: t.no name, "wanted " & pattern & ", got rc=" & $rc & ": " & text

proc linuxReady(): bool =
  var headers = false
  for kind, p in walkDir("/lib/modules"):
    if fileExists(p / "build" / "Makefile"): headers = true
  var image = false
  for kind, p in walkDir("/boot"):
    if p.extractFilename.startsWith("vmlinuz-"):
      try:
        var f: File
        if open(f, p): image = true; f.close()
      except IOError: discard
  headers and image and findExe("qemu-system-x86_64") != "" and
    findExe("busybox") != "" and findExe("cpio") != ""

proc loads(t: var T, name, src, slot, exercise: string, wants: seq[string]) =
  ## Build `src` for Linux and load it under QEMU; every text in `wants`
  ## must appear (`KLOG:` kernel log, `OUT:` the exercise's output).
  let outDir = getTempDir() / ("tuck-kmod-" & slot)
  let ko = outDir / (src.extractFilename.changeFileExt("") & ".ko")
  let cmd = "./tuck b " & quoteShell(src) & " --target:linux-kmod -o:" &
            quoteShell(outDir) & " >/dev/null 2>&1 || { echo BUILD_FAILED; exit 3; }; " &
            "TUCK_KMOD_EXERCISE=" & quoteShell(exercise) &
            " tools/kernel/linux-run.sh " & quoteShell(ko)
  let idx = t.needCmd(@["sh", "-c", cmd], vRun)
  if t.phase == pCollect:
    if not linuxReady(): t.work[idx].skipped = true
    return
  if t.skippedCmd(idx): t.skip name; return
  let (rc, text) = resultOf(t, idx)
  var missing: seq[string]
  for w in wants:
    if not text.contains(w): missing.add w
  if rc == 0 and missing.len == 0: t.ok name
  else: t.no name, "rc=" & $rc & ", missing " & $missing & ": " & text

proc windowsBuilds(t: var T, name, src, slot: string, imports: seq[string]) =
  ## Build `src` as a Windows driver and check its PE header and imports.
  let outDir = getTempDir() / ("tuck-kmd-" & slot)
  let sys = outDir / (src.extractFilename.changeFileExt("") & ".sys")
  let cmd = "./tuck b " & quoteShell(src) & " --target:windows-kmd -o:" &
            quoteShell(outDir) & " >/dev/null 2>&1 || { echo BUILD_FAILED; exit 3; }; " &
            "x86_64-w64-mingw32-objdump -p " & quoteShell(sys) & "; " &
            "x86_64-w64-mingw32-nm " & quoteShell(sys) & " | grep -w DriverEntry"
  let idx = t.needCmd(@["sh", "-c", cmd], vBuild)
  if t.phase == pCollect:
    if findExe("x86_64-w64-mingw32-gcc") == "": t.work[idx].skipped = true
    return
  if t.skippedCmd(idx): t.skip name; return
  let (rc, text) = resultOf(t, idx)
  var missing: seq[string]
  for w in @["(NT native)", "DLL Name: ntoskrnl.exe", "T DriverEntry"] & imports:
    if not text.contains(w): missing.add w
  if text.contains("There is an export table"):
    missing.add "no export table (a driver exports nothing)"
  if rc == 0 and missing.len == 0: t.ok name
  else: t.no name, "rc=" & $rc & ", missing " & $missing & ": " & text

proc run*(t: var T) =
  # --- what a kernel module may not contain (no toolchain) -----------------
  t.src "fn half({x: f64}) -> f64:\n  return x /f 2.0\n\nfn main() -> int:\n  return 0\n"
  t.kernelSays "floating point is refused in a kernel module", "linux-kmod",
               "TK-KN01"
  t.okCheck "...and is fine anywhere else"
  t.src "buffer B: Array[4, u32]\n\nfn main() -> int:\n  return 0\n"
  t.kernelSays "a buffer's physical address is refused", "windows-kmd", "TK-KN02"
  t.src "register R at 0x40000000:\n  X: bit 0 [read]\n\nfn main() -> int:\n  return 0\n"
  t.kernelSays "a register at a fixed address is refused", "linux-kmod",
               "TK-KN02"
  t.src "fn onX() [irq, irq_safe, no_alloc]:\n  return\n\nbind GPIOA -> onX\n\n" &
        "fn main() -> int:\n  return 0\n"
  t.kernelSays "bind is refused: a kernel has no vector table", "linux-kmod",
               "TK-KN03"
  # --- Linux: built with kbuild, loaded under QEMU ----------------------------
  t.loads("a Tuck module loads, prints from main, and unload runs at rmmod",
          Kdir / "hello" / "hello_kmod.tuck", "hello", "",
          @["insmod rc: 0", "KLOG: hello from Tuck, sum 55", "rmmod rc: 0",
            "KLOG: goodbye from Tuck"])
  t.loads("a character device answers each read from Tuck code (1, 4, 9)",
          Kdir / "chardev" / "tuckcount.tuck", "chardev",
          "cat /dev/tuckcount; cat /dev/tuckcount; cat /dev/tuckcount",
          @["insmod rc: 0", "OUT: 1", "OUT: 4", "OUT: 9",
            "KLOG: tuckcount: /dev/tuckcount is up", "KLOG: tuckcount: removed"])

  t.loads("the runtime works in the kernel on two CPUs: Seq, nested critical:, pool, slab, errors",
          Kdir / "runtime" / "kruntime.tuck", "runtime", "",
          @["insmod rc: 0", "KLOG: KRUNTIME_OK"])

  # --- Windows: built with mingw-w64, inspected ------------------------------
  t.windowsBuilds("the same hello builds as a Windows driver",
                  Kdir / "hello" / "hello_kmod.tuck", "hello",
                  @["DbgPrint", "ExAllocatePoolWithTag"])
  t.windowsBuilds("a WDM device driver links with its C half",
                  Kdir / "wincount" / "wincount.tuck", "wincount",
                  @["IoCreateDevice", "IoCreateSymbolicLink"])
  t.finish()
