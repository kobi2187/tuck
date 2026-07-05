# tests/parser_examples.nim
import os, strutils
import ../lexer
import ../compiler/ast
import ../compiler/parser

const exampleDir = "examples"

proc testParse(path: string) =
  let source = readFile(path)
  echo "=== Parsing: ", path
  
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
  let module = parser.parseModule()
  echo "Successfully parsed module with ", module.decls.len, " declarations."
  for i, decl in module.decls:
    echo "  Decl ", i + 1, ": kind=", decl.kind
    if decl.kind == dkFn or decl.kind == dkObject:
      echo "    name=", decl.name
  echo ""

when isMainModule:
  for path in walkDir(exampleDir):
    let filePath = path.path
    if filePath.endsWith(".tuck"):
      testParse(filePath)
