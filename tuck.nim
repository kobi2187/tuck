# tuck.nim — Tuck compiler CLI.
# Fail fast: every stage stops at the first error with file:line:col context.
#
#   tuck lex     file.tuck        (l)   tokens to stdout
#   tuck parse   file.tuck        (p)   syntax check; --ast dumps JSON
#   tuck check   file.tuck        (ch)  effects + types + PENDING report
#   tuck compile file.tuck        (c)   check + emit .nim (--beef for .bf too)
import os, strutils, times, tables, std/json, osproc
import lexer
import compiler/ast
import compiler/parser
import compiler/semantics
import compiler/typecheck
import compiler/lowering
import compiler/codegen
import compiler/codegen_beef
import compiler/ast_serializer
import compiler/modules

proc usage() =
  stderr.writeLine """tuck — the Tuck compiler

usage: tuck <command> <file.tuck> [options]

commands:
  lex, l        tokenize and print the token stream
  parse, p      parse; prints OK or the first syntax error
  check, ch     parse + effect check + type check + pending report
  compile, c    check + transpile to Nim (and Beef with --beef)
  build, b      compile + nim c to a binary (fn main runs at start)

options:
  --ast         (parse) dump the AST as JSON to stdout
  --beef        (compile) also emit a .bf Beef file
  -o:DIR        (compile/build) output directory (default: next to source)
  --nim:FLAGS   (build) extra nim flags, e.g. --nim:"--os:standalone --cpu:arm""""
  quit(2)

proc die(msg: string) =
  stderr.writeLine msg
  quit(1)

proc elapsedMs(t0: float): string =
  formatFloat((epochTime() - t0) * 1000, ffDecimal, 1) & " ms"

proc lexTokens(source: string): seq[Token] =
  var lex = Lexer(source: source, position: 0, line: 1, column: 1, indentStack: @[0])
  while true:
    let t = lex.nextToken()
    result.add(t)
    if t.kind == tkEOF: break

proc parseSource(source: string): Module =
  var p = Parser(source: source, tokens: lexTokens(source), cursor: 0)
  p.parseModule()

# check stage over the whole import closure; returns the loaded program
# (dep-first, entry module last) so compile can continue with it.
# needBodies=false (check): unchanged imports resolve from the signature
# index — no AST load at all. needBodies=true (compile): full ASTs.
proc checkProgram(path: string, needBodies = false): seq[LoadedModule] =
  var sigOnly = initTable[string, IndexEntry]()
  try:
    if needBodies:
      result = loadProgram(path)
    else:
      (result, sigOnly) = loadProgramIndexed(path)
  except ModuleError as err:
    die(path & ": " & err.msg)
  injectImportedTypes(result)  # imported types are visible unqualified
  var mods: seq[tuple[name, path: string, m: Module]]
  for lm in result: mods.add((lm.name, lm.path, lm.m))
  var preSigs = initTable[string, seq[SigInfo]]()
  for name, e in sigOnly: preSigs[name] = e.sigs
  var shortcuts: seq[string]
  try:
    for lm in result:
      verifyModuleEffects(lm.m)
    shortcuts = typecheckProgram(mods, preSigs)
  except SemanticError as err:
    # typecheckProgram errors already carry file:line:col; effects errors don't
    if ".tuck:" in err.msg: die(err.msg)
    else: die(path & ":" & $err.line & ":" & $err.col & ": " & err.msg)
  # program checked clean: refresh the signature index for future checks
  updateIndex(parentDir(absolutePath(path)), result, moduleSigs)
  var pend: seq[string]
  for lm in result:
    for entry in pendingReport(lm.m):
      # qualify pendings living in imported modules
      if lm.path != result[^1].path: pend.add(lm.name & "::" & entry)
      else: pend.add(entry)
  for name, e in sigOnly:
    for si in e.sigs:
      if si.isPending:
        pend.add(name & "::" & sigLine(si))
  if pend.len > 0:
    echo "PENDING (", pend.len, " unimplemented):"
    for entry in pend:
      echo "  ", entry
  if shortcuts.len > 0:
    echo "SHORTCUTS (", shortcuts.len, " routed to the global error handler):"
    for entry in shortcuts:
      echo "  ", entry

proc findBeefBuild(): string =
  if existsEnv("BEEFBUILD_BIN") and fileExists(getEnv("BEEFBUILD_BIN")):
    return getEnv("BEEFBUILD_BIN")
  let candidates = ["/opt/beef/IDE/dist/BeefBuild", "/opt/beef/bin/BeefBuild"]
  for c in candidates:
    if fileExists(c): return c
  let (output, rc) = execCmdEx("which BeefBuild")
  if rc == 0: return output.strip()
  return ""

# BeefBuild's per-platform Debug output dir name (verified: Linux64 on this host).
proc beefBuildTarget(): string =
  case hostOS
  of "linux": "Debug_Linux64"
  of "windows": "Debug_Win64"
  of "macosx": "Debug_macOS"
  else: "Debug_" & hostOS

proc buildBeefProject(beefBuild, projDir, entryBf: string, deps: seq[string],
                       srcOutDir, rtBeef: string) =
  removeDir(projDir)
  createDir(projDir / "src")
  copyFile(rtBeef, projDir / "src" / "TuckRt.bf")
  copyFile(entryBf, projDir / "src" / "Program.bf")
  for dep in deps:
    copyFile(srcOutDir / ("mod_" & dep & ".bf"), projDir / "src" / ("mod_" & dep & ".bf"))
  writeFile(projDir / "BeefProj.toml", """
FileVersion = 1

[Project]
Name = "tuckcheck"
TargetType = "BeefConsoleApplication"
StartupObject = "TuckApp.Program"
""")
  writeFile(projDir / "BeefSpace.toml", """
FileVersion = 1
Projects = {tuckcheck = {Path = "."}}

[Workspace]
StartupProject = "tuckcheck"
""")
  let rc = execShellCmd(quoteShell(beefBuild) & " -workspace=" & quoteShell(projDir))
  if rc != 0: die("tuck: BeefBuild failed")

when isMainModule:
  if paramCount() < 2: usage()
  let cmd = paramStr(1)
  let path = paramStr(2)
  if not fileExists(path): die("tuck: no such file: " & path)
  let source = readFile(path)
  var opts: seq[string]
  for i in 3 .. paramCount(): opts.add(paramStr(i))
  let t0 = epochTime()

  case cmd
  of "lex", "l":
    for t in lexTokens(source):
      echo t.line, ":", t.column, "\t", t.kind, "\t", t.value
    echo "OK (", elapsedMs(t0), ")"
  of "parse", "p":
    let m = parseSource(source)
    if "--ast" in opts:
      echo pretty(toJson(m))
    echo "OK — ", m.decls.len, " top-level declarations (", elapsedMs(t0), ")"
  of "check", "ch":
    discard checkProgram(path)
    echo "OK (", elapsedMs(t0), ")"
  of "compile", "c", "build", "b":
    let prog = checkProgram(path, needBodies = true)
    var outDir = parentDir(path)
    for o in opts:
      if o.startsWith("-o:"): outDir = o[3 .. ^1]
    if outDir == "": outDir = "."
    createDir(outDir)
    let base = extractFilename(path).changeFileExt("")
    # import path from the output dir back to the runtime module
    let rtDir = getAppDir() / "compiler"
    let rtImport = relativePath(rtDir / "tuck_rt", outDir).replace('\\', '/')
    var realModules = initTable[string, Module]()
    for lm in prog[0 ..< prog.high]:
      realModules[lm.name] = lm.m
    # imported modules first (each its own Nim file), entry module last
    for lm in prog:
      lowerModule(lm.m)
      let isEntry = lm.path == prog[^1].path
      let outName = if isEntry: base else: lm.name
      let nimPath = outDir / (outName & ".nim")
      writeFile(nimPath, emitNim(lm.m, rtImport, realModules, outName))
      echo "wrote ", nimPath
    let m = prog[^1].m
    var beefDeps: seq[string]
    if "--beef" in opts:
      for lm in prog[0 ..< prog.high]:
        let modBfPath = outDir / ("mod_" & lm.name & ".bf")
        writeFile(modBfPath, emitBeefModule(lm.name, lm.m, realModules))
        echo "wrote ", modBfPath
        beefDeps.add(lm.name)
      let bfPath = outDir / (base & ".bf")
      writeFile(bfPath, emitBeef(m, realModules, base))
      echo "wrote ", bfPath
    if cmd in ["build", "b"]:
      # entry point: `fn main` runs when the binary starts. No main =
      # library build: the emitted code IS the artifact, no binary.
      var hasMain = false
      for d in m.decls:
        if d != nil and d.kind == dkFn and d.name == "main": hasMain = true
      if not hasMain:
        echo "library (no fn main): emitted code only, no binary"
        echo "OK (", elapsedMs(t0), ")"
        quit(0)
      let mainNim = outDir / (base & ".nim")
      writeFile(mainNim, readFile(mainNim) & "\nwhen isMainModule:\n  main()\n")
      # nim flags passthrough for cross/bare-metal: --nim:"--os:standalone ..."
      var nimFlags = ""
      for o in opts:
        if o.startsWith("--nim:"): nimFlags = o[6 .. ^1]
      # Nim module names can't start with a digit or contain dashes
      var binBase = base.replace("-", "_")
      if binBase.len > 0 and binBase[0] in {'0' .. '9'}: binBase = "m_" & binBase
      let binNim = outDir / (binBase & ".nim")
      if binNim != mainNim: copyFile(mainNim, binNim)
      let binPath = outDir / binBase
      let nimCmd = "nim c --hints:off --warnings:off " & nimFlags &
                   " -o:" & quoteShell(binPath) & " " & quoteShell(binNim)
      let rc = execShellCmd(nimCmd)
      if rc != 0: die("tuck: nim compilation failed")
      echo "built ", binPath
      if "--beef" in opts:
        let beefBuild = findBeefBuild()
        if beefBuild == "":
          echo "tuck: BeefBuild not found (set BEEFBUILD_BIN) — skipping Beef build"
        else:
          let projDir = outDir / (binBase & "_beefproj")
          buildBeefProject(beefBuild, projDir, outDir / (base & ".bf"), beefDeps,
                            outDir, getAppDir() / "compiler" / "tuck_rt.bf")
          let beefBinPath = projDir / "build" / beefBuildTarget() / "tuckcheck" / "tuckcheck"
          if not fileExists(beefBinPath):
            die("tuck: Beef compilation failed")
          copyFile(beefBinPath, outDir / (binBase & "_beef"))
          inclFilePermissions(outDir / (binBase & "_beef"), {fpUserExec, fpGroupExec, fpOthersExec})
          echo "built ", outDir / (binBase & "_beef")
    echo "OK (", elapsedMs(t0), ")"
  else:
    usage()
