# svd2tuck — one CMSIS-SVD file to one importable Tuck module.
#
# The parser front half is vendored from EmbeddedNim/svd2nim (MIT); see
# ../vendor/README.md. Only the emitter here is ours. Output is plain Tuck
# text using the existing `register NAME at ADDR:` construct, so the compiler
# needs no new AST kind and the generated module needs no runtime support.
import std/os
import std/strutils
import std/strformat
import std/json
import std/sets
import std/tables
import std/algorithm

import ../vendor/basetypes
import ../vendor/svdparser
import ../vendor/transformations
import ../vendor/utils

const
  Version = "0.1.0"

  # The lexer's reserved words plus bracket-attribute names. A field or a
  # register name may not be one of these (TK-PA08, parser_base.expectName).
  TuckWords = [
    "fn", "let", "var", "const", "if", "elif", "else", "for", "in",
    "match", "loop", "break", "continue", "return", "type", "discard",
    "object", "mixin", "interface", "group", "public", "actor", "task",
    "fnsig", "on", "select", "registry", "decision", "pending", "when",
    "distinct", "bake", "import", "and", "or", "xor", "not", "true",
    "false", "none", "static_assert", "saturating", "wrapping",
    "trapping", "sealed", "packed", "volatile", "big_endian",
    "little_endian", "invariant", "io", "unsafe", "may_block",
    "no_alloc", "irq_safe", "error", "stack", "no_recursion",
    "recursion", "align", "priority", "urgent", "pure"
  ].toHashSet()

type
  Overlay = object
    onlyPeripherals: HashSet[string]
    omitRegisters: HashSet[string]
    renameRegisters: Table[string, string]
    forceAccess: Table[string, string]

  RegOut = object
    name: string
    address: int
    lines: seq[string]
    notes: seq[string]

proc tuckIdent(s: string): string =
  ## Keep Tuck's identifier alphabet, then dodge keywords and leading digits.
  ## Edge underscores are stripped too: the three backends append `_SHIFT` /
  ## `_MASK` to this name, and Nim rejects an identifier ending in `_`.
  for ch in s:
    if ch in IdentChars:
      if ch != '_' or (result.len > 0 and result[^1] != '_'): result.add ch
  # Nim 2.x rejects a doubled underscore anywhere in an identifier, and the
  # backends append `_SHIFT`/`_MASK` to these names.
  result = result.strip(chars = { '_' })
  if result.len == 0: result = "x"
  if result[0] notin IdentStartChars: result = "x" & result
  if result.toLowerAscii in TuckWords: result.add "x"

proc strSet(node: JsonNode, key: string): HashSet[string] =
  if node == nil or node.kind != JObject: return
  let v = node.getOrDefault(key)
  if v == nil or v.kind != JArray: return
  for item in v:
    if item.kind == JString: result.incl item.str

proc strMap(node: JsonNode, key: string): Table[string, string] =
  if node == nil or node.kind != JObject: return
  let v = node.getOrDefault(key)
  if v == nil or v.kind != JObject: return
  for k, item in v:
    if item.kind == JString: result[k] = item.str

proc loadOverlay(path: string): Overlay =
  if path == "": return
  let disk = parseFile(path)
  result.onlyPeripherals = disk.strSet("onlyPeripherals")
  result.omitRegisters = disk.strSet("omitRegisters")
  result.renameRegisters = disk.strMap("renameRegisters")
  result.forceAccess = disk.strMap("forceAccess")

proc processSvd(path: string): SvdDevice =
  ## The same normalisation svd2nim applies: derive inherited properties,
  ## expand dim arrays into concrete registers, resolve register properties.
  result = readSVD(path)
  result.deriveAll
  result.expandAll
  result.resolveAllProperties

proc accessText(dev: SvdDevice, reg: SvdRegisterTreeNode,
                f: SvdField, notes: var seq[string]): string =
  var acc = reg.resolvedProperties.access
  if f.access.isSome: acc = f.access.get
  case acc
  of raReadOnly: "[read]"
  of raWriteOnly: "[write]"
  of raReadWrite: "[read, write]"
  of raWriteOnce:
    notes.add &"{f.name}: writeOnce has no Tuck spelling; used [write]"
    "[write]"
  of raReadWriteOnce:
    notes.add &"{f.name}: read-writeOnce has no Tuck spelling; used [read, write]"
    "[read, write]"

proc emitField(outp: var RegOut, dev: SvdDevice, reg: SvdRegisterTreeNode,
               f: SvdField, used: var HashSet[string], ov: Overlay) =
  let key = outp.name & "." & f.name
  let name = tuckIdent(f.name)
  if name in used:
    outp.notes.add &"field {f.name} collided after sanitising; skipped"
    return
  used.incl name
  var noteSink: seq[string]
  let acc = accessText(dev, reg, f, noteSink)
  for n in noteSink: outp.notes.add key & ": " & n
  let forced = ov.forceAccess.getOrDefault(key, "")
  let bracket =
    case forced
    of "read": "[read]"
    of "write": "[write]"
    of "read, write", "readwrite", "rw": "[read, write]"
    of "": acc
    else:
      outp.notes.add &"unknown forceAccess '{forced}' for {key}; ignored"
      acc
  let bits =
    if f.lsb == f.msb: &"bit {f.lsb}"
    else: &"bits {f.lsb}..{f.msb}"
  let pad = if name.len < 8: " ".repeat(8 - name.len) else: ""
  outp.lines.add &"  {name}:{pad} {bits} {bracket}"

proc regNameFor(p: SvdPeripheral, n: SvdRegisterTreeNode,
                prefix: string, ov: Overlay): string =
  var parts: seq[string]
  # SvdId is Peripheral.Cluster.Register; the peripheral prefix is ours.
  let segs = n.id.split()
  for seg in segs[1..^1]: parts.add tuckIdent(stripPlaceHolder(seg))
  let raw = prefix & tuckIdent(stripPlaceHolder(p.name)) & "_" & parts.join("_")
  ov.renameRegisters.getOrDefault(raw, raw)

proc collectRegisters(dev: SvdDevice, prefix: string,
                      ov: Overlay): seq[RegOut] =
  for p in dev.peripherals.values:
    if ov.onlyPeripherals.len > 0 and p.name notin ov.onlyPeripherals: continue
    for node in p.walkRegistersOnly:
      let name = regNameFor(p, node, prefix, ov)
      if name in ov.omitRegisters: continue
      var outp = RegOut(name: name,
                        address: p.baseAddress + node.addressOffset)
      var used = initHashSet[string]()
      for f in node.fields: emitField(outp, dev, node, f, used, ov)
      if outp.lines.len == 0:
        outp.notes.add "no named fields; register omitted (Tuck has no whole-word MMIO)"
        continue
      result.add outp

  result.sort(proc (a, b: RegOut): int =
    if a.address != b.address: cmp(a.address, b.address) else: cmp(a.name, b.name))
  var seen = initHashSet[string]()
  var unique: seq[RegOut]
  for r in result:
    if r.name in seen:
      # A global register name is a compile error in Tuck. Keeping the first
      # (lowest address) makes output deterministic; the note is the audit.
      unique.add RegOut(name: "# " & r.name,
                        address: r.address, lines: @[],
                        notes: @[&"duplicate register name {r.name}; skipped"])
      continue
    seen.incl r.name
    unique.add r
  result = unique

proc render(dev: SvdDevice, regs: seq[RegOut], source, module: string): string =
  var notes: seq[string]
  var fieldCount = 0
  for r in regs:
    if r.name.startsWith("# "):
      notes.add r.notes[0]
      continue
    for n in r.notes: notes.add r.name & ": " & n
    fieldCount += r.lines.len
  result.add &"# Generated by svd2tuck {Version} from {source} (device {dev.metadata.name}).\n"
  result.add "# Do not edit. Regenerate with tools/svd2tuck.\n"
  result.add &"# {regs.len} registers, {fieldCount} fields. Addresses are absolute.\n"
  result.add "# Dropped by the Tuck register surface: reset values, field enums,\n"
  result.add "# modified-write values, read actions and write-once semantics.\n"
  if notes.len > 0:
    result.add "# Notes:\n"
    for n in notes: result.add "#   - " & n & "\n"
  for r in regs:
    if r.name.startsWith("# "):
      result.add r.name & " at 0x" & toHex(r.address, 8) & ":\n"
      continue
    result.add &"\nregister {r.name} at 0x{toHex(r.address, 8)}:\n"
    for ln in r.lines: result.add ln & "\n"

proc writeOutput(dir, module, text: string) =
  createDir(dir)
  let path = dir / (module & ".tuck")
  writeFile(path, text)
  stderr.writeLine "wrote " & path

proc usage() =
  stderr.writeLine """
svd2tuck - one CMSIS-SVD file to one importable Tuck module.

Usage:
  svd2tuck INPUT.svd [options]

Options:
  --out DIR           output directory (default: current directory)
  --module NAME       module/file name (default: lowercased SVD device name)
  --prefix NAME       prepended to every register name
  --overlay FILE      JSON overlay (omit/rename/forceAccess/onlyPeripherals)
  -h, --help          this help
"""
  quit(if commandLineParams().len == 0: 0 else: 2)

proc main() =
  let args = commandLineParams()
  if args.len == 0 or "-h" in args or "--help" in args: usage()
  var source = ""
  var outDir = getCurrentDir()
  var module = ""
  var prefix = ""
  var overlayPath = ""
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--out", "--module", "--prefix", "--overlay":
      if i + 1 >= args.len: quit("missing value for " & a, 2)
      inc i
      case a
      of "--out": outDir = args[i]
      of "--module": module = args[i]
      of "--prefix": prefix = args[i]
      of "--overlay": overlayPath = args[i]
      else: discard
    else:
      if a.startsWith("-"): quit("unknown option: " & a, 2)
      if source != "": quit("expected one SVD file", 2)
      source = a
    inc i
  if source == "": quit("expected an SVD file", 2)
  if not fileExists(source): quit("no such file: " & source, 2)

  let ov = loadOverlay(overlayPath)
  var dev = processSvd(source)
  if module == "": module = dev.metadata.name.toLowerAscii()
  if prefix == "": prefix = ""
  let regs = collectRegisters(dev, prefix, ov)
  let text = render(dev, regs, source.extractFilename, module)
  writeOutput(outDir, module, text)

when isMainModule:
  main()
