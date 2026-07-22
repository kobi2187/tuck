# compiler/parser.nim
import strutils, tables
import ast
import ../lexer

proc toString*(e: Expr): string =
  if e == nil: return ""
  case e.kind
  of exkLit: return e.litValue
  of exkVar: return e.name
  of exkField: return e.receiver.toString() & "." & e.fieldName
  of exkQualified:
    var res = ""
    for p in e.modulePath:
      res.add(p & "::")
    res.add(e.qualName)
    return res
  of exkStruct:
    var res = "{"
    for i, f in e.fields:
      if i > 0: res.add(", ")
      res.add(f[0] & ": " & f[1].toString())
    res.add("}")
    return res
  of exkBracket:
    var parts: seq[string]
    for a in e.brArgs: parts.add(a.toString())
    return e.brReceiver.toString() & "[" & parts.join(", ") & "]"
  of exkBracketAssign:
    return e.brTarget.toString() & " = " & e.brValue.toString()
  of exkList:
    var res = "["
    for i, item in e.items:
      if i > 0: res.add(", ")
      res.add(item.toString())
    res.add("]")
    return res
  of exkCall:
    var res = e.callee.toString()
    if e.args.len > 0:
      res.add("(")
      for i, arg in e.args:
        if i > 0: res.add(", ")
        res.add(arg.toString())
      res.add(")")
    return res
  of exkChain:
    var res = e.base.toString()
    for step in e.steps:
      res.add(" .." & step.target.toString())
      if step.arg != nil:
        res.add(" " & step.arg.toString())
    return res
  of exkBinary:
    let opStr = case e.binOp
                of boAdd: "+"
                of boSub: "-"
                of boMul: "*"
                of boDiv: "/"
                of boMod: "%"
                of boEq: "=="
                of boNeq: "!="
                of boLt: "<"
                of boGt: ">"
                of boLe: "<="
                of boGe: ">="
                of boAnd: "and"
                of boOr: "or"
                of boXor: "xor"
                of boRangeIncl: ".."
                of boRangeExcl: "..<"
    return e.left.toString() & " " & opStr & " " & e.right.toString()
  of exkUnary:
    let opStr = case e.unaryOp
                of uoNeg: "-"
                of uoNot: "not "
                of uoComposition: "+ "
                of uoPropagate: ""
    if e.unaryOp == uoPropagate:
      return e.operand.toString() & "?"
    return opStr & e.operand.toString()
  of exkBlock:
    return "block"
  of exkIf:
    return "if"
  of exkMatch:
    return "match"
  of exkFor:
    return "for"
  of exkWhile:
    return if e.whileCond == nil: "loop" else: "for " & e.whileCond.toString()
  of exkBreak:
    return "break"
  of exkContinue:
    return "continue"
  of exkAssign:
    return e.target.toString() & " = " & e.assignVal.toString()
  of exkReturn:
    let rVal = if e.returnVal != nil: e.returnVal.toString() else: ""
    return "return " & rVal
  of exkRaise:
    let rVal = if e.raiseVal != nil: e.raiseVal.toString() else: ""
    return "raise " & rVal
  of exkImport:
    return "import"

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

proc getSpan(p: Parser): Span =
  Span(line: p.current().line, col: p.current().column, file: "")

# Forward declarations
proc parseType*(p: var Parser): Type
proc parseExpr*(p: var Parser): Expr
proc parsePattern*(p: var Parser): Pattern
proc parseDecl*(p: var Parser): Decl
proc parseBlock*(p: var Parser): Expr

# [packed, align: 2, ...] — attribute bracket on a declaration (appends,
# since some callers pre-seed attrs)
proc parseDeclAttrs(p: var Parser, attrs: var seq[TypeAttr]) =
  if p.current().kind != tkLBracket: return
  discard p.advance()
  while p.current().kind != tkRBracket and p.current().kind != tkEOF:
    let attrSp = p.getSpan()
    let attrName = p.expect(tkIdent, "Expected attribute name").value
    if attrName == "invariant":
      p.reportError("invariant is a block inside the type body, not an attribute: `invariant:` then one indented predicate per line", attrSp.line, attrSp.col)
    var val = ""
    if p.current().kind == tkColon:
      discard p.advance()
      val = p.parseExpr().toString()
    attrs.add(TypeAttr(name: attrName, value: val, span: attrSp))
    if p.current().kind == tkComma:
      discard p.advance()
  discard p.expect(tkRBracket)

# invariant: block — one predicate per line, stored as dkExpr members
# (spec 4.7; the only form — inline/attr invariants are parse errors)
proc parseInvariantBlock(p: var Parser, members: var seq[Decl]) =
  let fSp = p.getSpan()
  discard p.advance() # eat "invariant"
  discard p.expect(tkColon)
  if p.current().kind == tkNewline:
    discard p.advance()
    while p.current().kind == tkNewline:
      discard p.advance()
    discard p.expect(tkIndent)
    while p.current().kind != tkDedent and p.current().kind != tkEOF:
      if p.current().kind == tkNewline:
        discard p.advance()
        continue
      let eSp = p.getSpan()
      members.add(Decl(span: eSp, kind: dkExpr, expr: p.parseExpr()))
      if p.current().kind == tkNewline:
        discard p.advance()
    discard p.expect(tkDedent)
  else:
    p.reportError("invariant is a block: `invariant:` then one indented predicate per line", fSp.line, fSp.col)
  if p.current().kind == tkNewline:
    discard p.advance()

# u16 [big_endian] / -> T [io] / !T [error: FsError] — attributes in TYPE-USE
# position (already inside the bracket; caller ate "[")
proc parseTypeUseAttrs(p: var Parser): seq[TypeAttr] =
  while p.current().kind != tkRBracket and p.current().kind != tkEOF:
    let attrSp = p.getSpan()
    let attrName = p.expect(tkIdent, "Expected attribute name").value
    if attrName == "error":
      # [error: FsError | NetError] — one attr per listed enum
      discard p.expect(tkColon)
      result.add(TypeAttr(name: "error",
        value: p.expect(tkIdent, "Expected error enum name").value, span: attrSp))
      while p.current().kind == tkPipe:
        discard p.advance()
        result.add(TypeAttr(name: "error",
          value: p.expect(tkIdent, "Expected error enum name after '|'").value, span: attrSp))
      if p.current().kind == tkComma:
        discard p.advance()
      continue
    var val = ""
    if p.current().kind == tkColon:
      discard p.advance()
      val = p.parseExpr().toString()
    result.add(TypeAttr(name: attrName, value: val, span: attrSp))
    if p.current().kind == tkComma:
      discard p.advance()
  discard p.expect(tkRBracket)

# (T, U) -> R fn types, (T) grouping, (A, B) tuples
proc parseParenType(p: var Parser, sp: Span): Type =
  discard p.advance()
  var types: seq[Type]
  while p.current().kind != tkRParen and p.current().kind != tkEOF:
    types.add(p.parseType())
    if p.current().kind == tkComma:
      discard p.advance()
  discard p.expect(tkRParen)
  if p.current().kind == tkArrow:
    discard p.advance()
    let retType = p.parseType()
    return Type(span: sp, kind: tkFunc, params: types, result: retType)
  elif types.len == 1:
    return types[0]
  else:
    return Type(span: sp, kind: tkTuple, elems: types)

# {A, B} inline enum or {a: T, b: U} inline record
proc parseBraceType(p: var Parser, sp: Span): Type =
  let isEnum = p.peek(2).kind in {tkComma, tkRBrace}
  discard p.advance()
  if isEnum:
    var variants: seq[VariantDef]
    while p.current().kind != tkRBrace and p.current().kind != tkEOF:
      let vSp = p.getSpan()
      let name = p.expect(tkIdent, "Expected tag name in enum").value
      variants.add(VariantDef(name: name, fields: @[], span: vSp))
      if p.current().kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBrace)
    return Type(span: sp, kind: tkSum, variants: variants, transitions: @[], attrs: @[])
  else:
    var fields: seq[FieldDef]
    while p.current().kind != tkRBrace and p.current().kind != tkEOF:
      let fSp = p.getSpan()
      let name = p.expect(tkIdent, "Expected field name in record definition").value
      discard p.expect(tkColon)
      let typ = p.parseType()
      fields.add(FieldDef(name: name, typ: typ, attrs: @[], span: fSp))
      if p.current().kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBrace)
    return Type(span: sp, kind: tkRecord, fields: fields, attrs: @[])

proc parsePrimaryType(p: var Parser): Type =
  let sp = p.getSpan()
  let curr = p.current()
  if curr.kind in {tkBang, tkQuestion, tkBangQuestion}:
    # !T / ?T / !?T — result wrappers (spec 4.8), stored as tkApp on "!"/"?"/"!?"
    let marker = case curr.kind
      of tkBang: "!"
      of tkQuestion: "?"
      else: "!?"
    discard p.advance()
    let inner = p.parseType()
    let wrapBase = Type(span: sp, kind: tkNamed, name: marker)
    return Type(span: sp, kind: tkApp, base: wrapBase, args: @[inner])

  elif curr.kind == tkLParen:
    return p.parseParenType(sp)

  elif curr.kind == tkLBrace:
    return p.parseBraceType(sp)

  elif curr.kind == tkFn:
    discard p.advance()
    return Type(span: sp, kind: tkNamed, name: "fn")

  elif curr.kind in {tkIntLit, tkFloatLit, tkStrLit}:
    let val = p.advance().value
    return Type(span: sp, kind: tkNamed, name: val)

  elif curr.kind == tkIdent:
    let name = p.advance().value
    var base = Type(span: sp, kind: tkNamed, name: name)
    if p.current().kind == tkLBracket:
      # Check if it's attributes or generics
      let first = p.peek(1)
      let isAttr = first.kind == tkIdent and (first.value in [
        "saturating", "sealed", "queue", "irq_safe", "no_alloc", "invariant",
        "packed", "align", "wrapping", "trapping",
        "big_endian", "little_endian", "volatile",       # spec 4.6 type + field attrs
        "error",                                          # [error: FsError] on fallible returns
        "io", "unsafe", "may_block", "stack", "priority"])  # effect markers after a return type
      discard p.advance() # eat "["
      if isAttr:
        # An attribute is `[name]` or `[name: value]`. If the name is followed
        # by anything else, this was meant as a TYPE ARGUMENT that happens to
        # share a name with an attribute — say so, rather than reporting a
        # surprising token. (The word list itself is the real bug; see
        # tests/known_bugs.nim.)
        # `error` additionally REQUIRES a value (`[error: FsError]`), so a
        # bare `[error]` is certainly a type argument, not an attribute.
        let bareAttr = p.peek(1).kind in {tkRBracket, tkComma}
        if p.peek(1).kind notin {tkColon, tkRBracket, tkComma} or
           (first.value == "error" and bareAttr):
          p.reportError("'" & first.value & "' is an attribute name, so " &
            "`" & base.name & "[" & first.value & "]` is read as an " &
            "attribute, not a type argument. Rename the type argument — " &
            "attribute names (error, stack, queue, align, priority, " &
            "volatile, io, sealed, packed, …) cannot currently be used as " &
            "type arguments.")
        base.attrs = p.parseTypeUseAttrs()
      else:
        var args: seq[Type]
        while p.current().kind != tkRBracket and p.current().kind != tkEOF:
          args.add(p.parseType())
          if p.current().kind == tkComma:
            discard p.advance()
        discard p.expect(tkRBracket)
        return Type(span: sp, kind: tkApp, base: base, args: args)
    return base

  else:
    p.reportError("Unexpected token in type expression: " & $curr.kind)

# Effect markers written after a return type (`-> T [io]`) parse as attrs on T —
# or on the payload inside a !/? wrapper. Harvest them off wherever they landed.
proc harvestEffects*(t: Type, effects: var seq[EffectMarker],
                     errorTypes: var seq[string]) =
  if t == nil: return
  var kept: seq[TypeAttr]
  for a in t.attrs:
    case a.name
    of "io": effects.add(emIo)
    of "no_alloc": effects.add(emNoAlloc)
    of "irq_safe": effects.add(emIrqSafe)
    of "unsafe": effects.add(emUnsafe)
    of "may_block": effects.add(emMayBlock)
    of "stack": effects.add(emStack)
    of "priority": effects.add(emPriority)
    of "error": errorTypes.add(a.value)  # [error: FsError | NetError]
    else: kept.add(a)
  t.attrs = kept
  if t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
     t.base.name in ["!", "?", "!?"]:
    for arg in t.args:
      harvestEffects(arg, effects, errorTypes)

proc parseType*(p: var Parser): Type =
  let sp = p.getSpan()
  var res = p.parsePrimaryType()
  while true:
    let curr = p.current()
    if curr.kind == tkStar:
      discard p.advance()
      let countSp = p.getSpan()
      let countVal = p.expect(tkIntLit, "Expected type multiplication count").value
      let starBase = Type(span: sp, kind: tkNamed, name: "*")
      let countType = Type(span: countSp, kind: tkNamed, name: countVal)
      res = Type(span: sp, kind: tkApp, base: starBase, args: @[res, countType])
    elif curr.kind == tkLBrace and p.peek(1).kind == tkIdent and p.peek(2).kind == tkArrow:
      discard p.advance()
      var renames: seq[(string, string)]
      while p.current().kind != tkRBrace and p.current().kind != tkEOF:
        let orig = p.expect(tkIdent, "Expected original field name").value
        discard p.expect(tkArrow)
        let target = p.expect(tkIdent, "Expected target field name").value
        renames.add((orig, target))
        if p.current().kind == tkComma:
          discard p.advance()
      discard p.expect(tkRBrace)
      res = Type(span: sp, kind: tkRename, underlying: res, renames: renames)
    elif curr.kind == tkPlus:
      discard p.advance()
      let rightWithSuffix = p.parseType()
      if res.kind == tkUnion:
        res.members.add(rightWithSuffix)
      else:
        res = Type(span: sp, kind: tkUnion, members: @[res, rightWithSuffix])
    elif curr.kind in {tkQuestion, tkBang, tkBangQuestion}:
      # postfix wrappers: int? (option), int! (fallible), int?! (both) —
      # equivalent to the prefix forms ?T / !T / !?T
      discard p.advance()
      let wname = case curr.kind
                  of tkQuestion: "?"
                  of tkBang: "!"
                  else: "!?"
      res = Type(span: sp, kind: tkApp,
                 base: Type(span: sp, kind: tkNamed, name: wname), args: @[res])
    else:
      break
  return res

proc parsePattern*(p: var Parser): Pattern =
  let sp = p.getSpan()
  let curr = p.current()
  
  if curr.kind == tkIdent and curr.value == "_":
    discard p.advance()
    return Pattern(span: sp, kind: pkWild)
  elif curr.kind == tkIdent:
    var name = p.advance().value
    while p.current().kind == tkDot:
      name.add(".")
      discard p.advance()
      if p.current().kind in {tkIdent, tkIntLit, tkFloatLit, tkStrLit}:
        name.add(p.current().value)
        let wasLit = p.current().kind in {tkIntLit, tkFloatLit}
        discard p.advance()
        if wasLit and p.current().kind == tkIdent:
          name.add(p.current().value)
          discard p.advance()
      else:
        p.reportError("Expected identifier or literal in pattern path")
    return Pattern(span: sp, kind: pkVar, name: name)
  elif curr.kind == tkIntLit:
    let val = p.advance().value
    return Pattern(span: sp, kind: pkLit, litKind: lkInt, litValue: val)
  elif curr.kind == tkFloatLit:
    let val = p.advance().value
    return Pattern(span: sp, kind: pkLit, litKind: lkFloat, litValue: val)
  elif curr.kind == tkStrLit:
    let val = p.advance().value
    return Pattern(span: sp, kind: pkLit, litKind: lkStr, litValue: val)
  elif curr.kind == tkTrue or curr.kind == tkFalse:
    let val = p.advance().value
    return Pattern(span: sp, kind: pkLit, litKind: lkBool, litValue: val)
  elif curr.kind == tkLBrace:
    discard p.advance()
    var fields: seq[(string, Pattern)]
    while p.current().kind != tkRBrace and p.current().kind != tkEOF:
      let name = p.expect(tkIdent, "Expected field name in pattern").value
      var pat: Pattern
      if p.current().kind == tkColon:
        discard p.advance()
        pat = p.parsePattern()
      else:
        pat = Pattern(span: sp, kind: pkVar, name: name)
      fields.add((name, pat))
      if p.current().kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBrace)
    return Pattern(span: sp, kind: pkRecord, fields: fields)
  else:
    p.reportError("Unexpected pattern syntax: " & $curr.kind)

proc isStructLiteral(p: Parser): bool =
  let first = p.peek(1)
  let second = p.peek(2)
  if first.kind == tkRBrace:
    return true
  if first.kind == tkIdent:
    if second.kind in {tkColon, tkComma, tkRBrace}:
      return true
  return false

# {a: 1, b} — struct literal; a bare name is shorthand for name: name
proc parseStructLiteral(p: var Parser, sp: Span): Expr =
  discard p.advance()
  var fields: seq[(string, Expr)]
  while p.current().kind != tkRBrace and p.current().kind != tkEOF:
    let name = p.expect(tkIdent, "Expected field name in struct literal").value
    var valExpr: Expr
    if p.current().kind == tkColon:
      discard p.advance()
      valExpr = p.parseExpr()
    else:
      valExpr = Expr(span: sp, kind: exkVar, name: name)
    fields.add((name, valExpr))
    if p.current().kind == tkComma:
      discard p.advance()
  discard p.expect(tkRBrace)
  return Expr(span: sp, kind: exkStruct, fields: fields)

# { stmt; stmt } — inline block expression
proc parseBraceBlock(p: var Parser, sp: Span): Expr =
  discard p.advance()
  var stmts: seq[Expr]
  while p.current().kind != tkRBrace and p.current().kind != tkEOF:
    stmts.add(p.parseExpr())
    if p.current().kind == tkNewline:
      discard p.advance()
  discard p.expect(tkRBrace)
  return Expr(span: sp, kind: exkBlock, stmts: stmts)

proc parsePrimaryExpr(p: var Parser): Expr =
  let sp = p.getSpan()
  let curr = p.current()
  # `err X` — raise an error value into the fn's result: `return err
  # FsError.NotFound`, shorthand `err NotFound` (resolved against the sig's
  # [error: E]), or re-raise a code: `err resp.err`
  if curr.kind == tkIdent and curr.value == "err" and
     p.peek().kind in {tkIdent, tkIntLit}:
    discard p.advance()
    let val = p.parseExpr()
    return Expr(span: sp, kind: exkRaise, raiseVal: val)
  if curr.kind == tkDotDot and p.peek().kind == tkDot:
    discard p.advance()
    discard p.advance()
    return Expr(span: sp, kind: exkVar, name: "...")
  if curr.kind == tkColon and p.peek().kind == tkIdent:
    discard p.advance()
    let name = p.expect(tkIdent).value
    return Expr(span: sp, kind: exkQualified, modulePath: @[], qualName: name)
  if curr.kind == tkMinus:
    discard p.advance()
    let operand = p.parsePrimaryExpr()
    return Expr(span: sp, kind: exkUnary, unaryOp: uoNeg, operand: operand)
  if curr.kind == tkNot:
    discard p.advance()
    let operand = p.parsePrimaryExpr()
    return Expr(span: sp, kind: exkUnary, unaryOp: uoNot, operand: operand)
  case curr.kind
  of tkIntLit:
    let val = p.advance().value
    return Expr(span: sp, kind: exkLit, litKind: lkInt, litValue: val)
  of tkFloatLit:
    let val = p.advance().value
    return Expr(span: sp, kind: exkLit, litKind: lkFloat, litValue: val)
  of tkStrLit:
    let val = p.advance().value
    return Expr(span: sp, kind: exkLit, litKind: lkStr, litValue: val)
  of tkTrue:
    discard p.advance()
    return Expr(span: sp, kind: exkLit, litKind: lkBool, litValue: "true")
  of tkFalse:
    discard p.advance()
    return Expr(span: sp, kind: exkLit, litKind: lkBool, litValue: "false")
  of tkNone:
    discard p.advance()
    return Expr(span: sp, kind: exkLit, litKind: lkUnit, litValue: "none")
  of tkIdent:
    let name = p.advance().value
    return Expr(span: sp, kind: exkVar, name: name)
  of tkLBrace:
    if p.isStructLiteral():
      return p.parseStructLiteral(sp)
    elif p.peek(1).kind == tkRBrace:
      return p.parseBraceBlock(sp)  # {} — empty struct, handled above; unreachable here, kept for safety
    else:
      # {expr} — a bare value is sugar for {value: expr}
      discard p.advance()
      let val = p.parseExpr()
      discard p.expect(tkRBrace)
      return Expr(span: sp, kind: exkStruct, fields: @[("value", val)])
  of tkLBracket:
    discard p.advance()
    var items: seq[Expr]
    while p.current().kind != tkRBracket and p.current().kind != tkEOF:
      items.add(p.parseExpr())
      if p.current().kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBracket)
    return Expr(span: sp, kind: exkList, items: items)
  of tkLParen:
    discard p.advance()
    let inner = p.parseExpr()
    discard p.expect(tkRParen)
    return inner
  else:
    p.reportError("Expected expression but got: " & $curr.kind)

# Type.Variant [unsafe] — deserialization escape hatch for sealed construction
# (spec 4.4). Consumes the marker and reports whether it was present.
proc tryUnsafeMarker(p: var Parser): bool =
  if p.current().kind == tkLBracket and p.peek(1).kind == tkIdent and
     p.peek(1).value == "unsafe" and p.peek(2).kind == tkRBracket:
    discard p.advance()  # [
    discard p.advance()  # unsafe
    discard p.advance()  # ]
    return true
  false

# expr alias(field: expr, ...) — record restructuring step (spec 2.5)
proc parseAliasStep(p: var Parser, expr: Expr): Expr =
  let spAlias = p.getSpan()
  discard p.advance()
  discard p.expect(tkLParen)
  var fields: seq[(string, Expr)]
  while p.current().kind != tkRParen and p.current().kind != tkEOF:
    let name = p.expect(tkIdent, "Expected field name in alias").value
    discard p.expect(tkColon)
    let valExpr = p.parseExpr()
    fields.add((name, valExpr))
    if p.current().kind == tkComma:
      discard p.advance()
  discard p.expect(tkRParen)
  let structExpr = Expr(span: spAlias, kind: exkStruct, fields: fields)
  let calleeExpr = Expr(span: spAlias, kind: exkVar, name: "alias")
  return Expr(span: spAlias, kind: exkCall, callee: calleeExpr, args: @[expr, structExpr])

# {payload} fnName / {payload} mod::fn / {payload} Type.Variant [unsafe] —
# the postfix call, Tuck's one call shape
proc parsePostfixCall(p: var Parser, expr: Expr, sp: Span): Expr =
  if p.peek().kind == tkColonColon:
    let moduleName = p.advance().value
    discard p.expect(tkColonColon)
    let name = p.expect(tkIdent, "Expected identifier after '::'").value
    let calleeExpr = Expr(span: sp, kind: exkQualified, modulePath: @[moduleName], qualName: name)
    return Expr(span: sp, kind: exkCall, callee: calleeExpr, args: @[expr])
  let callee = p.advance().value
  var calleeExpr = Expr(span: sp, kind: exkVar, name: callee)
  # Qualified postfix: the callee may be a dotted path; construction flows
  # payload-first like any call
  while p.current().kind == tkDot:
    discard p.advance()
    let fname = p.expect(tkIdent, "Expected name after '.'").value
    calleeExpr = Expr(span: sp, kind: exkField, receiver: calleeExpr, fieldName: fname)
    if p.tryUnsafeMarker():
      calleeExpr.ctorUnsafe = true
  return Expr(span: sp, kind: exkCall, callee: calleeExpr, args: @[expr])

# `xs[i]` binds to the expression before it; `xs [1, 2]` is a separate list
# literal in argument position. Tightness is the ONLY thing the parser
# decides here — whether the bracket then means indexing or type application
# depends on the receiver, which only the checker knows.
proc bracketIsTight(p: Parser): bool =
  if p.cursor == 0: return false
  let prev = p.tokens[p.cursor - 1]
  let br = p.current()
  br.line == prev.line and br.column == prev.column + prev.value.len

proc parseChainExpr(p: var Parser): Expr =
  var expr = p.parsePrimaryExpr()
  
  while true:
    let sp = p.getSpan()
    if p.current().kind == tkDot:
      discard p.advance()
      let fieldName = p.expect(tkIdent, "Expected field name after '.'").value
      expr = Expr(span: sp, kind: exkField, receiver: expr, fieldName: fieldName)
      if p.tryUnsafeMarker():
        expr.ctorUnsafe = true
      # `.fn {args}` — method form: receiver is the fn's first parameter,
      # the braced struct fills the remaining parameters
      if p.current().kind == tkLBrace:
        expr.dotArg = p.parsePrimaryExpr()
    elif p.current().kind == tkDotDot:
      discard p.advance()
      let fieldName = p.expect(tkIdent, "Expected builder field name after '..'").value
      var arg: Expr = nil
      if p.current().kind == tkLBrace:
        arg = p.parsePrimaryExpr()
      let step = ChainStep(op: coDotDot, target: Expr(span: sp, kind: exkVar, name: fieldName), arg: arg, span: sp)
      # steps accumulate on ONE chain node — every `..` in the chain mutates
      # the same base var
      if expr.kind == exkChain:
        expr.steps.add(step)
      else:
        expr = Expr(span: sp, kind: exkChain, base: expr, steps: @[step])
    elif p.current().kind == tkColonColon:
      discard p.advance()
      let name = p.expect(tkIdent, "Expected identifier after '::'").value
      let moduleName = if expr.kind == exkVar: expr.name else: ""
      expr = Expr(span: sp, kind: exkQualified, modulePath: @[moduleName], qualName: name)
    elif p.current().kind == tkLBracket and p.bracketIsTight():
      # `recv[a, b, ...]` — the argument sits after the callee, like every
      # other postfix continuation here. One arg on a value is an index; a
      # declared type receiver is a type application. The checker decides;
      # chaining (`grid[i][j]`) falls out of this loop.
      discard p.advance()
      var brArgs: seq[Expr]
      while p.current().kind != tkRBracket and p.current().kind != tkEOF:
        brArgs.add(p.parseExpr())
        if p.current().kind == tkComma:
          discard p.advance()
      discard p.expect(tkRBracket)
      expr = Expr(span: sp, kind: exkBracket, brReceiver: expr, brArgs: brArgs)
    elif p.current().kind == tkBake:
      discard p.advance()
      let arg = p.parsePrimaryExpr()
      let calleeExpr = Expr(span: sp, kind: exkVar, name: "bake")
      expr = Expr(span: sp, kind: exkCall, callee: calleeExpr, args: @[expr, arg])
    elif p.current().kind == tkLParen and expr.kind == exkVar and
         expr.name in ["sizeof", "alignof", "offsetof"]:
      # Compile-time builtins (spec 8.2) keep parens; everything else is postfix
      discard p.advance()
      var args: seq[Expr]
      while p.current().kind != tkRParen and p.current().kind != tkEOF:
        args.add(p.parseExpr())
        if p.current().kind == tkComma:
          discard p.advance()
      discard p.expect(tkRParen)
      expr = Expr(span: sp, kind: exkCall, callee: expr, args: args)
    elif p.current().kind == tkLParen:
      p.reportError("Function calls are postfix in Tuck: write {payload} fnName, not fnName(args)")
    elif p.current().kind == tkLBrace:
      let arg = p.parsePrimaryExpr()
      expr = Expr(span: sp, kind: exkCall, callee: expr, args: @[arg])
    elif p.current().kind == tkIdent and p.current().value == "alias" and p.peek().kind == tkLParen:
      expr = p.parseAliasStep(expr)
    elif p.current().kind == tkIdent and not (p.current().value in ["or", "and", "in", "invariant", "transitions"]):
      expr = p.parsePostfixCall(expr, sp)
    else:
      break
  return expr

proc parseBinaryExpr(p: var Parser, minPrecedence = 0): Expr =
  var left = p.parseChainExpr()
  
  let opPrecedences = {
    tkPlus: (1, boAdd), tkMinus: (1, boSub),
    tkStar: (2, boMul), tkSlash: (2, boDiv), tkPercent: (2, boMod),
    tkEq: (0, boEq), tkNeq: (0, boNeq),
    tkLt: (0, boLt), tkGt: (0, boGt), tkLte: (0, boLe), tkGte: (0, boGe),
    tkAnd: (-1, boAnd), tkOr: (-1, boOr),
    tkRange: (-2, boRangeIncl), tkRangeLt: (-2, boRangeExcl),
  }.toTable()
  
  while true:
    let currKind = p.current().kind
    if currKind in opPrecedences:
      let (prec, op) = opPrecedences[currKind]
      if prec >= minPrecedence:
        discard p.advance()
        let right = if currKind in {tkAnd, tkOr}: p.parseExpr() else: p.parseBinaryExpr(prec + 1)
        left = Expr(span: left.span, kind: exkBinary, binOp: op, left: left, right: right)
      else:
        break
    else:
      break
  return left

proc parseSelectExpr(p: var Parser): Expr =
  let sp = p.getSpan()
  discard p.expect(tkOn)
  discard p.expect(tkSelect)
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  discard p.expect(tkIndent)
  var arms: seq[MatchArm]
  while p.current().kind != tkDedent and p.current().kind != tkEOF:
    if p.current().kind == tkNewline:
      discard p.advance()
      continue
    discard p.expect(tkPipe)
    let pat = p.parsePattern()
    discard p.expect(tkArrow)
    discard p.parsePattern()
    discard p.expect(tkColon)
    let body = p.parseExpr()
    arms.add(MatchArm(pattern: pat, guard: nil, body: body, span: p.getSpan()))
    if p.current().kind == tkNewline:
      discard p.advance()
  discard p.expect(tkDedent)
  return Expr(span: sp, kind: exkMatch, subject: Expr(span: sp, kind: exkVar, name: "select"), arms: arms)

proc parseExpr*(p: var Parser): Expr =
  let sp = p.getSpan()
  let curr = p.current()
  if curr.kind == tkOn and p.peek().kind == tkSelect:
    return p.parseSelectExpr()

  if curr.kind == tkLet or curr.kind == tkVar:
    let mutable = curr.kind == tkVar
    discard p.advance()
    let name = p.expect(tkIdent, "Expected variable name").value
    discard p.expect(tkAssign)
    let valExpr = p.parseExpr()
    let target = Expr(span: sp, kind: exkVar, name: name)
    return Expr(span: sp, kind: exkAssign, target: target, assignVal: valExpr,
                isDecl: true, isMutable: mutable)

  if curr.kind == tkIf:
    discard p.advance()
    let cond = p.parseExpr()
    discard p.expect(tkColon)
    let thenBranch = p.parseBlock()
    var elseBranch: Expr
    if p.current().kind == tkElse:
      discard p.advance()
      discard p.expect(tkColon)
      elseBranch = p.parseBlock()
    return Expr(span: sp, kind: exkIf, cond: cond, thenBranch: thenBranch, elseBranch: elseBranch)
    
  elif curr.kind == tkReturn:
    discard p.advance()
    let val = if p.current().kind == tkNewline or p.current().kind == tkDedent: nil else: p.parseExpr()
    return Expr(span: sp, kind: exkReturn, returnVal: val)

  elif curr.kind == tkMatch:
    discard p.advance()
    let subject = p.parseExpr()
    discard p.expect(tkColon)
    discard p.expect(tkNewline)
    discard p.expect(tkIndent)
    var arms: seq[MatchArm]
    while p.current().kind != tkDedent and p.current().kind != tkEOF:
      if p.current().kind == tkNewline:
        discard p.advance()
        continue
      let pat = p.parsePattern()
      discard p.expect(tkColon)
      # arm body: a single expression on the same line, or an indented block
      let body = if p.current().kind == tkNewline: p.parseBlock()
                 else: p.parseExpr()
      arms.add(MatchArm(pattern: pat, guard: nil, body: body, span: p.getSpan()))
      if p.current().kind == tkNewline:
        discard p.advance()
    discard p.expect(tkDedent)
    return Expr(span: sp, kind: exkMatch, subject: subject, arms: arms)

  elif curr.kind == tkFor:
    discard p.advance()
    # iteration form iff lookahead is `ident in` or `ident , ident in`;
    # anything else after `for` is a while-style condition expression
    let isIter = p.current().kind == tkIdent and
      (p.peek(1).kind == tkIn or
       (p.peek(1).kind == tkComma and p.peek(2).kind == tkIdent and
        p.peek(3).kind == tkIn))
    if isIter:
      var iter = p.parsePattern()
      if p.current().kind == tkComma:
        discard p.advance()
        let second = p.parsePattern()
        iter = Pattern(span: iter.span, kind: pkTuple, elems: @[iter, second])
      discard p.expect(tkIn)
      let iterable = p.parseExpr()
      discard p.expect(tkColon)
      let body = p.parseBlock()
      return Expr(span: sp, kind: exkFor, iter: iter, iterable: iterable, body: body)
    else:
      let cond = p.parseExpr()
      discard p.expect(tkColon)
      let body = p.parseBlock()
      return Expr(span: sp, kind: exkWhile, whileCond: cond, whileBody: body)

  elif curr.kind == tkLoop:
    discard p.advance()
    discard p.expect(tkColon)
    let body = p.parseBlock()
    return Expr(span: sp, kind: exkWhile, whileCond: nil, whileBody: body)

  elif curr.kind == tkBreak:
    discard p.advance()
    return Expr(span: sp, kind: exkBreak)

  elif curr.kind == tkContinue:
    discard p.advance()
    return Expr(span: sp, kind: exkContinue)

  let left = p.parseBinaryExpr(-2)
  # `=` and the compound forms differ only in the operator folded into the
  # value, so they share one path — that keeps the bracket rewrite (setAt,
  # not assign-to-a-place) in a single spot instead of five.
  const compoundOps = {tkPlusAssign: boAdd, tkMinusAssign: boSub,
                       tkStarAssign: boMul, tkSlashAssign: boDiv}.toTable()
  if p.current().kind == tkAssign or p.current().kind in compoundOps:
    let opKind = p.current().kind
    discard p.advance()
    let right = p.parseExpr()
    # ponytail: `xs[i] += v` expands to `xs[i] = xs[i] + v`, so the receiver
    # and index are evaluated twice. Fine for vars; bind to a temp if a
    # side-effecting receiver ever needs to work here.
    let value = if opKind == tkAssign: right
                else: Expr(span: sp, kind: exkBinary, binOp: compoundOps[opKind],
                           left: left, right: right)
    if left.kind == exkBracket:
      return Expr(span: sp, kind: exkBracketAssign,
                  brTarget: left, brValue: value)
    return Expr(span: sp, kind: exkAssign, target: left, assignVal: value)
  return left

proc parseBlock*(p: var Parser): Expr =
  let sp = p.getSpan()
  discard p.expect(tkNewline)
  while p.current().kind == tkNewline:
    discard p.advance()
  if p.current().kind != tkIndent:
    return Expr(span: sp, kind: exkBlock, stmts: @[])
  discard p.expect(tkIndent)
  var stmts: seq[Expr]
  while p.current().kind != tkDedent and p.current().kind != tkEOF:
    if p.current().kind == tkNewline:
      discard p.advance()
      continue
    stmts.add(p.parseExpr())
    if p.current().kind == tkNewline:
      discard p.advance()
  discard p.expect(tkDedent)
  return Expr(span: sp, kind: exkBlock, stmts: stmts)

proc parseObjectBody(p: var Parser, fields: var seq[FieldDef], members: var seq[Decl]) =
  discard p.expect(tkNewline)
  discard p.expect(tkIndent)
  while p.current().kind != tkDedent and p.current().kind != tkEOF:
    if p.current().kind == tkNewline:
      discard p.advance()
      continue
      
    if p.current().kind == tkDotDot and p.peek(1).kind == tkDot:
      let fSp = p.getSpan()
      discard p.advance()
      discard p.advance()
      let expr = Expr(span: fSp, kind: exkVar, name: "...")
      members.add(Decl(span: fSp, kind: dkExpr, expr: expr))
      if p.current().kind == tkNewline:
        discard p.advance()
      continue

    let isMember = p.current().kind in {tkFn, tkLet, tkVar, tkPending, tkOn, tkPlus}
    if isMember:
      members.add(p.parseDecl())
    elif p.current().kind == tkIdent and p.current().value == "invariant":
      p.parseInvariantBlock(members)
    else:
      let fSp = p.getSpan()
      let fName = p.expect(tkIdent, "Expected field or member name in object").value
      discard p.expect(tkColon)
      let fType = p.parseType()
      if p.current().kind == tkAssign:
        discard p.advance()
        discard p.parseExpr()
      fields.add(FieldDef(name: fName, typ: fType, attrs: @[], span: fSp))
      if p.current().kind == tkNewline:
        discard p.advance()
  discard p.expect(tkDedent)

proc parseDecisionBody(p: var Parser): Expr =
  let sp = p.getSpan()
  discard p.expect(tkNewline)
  discard p.expect(tkIndent)
  var stmts: seq[Expr]
  while p.current().kind != tkDedent and p.current().kind != tkEOF:
    if p.current().kind == tkNewline:
      discard p.advance()
      continue
    discard p.expect(tkPipe)
    var rowPats: seq[Pattern]
    while p.current().kind != tkArrow and p.current().kind != tkEOF:
      rowPats.add(p.parsePattern())
    discard p.expect(tkArrow)
    let bodyExpr = p.parseExpr()
    let rowArm = MatchArm(pattern: Pattern(span: sp, kind: pkTuple, elems: rowPats), guard: nil, body: bodyExpr, span: sp)
    let rowExpr = Expr(span: sp, kind: exkMatch, subject: nil, arms: @[rowArm])
    stmts.add(rowExpr)
    if p.current().kind == tkNewline:
      discard p.advance()
  discard p.expect(tkDedent)
  return Expr(span: sp, kind: exkBlock, stmts: stmts)

# Body-less signature block: `: NEWLINE INDENT (fn name(params) -> ret [fx])* DEDENT`
# Shared by pending: (typed holes) and extern: (runtime / C implemented).
proc parseSigBlock(p: var Parser, what: string): seq[Decl] =
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  while p.current().kind == tkNewline:
    discard p.advance()
  discard p.expect(tkIndent)
  while p.current().kind != tkDedent and p.current().kind != tkEOF:
    if p.current().kind == tkNewline:
      discard p.advance()
      continue
    let spDecl = p.getSpan()
    discard p.expect(tkFn)
    var name = p.expect(tkIdent, "Expected function name in " & what & " declaration").value
    if p.current().kind == tkColonColon:
      # module-qualified sketch stub: fn http::get(...)
      discard p.advance()
      name = name & "::" & p.expect(tkIdent, "Expected identifier after '::'").value
    # generic sig: fn toStr[T](...) — Uppercase-first idents, like fn decls
    var sigGenerics: seq[string]
    if p.current().kind == tkLBracket and p.peek(1).kind == tkIdent and
       p.peek(1).value.len > 0 and p.peek(1).value[0] in {'A' .. 'Z'}:
      discard p.advance()
      while p.current().kind != tkRBracket and p.current().kind != tkEOF:
        sigGenerics.add(p.expect(tkIdent, "Expected type parameter").value)
        if p.current().kind == tkComma: discard p.advance()
      discard p.expect(tkRBracket)
    discard p.expect(tkLParen)
    var params: seq[Param]
    if p.current().kind != tkRParen:
      while true:
        let pSp = p.getSpan()
        if p.current().kind == tkLBrace:
          discard p.advance()
          while p.current().kind != tkRBrace and p.current().kind != tkEOF:
            let paramName = p.expect(tkIdent, "Expected parameter name").value
            discard p.expect(tkColon)
            let paramType = p.parseType()
            params.add(Param(name: paramName, typ: paramType, span: pSp))
            if p.current().kind == tkComma:
              discard p.advance()
          discard p.expect(tkRBrace)
        else:
          let paramName = p.expect(tkIdent, "Expected parameter name").value
          var paramType: Type = nil
          if paramName == "self" and p.current().kind != tkColon:
            paramType = Type(span: pSp, kind: tkNamed, name: "Self")
          else:
            discard p.expect(tkColon)
            paramType = p.parseType()
          params.add(Param(name: paramName, typ: paramType, span: pSp))
        if p.current().kind == tkComma:
          discard p.advance()
        else:
          break
    discard p.expect(tkRParen)
    var retType: Type
    if p.current().kind == tkArrow:
      discard p.advance()
      retType = p.parseType()
    var sigEffects: seq[EffectMarker]
    var sigErrTypes: seq[string]
    harvestEffects(retType, sigEffects, sigErrTypes)
    if p.current().kind == tkLBracket:
      discard p.advance()
      while p.current().kind != tkRBracket and p.current().kind != tkEOF:
        let effName = p.expect(tkIdent, "Expected effect marker").value
        if effName == "error":
          discard p.expect(tkColon)
          sigErrTypes.add(p.expect(tkIdent, "Expected error enum name after 'error:'").value)
          while p.current().kind == tkPipe:
            discard p.advance()
            sigErrTypes.add(p.expect(tkIdent, "Expected error enum name after '|'").value)
          if p.current().kind == tkComma: discard p.advance()
          continue
        case effName
        of "io": sigEffects.add(emIo)
        of "no_alloc": sigEffects.add(emNoAlloc)
        of "irq_safe": sigEffects.add(emIrqSafe)
        of "unsafe": sigEffects.add(emUnsafe)
        of "may_block": sigEffects.add(emMayBlock)
        of "stack": sigEffects.add(emStack)
        of "priority": sigEffects.add(emPriority)
        else: discard
        if p.current().kind == tkComma:
          discard p.advance()
      discard p.expect(tkRBracket)
    result.add(Decl(span: spDecl, kind: dkFn, name: name, fnParams: params,
                    fnGenerics: sigGenerics,
                    fnReturnType: retType, fnEffects: sigEffects, fnBody: nil,
                    fnErrorTypes: sigErrTypes))
    if p.current().kind == tkNewline:
      discard p.advance()
  discard p.expect(tkDedent)

# registry Name: | Variant {fields} — global event registry (spec 10)
proc parseRegistryDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  let name = p.expect(tkIdent, "Expected registry name").value
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  discard p.expect(tkIndent)
  var variants: seq[VariantDef]
  while p.current().kind != tkDedent and p.current().kind != tkEOF:
    if p.current().kind == tkNewline:
      discard p.advance()
      continue
    discard p.expect(tkPipe)
    let vSp = p.getSpan()
    let vName = p.expect(tkIdent, "Expected variant name in registry").value
    var vFields: seq[FieldDef]
    var hasParens = false
    if p.current().kind == tkLParen:
      hasParens = true
      discard p.advance()
    if p.current().kind == tkLBrace:
      discard p.advance()
      while p.current().kind != tkRBrace and p.current().kind != tkEOF:
        let fSp = p.getSpan()
        let fName = p.expect(tkIdent, "Expected variant field name").value
        discard p.expect(tkColon)
        let fType = p.parseType()
        vFields.add(FieldDef(name: fName, typ: fType, attrs: @[], span: fSp))
        if p.current().kind == tkComma:
          discard p.advance()
      discard p.expect(tkRBrace)
    if hasParens:
      discard p.expect(tkRParen)
    variants.add(VariantDef(name: vName, fields: vFields, span: vSp))
    if p.current().kind == tkNewline:
      discard p.advance()
  discard p.expect(tkDedent)
  return Decl(span: sp, kind: dkRegistry, name: name, variants: variants)

# task name({params}) -> ret [effects]: body (spec 9.2)
proc parseTaskDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  let name = p.expect(tkIdent, "Expected task name").value
  discard p.expect(tkLParen)
  var params: seq[Param]
  if p.current().kind != tkRParen:
    while true:
      let pSp = p.getSpan()
      if p.current().kind == tkLBrace:
        discard p.advance()
        while p.current().kind != tkRBrace and p.current().kind != tkEOF:
          let paramName = p.expect(tkIdent, "Expected parameter name").value
          discard p.expect(tkColon)
          let paramType = p.parseType()
          params.add(Param(name: paramName, typ: paramType, span: pSp))
          if p.current().kind == tkComma:
            discard p.advance()
        discard p.expect(tkRBrace)
      else:
        let paramName = p.expect(tkIdent, "Expected parameter name").value
        var paramType: Type = nil
        if paramName == "self" and p.current().kind != tkColon:
          paramType = Type(span: pSp, kind: tkNamed, name: "Self")
        else:
          discard p.expect(tkColon)
          paramType = p.parseType()
        params.add(Param(name: paramName, typ: paramType, span: pSp))
      if p.current().kind == tkComma:
        discard p.advance()
      else:
        break
  discard p.expect(tkRParen)
  var retType: Type
  if p.current().kind == tkArrow:
    discard p.advance()
    retType = p.parseType()
  var effects: seq[EffectMarker]
  var taskErrTypes: seq[string]
  harvestEffects(retType, effects, taskErrTypes)
  if p.current().kind == tkLBracket:
    discard p.advance()
    while p.current().kind != tkRBracket and p.current().kind != tkEOF:
      let effSp = p.getSpan()
      let effName = p.expect(tkIdent, "Expected effect marker").value
      var eff: EffectMarker
      case effName
      of "io": eff = emIo
      of "no_alloc": eff = emNoAlloc
      of "irq_safe": eff = emIrqSafe
      of "unsafe": eff = emUnsafe
      of "may_block": eff = emMayBlock
      of "stack": eff = emStack
      of "priority": eff = emPriority
      else:
        p.reportError("Unknown effect marker: " & effName, effSp.line, effSp.col)
      effects.add(eff)
      if p.current().kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBracket)
  discard p.expect(tkColon)
  let body = p.parseBlock()
  return Decl(span: sp, kind: dkTask, name: name, taskParams: params, taskReturnType: retType, taskEffects: effects, taskBody: body)

# type Name[T] [attrs] = alias | : body (fields / | variants / transitions / invariant:)
proc parseTypeDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  let name = p.expect(tkIdent, "Expected type name").value
  # `type Box[T]` — generic params are Uppercase idents; attrs are lowercase
  var typeGenerics: seq[string]
  if p.current().kind == tkLBracket and p.peek(1).kind == tkIdent and
     p.peek(1).value.len > 0 and p.peek(1).value[0] in {'A'..'Z'}:
    discard p.advance()
    while p.current().kind != tkRBracket and p.current().kind != tkEOF:
      typeGenerics.add(p.expect(tkIdent, "Expected generic parameter name").value)
      if p.current().kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBracket)
  var attrs: seq[TypeAttr]
  p.parseDeclAttrs(attrs)
  if p.current().kind == tkAssign:
    discard p.advance()
    let aliasType = p.parseType()
    if p.current().kind == tkNewline:
      discard p.advance()
    # Attributes may sit on either side of the `=`:
    #   type X [packed] = u16      (collected above, before the `=`)
    #   type X = u16 [saturating]  (collected by parseType, after it)
    # Keep both — assigning here used to CLOBBER the trailing ones, which is
    # why `[saturating]` was silently dropped.
    for a in attrs: aliasType.attrs.add(a)
    return Decl(span: sp, kind: dkType, name: name, generics: typeGenerics, typeBody: aliasType)
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  while p.current().kind == tkNewline:
    discard p.advance()
  discard p.expect(tkIndent)
  
  var variants: seq[VariantDef]
  var transitions: seq[Transition]
  var fields: seq[FieldDef]
  var members: seq[Decl]
  
  while p.current().kind != tkDedent and p.current().kind != tkEOF:
    if p.current().kind == tkNewline:
      discard p.advance()
      continue
      
    if p.current().kind == tkPipe:
      discard p.advance()
      let vSp = p.getSpan()
      let vName = p.expect(tkIdent, "Expected variant name").value
      var vFields: seq[FieldDef]
      var hasParens = false
      if p.current().kind == tkLParen:
        hasParens = true
        discard p.advance()
      if p.current().kind == tkLBrace:
        discard p.advance()
        while p.current().kind != tkRBrace and p.current().kind != tkEOF:
          let fSp = p.getSpan()
          let fName = p.expect(tkIdent, "Expected variant field name").value
          discard p.expect(tkColon)
          let fType = p.parseType()
          vFields.add(FieldDef(name: fName, typ: fType, attrs: @[], span: fSp))
          if p.current().kind == tkComma:
            discard p.advance()
        discard p.expect(tkRBrace)
      if hasParens:
        discard p.expect(tkRParen)
      variants.add(VariantDef(name: vName, fields: vFields, span: vSp))
      if p.current().kind == tkNewline:
        discard p.advance()
        
    elif p.current().kind == tkIdent and p.current().value == "transitions":
      discard p.advance()
      discard p.expect(tkColon)
      discard p.expect(tkNewline)
      discard p.expect(tkIndent)
      while p.current().kind != tkDedent and p.current().kind != tkEOF:
        if p.current().kind == tkNewline:
          discard p.advance()
          continue
        let tSp = p.getSpan()
        let fromState = p.expect(tkIdent, "Expected transition source state").value
        discard p.expect(tkArrow)
        let toState = p.expect(tkIdent, "Expected transition target state").value
        transitions.add(Transition(`from`: fromState, to: toState, span: tSp))
        if p.current().kind == tkNewline:
          discard p.advance()
      discard p.expect(tkDedent)
      
    elif p.current().kind == tkIdent and p.current().value == "invariant":
      p.parseInvariantBlock(members)

    else:
      let fSp = p.getSpan()
      let fName = p.expect(tkIdent, "Expected field or variant in type").value
      discard p.expect(tkColon)
      let fType = p.parseType()
      if p.current().kind == tkAssign:
        discard p.advance()
        discard p.parseExpr()
      fields.add(FieldDef(name: fName, typ: fType, attrs: @[], span: fSp))
      if p.current().kind == tkNewline:
        discard p.advance()
        
  discard p.expect(tkDedent)
  
  var bodyType: Type
  if variants.len > 0:
    bodyType = Type(span: sp, kind: tkSum, variants: variants, transitions: transitions, attrs: attrs)
  else:
    bodyType = Type(span: sp, kind: tkRecord, fields: fields, attrs: attrs)
    
  return Decl(span: sp, kind: dkType, name: name, generics: typeGenerics, typeBody: bodyType, typeMembers: members)

# fn name[T]({params}) -> ret [effects]: body — also `on select` arms and event handlers
proc parseFnDecl(p: var Parser, sp: Span): Decl =
  let curr = p.current()
  if curr.kind == tkOn and p.peek(1).kind == tkSelect:
    discard p.advance() # eat "on"
    discard p.advance() # eat "select"
    discard p.expect(tkColon)
    discard p.expect(tkNewline)
    discard p.expect(tkIndent)
    var arms: seq[MatchArm]
    while p.current().kind != tkDedent and p.current().kind != tkEOF:
      if p.current().kind == tkNewline:
        discard p.advance()
        continue
      discard p.expect(tkPipe)
      let pat = p.parsePattern()
      discard p.expect(tkArrow)
      discard p.parsePattern()
      discard p.expect(tkColon)
      let body = p.parseExpr()
      arms.add(MatchArm(pattern: pat, guard: nil, body: body, span: p.getSpan()))
      if p.current().kind == tkNewline:
        discard p.advance()
    discard p.expect(tkDedent)
    let selectExpr = Expr(span: sp, kind: exkMatch, subject: Expr(span: sp, kind: exkVar, name: "select"), arms: arms)
    return Decl(span: sp, kind: dkExpr, expr: selectExpr)

  discard p.advance()
  # `fn inline name(...)` — codegen-attribute keyword slot after fn
  var isInline = false
  if p.current().kind == tkIdent and p.current().value == "inline" and
     p.peek(1).kind == tkIdent:
    isInline = true
    discard p.advance()
  var name = p.expect(tkIdent, "Expected function or event name").value
  while p.current().kind == tkDot:
    discard p.advance()
    name.add("." & p.expect(tkIdent, "Expected qualified name component").value)
  var fnGenerics: seq[string]
  if p.current().kind == tkLBracket:
    discard p.advance()
    while p.current().kind != tkRBracket and p.current().kind != tkEOF:
      fnGenerics.add(p.expect(tkIdent, "Expected generic parameter name").value)
      if p.current().kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBracket)
  discard p.expect(tkLParen)
  var params: seq[Param]
  if p.current().kind != tkRParen:
    while true:
      let pSp = p.getSpan()
      if p.current().kind == tkLBrace:
        discard p.advance()
        while p.current().kind != tkRBrace and p.current().kind != tkEOF:
          let paramName = p.expect(tkIdent, "Expected parameter name").value
          discard p.expect(tkColon)
          let paramType = p.parseType()
          params.add(Param(name: paramName, typ: paramType, span: pSp))
          if p.current().kind == tkComma:
            discard p.advance()
        discard p.expect(tkRBrace)
      else:
        let paramName = p.expect(tkIdent, "Expected parameter name").value
        var paramType: Type = nil
        if paramName == "self" and p.current().kind != tkColon:
          paramType = Type(span: pSp, kind: tkNamed, name: "Self")
        else:
          discard p.expect(tkColon)
          paramType = p.parseType()
        params.add(Param(name: paramName, typ: paramType, span: pSp))
      if p.current().kind == tkComma:
        discard p.advance()
      else:
        break
  discard p.expect(tkRParen)
  var retType: Type
  if p.current().kind == tkArrow:
    discard p.advance()
    retType = p.parseType()
  var effects: seq[EffectMarker]
  var errTypes: seq[string]
  harvestEffects(retType, effects, errTypes)
  if p.current().kind == tkLBracket:
    discard p.advance()
    while p.current().kind != tkRBracket and p.current().kind != tkEOF:
      let effSp = p.getSpan()
      let effName = p.expect(tkIdent, "Expected effect marker").value
      if effName == "error":
        discard p.expect(tkColon)
        errTypes.add(p.expect(tkIdent, "Expected error enum name after 'error:'").value)
        while p.current().kind == tkPipe:
          discard p.advance()
          errTypes.add(p.expect(tkIdent, "Expected error enum name after '|'").value)
        if p.current().kind == tkComma: discard p.advance()
        continue
      var eff: EffectMarker
      case effName
      of "io": eff = emIo
      of "no_alloc": eff = emNoAlloc
      of "irq_safe": eff = emIrqSafe
      of "unsafe": eff = emUnsafe
      of "may_block": eff = emMayBlock
      of "stack": eff = emStack
      of "priority": eff = emPriority
      else:
        p.reportError("Unknown effect marker: " & effName, effSp.line, effSp.col)
      effects.add(eff)
      if p.current().kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBracket)
  var body: Expr = nil
  if p.current().kind == tkColon:
    discard p.advance()
    body = p.parseBlock()
  return Decl(span: sp, kind: dkFn, name: name, fnGenerics: fnGenerics, fnParams: params, fnReturnType: retType, fnEffects: effects, fnBody: body, fnErrorTypes: errTypes, isInline: isInline)

# decision name(inputs) -> ret: pattern-row table (spec 6.1)
proc parseDecisionDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  let name = p.expect(tkIdent, "Expected decision name").value
  discard p.expect(tkLParen)
  var params: seq[Param]
  if p.current().kind != tkRParen:
    while true:
      let pSp = p.getSpan()
      if p.current().kind == tkLBrace:
        discard p.advance()
        while p.current().kind != tkRBrace and p.current().kind != tkEOF:
          let paramName = p.expect(tkIdent, "Expected parameter name").value
          discard p.expect(tkColon)
          let paramType = p.parseType()
          params.add(Param(name: paramName, typ: paramType, span: pSp))
          if p.current().kind == tkComma:
            discard p.advance()
        discard p.expect(tkRBrace)
      else:
        let paramName = p.expect(tkIdent, "Expected parameter name").value
        var paramType: Type = nil
        if paramName == "self" and p.current().kind != tkColon:
          paramType = Type(span: pSp, kind: tkNamed, name: "Self")
        else:
          discard p.expect(tkColon)
          paramType = p.parseType()
        params.add(Param(name: paramName, typ: paramType, span: pSp))
      if p.current().kind == tkComma:
        discard p.advance()
      else:
        break
  discard p.expect(tkRParen)
  discard p.expect(tkArrow)
  let retType = p.parseType()
  discard p.expect(tkColon)
  let body = p.parseDecisionBody()
  return Decl(span: sp, kind: dkFn, name: name, fnParams: params, fnReturnType: retType, fnEffects: @[], fnBody: body, isDecision: true)

# arena Name [size: N]: members — bump allocator (spec 7.3)
proc parseArenaDecl(p: var Parser): Decl =
  let spArena = p.getSpan()
  discard p.advance() # eat "arena"
  let name = p.expect(tkIdent, "Expected arena name").value
  var attrs: seq[TypeAttr]
  p.parseDeclAttrs(attrs)
  discard p.expect(tkColon)
  var members: seq[Decl]
  discard p.expect(tkNewline)
  while p.current().kind == tkNewline:
    discard p.advance()
  discard p.expect(tkIndent)
  while p.current().kind != tkDedent and p.current().kind != tkEOF:
    if p.current().kind == tkNewline:
      discard p.advance()
      continue
    members.add(p.parseDecl())
  discard p.expect(tkDedent)
  let arenaType = Type(span: spArena, kind: tkRecord, fields: @[], attrs: attrs)
  return Decl(span: spArena, kind: dkType, name: name, generics: @[], typeBody: arenaType)

# register Name at 0xADDR: bit fields — type-safe MMIO (spec 8.1)
proc parseRegisterDecl(p: var Parser, sp: Span): Decl =
  discard p.advance() # eat "register"
  let name = p.expect(tkIdent, "Expected register name").value
  discard p.expect(tkIdent) # eat "at"
  let address = p.expect(tkIntLit, "Expected address literal").value
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  discard p.expect(tkIndent)
  var fields: seq[FieldDef]
  while p.current().kind != tkDedent and p.current().kind != tkEOF:
    if p.current().kind == tkNewline:
      discard p.advance()
      continue
    let fSp = p.getSpan()
    let fName = p.expect(tkIdent, "Expected register field name").value
    discard p.expect(tkColon)
    # Parse "bit 0" or "bits 3..7"
    var bitType = ""
    if p.current().kind == tkIdent:
      bitType = p.advance().value
    var bitVal = ""
    if p.current().kind == tkIntLit:
      bitVal = p.advance().value
      if p.current().kind == tkDotDot:
        bitVal.add("..")
        discard p.advance()
        if p.current().kind == tkIntLit:
          bitVal.add(p.current().value)
          discard p.advance()
    # Parse optional attributes [read, write]
    var rAttrs: seq[TypeAttr]
    if p.current().kind == tkLBracket:
      discard p.advance()
      while p.current().kind != tkRBracket and p.current().kind != tkEOF:
        let rAttrSp = p.getSpan()
        let rAttrName = p.expect(tkIdent, "Expected access attribute").value
        rAttrs.add(TypeAttr(name: rAttrName, value: "", span: rAttrSp))
        if p.current().kind == tkComma:
          discard p.advance()
      discard p.expect(tkRBracket)
    let typeName = bitType & " " & bitVal
    fields.add(FieldDef(name: fName, typ: Type(span: fSp, kind: tkNamed, name: typeName), attrs: rAttrs, span: fSp))
    if p.current().kind == tkNewline:
      discard p.advance()
  discard p.expect(tkDedent)
  return Decl(span: sp, kind: dkRegister, name: name, regAddress: address, regFields: fields)

# errors [policy: strict|continue|exit]: on unhandled(...) (spec 4.9)
proc parseErrorsDecl(p: var Parser, sp: Span): Decl =
  discard p.advance() # errors
  discard p.expect(tkLBracket)
  let key = p.expect(tkIdent, "Expected 'policy' in errors declaration").value
  if key != "policy":
    p.reportError("errors declaration takes [policy: strict|continue|exit], got '" & key & "'")
  discard p.expect(tkColon)
  # `continue` is a keyword since the loops ruling — accept it here as a policy name
  let policy = if p.current().kind == tkContinue: p.advance().value
               else: p.expect(tkIdent, "Expected policy name").value
  if policy notin ["strict", "continue", "exit"]:
    p.reportError("Unknown error policy '" & policy & "' — use strict, continue or exit")
  discard p.expect(tkRBracket)
  var handler: Decl = nil
  if p.current().kind == tkColon:
    discard p.advance()
    discard p.expect(tkNewline)
    while p.current().kind == tkNewline:
      discard p.advance()
    discard p.expect(tkIndent)
    while p.current().kind != tkDedent and p.current().kind != tkEOF:
      if p.current().kind == tkNewline:
        discard p.advance()
        continue
      let member = p.parseDecl()
      if member != nil and member.kind == dkFn and member.name == "unhandled":
        handler = member
      else:
        p.reportError("errors block allows only 'on unhandled({code, site})'")
    discard p.expect(tkDedent)
  return Decl(span: sp, kind: dkErrors, name: "errors", policyName: policy, errHandler: handler)

# extern: / extern [c, header: "x.h"]: — sigs implemented by tuck_rt or C
proc parseExternDecl(p: var Parser, sp: Span): Decl =
  discard p.advance() # extern
  var header = ""
  if p.current().kind == tkLBracket:
    discard p.advance()
    while p.current().kind != tkRBracket and p.current().kind != tkEOF:
      let key = p.expect(tkIdent, "Expected 'c' or 'header' in extern attributes").value
      if key == "header":
        discard p.expect(tkColon)
        header = p.expect(tkStrLit, "Expected header path string").value
      # "c" is the target marker; nothing to store
      if p.current().kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBracket)
  let decls = p.parseSigBlock("extern")
  for d in decls:
    d.isExtern = true
    d.externHeader = header
  return Decl(span: sp, kind: dkMixin, name: "extern", mixinMembers: decls)

proc parseDecl*(p: var Parser): Decl =
  let sp = p.getSpan()
  let curr = p.current()

  # extern: / extern [c, header: "uart.h"]: — signatures implemented by the
  # runtime (tuck_rt) or imported from C. No bodies, no stubs.
  if curr.kind == tkIdent and curr.value == "extern" and
     p.peek().kind in {tkColon, tkLBracket}:
    return p.parseExternDecl(sp)

  # Global error policy (spec 4.9): errors [policy: strict|continue|exit]:
  if curr.kind == tkIdent and curr.value == "errors" and p.peek().kind == tkLBracket:
    return p.parseErrorsDecl(sp)

  if curr.kind == tkIdent and curr.value == "register":
    return p.parseRegisterDecl(sp)

  elif curr.kind == tkIdent and curr.value == "pool":
    discard p.advance() # eat "pool"
    let name = p.expect(tkIdent, "Expected pool name").value
    discard p.expect(tkColon)
    let pType = p.parseType()
    return Decl(span: sp, kind: dkType, name: name, generics: @[], typeBody: pType)

  elif curr.kind == tkIdent and curr.value == "arena":
    return p.parseArenaDecl()

  case curr.kind
  of tkDecision:
    return p.parseDecisionDecl(sp)

  of tkFn, tkOn:
    return p.parseFnDecl(sp)

  of tkImport:
    discard p.advance()
    let modName = p.expect(tkIdent, "Expected module name after 'import'").value
    return Decl(span: sp, kind: dkImport, name: modName)

  of tkPending:
    discard p.advance()
    let decls = p.parseSigBlock("pending")
    for d in decls: d.isPending = true
    return Decl(span: sp, kind: dkMixin, name: "pending", mixinMembers: decls)

  of tkType:
    return p.parseTypeDecl(sp)

  of tkObject:
    discard p.advance()
    let name = p.expect(tkIdent, "Expected object name").value
    discard p.expect(tkColon)
    var fields: seq[FieldDef]
    var members: seq[Decl]
    p.parseObjectBody(fields, members)
    return Decl(span: sp, kind: dkObject, name: name, objFields: fields, mixins: @[], objMembers: members)

  of tkActor:
    discard p.advance()
    let name = p.expect(tkIdent, "Expected actor name").value
    var attrs: seq[TypeAttr]
    p.parseDeclAttrs(attrs)
    discard p.expect(tkColon)
    var fields: seq[FieldDef]
    var members: seq[Decl]
    p.parseObjectBody(fields, members)
    return Decl(span: sp, kind: dkActor, name: name, attrs: attrs, actorFields: fields, handlers: members)

  of tkTask:
    return p.parseTaskDecl(sp)

  of tkRegistry:
    return p.parseRegistryDecl(sp)

  of tkStaticAssert:
    discard p.advance()
    let expr = p.parseExpr()
    return Decl(span: sp, kind: dkStaticAssert, assertExpr: expr)

  of tkDistinct:
    discard p.advance()
    let name = p.expect(tkIdent, "Expected distinct type name").value
    discard p.expect(tkAssign)
    let aliasType = p.parseType()
    var attrs = aliasType.attrs  # parseType may have consumed [suffix: ms]
    attrs.add(TypeAttr(name: "distinct", value: "", span: sp))
    p.parseDeclAttrs(attrs)
    aliasType.attrs = attrs
    if p.current().kind == tkNewline:
      discard p.advance()
    return Decl(span: sp, kind: dkType, name: name, generics: @[], typeBody: aliasType)

  of tkMixin, tkInterface:
    discard p.advance()
    let name = p.expect(tkIdent, "Expected mixin name").value
    discard p.expect(tkColon)
    discard p.expect(tkNewline)
    discard p.expect(tkIndent)
    var members: seq[Decl]
    while p.current().kind != tkDedent and p.current().kind != tkEOF:
      if p.current().kind == tkNewline:
        discard p.advance()
      else:
        members.add(p.parseDecl())
    discard p.expect(tkDedent)
    return Decl(span: sp, kind: dkMixin, name: name, mixinMembers: members)

  of tkPlus:
    discard p.advance()
    let name = p.expect(tkIdent, "Expected composition name after '+'").value
    let target = Expr(span: sp, kind: exkVar, name: name)
    let unaryExpr = Expr(span: sp, kind: exkUnary, unaryOp: uoComposition, operand: target)
    return Decl(span: sp, kind: dkExpr, expr: unaryExpr)

  of tkLet, tkVar:
    let expr = p.parseExpr()
    return Decl(span: sp, kind: dkExpr, expr: expr)

  of tkConst:
    # const name = <compile-time data> — a declaration, not a statement
    discard p.advance()
    let name = p.expect(tkIdent, "Expected constant name after 'const'").value
    discard p.expect(tkAssign)
    let valExpr = p.parseExpr()
    return Decl(span: sp, kind: dkConst, name: name, constVal: valExpr)

  else:
    let expr = p.parseExpr()
    return Decl(span: sp, kind: dkExpr, expr: expr)

proc parseModule*(p: var Parser): Module =
  let sp = p.getSpan()
  var decls: seq[Decl]
  while p.current().kind != tkEOF:
    if p.current().kind == tkNewline:
      discard p.advance()
    else:
      decls.add(p.parseDecl())
  result = Module(path: @[], decls: decls, span: sp)
  # identity for the semantic layer, assigned once at the parse boundary
  assignIds(result)
