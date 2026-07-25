## Per-phase compiler profiler. Generates a large single-module program, then
## times each compile phase in isolation — lex, parse, verifyEffects,
## typecheck, lower, emitNim — to find where the time goes before optimizing.
##
## Phases that MUTATE the AST (typecheck, lower) are measured on a fresh parse
## each iteration so the work is real every time. Reports ms and % of total.
##
## Run via benches/run_phases.sh (builds with the right flags/paths).

import std/[times, os, strutils, tables]
import ../lexer
import ../compiler/parser
import ../compiler/semantics
import ../compiler/typecheck
import ../compiler/lowering
import ../compiler/codegen
import ../compiler/ast

proc gen(n: int): string =
  ## N independent type+fn pairs — real checker work N times, no shared shortcut.
  var s = ""
  for i in 0 ..< n:
    s.add("type T" & $i & " = {a: int, b: int}\n")
    s.add("fn f" & $i & "({a: int, b: int}) -> int:\n")
    s.add("  let s = a + b\n")
    s.add("  return s * " & $i & "\n")
  s

proc lexAll(src: string): seq[Token] =
  var lx = Lexer(source: src, position: 0, line: 1, column: 1, indentStack: @[0])
  while true:
    let t = lx.nextToken()
    result.add(t)
    if t.kind == tkEOF: break

proc parseFresh(src: string, toks: seq[Token]): Module =
  var p = Parser(source: src, tokens: toks, cursor: 0)
  p.parseModule()

proc ms(t0: float): float = (epochTime() - t0) * 1000.0

proc main() =
  let n = if paramCount() >= 1: parseInt(paramStr(1)) else: 4000
  let src = gen(n)
  let lines = src.count('\n')
  echo "phase profile: N=", n, " fns, ", lines, " lines"

  # --- lex (pure, repeatable) ---
  var toks: seq[Token]
  var t0 = epochTime()
  const lexReps = 5
  for _ in 0 ..< lexReps: toks = lexAll(src)
  let tLex = ms(t0) / lexReps

  # --- parse (pure: fresh tokens, builds a new tree) ---
  t0 = epochTime()
  const parseReps = 5
  var m: Module
  for _ in 0 ..< parseReps: m = parseFresh(src, toks)
  let tParse = ms(t0) / parseReps

  # --- verifyEffects (mutates resolution; parse fresh each rep) ---
  t0 = epochTime()
  const semReps = 5
  for _ in 0 ..< semReps:
    var mm = parseFresh(src, toks)
    verifyModuleEffects(mm)
  let tSem = ms(t0) / semReps - tParse   # subtract the parse we paid inside

  # --- typecheck (mutates; fresh parse+verify each rep) ---
  t0 = epochTime()
  const tcReps = 5
  for _ in 0 ..< tcReps:
    var mm = parseFresh(src, toks)
    verifyModuleEffects(mm)
    var mods = @[("m", "m.tuck", mm)]
    discard typecheckProgram(mods)
  let tTc = ms(t0) / tcReps - tParse - tSem

  # --- lower (mutates; fresh full front-end each rep) ---
  t0 = epochTime()
  const loReps = 5
  for _ in 0 ..< loReps:
    var mm = parseFresh(src, toks)
    verifyModuleEffects(mm)
    var mods = @[("m", "m.tuck", mm)]
    discard typecheckProgram(mods)
    lowerModule(mm)
  let tLo = ms(t0) / loReps - tParse - tSem - tTc

  # --- emitNim (needs a lowered tree; fresh each rep) ---
  t0 = epochTime()
  const emReps = 5
  for _ in 0 ..< emReps:
    var mm = parseFresh(src, toks)
    verifyModuleEffects(mm)
    var mods = @[("m", "m.tuck", mm)]
    discard typecheckProgram(mods)
    lowerModule(mm)
    discard emitNim(mm, realModules = initTable[string, Module]())
  let tEm = ms(t0) / emReps - tParse - tSem - tTc - tLo

  let total = tLex + tParse + tSem + tTc + tLo + tEm
  proc row(name: string, t: float) =
    echo "  ", name.alignLeft(16), (t).formatFloat(ffDecimal, 2).align(8), " ms  ",
         (100.0 * t / total).formatFloat(ffDecimal, 1).align(5), " %"
  row("lex", tLex)
  row("parse", tParse)
  row("verifyEffects", tSem)
  row("typecheck", tTc)
  row("lower", tLo)
  row("emitNim", tEm)
  echo "  ", "TOTAL".alignLeft(16), total.formatFloat(ffDecimal, 2).align(8), " ms  ",
       (lines.float / (total/1000.0)).formatFloat(ffDecimal, 0), " lines/sec"

main()
