## crash_decode — post-mortem decoding of a Cortex-M fault record.
##
## The board's fault handler prints one parseable line:
##   FAULT PC=... LR=... CFSR=... HFSR=... BFAR=... xPSR=...
## This module turns that line into a developer-facing answer:
##   - which status bits fired, and what they mean (not just a hex dump);
##   - whether the stacked PC can be trusted (IMPRECISERR cannot);
##   - the nearest symbol via `nm` and the source line via `addr2line`;
##   - what happened / why it matters / how to fix it.
##
## Tool names are parameters so a test can use host `nm`/`addr2line` while the
## CLI uses the ARM ones. Nothing here rejects a build: the program already
## stopped. The SARIF output uses the registered TK-CR01 warning code.

import std/[strutils, json, os, osproc]
import diagnostics, report_format

type
  FaultRecord* = object
    pc*: int64
    lr*: int64
    cfsr*: int64
    hfsr*: int64
    bfar*: int64
    xpsr*: int64

  CrashReport* = object
    elf*: string
    fault*: FaultRecord
    kind*: string
    precise*: bool
    bits*: seq[string]
    what*: string
    why*: string
    fix*: string
    pcSymbol*: string
    pcLocation*: string
    callerSymbol*: string
    callerLocation*: string

proc hexVal*(s: string): int64 =
  ## Hex with or without `0x`, case-insensitive. A malformed field is 0 —
  ## better to decode the rest of the record than to lose it all.
  let t = if s.startsWith("0x") or s.startsWith("0X"): s[2 .. ^1] else: s
  if t.len == 0: return 0
  try: parseHexInt(t).int64
  except ValueError: 0

proc field(line, key: string): string =
  ## Read `KEY=value` from a whitespace-separated record line.
  for tok in line.splitWhitespace():
    let eq = tok.find('=')
    if eq > 0 and tok[0 .. eq - 1].toUpperAscii == key.toUpperAscii:
      return tok[eq + 1 .. ^1]
  ""

proc parseFaultLine*(line: string): FaultRecord =
  ## Accepts a bare `PC=...` list or the full `FAULT PC=...` line.
  result = FaultRecord(pc: hexVal(field(line, "PC")),
                       lr: hexVal(field(line, "LR")),
                       cfsr: hexVal(field(line, "CFSR")),
                       hfsr: hexVal(field(line, "HFSR")),
                       bfar: hexVal(field(line, "BFAR")),
                       xpsr: hexVal(field(line, "xPSR")))

proc findElf*(log: string): string =
  ## A captured sim log is self-describing when the loop printed `ELF=<path>`.
  for line in log.splitLines():
    let t = line.strip()
    if t.startsWith("ELF="): return t[4 .. ^1].strip()
  ""

proc faultLine*(log: string): string =
  for line in log.splitLines():
    if line.contains("FAULT ") or line.strip().startsWith("FAULT "):
      return line
  ""

proc setBit(v: int64, bit: int): bool = (v and (1'i64 shl bit)) != 0

type BitDesc = tuple[reg: char, bit: int, msg: string]
  ## 'c' = CFSR (MMFSR bits 0-7, BFSR 8-15, UFSR 16-31), 'h' = HFSR.

const FaultBits: seq[BitDesc] = @[
  ('c', 0, "IACCVIOL: instruction fetch violated the MPU rules"),
  ('c', 1, "DACCVIOL: data access violated the MPU rules"),
  ('c', 3, "MMUNSTKERR: MemManage fault on exception return"),
  ('c', 4, "MMSTKERR: MemManage fault on exception entry (stack?)"),
  ('c', 5, "MMLSPERR: MemManage fault during lazy FP state save"),
  ('c', 7, "MMARVALID: MMAR holds the faulting address"),
  ('c', 8, "IBUSERR: bus fault on instruction fetch"),
  ('c', 9, "PRECISERR: precise bus fault; PC names the failing access"),
  ('c', 10, "IMPRECISERR: IMPRECISE bus fault; the stacked PC is NOT the store"),
  ('c', 11, "UNSTKERR: bus fault on exception return"),
  ('c', 12, "STKERR: bus fault on exception entry (stack overflow?)"),
  ('c', 13, "LSPERR: bus fault during lazy FP state save"),
  ('c', 15, "BFARVALID: BFAR holds the faulting address"),
  ('c', 16, "UNDEFINSTR: undefined instruction"),
  ('c', 17, "INVSTATE: invalid EPSR state (Thumb bit lost?)"),
  ('c', 18, "INVPC: invalid exception return (bad EXC_RETURN)"),
  ('c', 19, "NOCP: coprocessor instruction with no coprocessor"),
  ('c', 24, "UNALIGNED: unaligned word load/store (CCR.UNALIGN_TRP)"),
  ('c', 25, "DIVBYZERO: integer divide by zero (CCR.DIV_0_TRP)"),
  ('h', 1, "VECTTBL: vector table read failed"),
  ('h', 30, "FORCED: a Mem/Bus/Usage fault escalated to HardFault"),
  ('h', 31, "DEBUGEVT: debug event escalated to HardFault"),
]

proc decodeBits*(f: FaultRecord): seq[string] =
  ## Only set bits are reported; a hex dump is not an explanation. The table
  ## keeps this a loop rather than 22 look-alike `if`s (complexity ratchet).
  for b in FaultBits:
    let status = if b.reg == 'c': f.cfsr else: f.hfsr
    if setBit(status, b.bit): result.add b.msg

proc faultKinds(f: FaultRecord): string =
  ## A fault can set bits in more than one CFSR sub-register; name every one.
  var cats: seq[string]
  if (f.cfsr and 0xff'i64) != 0: cats.add "MemManage"
  if (f.cfsr and 0xff00'i64) != 0: cats.add "BusFault"
  if (f.cfsr and 0xffff0000'i64) != 0: cats.add "UsageFault"
  if cats.len == 0: cats.add "HardFault"
  cats.join(" + ")

proc faultWhat(f: FaultRecord, bits: seq[string], imprecise: bool): string =
  result = if bits.len > 0: bits[0] else: "no status bits recorded"
  if imprecise:
    result.add "; the stacked PC is IMPRECISE and cannot name the faulting store"
  if setBit(f.hfsr, 30):
    result.add "; escalated to HardFault because its handler was not enabled"

proc faultWhy(f: FaultRecord, imprecise: bool): string =
  if imprecise:
    return "A buffered write can fault several instructions after the store, " &
           "so trusting this PC sends you to the wrong line. Use LR (the call " &
           "site) and BFAR instead."
  if f.pc == 0:
    return "The core branched to address 0: there is no code there, so no " &
           "source line can be named for the PC. LR still names the call site " &
           "that performed the jump."
  if setBit(f.cfsr, 15) or setBit(f.cfsr, 7):
    return "The fault carries an exact address: that is the strongest clue " &
           "about which access to fix."
  "The stacked PC points at the failing instruction, so a source " &
    "line can be recovered from DWARF built with --debug-lines."

proc faultFix(f: FaultRecord, imprecise: bool): string =
  if imprecise:
    return "Do not edit code at the stacked PC. Decode LR-2 for the caller and " &
           "BFAR for the address; look for a buffer overrun, DMA write or bad " &
           "pointer in that call path."
  if setBit(f.cfsr, 17):
    return "A branch landed on an even address: Cortex-M Thumb code needs bit " &
           "0 set. Check a null or uninitialised function pointer, and decode " &
           "LR-2 for the call site that made the jump."
  if setBit(f.cfsr, 24):
    return "Align the address to 4 bytes, or use a byte/halfword access. " &
           "Cortex-M traps unaligned word accesses when CCR.UNALIGN_TRP is set."
  if setBit(f.cfsr, 25):
    return "Guard the divisor before the `/i`; divide-by-zero traps only when " &
           "CCR.DIV_0_TRP is set."
  if setBit(f.cfsr, 9) or setBit(f.cfsr, 15):
    return "Inspect the decoded PC and BFAR; check for a write to flash, a " &
           "read-only peripheral field, or a null/dangling pointer."
  if setBit(f.cfsr, 1) or setBit(f.cfsr, 7):
    return "Inspect MMAR and the MPU map: a write hit a region declared " &
           "read-only, or an access crossed a region boundary."
  if setBit(f.cfsr, 12) or setBit(f.cfsr, 11):
    return "Check the stack high-water mark and the reserved stack in the " &
           "linker script; an entry/return access fell outside it."
  "Follow the decoded symbol and call site back to the Tuck line, " &
    "rebuild with --debug-lines if no line is shown."

proc classify*(f: FaultRecord): tuple[kind: string, precise: bool,
                                      what, why, fix: string] =
  let bits = decodeBits(f)
  let imprecise = setBit(f.cfsr, 10)
  result = (faultKinds(f), not imprecise and bits.len > 0,
            faultWhat(f, bits, imprecise), faultWhy(f, imprecise),
            faultFix(f, imprecise))

proc nearestSymbol*(elf: string, address: int64, nmExe = ""): string =
  ## Symbol at or below `address`, Thumb bit masked. A symbol answers "which
  ## function"; a source line answers "what to edit" — both are kept.
  ## `execProcess` does not search PATH, so resolve the tool by name here.
  ## The address is a NUMBER, not a string: `$addr` would render decimal and
  ## `hexVal` would then read those digits as hex, landing on the wrong symbol.
  let exe = if nmExe == "": findExe("arm-none-eabi-nm") else: nmExe
  if exe == "": return "?"
  let target = address and not 1'i64
  let nmOut = execProcess(exe, args=["-n", elf], options={poStdErrToStdOut})
  var best: int64 = -1
  for line in nmOut.splitLines():
    let parts = line.splitWhitespace()
    if parts.len < 3: continue
    try:
      let a = parseHexInt("0x" & parts[0]).int64
      if a <= target and a > best:
        best = a
        result = parts[2]
    except ValueError: discard
  if result == "": result = "?"

proc sourceLine*(elf: string, address: int64, addrExe = ""): string =
  ## `addr2line -f -C` prints symbol then file:line. A `?:0`/`??` answer means
  ## no DWARF for that address; report that honestly rather than inventing a
  ## line from the generated file. As above, `address` stays numeric throughout.
  let exe = if addrExe == "": findExe("arm-none-eabi-addr2line") else: addrExe
  if exe == "": return ""
  let a = "0x" & toHex(address and not 1'i64, 8)
  let addrOut = execProcess(exe, args=["-e", elf, "-f", "-C", a],
                            options={poStdErrToStdOut})
  let ls = addrOut.splitLines()
  if ls.len < 2: return ""
  let loc = ls[1].strip()
  if loc == "" or loc.startsWith("??") or loc.contains(":?"): ""
  else: loc

proc decodeFault*(elf: string, f: FaultRecord,
                  nmExe = "", addrExe = ""): CrashReport =
  result.elf = elf
  result.fault = f
  result.bits = decodeBits(f)
  let c = classify(f)
  result.kind = c.kind
  result.precise = c.precise
  result.what = c.what
  result.why = c.why
  result.fix = c.fix
  if f.pc == 0:
    # A null call target: "nearest symbol at or below 0" would name whatever
    # happens to sit at address 0 (the vector table) and send the developer
    # to the wrong place. Say what it is instead.
    result.pcSymbol = "(null target — no symbol)"
    result.pcLocation = ""
  elif elf != "":
    result.pcSymbol = nearestSymbol(elf, f.pc, nmExe)
    result.pcLocation = sourceLine(elf, f.pc, addrExe)
  if elf != "":
    # LR points to the instruction AFTER the call. Subtract 2 (one Thumb
    # instruction) to land on the call itself — that is the Tuck line a
    # developer can edit, not the following statement.
    let caller = if f.lr > 2: f.lr - 2 else: f.lr
    result.callerSymbol = nearestSymbol(elf, caller, nmExe)
    result.callerLocation = sourceLine(elf, caller, addrExe)

proc lineOf(location: string): (string, int) =
  if location == "": ("", 0)
  else:
    let p = location.rfind(':')
    if p < 0 or p == location.high: (location, 0)
    else:
      let n = location[p + 1 .. ^1]
      try: (location[0 .. p - 1], parseInt(n))
      except ValueError: (location, 0)

proc bestSite*(r: CrashReport): (string, int) =
  ## Prefer the faulting PC's source line, then the caller's; a location in a
  ## generated .nim is less useful than a Tuck one, so prefer a `.tuck` file
  ## when both are present. An imprecise PC is NEVER offered as the place to
  ## edit: the hardware buffered the write, so that line is a guess.
  let caller = lineOf(r.callerLocation)
  if not r.precise: return caller
  let pc = lineOf(r.pcLocation)
  if pc[0].endsWith(".tuck"): pc
  elif caller[0].endsWith(".tuck"): caller
  elif pc[1] > 0: pc
  else: caller

proc toFindings*(r: CrashReport): seq[Finding] =
  let site = bestSite(r)
  var msg = r.kind & ": " & r.what & ". Fix: " & r.fix
  if site[1] > 0:
    msg.add " (" & site[0] & ":" & $site[1] & ")"
  result.add Finding(code: $dcCrDecoded, msg: msg,
                     path: (if site[0] != "": site[0] else: r.elf),
                     line: (if site[1] > 0: site[1] else: 1), col: 1,
                     level: "warning")

proc renderText*(r: CrashReport): string =
  result.add "Crash: " & r.kind & " (CFSR=0x" & toHex(r.fault.cfsr, 8) &
             ", HFSR=0x" & toHex(r.fault.hfsr, 8) & ")\n"
  if r.bits.len > 0:
    for b in r.bits: result.add "  bit: " & b & "\n"
  result.add "  What: " & r.what & "\n"
  result.add "  PC " & toHex(r.fault.pc, 8) & " -> " & r.pcSymbol
  if r.pcLocation != "":
    if r.precise: result.add " (" & r.pcLocation & ")"
    else: result.add " (" & r.pcLocation & ", UNRELIABLE: imprecise fault)"
  result.add "\n"
  result.add "  LR " & toHex(r.fault.lr, 8) & " -> " & r.callerSymbol &
             " (call site "
  if r.callerLocation != "": result.add r.callerLocation
  else: result.add "unavailable — build with --debug-lines"
  result.add ")\n"
  result.add "  Why: " & r.why & "\n"
  result.add "  Fix: " & r.fix & "\n"

proc renderJson*(r: CrashReport): string =
  var bits = newJArray()
  for b in r.bits: bits.add %b
  let site = bestSite(r)
  let findings = parseJson(toJson(r.toFindings()))["findings"]
  pretty(%*{
    "elf": r.elf,
    "fault": %*{
      "pc": "0x" & toHex(r.fault.pc, 8), "lr": "0x" & toHex(r.fault.lr, 8),
      "cfsr": "0x" & toHex(r.fault.cfsr, 8),
      "hfsr": "0x" & toHex(r.fault.hfsr, 8),
      "bfar": "0x" & toHex(r.fault.bfar, 8),
      "xpsr": "0x" & toHex(r.fault.xpsr, 8)
    },
    "class": r.kind, "precise": r.precise, "bits": bits,
    "pc": %*{"symbol": r.pcSymbol, "location": r.pcLocation},
    "caller": %*{"symbol": r.callerSymbol, "location": r.callerLocation},
    "sourceLocation": site[0], "sourceLine": site[1],
    "what": r.what, "why": r.why, "fix": r.fix,
    "findings": findings
  })
