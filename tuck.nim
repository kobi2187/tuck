# tuck.nim — Tuck compiler CLI.
# Fail fast: every stage stops at the first error with file:line:col context.
#
#   tuck lex     file.tuck        (l)   tokens to stdout
#   tuck parse   file.tuck        (p)   syntax check; --ast dumps JSON
#   tuck check   file.tuck        (ch)  effects + types + PENDING report
#   tuck compile file.tuck        (c)   check + emit .nim (--beef for .bf too)
import os, strutils, times, std/json
import lexer
import compiler/ast
import compiler/parser
import compiler/semantics
import compiler/typecheck
import compiler/lowering
import compiler/codegen
import compiler/codegen_beef
import compiler/ast_serializer

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

# check stage; returns the module so compile can continue with it
proc checkSource(source, path: string): Module =
  result = parseSource(source)
  try:
    verifyModuleEffects(result)
    typecheckModule(result)
  except SemanticError as err:
    die(path & ":" & $err.line & ":" & $err.col & ": " & err.msg)
  let pend = pendingReport(result)
  if pend.len > 0:
    echo "PENDING (", pend.len, " unimplemented):"
    for entry in pend:
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
    discard checkSource(source, path)
    echo "OK (", elapsedMs(t0), ")"
  of "compile", "c":
    let m = checkSource(source, path)
    lowerModule(m)
    var outDir = parentDir(path)
    for o in opts:
      if o.startsWith("-o:"): outDir = o[3 .. ^1]
    if outDir == "": outDir = "."
    createDir(outDir)
    let base = extractFilename(path).changeFileExt("")
    # import path from the output dir back to the runtime module
    let rtDir = getAppDir() / "compiler"
    let rtImport = relativePath(rtDir / "tuck_rt", outDir).replace('\\', '/')
    let nimPath = outDir / (base & ".nim")
    writeFile(nimPath, emitNim(m, rtImport))
    echo "wrote ", nimPath
    if "--beef" in opts:
      let bfPath = outDir / (base & ".bf")
      writeFile(bfPath, emitBeef(m))
      echo "wrote ", bfPath
    echo "OK (", elapsedMs(t0), ")"
  else:
    usage()
