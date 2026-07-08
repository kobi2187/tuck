# tuck.nim — Tuck compiler CLI.
# Fail fast: every stage stops at the first error with file:line:col context.
#
#   tuck lex     file.tuck        (l)   tokens to stdout
#   tuck parse   file.tuck        (p)   syntax check; --ast dumps JSON
#   tuck check   file.tuck        (ch)  effects + types + PENDING report
#   tuck compile file.tuck        (c)   check + emit .nim (--beef for .bf too)
import os, strutils, times, tables, std/json
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

options:
  --ast         (parse) dump the AST as JSON to stdout
  --beef        (compile) also emit a .bf Beef file
  -o:DIR        (compile) output directory (default: next to source)"""
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
  of "compile", "c":
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
      writeFile(nimPath, emitNim(lm.m, rtImport, realModules))
      echo "wrote ", nimPath
    let m = prog[^1].m
    if "--beef" in opts:
      let bfPath = outDir / (base & ".bf")
      writeFile(bfPath, emitBeef(m))
      echo "wrote ", bfPath
    echo "OK (", elapsedMs(t0), ")"
  else:
    usage()
