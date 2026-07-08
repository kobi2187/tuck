# lexer.nim
import os, strutils, tables

type
  TokenKind* = enum
    tkError,
    tkEOF,
    tkNewline,
    tkIndent,
    tkDedent,
    tkIntLit,
    tkFloatLit,
    tkStrLit,
    tkIdent,

    # Operators and Punctuations
    tkDot,        # .
    tkDotDot,     # ..
    tkColon,      # :
    tkColonColon, # ::
    tkComma,      # ,
    tkArrow,      # ->
    tkFatArrow,   # =>
    tkPipe,       # |
    tkQuestion,   # ?
    tkBang,       # !
    tkBangQuestion,# !?
    tkAssign,     # =
    tkPlus, tkMinus, tkStar, tkSlash, tkPercent,
    tkEq, tkNeq, tkLt, tkGt, tkLte, tkGte,

    # Grouping
    tkLParen, tkRParen,
    tkLBrace, tkRBrace,
    tkLBracket, tkRBracket,

    # Keywords
    tkFn, tkLet, tkVar, tkIf, tkElif, tkElse,
    tkFor, tkIn, tkMatch, tkReturn, tkType,
    tkObject, tkMixin, tkInterface, tkActor, tkTask,
    tkPending, tkOn, tkSelect, tkRegistry,
    tkDecision, tkPool, tkArena, tkRegister,
    tkWhen, tkDistinct, tkBake, tkImport,
    tkAnd, tkOr, tkNot, tkTrue, tkFalse, tkNone,
    tkStaticAssert,

    tkSymbol, # legacy fallback
    tkPlusAssign, tkMinusAssign, tkStarAssign, tkSlashAssign

  Token* = object
    kind*: TokenKind
    value*: string
    line*: int
    column*: int

  Lexer* = object
    source*: string
    position*: int
    line*: int
    column*: int
    linesLen*: seq[int] # legacy fallback
    indentStack*: seq[int]
    pendingTokens*: seq[Token]

const keywords = {
  "fn": tkFn, "let": tkLet, "var": tkVar,
  "if": tkIf, "elif": tkElif, "else": tkElse,
  "for": tkFor, "in": tkIn, "match": tkMatch,
  "return": tkReturn, "type": tkType,
  "object": tkObject, "mixin": tkMixin, "interface": tkInterface,
  "actor": tkActor, "task": tkTask,
  "on": tkOn, "select": tkSelect,
  "registry": tkRegistry, "decision": tkDecision,
  "pending": tkPending, "when": tkWhen,
  "distinct": tkDistinct, "bake": tkBake, "import": tkImport,
  "and": tkAnd, "or": tkOr, "not": tkNot,
  "true": tkTrue, "false": tkFalse, "none": tkNone,
  "static_assert": tkStaticAssert
}.toTable()

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

proc reportError*(L: Lexer, message: string, line: int, col: int) =
  let ctxLine = getLineContext(L.source, line)
  stderr.writeLine "\n[Lexical Error] at line " & $line & ", column " & $col & ":"
  stderr.writeLine "  " & message
  if ctxLine.len > 0:
    stderr.writeLine ""
    stderr.writeLine "    " & ctxLine
    stderr.writeLine "    " & repeat(' ', col - 1) & "^"
  stderr.writeLine ""
  quit(1)

proc peek*(L: Lexer, offset = 0): char =
  if L.position + offset < L.source.len:
    L.source[L.position + offset]
  else:
    '\0'

proc advance*(L: var Lexer) =
  if L.position < L.source.len:
    if L.source[L.position] == '\n':
      L.line += 1
      L.column = 1
    else:
      L.column += 1
    L.position += 1

proc handleIndent*(L: var Lexer) =
  if L.indentStack.len == 0:
    L.indentStack.add(0)

  var spaces = 0
  while L.peek() == ' ':
    spaces += 1
    L.advance()

  if L.peek() == '\t':
    L.reportError("Tabs are not allowed. Use spaces.", L.line, L.column)

  if L.peek() == '\n' or L.peek() == '#' or L.peek() == '\0':
    return

  let currentIndent = L.indentStack[^1]
  if spaces > currentIndent:
    L.indentStack.add(spaces)
    L.pendingTokens.add(Token(kind: tkIndent, value: "", line: L.line, column: L.column))
  elif spaces < currentIndent:
    while L.indentStack.len > 0 and L.indentStack[^1] > spaces:
      discard L.indentStack.pop()
      L.pendingTokens.add(Token(kind: tkDedent, value: "", line: L.line, column: L.column))
    let activeIndent = if L.indentStack.len > 0: L.indentStack[^1] else: 0
    if activeIndent != spaces:
      L.reportError("Inconsistent indentation level. Expected matching indentation.", L.line, L.column)

proc handleEOF*(L: var Lexer) =
  while L.indentStack.len > 1:
    discard L.indentStack.pop()
    L.pendingTokens.add(Token(kind: tkDedent, value: "", line: L.line, column: L.column))
  L.pendingTokens.add(Token(kind: tkEOF, value: "", line: L.line, column: L.column))

proc lexString*(L: var Lexer) =
  let startLine = L.line
  let startCol = L.column
  L.advance() # eat opening '"'
  var val = ""
  while L.peek() != '"' and L.peek() != '\0':
    val.add(L.peek())
    L.advance()
  if L.peek() == '"':
    L.advance() # eat closing '"'
    L.pendingTokens.add(Token(kind: tkStrLit, value: val, line: startLine, column: startCol))
  else:
    L.reportError("Unterminated string literal.", startLine, startCol)

proc lexNumber*(L: var Lexer) =
  let startLine = L.line
  let startCol = L.column
  var val = ""
  if L.peek() == '0' and (L.peek(1) == 'x' or L.peek(1) == 'X'):
    val.add("0x")
    L.advance()
    L.advance()
    while L.peek() in '0'..'9' or L.peek() in 'a'..'f' or L.peek() in 'A'..'F':
      val.add(L.peek())
      L.advance()
    L.pendingTokens.add(Token(kind: tkIntLit, value: val, line: startLine, column: startCol))
    return
  while L.peek() in '0'..'9':
    val.add(L.peek())
    L.advance()
  if L.peek() == '.' and L.peek(1) in '0'..'9':
    val.add('.')
    L.advance()
    while L.peek() in '0'..'9':
      val.add(L.peek())
      L.advance()
    if L.peek() == '.':
      L.reportError("Broken numeric literal: multiple decimal points.", startLine, startCol)
    L.pendingTokens.add(Token(kind: tkFloatLit, value: val, line: startLine, column: startCol))
  else:
    L.pendingTokens.add(Token(kind: tkIntLit, value: val, line: startLine, column: startCol))

proc lexIdent*(L: var Lexer) =
  let startLine = L.line
  let startCol = L.column
  var val = ""
  while L.peek() in 'a'..'z' or L.peek() in 'A'..'Z' or L.peek() in '0'..'9' or L.peek() == '_':
    val.add(L.peek())
    L.advance()
  let kind = keywords.getOrDefault(val, tkIdent)
  L.pendingTokens.add(Token(kind: kind, value: val, line: startLine, column: startCol))

proc tryTwoChar*(L: var Lexer, match: string, kind: TokenKind): bool =
  if L.peek() == match[0] and L.peek(1) == match[1]:
    let startLine = L.line
    let startCol = L.column
    L.advance()
    L.advance()
    L.pendingTokens.add(Token(kind: kind, value: match, line: startLine, column: startCol))
    return true
  return false

proc emitOneChar*(L: var Lexer, kind: TokenKind, val: string) =
  L.pendingTokens.add(Token(kind: kind, value: val, line: L.line, column: L.column))
  L.advance()

proc skipComment*(L: var Lexer) =
  while L.peek() != '\n' and L.peek() != '\0':
    L.advance()

proc skipSpaces*(L: var Lexer) =
  while L.peek() == ' ' or L.peek() == '\t':
    if L.peek() == '\t':
      L.reportError("Tabs are not allowed. Use spaces.", L.line, L.column)
    L.advance()

proc scanNext*(L: var Lexer) =
  if L.column == 1:
    L.handleIndent()
    if L.pendingTokens.len > 0:
      return

  let ch = L.peek()
  case ch
  of '\0':
    L.handleEOF()
  of ' ':
    L.skipSpaces()
  of '#':
    L.skipComment()
  of '\n':
    if L.pendingTokens.len > 0 or L.position > 0:
      L.pendingTokens.add(Token(kind: tkNewline, value: "\n", line: L.line, column: L.column))
    L.advance()
  of '"':
    L.lexString()
  of '0'..'9':
    L.lexNumber()
  of 'a'..'z', 'A'..'Z', '_':
    L.lexIdent()
  else:
    if L.tryTwoChar("..", tkDotDot): return
    if L.tryTwoChar("->", tkArrow): return
    if L.tryTwoChar("=>", tkFatArrow): return
    if L.tryTwoChar("::", tkColonColon): return
    if L.tryTwoChar("!?", tkBangQuestion): return
    if L.tryTwoChar("==", tkEq): return
    if L.tryTwoChar("!=", tkNeq): return
    if L.tryTwoChar("<=", tkLte): return
    if L.tryTwoChar(">=", tkGte): return
    if L.tryTwoChar("+=", tkPlusAssign): return
    if L.tryTwoChar("-=", tkMinusAssign): return
    if L.tryTwoChar("*=", tkStarAssign): return
    if L.tryTwoChar("/=", tkSlashAssign): return

    case ch
    of '.': L.emitOneChar(tkDot, ".")
    of ':': L.emitOneChar(tkColon, ":")
    of ',': L.emitOneChar(tkComma, ",")
    of '|': L.emitOneChar(tkPipe, "|")
    of '?': L.emitOneChar(tkQuestion, "?")
    of '!': L.emitOneChar(tkBang, "!")
    of '=': L.emitOneChar(tkAssign, "=")
    of '+': L.emitOneChar(tkPlus, "+")
    of '-': L.emitOneChar(tkMinus, "-")
    of '*': L.emitOneChar(tkStar, "*")
    of '/': L.emitOneChar(tkSlash, "/")
    of '%': L.emitOneChar(tkPercent, "%")
    of '<': L.emitOneChar(tkLt, "<")
    of '>': L.emitOneChar(tkGt, ">")
    of '(': L.emitOneChar(tkLParen, "(")
    of ')': L.emitOneChar(tkRParen, ")")
    of '{': L.emitOneChar(tkLBrace, "{")
    of '}': L.emitOneChar(tkRBrace, "}")
    of '[': L.emitOneChar(tkLBracket, "[")
    of ']': L.emitOneChar(tkRBracket, "]")
    else:
      L.reportError("Unexpected character: " & ch, L.line, L.column)

proc nextToken*(L: var Lexer): Token =
  while L.pendingTokens.len == 0:
    let oldPos = L.position
    L.scanNext()
    if L.position == oldPos and L.pendingTokens.len == 0:
      break

  if L.pendingTokens.len > 0:
    result = L.pendingTokens[0]
    L.pendingTokens.delete(0)
  else:
    result = Token(kind: tkEOF, value: "", line: L.line, column: L.column)

proc main() =
  let cmdArgs = commandLineParams()
  if cmdArgs.len > 0:
    let source = readFile(cmdArgs[0])
    var lexer = Lexer(source: source, position: 0, line: 1, column: 1, indentStack: @[0])
    while true:
      let token = lexer.nextToken()
      echo token
      if token.kind == tkEOF:
        break

when isMainModule:
  main()