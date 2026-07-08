# tests/compile_all_examples.nim
import os, strutils, std/json
import ../lexer
import ../compiler/ast
import ../compiler/parser
import ../compiler/lowering
import ../compiler/codegen
import ../compiler/codegen_beef
import ../compiler/ast_serializer
import ../compiler/semantics
import ../compiler/typecheck

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
]

proc nimCheckOutput(baseName: string): bool =
  # Dashes are invalid in Nim module names: check via a sanitized copy.
  let checkDir = outDir / "nimcheck"
  createDir(checkDir)
  let modName = "m_" & baseName.replace("-", "_")
  var src = readFile(outDir / (baseName & ".nim"))
  src = src.replace("import ../compiler/tuck_rt", "import ../../../compiler/tuck_rt")
  writeFile(checkDir / (modName & ".nim"), src)
  let (_, rc) = execCmdEx("nim check --hints:off --warnings:off " &
                          quoteShell(checkDir / (modName & ".nim")))
  return rc == 0

proc compileExample(path: string) =
  let filename = extractFilename(path)
  let baseName = filename.changeFileExt("")
  let source = readFile(path)
  
  # Step 1: Lexing
  var lexer = Lexer(source: source, position: 0, line: 1, column: 1, indentStack: @[0])
  var tokens: seq[Token]
  while true:
    let token = lexer.nextToken()
    tokens.add(token)
    if token.kind == tkEOF:
      break
      
  # Step 2: Parsing
  var parser = Parser(source: source, tokens: tokens, cursor: 0)
  let m = parser.parseModule()
  
  # Step 2.3: Semantic verification
  verifyModuleEffects(m)

  # Step 2.4: Type checking (before lowering — lowering rewrites call args)
  let shortcuts = typecheckModule(m)
  if shortcuts.len > 0:
    echo "  SHORTCUTS (", shortcuts.len, " routed to the global error handler) in ", filename, ":"
    for entry in shortcuts:
      echo "    ", entry

  # Step 2.5: Compile-time TODO report
  let pend = pendingReport(m)
  if pend.len > 0:
    echo "  PENDING (", pend.len, " unimplemented) in ", filename, ":"
    for entry in pend:
      echo "    ", entry

  # Step 3: Lowering
  lowerModule(m)
  
  # Step 4: Serialize AST
  let astJson = toJson(m)
  writeFile(outDir / (baseName & ".json"), pretty(astJson))
  
  # Step 5: Code Generation
  let nimCode = emitNim(m)
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
