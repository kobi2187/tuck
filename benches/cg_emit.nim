## Single-shot emitNim driver for callgrind. No timing, no reps — callgrind
## counts instructions, so one run is enough and reps only slow it down.
##   nim c -d:release --debugger:native -o:benches/.cg benches/cg_emit.nim
##   valgrind --tool=callgrind --callgrind-out-file=/tmp/cg.out benches/.cg 400
##   callgrind_annotate /tmp/cg.out | head -40
import std/[os, strutils, tables]
import ../lexer
from ../compiler/modules import lexSource
import ../compiler/parser
import ../compiler/semantics
import ../compiler/typecheck
import ../compiler/lowering
import ../compiler/codegen_emit
import ../compiler/resolution
import ../compiler/ast

proc gen(n: int): string =
  ## A synthetic program of `n` record types, `n` fns and a main calling each
  ## — sized to make the emitter's per-decl cost visible.
  for i in 0 ..< n:
    result.add("type T" & $i & " = {a: int, b: int}\n")
    result.add("fn f" & $i & "({a: int, b: int}) -> int:\n")
    result.add("  let s = a + b\n")
    result.add("  return s * " & $i & "\n")
  result.add("fn main() -> int:\n")
  for i in 0 ..< n:
    result.add("  let v" & $i & " = {a: 1, b: 2} f" & $i & "\n")
  result.add("  return 0\n")


when isMainModule:
  let n = if paramCount() >= 1: parseInt(paramStr(1)) else: 400
  let src = gen(n)
  var p = Parser(source: src, tokens: lexSource(src), cursor: 0)
  var m = p.parseModule()
  var mods = @[("m", "m.tuck", m)]
  # typecheck first: it resets the semantic layer the effect pass writes to
  typecheckProgram(mods)
  verifyModuleEffects(m)
  lowerModule(semLayer, m, initTable[string, Module]())
  # the ONLY thing under the profiler that matters
  let emitted = emitNim(m, semLayer)
  echo "emitted ", emitted.len, " bytes for N=", n
