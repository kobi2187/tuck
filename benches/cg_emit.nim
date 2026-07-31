## Single-shot emitNim driver for callgrind. No timing, no reps — callgrind
## counts instructions, so one run is enough and reps only slow it down.
##   nim c -d:release --debugger:native -o:benches/.cg benches/cg_emit.nim
##   valgrind --tool=callgrind --callgrind-out-file=/tmp/cg.out benches/.cg 400
##   callgrind_annotate /tmp/cg.out | head -40
import std/[os, strutils, tables]
import ../lexer
import ../compiler/parser
import ../compiler/semantics
import ../compiler/typecheck
import ../compiler/lowering
import ../compiler/codegen
import ../compiler/ast

proc gen(n: int): string =
  for i in 0 ..< n:
    result.add("type T" & $i & " = {a: int, b: int}\n")
    result.add("fn f" & $i & "({a: int, b: int}) -> int:\n")
    result.add("  let s = a + b\n")
    result.add("  return s * " & $i & "\n")
  result.add("fn main() -> int:\n")
  for i in 0 ..< n:
    result.add("  let v" & $i & " = {a: 1, b: 2} f" & $i & "\n")
  result.add("  return 0\n")

proc lexAll(src: string): seq[Token] =
  var lx = Lexer(source: src, position: 0, line: 1, column: 1, indentStack: @[0])
  while true:
    let t = lx.nextToken()
    result.add(t)
    if t.kind == tkEOF: break

when isMainModule:
  let n = if paramCount() >= 1: parseInt(paramStr(1)) else: 400
  let src = gen(n)
  var p = Parser(source: src, tokens: lexAll(src), cursor: 0)
  var m = p.parseModule()
  verifyModuleEffects(m)
  var mods = @[("m", "m.tuck", m)]
  discard typecheckProgram(mods)
  lowerModule(m)
  # the ONLY thing under the profiler that matters
  let emitted = emitNim(m, realModules = initTable[string, Module]())
  echo "emitted ", emitted.len, " bytes for N=", n
