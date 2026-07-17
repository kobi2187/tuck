# tests/end_to_end.nim
import ../lexer
import ../compiler/parser
import ../compiler/codegen
import ../compiler/codegen_beef
import ../compiler/lowering
import ../compiler/ast_serializer
import ../compiler/semantics
import ../compiler/typecheck
import std/json

const testTuckCode = """
fn addOne(x: int) -> int:
  return x + 1

type Controls:
  volume: int
  muted: bool

type Connection:
  latency: int

type PlayerComposition = Controls + Connection {latency -> delay}

register RCC_CR at 0x40021000:
  HSION: bit 0 [read, write]
  HSIRDY: bit 1 [read]

type Temperature:
  celsius: float
  invariant:
    celsius >= -273.15

type TrafficLight:
  | Red
  | Yellow
  | Green
  transitions:
    Red -> Green
    Green -> Yellow
    Yellow -> Red

decision classifyPacket({priority: int, size: int, encrypted: bool}) -> int:
  | 2    128   true  -> 1
  | 2    128   false -> 2
  | 2    64    _     -> 3
  | 1     _     _     -> 4
  | _       _     _     -> 5

fn main() -> void:
  let val1 = 9 addOne
  let val2 = {priority: 2, size: 64, encrypted: false} classifyPacket
  val2 echo
  return
"""

proc runEndToEnd() =
  # Step 1: Lexing
  var lexer = Lexer(source: testTuckCode, position: 0, line: 1, column: 1, indentStack: @[0])
  var tokens: seq[Token]
  while true:
    let token = lexer.nextToken()
    tokens.add(token)
    if token.kind == tkEOF:
      break
      
  # Step 2: Parsing
  var parser = Parser(source: testTuckCode, tokens: tokens, cursor: 0)
  let m = parser.parseModule()
  
  # Step 2.3: Semantic Verification
  verifyModuleEffects(m)

  # Step 2.4: Type checking
  typecheckModule(m)

  # Step 2.5: Compile-time TODO report
  let pend = pendingReport(m)
  if pend.len > 0:
    echo "PENDING (", pend.len, " unimplemented):"
    for entry in pend:
      echo "  ", entry

  # Step 2.5: AST Lowering Pass
  lowerModule(m)
  
  # Serialize AST to file
  let astJson = toJson(m)
  writeFile("tests/temp_ast.json", pretty(astJson))
  echo "Written serialized AST to tests/temp_ast.json"
  
  # Step 3: Codegen to Nim
  let nimCode = emitNim(m)
  echo "=== Generated Nim Code ==="
  echo nimCode
  echo "=========================="
  
  let tempPath = "tests/temp_out.nim"
  writeFile(tempPath, nimCode)
  echo "Written Nim output to tests/temp_out.nim"

  # Step 4: Codegen to Beef
  let beefCode = emitBeef(m)
  echo "=== Generated Beef Code ==="
  echo beefCode
  echo "=========================="

  let tempBeefPath = "tests/temp_out.bf"
  writeFile(tempBeefPath, beefCode)
  echo "Written Beef output to tests/temp_out.bf"

proc testSemanticError() =
  # A pure function calling a function marked with [io] effect
  const invalidCode = """
fn writeLog() [io]:
  discard

fn doWork() -> void:
  {} writeLog
"""
  var lexer = Lexer(source: invalidCode, position: 0, line: 1, column: 1, indentStack: @[0])
  var tokens: seq[Token]
  while true:
    let token = lexer.nextToken()
    tokens.add(token)
    if token.kind == tkEOF:
      break
  var parser = Parser(source: invalidCode, tokens: tokens, cursor: 0)
  let m = parser.parseModule()
  
  try:
    verifyModuleEffects(m)
    echo "FAILED: Expected semantic error but none was thrown."
  except SemanticError as err:
    echo "SUCCESS: Caught expected semantic error: ", err.msg, " at line ", err.line, ":", err.col

when isMainModule:
  runEndToEnd()
  testSemanticError()
