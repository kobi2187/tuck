# compiler/parser_expr.nim
#
# Expression + pattern parsing: the cohesive, mutually-recursive core
# (parseExpr <-> parseChainExpr <-> parsePattern <-> parseBlock and friends).
# This recursion is real cohesion, so it lives in one module. Depends only on
# parser_base (Parser state + token accessors) — it calls neither parseType nor
# parseDecl, which is what lets it sit at the bottom of the parser DAG.
import strutils, tables
import ast
import ../lexer
import parser_base

# internal mutual recursion within the expression grammar
proc parseExpr*(p: var Parser): Expr
proc parseChainExpr(p: var Parser): Expr
proc parsePattern*(p: var Parser): Pattern
proc parseBlock*(p: var Parser): Expr

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
    let operand = p.parseChainExpr()
    return Expr(span: sp, kind: exkUnary, unaryOp: uoNeg, operand: operand)
  if curr.kind == tkNot:
    discard p.advance()
    let operand = p.parseChainExpr()
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
    elif p.current().kind == tkIdent and p.current().value == "send" and
         expr.kind == exkVar and p.peek().kind == tkIdent:
      # `ActorType send handler {payload}` — direct send to an actor singleton.
      # The brace is the handler's message payload (optional for a no-arg on).
      discard p.advance()                    # eat `send`
      let handler = p.expect(tkIdent, "Expected handler name after 'send'").value
      var payload: Expr = nil
      if p.current().kind == tkLBrace:
        payload = p.parsePrimaryExpr()
      expr = Expr(span: sp, kind: exkSend, sendActor: expr.name,
                  sendHandler: handler, sendPayload: payload)
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
  # task-body `on select:` (spec §9.3) — direct exkSelect node. Each arm is
  # `| <source> <arg> -> {bind}: body`; source is `read <fd>` (wait readable)
  # or `timeout <ms>` (deadline). Replaces the old exkMatch-fake-subject hack.
  let sp = p.getSpan()
  discard p.expect(tkOn)
  discard p.expect(tkSelect)
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  discard p.expect(tkIndent)
  var arms: seq[SelectArm]
  while p.current().kind != tkDedent and p.current().kind != tkEOF:
    if p.current().kind == tkNewline:
      discard p.advance()
      continue
    let armSp = p.getSpan()
    discard p.expect(tkPipe)
    var source = p.expect(tkIdent, "Expected a select source").value
    # dotted sources (`resp.ok`, `timeout.5s`) — consume `.<part>` runs into an
    # opaque source string (given meaning later). `read`/`timeout` stay bare and
    # carry an arg.
    while p.current().kind == tkDot:
      source.add(p.advance().value)                    # the dot
      if p.current().kind in {tkIdent, tkIntLit}:
        source.add(p.advance().value)
    # the source's argument: fd for read, ms for timeout (a primary expr)
    var arg: Expr = nil
    if p.current().kind != tkArrow and p.current().kind != tkColon:
      arg = p.parsePrimaryExpr()
    discard p.expect(tkArrow)
    var binding: seq[Param]
    if p.current().kind == tkLBrace:
      discard p.advance()
      while p.current().kind != tkRBrace and p.current().kind != tkEOF:
        let bn = p.expect(tkIdent, "Expected binding name").value
        binding.add(Param(name: bn, typ: nil, span: armSp))
        if p.current().kind == tkComma: discard p.advance()
      discard p.expect(tkRBrace)
    discard p.expect(tkColon)
    let body = p.parseExpr()
    arms.add(SelectArm(source: source, arg: arg, binding: binding,
                       body: body, span: armSp))
    if p.current().kind == tkNewline:
      discard p.advance()
  discard p.expect(tkDedent)
  return Expr(span: sp, kind: exkSelect, selArms: arms)

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

