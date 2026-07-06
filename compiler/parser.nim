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
proc parsePrimaryType(p: var Parser): Type =
  let sp = p.getSpan()
  let curr = p.current()
  if curr.kind == tkBang:
    discard p.advance()
    let inner = p.parseType()
    let bangBase = Type(span: sp, kind: tkNamed, name: "!")
    return Type(span: sp, kind: tkApp, base: bangBase, args: @[inner])
  elif curr.kind == tkQuestion:
    discard p.advance()
    let inner = p.parseType()
    let questBase = Type(span: sp, kind: tkNamed, name: "?")
    return Type(span: sp, kind: tkApp, base: questBase, args: @[inner])
  elif curr.kind == tkBangQuestion:
    discard p.advance()
    let inner = p.parseType()
    let bqBase = Type(span: sp, kind: tkNamed, name: "!?")
    return Type(span: sp, kind: tkApp, base: bqBase, args: @[inner])

  elif curr.kind == tkLParen:
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

  elif curr.kind == tkLBrace:
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
        "io", "unsafe", "may_block", "stack", "priority"])  # effect markers after a return type
      discard p.advance() # eat "["
      if isAttr:
        var tAttrs: seq[TypeAttr]
        while p.current().kind != tkRBracket and p.current().kind != tkEOF:
          let attrSp = p.getSpan()
          let attrName = p.expect(tkIdent, "Expected attribute name").value
          var val = ""
          if p.current().kind == tkColon:
            discard p.advance()
            val = p.parseExpr().toString()
          tAttrs.add(TypeAttr(name: attrName, value: val, span: attrSp))
          if p.current().kind == tkComma:
            discard p.advance()
        discard p.expect(tkRBracket)
        base.attrs = tAttrs
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
proc harvestEffects*(t: Type, effects: var seq[EffectMarker]) =
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
    else: kept.add(a)
  t.attrs = kept
  if t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
     t.base.name in ["!", "?", "!?"]:
    for arg in t.args:
      harvestEffects(arg, effects)

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

proc parsePrimaryExpr(p: var Parser): Expr =
  let sp = p.getSpan()
  let curr = p.current()
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
    else:
      discard p.advance()
      var stmts: seq[Expr]
      while p.current().kind != tkRBrace and p.current().kind != tkEOF:
        stmts.add(p.parseExpr())
        if p.current().kind == tkNewline:
          discard p.advance()
      discard p.expect(tkRBrace)
      return Expr(span: sp, kind: exkBlock, stmts: stmts)
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

proc parseChainExpr(p: var Parser): Expr =
  var expr = p.parsePrimaryExpr()
  
  while true:
    let sp = p.getSpan()
    if p.current().kind == tkDot:
      discard p.advance()
      let fieldName = p.expect(tkIdent, "Expected field name after '.'").value
      expr = Expr(span: sp, kind: exkField, receiver: expr, fieldName: fieldName)
      # Type.Variant [unsafe] — escape hatch for sealed construction (spec 4.4)
      if p.current().kind == tkLBracket and p.peek(1).kind == tkIdent and
         p.peek(1).value == "unsafe" and p.peek(2).kind == tkRBracket:
        discard p.advance()  # [
        discard p.advance()  # unsafe
        discard p.advance()  # ]
        expr.ctorUnsafe = true
    elif p.current().kind == tkDotDot:
      discard p.advance()
      let fieldName = p.expect(tkIdent, "Expected builder field name after '..'").value
      var arg: Expr = nil
      if p.current().kind == tkLBrace:
        arg = p.parsePrimaryExpr()
      var steps: seq[ChainStep]
      steps.add(ChainStep(op: coDotDot, target: Expr(span: sp, kind: exkVar, name: fieldName), arg: arg, span: sp))
      expr = Expr(span: sp, kind: exkChain, base: expr, steps: steps)
    elif p.current().kind == tkQuestion:
      discard p.advance()
      expr = Expr(span: sp, kind: exkUnary, unaryOp: uoPropagate, operand: expr)
    elif p.current().kind == tkColonColon:
      discard p.advance()
      let name = p.expect(tkIdent, "Expected identifier after '::'").value
      let moduleName = if expr.kind == exkVar: expr.name else: ""
      expr = Expr(span: sp, kind: exkQualified, modulePath: @[moduleName], qualName: name)
    elif p.current().kind == tkBake:
      discard p.advance()
      let arg = p.parsePrimaryExpr()
      let calleeExpr = Expr(span: sp, kind: exkVar, name: "bake")
      expr = Expr(span: sp, kind: exkCall, callee: calleeExpr, args: @[expr, arg])
    elif p.current().kind == tkLParen:
      discard p.advance()
      var args: seq[Expr]
      while p.current().kind != tkRParen and p.current().kind != tkEOF:
        args.add(p.parseExpr())
        if p.current().kind == tkComma:
          discard p.advance()
      discard p.expect(tkRParen)
      expr = Expr(span: sp, kind: exkCall, callee: expr, args: args)
    elif p.current().kind == tkLBrace:
      let arg = p.parsePrimaryExpr()
      expr = Expr(span: sp, kind: exkCall, callee: expr, args: @[arg])
    elif p.current().kind == tkIdent and p.current().value == "alias" and p.peek().kind == tkLParen:
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
      expr = Expr(span: spAlias, kind: exkCall, callee: calleeExpr, args: @[expr, structExpr])
    elif p.current().kind == tkIdent and not (p.current().value in ["or", "and", "in", "invariant", "transitions"]):
      if p.peek().kind == tkColonColon:
        let moduleName = p.advance().value
        discard p.expect(tkColonColon)
        let name = p.expect(tkIdent, "Expected identifier after '::'").value
        let calleeExpr = Expr(span: sp, kind: exkQualified, modulePath: @[moduleName], qualName: name)
        expr = Expr(span: sp, kind: exkCall, callee: calleeExpr, args: @[expr])
      else:
        let callee = p.advance().value
        let calleeExpr = Expr(span: sp, kind: exkVar, name: callee)
        expr = Expr(span: sp, kind: exkCall, callee: calleeExpr, args: @[expr])
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
      let body = p.parseExpr()
      arms.add(MatchArm(pattern: pat, guard: nil, body: body, span: p.getSpan()))
      if p.current().kind == tkNewline:
        discard p.advance()
    discard p.expect(tkDedent)
    return Expr(span: sp, kind: exkMatch, subject: subject, arms: arms)

  elif curr.kind == tkFor:
    discard p.advance()
    let iter = p.parsePattern()
    discard p.expect(tkIn)
    let iterable = p.parseExpr()
    discard p.expect(tkColon)
    let body = p.parseBlock()
    return Expr(span: sp, kind: exkFor, iter: iter, iterable: iterable, body: body)

  let left = p.parseBinaryExpr(-2)
  if p.current().kind == tkAssign:
    discard p.advance()
    let right = p.parseExpr()
    return Expr(span: sp, kind: exkAssign, target: left, assignVal: right)
  elif p.current().kind == tkPlusAssign:
    discard p.advance()
    let right = p.parseExpr()
    return Expr(span: sp, kind: exkAssign, target: left, assignVal: Expr(span: sp, kind: exkBinary, binOp: boAdd, left: left, right: right))
  elif p.current().kind == tkMinusAssign:
    discard p.advance()
    let right = p.parseExpr()
    return Expr(span: sp, kind: exkAssign, target: left, assignVal: Expr(span: sp, kind: exkBinary, binOp: boSub, left: left, right: right))
  elif p.current().kind == tkStarAssign:
    discard p.advance()
    let right = p.parseExpr()
    return Expr(span: sp, kind: exkAssign, target: left, assignVal: Expr(span: sp, kind: exkBinary, binOp: boMul, left: left, right: right))
  elif p.current().kind == tkSlashAssign:
    discard p.advance()
    let right = p.parseExpr()
    return Expr(span: sp, kind: exkAssign, target: left, assignVal: Expr(span: sp, kind: exkBinary, binOp: boDiv, left: left, right: right))
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
      let fSp = p.getSpan()
      discard p.advance()
      discard p.expect(tkColon)
      let expr = p.parseExpr()
      members.add(Decl(span: fSp, kind: dkExpr, expr: expr))
      if p.current().kind == tkNewline:
        discard p.advance()
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

proc parseDecl*(p: var Parser): Decl =
  let sp = p.getSpan()
  let curr = p.current()
  
  if curr.kind == tkIdent and curr.value == "register":
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

  elif curr.kind == tkIdent and curr.value == "pool":
    discard p.advance() # eat "pool"
    let name = p.expect(tkIdent, "Expected pool name").value
    discard p.expect(tkColon)
    let pType = p.parseType()
    return Decl(span: sp, kind: dkType, name: name, generics: @[], typeBody: pType)

  elif curr.kind == tkIdent and curr.value == "arena":
    let spArena = p.getSpan()
    discard p.advance() # eat "arena"
    let name = p.expect(tkIdent, "Expected arena name").value
    var attrs: seq[TypeAttr]
    if p.current().kind == tkLBracket:
      discard p.advance()
      while p.current().kind != tkRBracket and p.current().kind != tkEOF:
        let attrSp = p.getSpan()
        let attrName = p.expect(tkIdent, "Expected attribute name").value
        var val = ""
        if p.current().kind == tkColon:
          discard p.advance()
          val = p.parseExpr().toString()
        attrs.add(TypeAttr(name: attrName, value: val, span: attrSp))
        if p.current().kind == tkComma:
          discard p.advance()
      discard p.expect(tkRBracket)
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

  case curr.kind
  of tkDecision:
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

  of tkFn, tkOn:
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
    var name = p.expect(tkIdent, "Expected function or event name").value
    while p.current().kind == tkDot:
      discard p.advance()
      name.add("." & p.expect(tkIdent, "Expected qualified name component").value)
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
    harvestEffects(retType, effects)
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
    var body: Expr = nil
    if p.current().kind == tkColon:
      discard p.advance()
      body = p.parseBlock()
    return Decl(span: sp, kind: dkFn, name: name, fnParams: params, fnReturnType: retType, fnEffects: effects, fnBody: body)

  of tkPending:
    discard p.advance()
    discard p.expect(tkColon)
    discard p.expect(tkNewline)
    while p.current().kind == tkNewline:
      discard p.advance()
    discard p.expect(tkIndent)
    var decls: seq[Decl]
    while p.current().kind != tkDedent and p.current().kind != tkEOF:
      if p.current().kind == tkNewline:
        discard p.advance()
        continue
      let spDecl = p.getSpan()
      discard p.expect(tkFn)
      let name = p.expect(tkIdent, "Expected function name in pending declaration").value
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
      var pendEffects: seq[EffectMarker]
      if p.current().kind == tkLBracket:
        discard p.advance()
        while p.current().kind != tkRBracket and p.current().kind != tkEOF:
          let effName = p.expect(tkIdent, "Expected effect marker").value
          case effName
          of "io": pendEffects.add(emIo)
          of "no_alloc": pendEffects.add(emNoAlloc)
          of "irq_safe": pendEffects.add(emIrqSafe)
          of "unsafe": pendEffects.add(emUnsafe)
          of "may_block": pendEffects.add(emMayBlock)
          of "stack": pendEffects.add(emStack)
          of "priority": pendEffects.add(emPriority)
          else: discard
          if p.current().kind == tkComma:
            discard p.advance()
        discard p.expect(tkRBracket)
      decls.add(Decl(span: spDecl, kind: dkFn, name: name, fnParams: params, fnReturnType: retType, fnEffects: pendEffects, fnBody: nil, isPending: true))
      if p.current().kind == tkNewline:
        discard p.advance()
    discard p.expect(tkDedent)
    return Decl(span: sp, kind: dkMixin, name: "pending", mixinMembers: decls)

  of tkType:
    discard p.advance()
    let name = p.expect(tkIdent, "Expected type name").value
    var attrs: seq[TypeAttr]
    if p.current().kind == tkLBracket:
      discard p.advance()
      while p.current().kind != tkRBracket and p.current().kind != tkEOF:
        let attrSp = p.getSpan()
        let attrName = p.expect(tkIdent, "Expected attribute name").value
        var val = ""
        if p.current().kind == tkColon:
          discard p.advance()
          val = p.parseExpr().toString()
        attrs.add(TypeAttr(name: attrName, value: val, span: attrSp))
        if p.current().kind == tkComma:
          discard p.advance()
      discard p.expect(tkRBracket)
    if p.current().kind == tkAssign:
      discard p.advance()
      let aliasType = p.parseType()
      if p.current().kind == tkNewline:
        discard p.advance()
      aliasType.attrs = attrs
      return Decl(span: sp, kind: dkType, name: name, generics: @[], typeBody: aliasType)
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
        let fSp = p.getSpan()
        discard p.advance()
        discard p.expect(tkColon)
        let expr = p.parseExpr()
        members.add(Decl(span: fSp, kind: dkExpr, expr: expr))
        if p.current().kind == tkNewline:
          discard p.advance()
          
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
      
    return Decl(span: sp, kind: dkType, name: name, generics: @[], typeBody: bodyType, typeMembers: members)

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
    if p.current().kind == tkLBracket:
      discard p.advance()
      while p.current().kind != tkRBracket and p.current().kind != tkEOF:
        let attrSp = p.getSpan()
        let attrName = p.expect(tkIdent, "Expected attribute name").value
        var val = ""
        if p.current().kind == tkColon:
          discard p.advance()
          val = p.parseExpr().toString()
        attrs.add(TypeAttr(name: attrName, value: val, span: attrSp))
        if p.current().kind == tkComma:
          discard p.advance()
      discard p.expect(tkRBracket)
    discard p.expect(tkColon)
    var fields: seq[FieldDef]
    var members: seq[Decl]
    p.parseObjectBody(fields, members)
    return Decl(span: sp, kind: dkActor, name: name, attrs: attrs, actorFields: fields, handlers: members)

  of tkTask:
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
    harvestEffects(retType, effects)
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

  of tkRegistry:
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

  of tkStaticAssert:
    discard p.advance()
    let expr = p.parseExpr()
    return Decl(span: sp, kind: dkStaticAssert, assertExpr: expr)

  of tkDistinct:
    discard p.advance()
    let name = p.expect(tkIdent, "Expected distinct type name").value
    discard p.expect(tkAssign)
    let aliasType = p.parseType()
    var attrs: seq[TypeAttr]
    attrs.add(TypeAttr(name: "distinct", value: "", span: sp))
    if p.current().kind == tkLBracket:
      discard p.advance()
      while p.current().kind != tkRBracket and p.current().kind != tkEOF:
        let attrSp = p.getSpan()
        let attrName = p.expect(tkIdent, "Expected attribute name").value
        var val = ""
        if p.current().kind == tkColon:
          discard p.advance()
          val = p.parseExpr().toString()
        attrs.add(TypeAttr(name: attrName, value: val, span: attrSp))
        if p.current().kind == tkComma:
          discard p.advance()
      discard p.expect(tkRBracket)
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
  return Module(path: @[], decls: decls, span: sp)
