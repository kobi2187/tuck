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

proc expectAttrName*(p: var Parser, msg: string): Token =
  ## An attribute name. Either a reserved BARE marker (tkAttr — `sealed`,
  ## `io`) or an ordinary identifier used as a valued attribute's parameter
  ## name (`count` in `[count: 4]`). Only the bare markers are reserved,
  ## because only they collide with a type argument's shape.
  if p.current().kind in {tkIdent, tkAttr}:
    return p.advance()
  p.reportError(msg)

proc expectTypeName*(p: var Parser, what: string): Token =
  ## A user-declared type name — type, object, interface, actor, distinct,
  ## fnsig, registry, pool, arena — must be Capitalized.
  ##
  ## This is what makes `Box[error]` decidable. `Box[T]` and `u16 [saturating]`
  ## are the same shape, a bracket after a type name, so the parser needed a
  ## word list to tell an attribute from a type argument. The attribute set is
  ## CLOSED, so that list was never incomplete — it was AMBIGUOUS, because
  ## `error`, `sealed` and `stack` are all good type-parameter names too. Case
  ## resolves what no list can. Primitives (u8, int, str, …) stay lowercase and
  ## are a closed set of their own.
  ##
  ## Enforced at declaration rather than at use, so the error lands where the
  ## name is chosen. The corpus already followed this everywhere — zero
  ## lowercase user type names across examples and std — so this codifies
  ## existing practice rather than changing it.
  let tok = p.expect(tkIdent, "Expected " & what & " name")
  if tok.value.len > 0 and tok.value[0] notin {'A'..'Z'}:
    p.reportError("a " & what & " name must be Capitalized — `" & tok.value &
                  "` starts lowercase. Lowercase names are reserved for " &
                  "primitives (u8, int, str, …) and attributes ([sealed], " &
                  "[io], …), which is what lets `Box[T]` be told apart from " &
                  "`u16 [saturating]`.", tok.line, tok.column)
  tok

proc getSpan*(p: Parser): Span =
  Span(line: p.current().line, col: p.current().column, file: "")
