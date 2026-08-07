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
  ## Reject the source. Raises rather than printing and quitting, so a caller
  ## can tell a rejection from a crash; `tuck.nim` catches this and prints.
  ## Defaults to the current token's position when none is given.
  var err = newException(SyntaxError, msg)
  err.line = if line == -1: p.current().line else: line
  err.col = if col == -1: p.current().column else: col
  err.context = getLineContext(p.source, err.line)
  err.stage = "Parse Error"
  raise err

proc expect*(p: var Parser, kind: TokenKind, msg = ""): Token =
  if p.current().kind != kind:
    let errMsg = if msg.len > 0: msg else: "Expected token '" & $kind & "' but got '" & $p.current().kind & "' with value '" & p.current().value & "'"
    p.reportError(errMsg)
  result = p.advance()

proc expectAttrName*(p: var Parser, msg: string): Token =
  ## An attribute name — a reserved marker (tkAttr) or an ordinary identifier
  ## used as a valued attribute's parameter name (`count` in `[count: 4]`).
  if p.current().kind in {tkIdent, tkAttr}:
    return p.advance()
  p.reportError(msg)

proc expectMemberName*(p: var Parser, msg: string): Token =
  ## A name in a position where ONLY a name can appear — a parameter, field,
  ## variant, module or member. Accepts tkAttr as well as tkIdent.
  ##
  ## Attribute names are reserved so `Box[error]` cannot be a type argument.
  ## But `{priority: Priority}` is a FIELD, and `import console` a MODULE —
  ## positions where no attribute could ever appear, so the reserved word is
  ## just a name and the parser says so. The lexer cannot make that call; the
  ## parser knows what it is looking for.
  ##
  ## This is what lets reservation be total without stealing ordinary words
  ## from the user. Type names are Capitalized, so a lowercase field named
  ## `priority` never collides with the type `Priority` either.
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

template indentedBlock*(p: var Parser, body: untyped) =
  ## Walk an indented block: enter it, run `body` once per non-blank line,
  ## and leave it. Blank lines inside a block are skipped here so no caller
  ## repeats the check.
  ##
  ## A TEMPLATE rather than a proc because `body` is arbitrary parsing code
  ## that reads and writes the caller's own locals — passing it as a closure
  ## would buy nothing and cost the capture. Every indented construct in the
  ## grammar (object bodies, sig blocks, decision tables, registry variants,
  ## register fields, mixins, arenas) opens with exactly this scaffolding, and
  ## each used to spell it out.
  discard p.expect(tkIndent)
  while p.current().kind notin {tkDedent, tkEOF}:
    if p.current().kind == tkNewline:
      discard p.advance()
    else:
      body
  discard p.expect(tkDedent)
