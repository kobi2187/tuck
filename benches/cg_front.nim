## Single-shot front-end driver for callgrind: lex + parse + effects +
## typecheck, no reps. Companion to cg_emit.nim, which covers the back end.
##   nim c -d:release --debugger:native -o:benches/.cgf benches/cg_front.nim
##   valgrind --tool=callgrind --callgrind-out-file=/tmp/cgf.out benches/.cgf 400
##   callgrind_annotate --tree=calling /tmp/cgf.out | head -60
import std/[os, strutils]
import ../lexer
import ../compiler/parser
import ../compiler/semantics
import ../compiler/typecheck
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
  let toks = lexAll(src)
  var p = Parser(source: src, tokens: toks, cursor: 0)
  var m = p.parseModule()
  verifyModuleEffects(m)
  var mods = @[("m", "m.tuck", m)]
  discard typecheckProgram(mods)
  echo "front end done: ", toks.len, " tokens, ", m.decls.len, " decls, N=", n
