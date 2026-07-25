# compiler/parser_base.nim
#
# The parser's shared foundation: the `Parser` state (source + token stream +
# cursor) and the token-stream accessors every parsing bucket needs. The
# expression, type, and declaration parsers each import this; it holds no
# grammar of its own.
import strutils
import ../lexer
import ast

type
  Parser* = object
    source*: string
    tokens*: seq[Token]
    cursor*: int

proc current*(p: Parser): Token =
  if p.cursor < p.tokens.len:
    p.tokens[p.cursor]
  else:
    Token(kind: tkEOF, value: "", line: if p.tokens.len > 0: p.tokens[^1].line else: 1, column: if p.tokens.len > 0: p.tokens[^1].column else: 1)

proc peek*(p: Parser, offset = 1): Token =
  let idx = p.cursor + offset
  if idx < p.tokens.len:
    p.tokens[idx]
  else:
    Token(kind: tkEOF, value: "", line: if p.tokens.len > 0: p.tokens[^1].line else: 1, column: if p.tokens.len > 0: p.tokens[^1].column else: 1)

proc advance*(p: var Parser): Token =
  result = p.current()
  if p.cursor < p.tokens.len:
    p.cursor += 1

proc getLineContext(source: string, targetLine: int): string =
  var lineNum = 1
  var currentLine = ""
  for ch in source:
    if ch == '\n':
      if lineNum == targetLine:
        return currentLine
      currentLine = ""
      lineNum += 1
    else:
      currentLine.add(ch)
  if lineNum == targetLine:
    return currentLine
  return ""

proc reportError*(p: Parser, msg: string, line = -1, col = -1) =
  let targetLine = if line == -1: p.current().line else: line
  let targetCol = if col == -1: p.current().column else: col
  let ctxLine = getLineContext(p.source, targetLine)
  stderr.writeLine "\n[Parse Error] at line " & $targetLine & ", column " & $targetCol & ":"
  stderr.writeLine "  " & msg
  if ctxLine.len > 0:
    stderr.writeLine ""
    stderr.writeLine "    " & ctxLine
    stderr.writeLine "    " & repeat(' ', targetCol - 1) & "^"
  stderr.writeLine ""
  quit(1)

proc expect*(p: var Parser, kind: TokenKind, msg = ""): Token =
  if p.current().kind != kind:
    let errMsg = if msg.len > 0: msg else: "Expected token '" & $kind & "' but got '" & $p.current().kind & "' with value '" & p.current().value & "'"
    p.reportError(errMsg)
  result = p.advance()

proc getSpan*(p: Parser): Span =
  Span(line: p.current().line, col: p.current().column, file: "")
