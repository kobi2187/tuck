# lexer.nim
#
# STAGE 1 OF THE PIPELINE — text becomes tokens.
#
# Source code arrives as one long string. `fn main() -> void:` is 19
# characters; nothing in it says "this part is a keyword" or "this part is a
# name". The lexer chops the string into TOKENS, the words of the language, so
# that every later stage can stop worrying about characters:
#
#   fn main() -> void:
#     -> tkFn, tkIdent("main"), tkLParen, tkRParen, tkArrow,
#        tkIdent("void"), tkColon
#
# Why this is its own stage: without it, the parser would re-answer the same
# boring questions everywhere — is this whitespace, is this a comment, does
# this number have a decimal point, is `!=` one token or two. Answer them once
# here, and everything downstream deals in tokens.
#
# INDENTATION. Tuck uses indentation for blocks, like Python. The lexer tracks
# the indent level and emits tkIndent / tkDedent tokens when it changes. That
# turns "block structure" into ordinary tokens, so the parser can treat an
# indented block exactly like anything else with an opener and a closer. It is
# the standard trick for offside-rule languages, and it is why the parser never
# has to count spaces.
#
# What this stage does NOT do: it has no idea whether a program makes sense.
# `fn fn fn` lexes perfectly happily into three tkFn tokens. Deciding that this
# is nonsense is the parser's job (bad structure) and the typechecker's job
# (bad meaning). A lexer only knows how to spell, never what things mean.
#
# Depends on nothing in compiler/ — it sits at the very bottom of the DAG.
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
    tkDotDot,     # ..  (tight — chain mutator)
    tkRange,      # spaced ` .. ` — inclusive range
    tkRangeLt,    # ..< — exclusive range
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
    tkPlus, tkMinus, tkStar, tkPercent,
    tkSlash,                      # bare `/` — rejected; see tkSlashInt
    tkSlashInt, tkSlashFloat,     # /i /f — divide names its arithmetic (R1)
    tkEq, tkNeq, tkLt, tkGt, tkLte, tkGte,

    # Grouping
    tkLParen, tkRParen,
    tkLBrace, tkRBrace,
    tkLBracket, tkRBracket,

    # Keywords
    tkFn, tkLet, tkVar, tkConst, tkIf, tkElif, tkElse,
    tkFor, tkIn, tkMatch, tkReturn, tkType,
    tkLoop, tkBreak, tkContinue,
    tkObject, tkMixin, tkInterface, tkActor, tkTask, tkFnsig,
    tkPending, tkOn, tkSelect, tkRegistry,
    tkDecision, tkPool, tkArena, tkRegister,
    tkWhen, tkDistinct, tkBake, tkImport,
    tkAnd, tkOr, tkNot, tkTrue, tkFalse, tkNone,
    tkStaticAssert,
    tkAttr,   # an ATTRIBUTE name — sealed, io, error, stack, … (see keywords)

    tkSymbol, # legacy fallback
    tkPlusAssign, tkMinusAssign, tkStarAssign, tkSlashAssign,
    tkSlashIntAssign, tkSlashFloatAssign    # /i= /f=

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
  "fn": tkFn, "let": tkLet, "var": tkVar, "const": tkConst,
  "if": tkIf, "elif": tkElif, "else": tkElse,
  "for": tkFor, "in": tkIn, "match": tkMatch,
  "loop": tkLoop, "break": tkBreak, "continue": tkContinue,
  "return": tkReturn, "type": tkType,
  "object": tkObject, "mixin": tkMixin, "interface": tkInterface,
  "actor": tkActor, "task": tkTask, "fnsig": tkFnsig,
  "on": tkOn, "select": tkSelect,
  "registry": tkRegistry, "decision": tkDecision,
  "pending": tkPending, "when": tkWhen,
  "distinct": tkDistinct, "bake": tkBake, "import": tkImport,
  "and": tkAnd, "or": tkOr, "not": tkNot,
  "true": tkTrue, "false": tkFalse, "none": tkNone,
  "static_assert": tkStaticAssert,

  # ATTRIBUTE NAMES — reserved globally, exactly like the keywords above.
  # They all share one token kind because the parser never needs to tell them
  # apart lexically; parseTypeUseAttrs reads the name off the token's value.
  #
  # Reserved rather than context-sensitive so `Box[error]` is decidable
  # without a word list in the parser: a reserved word is never a user
  # identifier, so a bracket entry that lexes as tkAttr IS an attribute and
  # one that lexes as tkIdent IS a type argument. The old parser-side list
  # could not do this, because `error` lexed as an ordinary identifier and
  # `Box[error]` and `u16 [error: E]` were the same shape.
  # BARE MARKERS ONLY. These stand alone in a bracket — `[sealed]`, `[io]` —
  # which is precisely the shape that collides with a type argument `[T]`.
  #
  # NOT here: attribute PARAMETER names (count, size, queue, policy, read,
  # write, emit, impl, header, lib, c, nim, odin, at, bit, bits). Those always
  # appear as `name: value`, so `[count: 4]` is identifiable by shape and
  # needs no reservation — and they are ordinary field names besides
  # (`{c: Counter}`, `count: int`).
  # NOT `invariant` either — that is a BLOCK keyword in a type body
  # (`invariant:` then indented predicates), never a bracket marker.
  "saturating": tkAttr, "wrapping": tkAttr, "trapping": tkAttr,
  "sealed": tkAttr, "packed": tkAttr, "volatile": tkAttr,
  "big_endian": tkAttr, "little_endian": tkAttr,
  "io": tkAttr, "unsafe": tkAttr, "may_block": tkAttr, "no_alloc": tkAttr,
  "irq_safe": tkAttr
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
  let startPos = L.position
  while L.peek() != '"' and L.peek() != '\0':
    L.advance()
  if L.peek() == '"':
    let val = L.source[startPos ..< L.position]   # one slice, not N appends
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
  # An identifier is a contiguous run of the source, so take it as one slice.
  # Appending char by char regrows the string as it goes, and this is the
  # hottest allocator in the front end (~9,600 calls for a 400-fn file).
  let startPos = L.position
  while L.peek() in 'a'..'z' or L.peek() in 'A'..'Z' or L.peek() in '0'..'9' or L.peek() == '_':
    L.advance()
  let val = L.source[startPos ..< L.position]
  let kind = keywords.getOrDefault(val, tkIdent)
  L.pendingTokens.add(Token(kind: kind, value: val, line: startLine, column: startCol))

proc tryTwoChar*(L: var Lexer, match: string, kind: TokenKind): bool =
  ## Any fixed-length operator, longest-match-first at the call site. (Named
  ## for the two-char case it started with; `/i=` and `/f=` are three.)
  for i, c in match:
    if L.peek(i) != c: return false
  let startLine = L.line
  let startCol = L.column
  for _ in match: L.advance()
  L.pendingTokens.add(Token(kind: kind, value: match, line: startLine, column: startCol))
  return true

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
    if L.peek() == '.' and L.peek(1) == '.':
      let sl = L.line
      let sc = L.column
      if L.peek(2) == '<':
        L.advance(); L.advance(); L.advance()
        L.pendingTokens.add(Token(kind: tkRangeLt, value: "..<", line: sl, column: sc))
        return
      # spaced ` .. ` = range; tight `..ident` = chain mutator
      let spacedBefore = L.position > 0 and L.source[L.position - 1] == ' '
      let spacedAfter = L.peek(2) == ' '
      let kind = if spacedBefore and spacedAfter: tkRange else: tkDotDot
      L.advance(); L.advance()
      L.pendingTokens.add(Token(kind: kind, value: "..", line: sl, column: sc))
      return
    # Switch on the first character before trying anything: every multi-char
    # operator is uniquely determined by it, so a `/` never has to be tested
    # against "->", "==" and ten others first. Longest match still wins WITHIN
    # a branch, which is the only place it matters (`/i=` before `/i`).
    case ch
    of '-':
      if L.tryTwoChar("->", tkArrow): return
      if L.tryTwoChar("-=", tkMinusAssign): return
    of '=':
      if L.tryTwoChar("=>", tkFatArrow): return
      if L.tryTwoChar("==", tkEq): return
    of ':':
      if L.tryTwoChar("::", tkColonColon): return
    of '?':
      if L.tryTwoChar("?!", tkBangQuestion): return  # T?! == T!? — same wrapper
    of '!':
      if L.tryTwoChar("!?", tkBangQuestion): return
      if L.tryTwoChar("!=", tkNeq): return
    of '<':
      if L.tryTwoChar("<=", tkLte): return
    of '>':
      if L.tryTwoChar(">=", tkGte): return
    of '+':
      if L.tryTwoChar("+=", tkPlusAssign): return
    of '*':
      if L.tryTwoChar("*=", tkStarAssign): return
    of '/':
      # Division names its arithmetic (ruling R1, 2026-07-28): `/i` is integer
      # divide, `/f` is float divide, and a bare `/` does not exist. On embedded
      # a silently-wrong quotient is worse than a character of typing. Longest
      # match first — `/i=` must be tried before `/i`.
      if L.tryTwoChar("/i=", tkSlashIntAssign): return
      if L.tryTwoChar("/f=", tkSlashFloatAssign): return
      if L.tryTwoChar("/i", tkSlashInt): return
      if L.tryTwoChar("/f", tkSlashFloat): return
    else: discard

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
    # bare `/` is deliberately not a token — see the R1 note above. It reaches
    # the parser as tkSlash only to produce a message naming the replacement.
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