# compiler/parser_base.nim
#
# The parser's shared foundation: the `Parser` state (source + token stream +
# cursor) and the token-stream accessors every parsing bucket needs. The
# expression, type, and declaration parsers each import this; it holds no
# grammar of its own.
import ../lexer
import ast
import diagnostics
import host_keywords
import codegen_common
export diagnostics   # every reportError caller needs the codes

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

proc reportError*(p: Parser, msg: string, line = -1, col = -1,
                  dc = dcNone) =
  ## Reject the source. Raises rather than printing and quitting, so a caller
  ## can tell a rejection from a crash; `tuck.nim` catches this and prints.
  ## Defaults to the current token's position when none is given.
  ##
  ## `dc` is the lookup code (diagnostics.nim). It rides in `err.code` rather
  ## than being pasted into the message, so the driver decides how to show it.
  var err = newException(SyntaxError, msg)
  err.line = if line == -1: p.current().line else: line
  err.col = if col == -1: p.current().column else: col
  err.context = getLineContext(p.source, err.line)
  err.stage = "Parse Error"
  err.code = code(dc)
  raise err

proc expect*(p: var Parser, kind: TokenKind, msg = ""): Token =
  if p.current().kind != kind:
    let errMsg = if msg.len > 0: msg
                 else: "Expected " & describe(kind) & " here, found " &
                       describe(p.current())
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
  ##
  ## A KEYWORD is different: `pending` and `when` open real constructs, so
  ## they stay reserved even here. The author still deserves to be told which
  ## word collided — "expected a field name" while pointing at one reads as a
  ## parser fault rather than a naming one.
  if p.current().kind in {tkIdent, tkAttr}:
    return p.advance()
  let t = p.current()
  if t.value.len > 0 and t.value[0] in {'a'..'z'} and
     t.kind notin {tkIndent, tkDedent, tkNewline, tkEOF}:
    p.reportError(msg & " — `" & t.value & "` is a reserved word and cannot " &
                  "be used as a name here", dc = dcPaReservedWord)
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

proc skipSeparators*(p: var Parser) =
  ## Inside a bracketed list, a line break separates exactly as a comma does,
  ## so the last comma on a line is optional and the closing bracket may sit
  ## on a line of its own:
  ##
  ##     let r = {url: "...", verb: "GET"
  ##              timeoutMs: 30
  ##              retries: 4} describe
  ##
  ## The lexer leaves indentation alone inside brackets (Lexer.bracketDepth)
  ## but still emits the newline, because THIS is what it is for.
  while p.current().kind == tkNewline: discard p.advance()

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
  ##
  ## A comment-only first line lexes as a bare newline (the comment itself is
  ## dropped), so the leading skip is what lets any block open with a comment
  ## — fn bodies grew their own copy of it, and every other construct went
  ## without until a `transitions:` block that opened with one was rejected.
  while p.current().kind == tkNewline: discard p.advance()
  discard p.expect(tkIndent)
  while p.current().kind notin {tkDedent, tkEOF}:
    if p.current().kind == tkNewline:
      discard p.advance()
    else:
      body
  discard p.expect(tkDedent)

var parseTypeHook*: proc(p: var Parser): Type {.nimcall.} = nil
  ## parser_type's `parseType`, reachable from the EXPRESSION layer.
  ##
  ## The parser is a DAG on purpose — parser_expr sits at the bottom and calls
  ## neither parseType nor parseDecl — and `let x: T = v` is the one place the
  ## grammar genuinely crosses back: a type appears inside an expression-level
  ## binding. A direct call would make the two modules mutually recursive and
  ## cost the layering everywhere else; one indirection here does not.
  ##
  ## parser_type installs it at module init. Nil means the type layer was
  ## never imported, which only a unit test of the expression layer alone can
  ## produce — the binding then behaves as it did before annotations existed.

proc failIfHostKeyword*(p: Parser, name: string, sp: Span,
                        what = "parameter") =
  ## A parameter and a FIELD both keep the name the author wrote — mangle.nim
  ## prefixes every other user name but leaves these alone — so a word some
  ## backend reserves reaches its compiler verbatim and breaks there. Refused
  ## here rather than renamed, so the emitted code keeps saying what the
  ## source says. See compiler/host_keywords.nim for why the list is measured
  ## rather than copied.
  ##
  ## Fields were the unguarded half: `type T:\n  out: str` emitted
  ## `out*: string` and nim answered "identifier expected, but found
  ## \'keyword out\'"; D broke on the same shape. Guarding only params was
  ## also inconsistent in a way a user would feel, since a payload field binds
  ## to a parameter BY NAME — a field the author cannot pass to a parameter
  ## they are not allowed to declare.
  # `tuckTag` is codegen's own: an actor envelope and a registry event type
  # carry it as their discriminator, beside the user's payload fields. Moving
  # OUR name off `kind` fixed the collision an ordinary field name caused;
  # refusing this one keeps it fixed instead of relocating the hole.
  if name == TagField:
    p.reportError("'" & name & "' is the name Tuck's own generated code uses " &
                  "for an actor's and a registry's message tag, so it cannot " &
                  "also be a " & what & " name. Fix: choose another name",
                  sp.line, sp.col, dcPaHostKeyword)
  if isHostKeyword(name):
    p.reportError("\'" & name & "\' is a keyword in one of Tuck\'s backends, so " &
                  "it cannot be a " & what & " name — the emitted code would " &
                  "carry it through verbatim. Fix: choose another name",
                  sp.line, sp.col, dcPaHostKeyword)
