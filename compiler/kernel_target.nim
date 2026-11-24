# compiler/kernel_target.nim — `tuck build --target:linux-kmod | windows-kmd`:
# a Tuck program as an operating-system kernel module (docs/kernel/README.md).
#
# The program is compiled exactly as for a board — freestanding, no memory
# manager, the stackless scheduler — but for x86-64 with the kernel's C
# flags, into ONE relocatable object that includes no kernel header. The
# platform's glue (platforms/<target>/tuck_kglue.c, the only file compiled
# against the kernel) supplies what the program needs — allocation,
# printing, `critical:`, a stop for a failed check — and the entry points:
# `main` is the module's init, `unload` (when declared) its exit.
#
#   linux-kmod   kbuild links glue + object into NAME.ko against the kernel
#                headers (TUCK_KDIR, else /lib/modules/<newest>/build)
#   windows-kmd  mingw-w64 links them into NAME.sys, a native-subsystem
#                image whose entry is DriverEntry, against ntoskrnl
import std/[os, osproc, strutils, algorithm, sequtils]

type KernelTarget* = enum
  ktNone = "", ktLinux = "linux-kmod", ktWindows = "windows-kmd"

proc kernelTargetOf*(opts: seq[string]): KernelTarget =
  ## `--target:linux-kmod` or `--target:windows-kmd`; ktNone otherwise.
  ## `--target:NAME` also selects `when target:` blocks (spec), for any NAME:
  ## the two kernel names do both, so a driver can choose per OS with
  ## `when target: linux-kmod`; any other name keeps only that meaning.
  for o in opts:
    if not o.startsWith("--target:"): continue
    case o["--target:".len .. ^1]
    of "linux-kmod": return ktLinux
    of "windows-kmd": return ktWindows
    else: discard
  ktNone

proc kernelEntry*(mainCall, unloadCall, prelude: string): string =
  ## The program's side of the entry points the glue calls after NimMain:
  ## `main`'s result is the init's, as a C int; `unload` (or nothing) the
  ## exit. `prelude` is what a hosted entry runs before main (registrations).
  var pre = ""
  for ln in prelude.splitLines:
    if ln.strip != "": pre.add "    " & ln.strip & "\n"
  "\nwhen isMainModule:\n" &
  "  proc tuck_kmod_init(): cint {.exportc: \"tuck_kmod_init\".} =\n" &
  pre &
  "    cint(" & mainCall & ")\n" &
  "  proc tuck_kmod_exit() {.exportc: \"tuck_kmod_exit\".} =\n" &
  "    " & (if unloadCall == "": "discard" else: unloadCall) & "\n"

const LinuxKernelCFlags = [
  # The x86-64 kernel's code model and ABI: no red zone (an interrupt pushes
  # onto the same stack), no SSE/x87 (the kernel does not save FPU state on
  # entry), no stack protector or PIC, and its Spectre mitigations
  # (retpoline thunks, return thunks), which objtool checks for.
  "-mcmodel=kernel", "-mno-red-zone", "-fno-pic", "-fno-pie", "-mno-sse",
  "-mno-sse2", "-mno-mmx", "-mno-80387", "-mno-3dnow",
  "-fno-stack-protector", "-ffreestanding", "-fno-asynchronous-unwind-tables",
  "-fno-common", "-fcf-protection=branch", "-mindirect-branch=thunk-extern",
  "-mfunction-return=thunk-extern", "-mindirect-branch-register"]

const WindowsKernelCFlags = [
  # Windows x64 has no red zone in its ABI; drivers are built without the
  # CRT, and without SSE here too, so a float cannot slip in without the
  # state save the kernel would need for x87/MMX.
  "-ffreestanding", "-fno-stack-protector", "-mno-sse", "-mno-sse2",
  "-mno-mmx", "-mno-80387", "-mno-3dnow", "-fno-asynchronous-unwind-tables"]

proc kernelNimFlags*(t: KernelTarget): string =
  ## What `nim c` needs to compile the program into objects for `t`: nothing
  ## is linked or given a C `main` here; linkKernelModule does the rest.
  var cflags: seq[string]
  case t
  of ktLinux: cflags = @LinuxKernelCFlags
  of ktWindows: cflags = @WindowsKernelCFlags
  of ktNone: return ""
  result = " --os:any --cpu:amd64 -d:noSignalHandler -d:freestanding" &
    " -d:tuckKernel -d:tuck" & (if t == ktLinux: "LinuxKernel" else: "WindowsKernel") &
    " --threads:off --tlsEmulation:off --noMain:on --noLinking:on" &
    " --stackTrace:off --lineTrace:off"
  if t == ktWindows:
    result.add " --cc:gcc --gcc.exe:x86_64-w64-mingw32-gcc" &
               " --gcc.linkerexe:x86_64-w64-mingw32-gcc"
  for f in cflags: result.add " --passC:" & f

proc linuxKdir*(): string =
  ## The kernel build tree: $TUCK_KDIR, else the newest /lib/modules/*/build.
  result = getEnv("TUCK_KDIR")
  if result != "": return
  var vers: seq[string]
  for kind, p in walkDir("/lib/modules"):
    if fileExists(p / "build" / "Makefile"): vers.add p
  vers.sort
  if vers.len > 0: result = vers[^1] / "build"

proc kernelToolsMissing*(t: KernelTarget): string =
  ## What the target needs that this machine lacks, or "".
  case t
  of ktLinux:
    if findExe("ld") == "": return "ld (binutils)"
    if linuxKdir() == "":
      return "kernel headers (apt install linux-headers-$(uname -r), or TUCK_KDIR)"
  of ktWindows:
    if findExe("x86_64-w64-mingw32-gcc") == "":
      return "x86_64-w64-mingw32-gcc (apt install gcc-mingw-w64-x86-64)"
  of ktNone: discard
  ""

proc nimObjects(nimCache: string): seq[string] =
  for kind, p in walkDir(nimCache):
    if p.endsWith(".o") or p.endsWith(".obj"): result.add p
  result.sort

proc run(cmd: string, what: string): bool =
  let (output, rc) = execCmdEx(cmd)
  if rc != 0:
    stderr.writeLine "tuck: " & what & " failed:\n" & output
  rc == 0

proc linkLinux(name, nimCache, outDir, appDir: string,
               cSources: seq[string]): string =
  ## kbuild in outDir/kmod: the glue compiled against the headers, the
  ## program's object shipped prebuilt (kbuild's `_shipped` rule copies it;
  ## modpost wants the `.cmd` record kbuild keeps for every object).
  let kdir = linuxKdir()
  let work = absolutePath(outDir / "kmod")
  createDir(work)
  let shipped = work / "tuck_nim.o_shipped"
  if not run("ld -r -o " & quoteShell(shipped) & " " &
             nimObjects(nimCache).mapIt(quoteShell(it)).join(" "),
             "combining the program's objects"): return ""
  writeFile(work / ".tuck_nim.o.cmd",
    "savedcmd_tuck_nim.o := ld -r (tuck build: the Tuck program, compiled by Nim with kernel flags)\n")
  copyFile(appDir / "platforms" / "linux-kmod" / "tuck_kglue.c", work / "tuck_kglue.c")
  copyFile(appDir / "platforms" / "tuck_platform.h", work / "tuck_platform.h")
  # The program's own C (`extern [c, lib: "x.c"]`): compiled here, against
  # the kernel's headers, with any header it names beside it.
  var extra = ""
  for src in cSources:
    copyFile(src, work / src.extractFilename)
    for kind, h in walkDir(src.parentDir):
      if h.endsWith(".h"): copyFile(h, work / h.extractFilename)
    extra.add " " & src.extractFilename.changeFileExt(".o")
  writeFile(work / "Kbuild",
    "obj-m := " & name & ".o\n" & name & "-y := tuck_kglue.o tuck_nim.o" & extra & "\n" &
    "ccflags-y := -DTUCK_MODULE_DESCRIPTION='\"" & name & " (Tuck)\"' -I$(src)\n")
  if not run("make -s -C " & quoteShell(kdir) & " M=" & quoteShell(work) &
             " modules", "kbuild"): return ""
  result = outDir / (name & ".ko")
  copyFile(work / (name & ".ko"), result)

proc linkWindows(name, nimCache, outDir, appDir: string,
                 cSources: seq[string]): string =
  ## A native-subsystem PE whose entry is DriverEntry, against ntoskrnl and
  ## hal; no CRT, no default libraries.
  let cc = "x86_64-w64-mingw32-gcc"
  let work = absolutePath(outDir / "kmd")
  createDir(work)
  let glueObj = work / "tuck_kglue.o"
  if not run(cc & " -c -ffreestanding -Wall -I/usr/x86_64-w64-mingw32/include/ddk -I" &
             quoteShell(appDir / "platforms") & " " &
             quoteShell(appDir / "platforms" / "windows-kmd" / "tuck_kglue.c") &
             " -o " & quoteShell(glueObj), "compiling the Windows glue"): return ""
  # The program's own C, compiled against the DDK headers like the glue.
  var objs = @[glueObj]
  for src in cSources:
    let obj = work / src.extractFilename.changeFileExt(".o")
    if not run(cc & " -c -ffreestanding -Wall -I/usr/x86_64-w64-mingw32/include/ddk -I" &
               quoteShell(src.parentDir) & " " & quoteShell(src) & " -o " & quoteShell(obj),
               "compiling " & src.extractFilename): return ""
    objs.add obj
  result = outDir / (name & ".sys")
  if not run(cc & " -o " & quoteShell(result) & " " & objs.mapIt(quoteShell(it)).join(" ") & " " &
             nimObjects(nimCache).mapIt(quoteShell(it)).join(" ") &
             " -nostdlib -nostartfiles -shared -Wl,--subsystem,native" &
             " -Wl,--entry,DriverEntry -Wl,--image-base,0x140000000" &
             " -Wl,--dynamicbase -Wl,--nxcompat -Wl,--exclude-all-symbols -lntoskrnl -lhal -lgcc",
             "linking the driver"): return ""

proc linkKernelModule*(t: KernelTarget, name, nimCache, outDir, appDir: string,
                       cSources: seq[string] = @[]): string =
  ## Link the compiled program into the target's module; "" when it failed
  ## (the reason is already on stderr).
  let modName = name.replace("-", "_")
  case t
  of ktLinux: linkLinux(modName, nimCache, outDir, appDir, cSources)
  of ktWindows: linkWindows(modName, nimCache, outDir, appDir, cSources)
  of ktNone: ""
