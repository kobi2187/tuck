## `tuck decode-crash` — the post-mortem fault decoder.
##
## Pins what a developer gets after a crash: status bits decoded into words,
## precise vs imprecise stated (so a buffered store never gets a fake line),
## a parseable record from a captured log, JSON/SARIF with TK-CR01 as a
## WARNING, and DWARF that names the .tuck rather than the generated .nim.
##
## No QEMU here: the ELF is fake unless the last case builds a host one. Every
## fast case passes /bin/false as nm/addr2line so the assertions are about the
## decoder, not about which binutils happen to be installed.

import std/[json, os, osproc, sequtils, strutils]
import ../harness

proc decodeSays(t: var T, name: string, argv: seq[string],
                check: proc (text: string): bool) =
  let idx = t.needCmd(argv)
  if t.phase == pCollect: return
  if t.skippedCmd(idx): t.skip name; return
  let (rc, text) = resultOf(t, idx)
  if rc != 0: t.no name, "decode-crash failed: " & text
  elif check(text): t.ok name
  else: t.no name, "unexpected report: " & text

proc decodeJson(t: var T, name: string, argv: seq[string],
                check: proc (n: JsonNode): bool) =
  let idx = t.needCmd(argv)
  if t.phase == pCollect: return
  if t.skippedCmd(idx): t.skip name; return
  let (rc, text) = resultOf(t, idx)
  if rc != 0:
    t.no name, "decode-crash --format:json failed: " & text
    return
  try:
    if check(parseJson(text)): t.ok name
    else: t.no name, "JSON did not carry the expected shape: " & text
  except JsonParsingError as e:
    t.no name, "JSON did not parse: " & e.msg

proc decodeSarif(t: var T, name: string, argv: seq[string],
                 check: proc (n: JsonNode): bool) =
  let idx = t.needCmd(argv)
  if t.phase == pCollect: return
  if t.skippedCmd(idx): t.skip name; return
  let (rc, text) = resultOf(t, idx)
  if rc != 0:
    t.no name, "decode-crash --format:sarif failed: " & text
    return
  try:
    if check(parseJson(text)): t.ok name
    else: t.no name, "SARIF did not carry the expected shape: " & text
  except JsonParsingError as e:
    t.no name, "SARIF did not parse: " & e.msg

proc run*(t: var T) =
  let exe = t.root / "tuck"
  # Common tail: no binutils needed for these cases, and a fake ELF keeps the
  # decoder from touching a real file.
  let noTools = @["--nm:/bin/false", "--addr2line:/bin/false"]

  # --- 1. status bits become words, not a hex dump -----------------------
  t.decodeSays "PRECISERR is named and PC is trusted",
    @[exe, "decode-crash", "/nope.elf", "--pc:0x2000", "--cfsr:0x200"] & noTools,
    proc (s: string): bool =
      s.contains("PRECISERR") and s.contains("BFAR") and
      not s.contains("IMPRECISE")

  t.decodeJson "an imprecise fault is recorded as not precise",
    @[exe, "decode-crash", "/nope.elf", "--pc:0x2000", "--cfsr:0x400",
      "--format:json"] & noTools,
    proc (n: JsonNode): bool =
      n["precise"].getBool == false and
        n["bits"].getElems.anyIt(it.getStr.startsWith("IMPRECISERR")) and
        n["what"].getStr.contains("IMPRECISE")

  t.decodeJson "MemManage names DACCVIOL and MMARVALID",
    @[exe, "decode-crash", "/nope.elf", "--pc:0x2000", "--cfsr:0x82",
      "--format:json"] & noTools,
    proc (n: JsonNode): bool =
      n["class"].getStr == "MemManage" and
        n["bits"].getElems.anyIt(it.getStr.startsWith("DACCVIOL")) and
        n["bits"].getElems.anyIt(it.getStr.startsWith("MMARVALID"))

  t.decodeSays "an unaligned store is named, with the fix",
    @[exe, "decode-crash", "/nope.elf", "--pc:0x15a", "--cfsr:0x01000000",
      "--hfsr:0x40000000"] & noTools,
    proc (s: string): bool =
      s.contains("UNALIGNED") and s.contains("Align the address") and
        s.contains("FORCED")

  t.decodeSays "PC=0 is a null target, not symbol 0",
    @[exe, "decode-crash", "/nope.elf", "--pc:0", "--lr:0x185",
      "--cfsr:0x20000"] & noTools,
    proc (s: string): bool =
      s.contains("null target") and s.contains("Thumb")

  t.decodeJson "INVSTATE gives the null-branch fix",
    @[exe, "decode-crash", "/nope.elf", "--pc:0", "--cfsr:0x20000",
      "--format:json"] & noTools,
    proc (n: JsonNode): bool =
      n["fix"].getStr.contains("Thumb code needs bit 0 set")

  # --- 2. a captured log carries the whole record ------------------------
  t.src """
fn main() -> int:
  return 0
"""
  t.addFile "fault.log",
    "ELF=/tmp/opencode/fault-test.elf\n" &
    "BEFORE_FAULT\n" &
    "FAULT PC=0000015a LR=00000185 CFSR=01000000 HFSR=40000000 " &
    "BFAR=00000000 xPSR=01000000\n"
  let log = t.curDir / "fault.log"

  t.decodeJson "--log finds the ELF and parses every field",
    @[exe, "decode-crash", "-", "--log:" & log, "--format:json"] & noTools,
    proc (n: JsonNode): bool =
      n["elf"].getStr == "/tmp/opencode/fault-test.elf" and
        n["fault"]["pc"].getStr == "0x0000015A" and
        n["fault"]["lr"].getStr == "0x00000185" and
        n["fault"]["cfsr"].getStr == "0x01000000" and
        n["fault"]["bfar"].getStr == "0x00000000" and
        n["precise"].getBool

  # --- 3. machine-readable reports ---------------------------------------
  t.decodeJson "JSON carries one TK-CR01 finding",
    @[exe, "decode-crash", "-", "--log:" & log, "--format:json"] & noTools,
    proc (n: JsonNode): bool =
      n["findings"].len == 1 and
        n["findings"][0]["code"].getStr == "TK-CR01"

  t.decodeSarif "SARIF uses TK-CR01 at warning level with a location",
    @[exe, "decode-crash", "-", "--log:" & log, "--format:sarif"] & noTools,
    proc (n: JsonNode): bool =
      let r = n["runs"][0]["results"][0]
      n["version"].getStr == "2.1.0" and
        r["ruleId"].getStr == "TK-CR01" and
        r["level"].getStr == "warning" and
        r["locations"][0]["physicalLocation"]["artifactLocation"]["uri"].getStr ==
          "/tmp/opencode/fault-test.elf"

  # The old positional form is still the one in the docs and muscle memory.
  t.decodeSays "the two-positional form still works",
    @[exe, "decode-crash", "/tmp/opencode/fault-test.elf", "0x15a"] & noTools,
    proc (s: string): bool = s.contains("Crash:")

  # The code is registered and explainable, as a warning.
  let e = t.needCmd(@[exe, "explain", "TK-CR01"])
  if t.phase != pCollect:
    let (rc, text) = resultOf(t, e)
    if rc == 0 and text.contains("Crash Warning"):
      t.ok "TK-CR01 explains as a Crash Warning"
    else:
      t.no "TK-CR01 explains as a Crash Warning", text

  # --- 4. DWARF names the Tuck file, not the generated Nim ----------------
  # A host build is enough for the tool chain; the ARM build is the QEMU gate
  # in testing_experiment/. The line number can be offset by Nim's #line
  # directives, so assert the *file suffix* — the developer-facing promise.
  t.src """
fn helper({x: int}) -> int:
  return x + 1

fn main() -> int:
  let y = {x: 1} helper
  return y
"""
  let dir = t.curDir
  # The call instruction inside main is a statement with a line pragma; the
  # function's entry address is only the prologue. Find it from disassembly
  # so this works under /bin/sh (no bash-only 16# hex arithmetic).
  let script = "cd " & quoteShell(dir) & " && " & quoteShell(exe) &
    " b t.tuck --debug-lines --nim:\"--passC:-g\" -o:out >/dev/null 2>&1 && " &
    "a=$(objdump -d out/t | awk '/<tuckXCBX91fnXCBX91main.*>:/{f=1;next} " &
    "f && /call/{gsub(\":\",\"\",$1); print \"0x\"$1; exit}') && " &
    "test -n \"$a\" && addr2line -e out/t -C \"$a\" | tail -1"
  let idx = t.needCmd(@["/bin/sh", "-c", script], vBuild)
  if t.phase != pCollect:
    if t.skippedCmd(idx) or findExe("nm") == "" or findExe("addr2line") == "":
      t.skip "addr2line names the .tuck with --debug-lines"
    else:
      let (rc, text) = resultOf(t, idx)
      if rc == 0 and text.contains(".tuck:"):
        t.ok "addr2line names the .tuck with --debug-lines"
      else:
        t.no "addr2line names the .tuck with --debug-lines", text

  t.finish()
