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
      let name = p.expectMemberName("Expected field name in pattern").value
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
  # tkAttr as well as tkIdent: a reserved attribute name is still a legal
  # FIELD name — `{priority: Priority}` — because a field position can never
  # hold an attribute. Reserved-ness is decided by position, not by the word.
  if first.kind in {tkIdent, tkAttr}:
    if second.kind in {tkColon, tkComma, tkRBrace}:
      return true
  return false

# {a: 1, b} — struct literal; a bare name is shorthand for name: name
proc parseStructLiteral(p: var Parser, sp: Span): Expr =
  discard p.advance()
  var fields: seq[FieldInit]
  while p.current().kind != tkRBrace and p.current().kind != tkEOF:
    let name = p.expectMemberName("Expected field name in struct literal").value
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
    p.reportError("Expected an expression here, found " & describe(curr))

# Type.Variant [unsafe] — deserialization escape hatch for sealed construction
# (spec 4.4). Consumes the marker and reports whether it was present.
proc tryUnsafeMarker(p: var Parser): bool =
  # `unsafe` is a reserved bare marker (tkAttr), so the kind check is the
  # value check — no identifier could reach here spelled `unsafe`.
  if p.current().kind == tkLBracket and p.peek(1).kind == tkAttr and
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
  var fields: seq[FieldInit]
  while p.current().kind != tkRParen and p.current().kind != tkEOF:
    let name = p.expectMemberName("Expected field name in alias").value
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
    let fname = p.expectMemberName("Expected name after '.'").value
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

const NonCallIdents = ["or", "and", "in", "invariant", "transitions"]
  ## Idents that continue an ENCLOSING construct rather than calling the
  ## expression to their left, so a chain must stop before them.

const ParenBuiltins = ["sizeof", "alignof", "offsetof"]
  ## Compile-time builtins (spec 8.2) keep parens; everything else is postfix.

proc chainField(p: var Parser, expr: Expr, sp: Span): Expr =
  ## `.name`, and `.fn {args}` — the method form, where the receiver is the
  ## fn's first parameter and the braced struct fills the rest.
  discard p.advance()
  let fieldName = p.expectMemberName("Expected field name after '.'").value
  result = Expr(span: sp, kind: exkField, receiver: expr, fieldName: fieldName)
  if p.tryUnsafeMarker(): result.ctorUnsafe = true
  if p.current().kind == tkLBrace: result.dotArg = p.parsePrimaryExpr()

proc chainMutation(p: var Parser, expr: Expr, sp: Span): Expr =
  ## `..name {value}` — a builder step. Steps accumulate on ONE chain node,
  ## because every `..` in the chain mutates the same base var.
  discard p.advance()
  let fieldName = p.expect(tkIdent,
                           "Expected builder field name after '..'").value
  var arg: Expr = nil
  if p.current().kind == tkLBrace: arg = p.parsePrimaryExpr()
  let step = ChainStep(op: coDotDot, arg: arg, span: sp,
                       target: Expr(span: sp, kind: exkVar, name: fieldName))
  if expr.kind == exkChain:
    expr.steps.add(step)
    return expr
  Expr(span: sp, kind: exkChain, base: expr, steps: @[step])

proc chainQualified(p: var Parser, expr: Expr, sp: Span): Expr =
  ## `module::name`.
  discard p.advance()
  let name = p.expect(tkIdent, "Expected identifier after '::'").value
  let moduleName = if expr.kind == exkVar: expr.name else: ""
  Expr(span: sp, kind: exkQualified, modulePath: @[moduleName], qualName: name)

proc skipEffectAnnotation(p: var Parser) =
  ## A trailing bare-marker bracket on a call — `uart.flush {buf} [io]`. An
  ## effect ANNOTATION on the statement, not part of the expression, so it is
  ## consumed and dropped rather than ending the chain. Only a reserved marker
  ## qualifies; `xs [1, 2]` is still a separate list literal, and `xs[i]` is
  ## still indexing.
  discard p.advance()  # [
  discard p.advance()  # marker
  discard p.advance()  # ]

proc parseCommaList(p: var Parser, closer: TokenKind): seq[Expr] =
  ## Comma-separated expressions up to `closer`, which is consumed.
  while p.current().kind != closer and p.current().kind != tkEOF:
    result.add(p.parseExpr())
    if p.current().kind == tkComma: discard p.advance()
  discard p.expect(closer)

proc chainBracket(p: var Parser, expr: Expr, sp: Span): Expr =
  ## `recv[a, b, ...]` — the argument sits after the callee, like every other
  ## postfix continuation. One arg on a value is an index; a declared type
  ## receiver is a type application. The checker decides; chaining
  ## (`grid[i][j]`) falls out of the loop.
  discard p.advance()
  Expr(span: sp, kind: exkBracket, brReceiver: expr,
       brArgs: p.parseCommaList(tkRBracket))

proc chainBake(p: var Parser, expr: Expr, sp: Span): Expr =
  discard p.advance()
  let arg = p.parsePrimaryExpr()
  Expr(span: sp, kind: exkCall, args: @[expr, arg],
       callee: Expr(span: sp, kind: exkVar, name: "bake"))

proc chainBuiltinCall(p: var Parser, expr: Expr, sp: Span): Expr =
  discard p.advance()
  Expr(span: sp, kind: exkCall, callee: expr,
       args: p.parseCommaList(tkRParen))

proc chainSend(p: var Parser, expr: Expr, sp: Span): Expr =
  ## `ActorType send handler {payload}` — a direct send to an actor
  ## singleton. The brace is the handler's message payload, optional for a
  ## no-arg `on`.
  discard p.advance()                    # eat `send`
  let handler = p.expectMemberName("Expected handler name after 'send'").value
  var payload: Expr = nil
  if p.current().kind == tkLBrace: payload = p.parsePrimaryExpr()
  Expr(span: sp, kind: exkSend, sendActor: expr.name, sendHandler: handler,
       sendPayload: payload)

proc isSendStep(p: Parser, expr: Expr): bool =
  p.current().kind == tkIdent and p.current().value == "send" and
    expr.kind == exkVar and p.peek().kind == tkIdent

proc isAliasStep(p: Parser): bool =
  p.current().kind == tkIdent and p.current().value == "alias" and
    p.peek().kind == tkLParen

proc isBuiltinCall(p: Parser, expr: Expr): bool =
  p.current().kind == tkLParen and expr.kind == exkVar and
    expr.name in ParenBuiltins

proc isEffectAnnotation(p: Parser): bool =
  p.current().kind == tkLBracket and p.peek(1).kind == tkAttr and
    p.peek(2).kind == tkRBracket

proc chainStep(p: var Parser, expr: Expr, sp: Span, done: var bool): Expr =
  ## One postfix continuation. `done` is set when nothing continues the chain,
  ## which is what ends the loop.
  done = false
  case p.current().kind
  of tkDot: return p.chainField(expr, sp)
  of tkDotDot: return p.chainMutation(expr, sp)
  of tkColonColon: return p.chainQualified(expr, sp)
  of tkBake: return p.chainBake(expr, sp)
  of tkLBrace: return Expr(span: sp, kind: exkCall, callee: expr,
                           args: @[p.parsePrimaryExpr()])
  of tkLBracket:
    if p.isEffectAnnotation():
      p.skipEffectAnnotation()
      return expr
    if p.bracketIsTight(): return p.chainBracket(expr, sp)
  of tkLParen:
    if p.isBuiltinCall(expr): return p.chainBuiltinCall(expr, sp)
    p.reportError("Function calls are postfix in Tuck: write {payload} " &
                  "fnName, not fnName(args)")
  of tkIdent:
    if p.isSendStep(expr): return p.chainSend(expr, sp)
    if p.isAliasStep(): return p.parseAliasStep(expr)
    if p.current().value notin NonCallIdents:
      return p.parsePostfixCall(expr, sp)
  else: discard
  done = true
  expr

proc parseChainExpr(p: var Parser): Expr =
  ## A primary expression followed by any number of postfix continuations —
  ## field access, builder mutation, indexing, a call, a send.
  result = p.parsePrimaryExpr()
  var done = false
  while not done:
    result = p.chainStep(result, p.getSpan(), done)

proc parseBinaryExpr(p: var Parser, minPrecedence = 0): Expr =
  var left = p.parseChainExpr()
  
  let opPrecedences = {
    tkPlus: (1, boAdd), tkMinus: (1, boSub),
    tkStar: (2, boMul), tkPercent: (2, boMod),
    tkSlashInt: (2, boDivInt), tkSlashFloat: (2, boDivFloat),
    tkEq: (0, boEq), tkNeq: (0, boNeq),
    tkLt: (0, boLt), tkGt: (0, boGt), tkLte: (0, boLe), tkGte: (0, boGe),
    tkAnd: (-1, boAnd), tkOr: (-1, boOr),
    tkRange: (-2, boRangeIncl), tkRangeLt: (-2, boRangeExcl),
  }.toTable()
  
  while true:
    let currKind = p.current().kind
    # A bare `/` is not an operator (R1). Caught here rather than left to
    # "unexpected token", because the fix is a specific one the message can
    # name — and silently treating it as a float divide is the exact failure
    # the ruling exists to prevent.
    if currKind in {tkSlash, tkSlashAssign}:
      p.reportError("`/` is not an operator in Tuck — write `/i` for integer " &
        "division (truncating) or `/f` for float division. The operator names " &
        "the arithmetic so the result cannot depend on how the operands were " &
        "inferred." &
        (if currKind == tkSlashAssign: " Same for `/=`: use `/i=` or `/f=`."
         else: ""))
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

proc parseBinding(p: var Parser, sp: Span, mutable: bool): Expr =
  ## `let name = value` / `var name = value`.
  discard p.advance()
  let name = p.expect(tkIdent, "Expected variable name").value
  discard p.expect(tkAssign)
  Expr(span: sp, kind: exkAssign, assignVal: p.parseExpr(), isDecl: true,
       isMutable: mutable, target: Expr(span: sp, kind: exkVar, name: name))

proc parseElseBranch(p: var Parser): Expr =
  ## `elif C: B` is sugar for `else: (if C: B)` — the nested if lands in
  ## elseBranch, so nothing downstream (checker, codegen) needs to know it was
  ## written as an elif. Recursion handles chains of any length plus a
  ## trailing `else`.
  if p.current().kind == tkElif: return p.parseExpr()
  if p.current().kind != tkElse: return nil
  discard p.advance()
  discard p.expect(tkColon)
  p.parseBlock()

proc parseIfExpr(p: var Parser, sp: Span): Expr =
  discard p.advance()
  let cond = p.parseExpr()
  discard p.expect(tkColon)
  let thenBranch = p.parseBlock()
  Expr(span: sp, kind: exkIf, cond: cond, thenBranch: thenBranch,
       elseBranch: p.parseElseBranch())

proc parseReturnExpr(p: var Parser, sp: Span): Expr =
  ## A bare `return` ends the line; anything else is the returned value.
  discard p.advance()
  let val = if p.current().kind in {tkNewline, tkDedent}: nil
            else: p.parseExpr()
  Expr(span: sp, kind: exkReturn, returnVal: val)

proc parseMatchArm(p: var Parser): MatchArm =
  ## `| Pat -> body` and `Pat: body` are the same arm. The arrow form matches
  ## decision tables and select arms, so one shape reads across every
  ## construct that dispatches on a pattern.
  let arrowForm = p.current().kind == tkPipe
  if arrowForm: discard p.advance()
  let pat = p.parsePattern()
  if arrowForm: discard p.expect(tkArrow) else: discard p.expect(tkColon)
  # arm body: a single expression on the same line, or an indented block
  let body = if p.current().kind == tkNewline: p.parseBlock()
             else: p.parseExpr()
  result = MatchArm(pattern: pat, guard: nil, body: body, span: p.getSpan())
  if p.current().kind == tkNewline: discard p.advance()

proc parseMatchExpr(p: var Parser, sp: Span): Expr =
  discard p.advance()
  let subject = p.parseExpr()
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  var arms: seq[MatchArm]
  p.indentedBlock:
    arms.add(p.parseMatchArm())
  Expr(span: sp, kind: exkMatch, subject: subject, arms: arms)

proc isIterationForm(p: Parser): bool =
  ## `for` iterates iff the lookahead is `ident in` or `ident, ident in`;
  ## anything else after `for` is a while-style condition expression.
  p.current().kind == tkIdent and
    (p.peek(1).kind == tkIn or
     (p.peek(1).kind == tkComma and p.peek(2).kind == tkIdent and
      p.peek(3).kind == tkIn))

proc parseLoopVars(p: var Parser): Pattern =
  ## One binding, or `idx, item` as a tuple pattern.
  let first = p.parsePattern()
  if p.current().kind != tkComma: return first
  discard p.advance()
  let second = p.parsePattern()
  Pattern(span: first.span, kind: pkTuple, elems: @[first, second])

proc parseForExpr(p: var Parser, sp: Span): Expr =
  discard p.advance()
  if not p.isIterationForm():
    let cond = p.parseExpr()
    discard p.expect(tkColon)
    return Expr(span: sp, kind: exkWhile, whileCond: cond,
                whileBody: p.parseBlock())
  let iter = p.parseLoopVars()
  discard p.expect(tkIn)
  let iterable = p.parseExpr()
  discard p.expect(tkColon)
  Expr(span: sp, kind: exkFor, iter: iter, iterable: iterable,
       body: p.parseBlock())

proc parseLoopExpr(p: var Parser, sp: Span): Expr =
  ## `loop:` — a while with no condition.
  discard p.advance()
  discard p.expect(tkColon)
  Expr(span: sp, kind: exkWhile, whileCond: nil, whileBody: p.parseBlock())

proc parseExpr*(p: var Parser): Expr =
  let sp = p.getSpan()
  let curr = p.current()
  if curr.kind == tkOn and p.peek().kind == tkSelect:
    return p.parseSelectExpr()

  case curr.kind
  of tkLet, tkVar: return p.parseBinding(sp, mutable = curr.kind == tkVar)
  of tkIf, tkElif: return p.parseIfExpr(sp)
  of tkReturn: return p.parseReturnExpr(sp)
  of tkMatch: return p.parseMatchExpr(sp)
  of tkFor: return p.parseForExpr(sp)
  of tkLoop: return p.parseLoopExpr(sp)
  of tkBreak:
    discard p.advance()
    return Expr(span: sp, kind: exkBreak)
  of tkContinue:
    discard p.advance()
    return Expr(span: sp, kind: exkContinue)
  else: discard

  let left = p.parseBinaryExpr(-2)
  # `=` and the compound forms differ only in the operator folded into the
  # value, so they share one path — that keeps the bracket rewrite (setAt,
  # not assign-to-a-place) in a single spot instead of five.
  const compoundOps = {tkPlusAssign: boAdd, tkMinusAssign: boSub,
                       tkStarAssign: boMul,
                       tkSlashIntAssign: boDivInt,
                       tkSlashFloatAssign: boDivFloat}.toTable()
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
  ## An indented block, OR — when the body continues on the same line — a
  ## single expression (ruling R2/R3: `let x = if c: 1 else: 2`). Returning
  ## the bare expression rather than wrapping it in a one-statement block
  ## keeps the value obvious to the checker and both emitters.
  let sp = p.getSpan()
  if p.current().kind notin {tkNewline, tkEOF}:
    return p.parseExpr()
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

