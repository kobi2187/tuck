import os, strutils
include "../lexer.nim"

const exampleDir = "examples"

proc printTokens(path: string) =
  let source = readFile(path)
  echo "=== ", path
  var lexer = Lexer(source: source, position: 0, line: 1, column: 1, linesLen: @[], indentStack: @[])
  while true:
    let token = lexer.nextToken()
    echo token
    if token.kind == tkEOF:
      break
  echo ""

when isMainModule:
  for path in walkDir(exampleDir):
    let filePath = path.path
    if filePath.endsWith(".tuck"):
      printTokens(filePath)
