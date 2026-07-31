## Per-phase compiler profiler. Generates a large single-module program, then
## times each compile phase in isolation — lex, parse, verifyEffects,
## typecheck, lower, emitNim — to find where the time goes before optimizing.
##
## TWO RULES THIS FILE EXISTS TO FOLLOW, both learned by getting them wrong:
##
## 1. TIME EACH PHASE DIRECTLY, never by subtraction. Timing A+B+C and
##    subtracting separately-measured A and B puts all of their drift on C, the
##    smallest term. That reported lowering at up to 18x its real cost and
##    sometimes as a NEGATIVE number — and an 18x figure is exactly the kind of
##    thing someone optimizes against for a day before noticing.
##
## 2. SETUP OUTSIDE THE TIMER. The mutating phases (typecheck, lower, emitNim)
##    consume the tree they run on, so each iteration needs a fresh one. Trees
##    are pre-built into a pool below and one is taken per iteration, because
##    building inside the timed body would measure the front end again.
##
## Timing itself is benchy's: warmup, many runs, min/avg/stddev. The min is the
## number to read — it is the run least disturbed by the OS, and it settles
## within a handful of runs, so every phase is capped at POOL of them.
##
## Run: nim c -d:release --hints:off -o:benches/.bph benches/bench_phases.nim
##      benches/.bph [N]          (N = generated fn count, default 4000)

import std/[os, strutils, tables]
import benchy
import ../lexer
import ../compiler/parser
import ../compiler/semantics
import ../compiler/typecheck
import ../compiler/lowering
import ../compiler/codegen
import ../compiler/ast

proc gen(n: int): string =
  ## N independent type+fn pairs, then a body calling every one of them.
  ## The calls matter: payload explosion in lowering is per CALL EXPRESSION,
  ## so a file of declarations alone would not exercise it.
  var s = ""
  for i in 0 ..< n:
    s.add("type T" & $i & " = {a: int, b: int}\n")
    s.add("fn f" & $i & "({a: int, b: int}) -> int:\n")
    s.add("  let s = a + b\n")
    s.add("  return s * " & $i & "\n")
  s.add("fn main() -> int:\n")
  for i in 0 ..< n:
    s.add("  let v" & $i & " = {a: 1, b: 2} f" & $i & "\n")
  s.add("  return 0\n")
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

# How many pre-built trees each mutating phase gets — and therefore how many
# times it runs, since benchy stops when the pool does.
#
# Building the pool is the whole cost of this benchmark: each entry is a full
# front-end run that gets thrown away. 40 entries x 4 mutating phases took 23s
# at N=2000. The number to read is the MIN, which stabilises long before then;
# 12 keeps that and returns in a third of the time.
const POOL = 12

proc main() =
  let n = if paramCount() >= 1: parseInt(paramStr(1)) else: 4000
  let src = gen(n)
  let lines = src.count('\n')
  echo "phase profile: N=", n, " fns, ", lines, " lines"
  echo "(read the MIN column; setup is outside every timer)"

  let toks = lexAll(src)

  # benchy's `keep` is a no-op, so a result only handed to it is dead code and
  # -d:release deletes the call — these phases reported 0.001 ms until the
  # results were accumulated into something the program actually reads.
  var sink = 0

  timeIt "lex", POOL:
    sink += lexAll(src).len

  timeIt "parse", POOL:
    sink += parseFresh(src, toks).decls.len

  # verifyEffects mutates the resolution layer, so each run needs its own tree.
  var semPool: seq[Module]
  for _ in 0 ..< POOL: semPool.add(parseFresh(src, toks))
  var semIdx = 0
  timeIt "verifyEffects", POOL:
    verifyModuleEffects(semPool[semIdx])
    inc semIdx

  var tcPool: seq[Module]
  for _ in 0 ..< POOL:
    var mm = parseFresh(src, toks)
    verifyModuleEffects(mm)
    tcPool.add(mm)
  var tcIdx = 0
  timeIt "typecheck", POOL:
    var mods = @[("m", "m.tuck", tcPool[tcIdx])]
    discard typecheckProgram(mods)
    inc tcIdx

  var loPool: seq[Module]
  for _ in 0 ..< POOL:
    var mm = parseFresh(src, toks)
    verifyModuleEffects(mm)
    var mods = @[("m", "m.tuck", mm)]
    discard typecheckProgram(mods)
    loPool.add(mm)
  var loIdx = 0
  timeIt "lower", POOL:
    lowerModule(loPool[loIdx])
    inc loIdx

  var emPool: seq[Module]
  for _ in 0 ..< POOL:
    var mm = parseFresh(src, toks)
    verifyModuleEffects(mm)
    var mods = @[("m", "m.tuck", mm)]
    discard typecheckProgram(mods)
    lowerModule(mm)
    emPool.add(mm)
  var emIdx = 0
  timeIt "emitNim", POOL:
    sink += emitNim(emPool[emIdx], realModules = initTable[string, Module]()).len
    inc emIdx

  # Make `sink` observable so none of the above can be optimized away.
  if sink == -1: echo "unreachable"

main()
