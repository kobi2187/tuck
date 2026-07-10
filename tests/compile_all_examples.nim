# tests/compile_all_examples.nim
import os, strutils, tables, std/json
import ../lexer
import ../compiler/ast
import ../compiler/parser
import ../compiler/lowering
import ../compiler/codegen
import ../compiler/codegen_beef
import ../compiler/ast_serializer
import ../compiler/semantics
import ../compiler/typecheck
import ../compiler/modules

import osproc

const
  exampleDir = "examples"
  outDir = "tests/examples_out"

# Examples whose generated Nim must pass `nim check`. Others reference
# deliberately-undeclared sketch functions (fetch, merge, ...) and cannot.
# When a new example goes green, add it here so regressions are caught.
const nimCheckExpected = [
  "01-data-flow",
  "05-actors-effects",
  "07-comments",
  "06-transitions-example",
  "08-actors_isolated_state",
  "10-invariants",
  "13-arena-mem",
  "15-type-attributes",
  "19-event-registry",
  "21-decision-bitmask",
  "22-error-policy",
  "23-units",
  "14-task",
  "24-stdlib",
]

proc nimCheckOutput(baseName: string): bool =
  # Dashes are invalid in Nim module names: check via a sanitized copy.
  let checkDir = outDir / "nimcheck"
  createDir(checkDir)
  let modName = "m_" & baseName.replace("-", "_")
  var src = readFile(outDir / (baseName & ".nim"))
  src = src.replace("import ../compiler/tuck_rt", "import ../../../compiler/tuck_rt")
  # imported Tuck modules sit as sibling .nim files; carry them along
  for line in src.splitLines:
    if line.startsWith("import ") and "/" notin line:
      let dep = line[7 .. ^1].strip()
      var depSrc = readFile(outDir / (dep & ".nim"))
      depSrc = depSrc.replace("import ../compiler/tuck_rt", "import ../../../compiler/tuck_rt")
      writeFile(checkDir / (dep & ".nim"), depSrc)
  writeFile(checkDir / (modName & ".nim"), src)
  let (_, rc) = execCmdEx("nim check --hints:off --warnings:off " &
                          quoteShell(checkDir / (modName & ".nim")))
  return rc == 0

proc compileExample(path: string) =
  let filename = extractFilename(path)
  let baseName = filename.changeFileExt("")

  # Steps 1-2: whole import closure (lex + parse, msgpack-cached imports)
  let prog = loadProgram(path)
  var mods: seq[tuple[name, path: string, m: Module]]
  for lm in prog: mods.add((lm.name, lm.path, lm.m))

  # Step 2.3: Semantic verification
  for lm in prog:
    verifyModuleEffects(lm.m)

  # Step 2.4: Type checking (before lowering — lowering rewrites call args)
  let shortcuts = typecheckProgram(mods)
  if shortcuts.len > 0:
    echo "  SHORTCUTS (", shortcuts.len, " routed to the global error handler) in ", filename, ":"
    for entry in shortcuts:
      echo "    ", entry

  # Step 2.5: Compile-time TODO report
  let m = prog[^1].m
  let pend = pendingReport(m)
  if pend.len > 0:
    echo "  PENDING (", pend.len, " unimplemented) in ", filename, ":"
    for entry in pend:
      echo "    ", entry

  # Step 3: Lowering
  for lm in prog:
    lowerModule(lm.m)

  # Step 4: Serialize AST
  let astJson = toJson(m)
  writeFile(outDir / (baseName & ".json"), pretty(astJson))

  # Step 5: Code Generation — imported modules become sibling Nim files
  var realModules = initTable[string, Module]()
  for lm in prog[0 ..< prog.high]:
    realModules[lm.name] = lm.m
  for lm in prog[0 ..< prog.high]:
    writeFile(outDir / (lm.name & ".nim"), emitNim(lm.m, realModules = realModules))
  let nimCode = emitNim(m, realModules = realModules)
  writeFile(outDir / (baseName & ".nim"), nimCode)

  let beefCode = emitBeef(m)
  writeFile(outDir / (baseName & ".bf"), beefCode)

when isMainModule:
  createDir(outDir)
  echo "Compiling all examples to: ", outDir
  var count = 0
  for path in walkDir(exampleDir):
    let filePath = path.path
    if filePath.endsWith(".tuck"):
      compileExample(filePath)
      count += 1
  echo "Successfully compiled ", count, " examples!"

  echo "Running nim check on generated output..."
  var checkFailures = 0
  for baseName in nimCheckExpected:
    if nimCheckOutput(baseName):
      echo "  PASS nim check: ", baseName
    else:
      echo "  FAIL nim check: ", baseName, " (regression — was valid Nim before)"
      checkFailures.inc
  if checkFailures > 0:
    quit(1)
  echo "All ", nimCheckExpected.len, " expected outputs are valid Nim."
