# compiler/parser_expr.nim
#
# Expression + pattern parsing: the cohesive, mutually-recursive core
# (parseExpr <-> parseChainExpr <-> parsePattern <-> parseBlock and friends).
# This recursion is real cohesion, so it lives in one module. Depends only on
# parser_base (Parser state + token accessors) — it calls neither parseType nor
# parseDecl, which is what lets it sit at the bottom of the parser DAG.
import tables, sets
import ast
import ast_ops
import ../lexer
import parser_base
import diagnostics
from parser_stringify import opStr

# internal mutual recursion within the expression grammar
proc parseExpr*(p: var Parser): Expr
proc parseChainExpr(p: var Parser): Expr
proc parsePattern*(p: var Parser): Pattern
proc parseBlock*(p: var Parser): Expr
proc parseStatementExpr(p: var Parser): Expr

proc parseRecordPattern(p: var Parser, sp: Span): Pattern =
  ## Parses a record pattern: `{field: pat, ...}`
  ## A bare field name is shorthand for binding the field to that name.
  discard p.advance()
  var fields: seq[(string, Pattern)]
  while p.current().kind != tkRBrace and p.current().kind != tkEOF:
    let name = p.expectName("Expected field name in pattern").value
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

proc parseIdentPattern(p: var Parser, sp: Span): Pattern =
  ## Parses an identifier pattern with optional dot-separated path
  ## `Enum.Tag`, `Error.code` and a literal tail like `timeout.5s` all read as
  ## one dotted name, left for the checker to resolve.
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

proc parsePattern*(p: var Parser): Pattern =
  ## One match pattern: `_`, a (dotted) name, a literal, a record pattern, or
  ## a parenthesised tuple of patterns.
  let sp = p.getSpan()
  let curr = p.current()

  if curr.kind == tkIdent and curr.value == "_":
    discard p.advance()
    return Pattern(span: sp, kind: pkWild)
  elif curr.kind == tkIdent:
    return p.parseIdentPattern(sp)
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
    return p.parseRecordPattern(sp)
  else:
    p.reportError("Unexpected pattern syntax: " & $curr.kind)

proc isStructLiteral(p: Parser): bool =
  ## Does the `{` under the cursor open a struct literal (`{}`, `{a: …}`,
  ## `{a, b}`) rather than a brace block? Decided by the two tokens after it.
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

proc exprName(e: Expr): string =
  ## A short spelling of the expression a message is about — the name when it
  ## is one, else a placeholder, since this only ever reports on a chain base.
  if e != nil and e.kind == exkVar: e.name
  elif e != nil and e.kind == exkField: e.fieldName
  else: "that"

proc nestedPayloadCall(e: Expr): Expr =
  ## A field whose VALUE IS a payload call — the shape `{...} fn` sitting
  ## directly where a value belongs. Returns that call, or nil.
  ##
  ## DIRECTLY, not at any depth. A construction inside a list inside a payload
  ## (`{ps: [{n: 1} P]}`) is a list of values and reads as one; walking into
  ## every child refused it too, along with 18 assertions across six suites.
  ## The shape worth refusing is the one where the field value itself is an
  ## application, because that is where a `let` adds a name and a place.
  ##
  ## A nested record LITERAL is not one either: `{point: {x: 1, y: 2}} Thing`
  ## holds a value, not an application.
  if e == nil: return nil
  if e.kind == exkCall and e.args.len == 1 and e.args[0] != nil and
     e.args[0].kind == exkStruct:
    return e
  nil

proc failIfCallInPayload(p: Parser, value: Expr) =
  ## A payload field holds a VALUE. A call nested inside one goes to a `let`
  ## first, so it has a name and a place.
  ##
  ## This is not only a readability rule. The in-place append is SYNTACTIC —
  ## `xs = {items: xs, ...} push` appends in place, and the same call nested
  ## inside a construction does not — so alloc.string's Builder shipped
  ## quadratic from one nested spelling. Under this rule that line does not
  ## parse.
  let bad = nestedPayloadCall(value)
  if bad == nil: return
  p.reportError("a call inside a payload — bind it to a `let` first, then " &
                "use the name here", bad.span.line, bad.span.col,
                dcPaCallInPayload)

proc failIfChainAfterPayloadCall(p: Parser, called: Expr) =
  ## `{x: expr} f.someField` — the sibling rule to failIfCallInPayload, in
  ## the opposite direction: not a call NESTED inside a payload, but a chain
  ## continuing STRAIGHT OUT of one. `{payload} fnName` is meant to read as
  ## a complete application, same as TK-PA13 means a payload field to hold
  ## only a value — nothing chains directly off its result; bind it first.
  ##
  ## Not just style: this shape used to reach the checker as one expression
  ## and skip verifying the call's OWN arguments against its declared
  ## params entirely — found spiking the `group` feature, reproduced with
  ## an ordinary non-generic call (`{x: "not an int"} takesInt.len` passed
  ## where `takesInt` declares `x: int`). Refusing the shape at parse time
  ## removes the gap instead of patching whatever let it through.
  ## Narrowed to `..` only: a `.` immediately after the call is now always
  ## consumed upstream (parsePostfixCall's own dotted-callee loop), ambiguous
  ## between a qualified constructor, a slot call, and a genuine chain onto
  ## a call's result — see typecheck.nim's failIfChainAfterPayloadCall for
  ## where that disambiguation, needing name resolution, actually happens.
  ## `..` has no such ambiguity: a builder-mutation chain never continues a
  ## qualified name or a slot call, so this stays a parse-time rejection.
  if called == nil or called.kind != exkCall or called.args.len != 1 or
     called.args[0] == nil or called.args[0].kind != exkStruct: return
  if p.current().kind != tkDotDot: return
  p.reportError("a builder chain after `{payload} " & exprName(called.callee) &
                "` — bind it to a `let` first, then chain from the name",
                called.span.line, called.span.col,
                dcPaChainAfterPayloadCall)

proc parseStructLiteral(p: var Parser, sp: Span): Expr =
  ## {a: 1, b} — struct literal; a bare name is shorthand for name: name
  ## Fields may be separated by commas or line breaks.
  discard p.advance()
  var fields: seq[FieldInit]
  while true:
    p.skipSeparators()
    if p.current().kind == tkRBrace or p.current().kind == tkEOF: break
    let name = p.expectName("Expected field name in struct literal").value
    var valExpr: Expr
    if p.current().kind == tkColon:
      discard p.advance()
      valExpr = p.parseExpr()
      p.failIfCallInPayload(valExpr)
    else:
      valExpr = Expr(span: sp, kind: exkVar, name: name)
    fields.add((name, valExpr))
    p.skipSeparators()
    if p.current().kind == tkComma:
      discard p.advance()
  discard p.expect(tkRBrace)
  return Expr(span: sp, kind: exkStruct, fields: fields)

proc parseBraceBlock(p: var Parser, sp: Span): Expr =
  ## { stmt; stmt } — inline block expression
  ## Statements are separated by line breaks.
  discard p.advance()
  var stmts: seq[Expr]
  while p.current().kind != tkRBrace and p.current().kind != tkEOF:
    stmts.add(p.parseStatementExpr())
    if p.current().kind == tkNewline:
      discard p.advance()
  discard p.expect(tkRBrace)
  return Expr(span: sp, kind: exkBlock, stmts: stmts)

proc parseErrKeyword(p: var Parser, sp: Span): Expr =
  ## Parses `err X` — raise an error value into the fn's result
  ## nil when the current tokens are not that shape, so the caller tries the
  ## next form.
  if p.current().kind == tkIdent and p.current().value == "err" and
     p.peek().kind in {tkIdent, tkIntLit}:
    discard p.advance()
    let val = p.parseExpr()
    return Expr(span: sp, kind: exkRaise, raiseVal: val)
  nil

proc parseQualifiedRef(p: var Parser, sp: Span): Expr =
  ## Parses `:name` or `:mod::fn` — module-qualified or bare reference
  ## nil when the current tokens are not that shape.
  if p.current().kind == tkColon and p.peek().kind == tkIdent:
    discard p.advance()
    let name = p.expect(tkIdent).value
    # `:mod::fn` — a reference to another module's fn. The module has to be
    # kept: without it the reference degrades to a bare `:fn`, which the flat
    # signature table still resolves and Nim's and Odin's own scope merge
    # still emits correctly, so the loss stayed invisible until D — which
    # decides "reference, not call" from the checker's type — emitted
    # `mod.fn` where `&mod.fn` was meant.
    if p.current().kind == tkColonColon and p.peek().kind == tkIdent:
      discard p.advance()
      let member = p.expect(tkIdent).value
      return Expr(span: sp, kind: exkQualified, modulePath: @[name],
                  qualName: member)
    return Expr(span: sp, kind: exkQualified, modulePath: @[], qualName: name)
  nil

proc parsePrimaryExpr(p: var Parser): Expr =
  ## One primary expression: `err X`, a `:fn` reference, unary `-`/`not`, a
  ## literal, a name, a paren group or tuple, a list, a struct literal or a
  ## brace block. Postfix steps are the chain parser's job.
  let sp = p.getSpan()
  let curr = p.current()
  # Try error keyword: `err X`
  let errExpr = p.parseErrKeyword(sp)
  if errExpr != nil: return errExpr
  # Try qualified reference: `:name` or `:mod::fn`
  let qualExpr = p.parseQualifiedRef(sp)
  if qualExpr != nil: return qualExpr
  # Try unary minus
  if curr.kind == tkMinus:
    discard p.advance()
    let operand = p.parseChainExpr()
    return Expr(span: sp, kind: exkUnary, unaryOp: uoNeg, operand: operand)
  # Try unary not
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
    while true:
      p.skipSeparators()
      if p.current().kind == tkRBracket or p.current().kind == tkEOF: break
      items.add(p.parseExpr())
      p.skipSeparators()
      if p.current().kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBracket)
    return Expr(span: sp, kind: exkList, items: items)
  of tkLParen:
    discard p.advance()
    let inner = p.parseExpr()
    discard p.expect(tkRParen)
    p.grouped.incl(cast[pointer](inner))
    return inner
  else:
    p.reportError("Expected an expression here, found " & describe(curr))

proc tryUnsafeMarker(p: var Parser): bool =
  ## Type.Variant [unsafe] — deserialization escape hatch for sealed construction
  ## (spec 4.4). Consumes the marker and reports whether it was present.
  # `unsafe` is a reserved bare marker (tkAttr), so the kind check is the
  # value check — no identifier could reach here spelled `unsafe`.
  if p.current().kind == tkLBracket and p.peek(1).kind == tkAttr and
     p.peek(1).value == "unsafe" and p.peek(2).kind == tkRBracket:
    discard p.advance()  # [
    discard p.advance()  # unsafe
    discard p.advance()  # ]
    return true
  false

proc parseAliasStep(p: var Parser, expr: Expr): Expr =
  ## `expr alias(old -> new, ...)` — rename a flowing record's fields (spec
  ## 2.4c). The arrow is Tuck's one rename spelling (TK-PA17); the colon form
  ## `alias(old: new)` it replaced is refused with the fix. Parsed into the
  ## same `alias` combinator node as before, over a struct whose field NAME
  ## is the old name and whose value is the new name — so nothing after the
  ## parser changed.
  let spAlias = p.getSpan()
  discard p.advance()
  discard p.expect(tkLParen)
  var fields: seq[FieldInit]
  while p.current().kind != tkRParen and p.current().kind != tkEOF:
    let name = p.expectName("Expected field name in alias").value
    if p.current().kind == tkColon:
      p.reportError("`alias` renames with `->`: write `" & name & " -> " &
                    (if p.peek().kind in {tkIdent, tkAttr}: p.peek().value
                     else: "newName") & "`", dc = dcPaRenameArrow)
    discard p.expect(tkArrow, "Expected `->` after '" & name & "' in alias")
    let targetSp = p.getSpan()
    let target = p.expectName("Expected the new field name in alias").value
    fields.add((name, Expr(span: targetSp, kind: exkVar, name: target)))
    if p.current().kind == tkComma:
      discard p.advance()
  discard p.expect(tkRParen)
  let structExpr = Expr(span: spAlias, kind: exkStruct, fields: fields)
  return Expr(span: spAlias, kind: exkCombinator, comb: ckAlias,
              combRecv: expr, combArg: structExpr)

proc parsePostfixCall(p: var Parser, expr: Expr, sp: Span): Expr =
  ## {payload} fnName / {payload} mod::fn / {payload} Type.Variant [unsafe] —
  ## the postfix call, Tuck's one call shape
  ## The payload is the receiver `expr`; the callee is the name after it.
  if p.peek().kind == tkColonColon:
    let moduleName = p.advance().value
    discard p.expect(tkColonColon)
    let name = p.expect(tkIdent, "Expected identifier after '::'").value
    let calleeExpr = Expr(span: sp, kind: exkQualified, modulePath: @[moduleName], qualName: name)
    return Expr(span: sp, kind: exkCall, callee: calleeExpr, args: @[expr])
  let callee = p.advance().value
  var calleeExpr = Expr(span: sp, kind: exkVar, name: callee)
  # Qualified postfix: the callee may be a dotted path — `{a, b} Shape.Circle`
  # (a qualified sum-variant constructor) and `{a, b} c.add` (calling THROUGH
  # a variable's fnsig-typed field/slot, examples/31-fnsig-callback.tuck) are
  # both this shape, and the parser genuinely cannot tell them apart from
  # `{x: v} takesInt.len` (a call chained onto a PLAIN FN's result, which
  # should be rejected) — all three are `lowercase-or-uppercase.lowercase`
  # syntactically, and only the checker knows whether the base name is a
  # type, a variable holding a callable slot, or an ordinary function with
  # no fields at all. Tried gating this on capitalization first; broke
  # example 31, which is the identical shape with a variable base. Left
  # greedy here on purpose — failIfChainAfterPayloadCall (typecheck.nim)
  # does the actual rejection, once name resolution can tell the cases apart.
  while p.current().kind == tkDot:
    discard p.advance()
    let fname = p.expectName("Expected name after '.'").value
    calleeExpr = Expr(span: sp, kind: exkField, receiver: calleeExpr, fieldName: fname)
    if p.tryUnsafeMarker():
      calleeExpr.ctorUnsafe = true
  return Expr(span: sp, kind: exkCall, callee: calleeExpr, args: @[expr])

proc bracketIsTight(p: Parser): bool =
  ## `xs[i]` binds to the expression before it; `xs [1, 2]` is a separate list
  ## literal in argument position. Tightness is the ONLY thing the parser
  ## decides here — whether the bracket then means indexing or type application
  ## depends on the receiver, which only the checker knows.
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
  let fieldName = p.expectName("Expected field name after '.'").value
  result = Expr(span: sp, kind: exkField, receiver: expr, fieldName: fieldName)
  if p.tryUnsafeMarker(): result.ctorUnsafe = true
  if p.current().kind == tkLBrace: result.dotArg = p.parsePrimaryExpr()

proc chainMutation(p: var Parser, expr: Expr, sp: Span): Expr =
  ## `..name {value}` — a builder step. Steps accumulate on ONE chain node,
  ## because every `..` in the chain mutates the same base var.
  discard p.advance()
  let fieldName = p.expect(tkIdent,
                           "Expected builder field name after '..'").value
  # `..mod::fn` — the step's target is QUALIFIED, and the `::` belongs to the
  # target, not to the chain. Read here, because the chain loop sees `::`
  # only after this step has already been attached: chainQualified would then
  # receive the whole chain, fail its `exkVar` test, and return a fresh node
  # built from an empty module name — silently discarding the receiver. That
  # is how `cfg ..bigmod::withDefaults ..f1 {60}` came to emit
  # `tuck_withDefaults.f1 = 60`, with `cfg` gone.
  var target = Expr(span: sp, kind: exkVar, name: fieldName)
  if p.current().kind == tkColonColon:
    discard p.advance()
    let member = p.expect(tkIdent, "Expected identifier after '::'").value
    target = Expr(span: sp, kind: exkQualified, modulePath: @[fieldName],
                  qualName: member)
  var arg: Expr = nil
  if p.current().kind == tkLBrace: arg = p.parsePrimaryExpr()
  let step = ChainStep(arg: arg, span: sp, target: target)
  if expr.kind == exkChain:
    expr.steps.add(step)
    return expr
  Expr(span: sp, kind: exkChain, base: expr, steps: @[step])

proc chainQualified(p: var Parser, expr: Expr, sp: Span): Expr =
  ## `module::name`.
  discard p.advance()
  let name = p.expect(tkIdent, "Expected identifier after '::'").value
  # A module qualifier names a MODULE, which is always a bare name. Anything
  # else reaching here means the receiver is a larger expression that this
  # would silently drop — refused rather than rebuilt from an empty module
  # name, which produced the unfindable `::name`.
  # Read the name BEFORE reporting: `expr.name` does not exist on any other
  # kind, and Expr is a variant object, so touching it is a runtime
  # FieldDefect rather than a compile error.
  let moduleName = if expr.kind == exkVar: expr.name else: ""
  if moduleName == "":
    p.reportError("'::' qualifies a MODULE name, so the left side must be a " &
                  "plain module name — not a larger expression",
                  sp.line, sp.col)
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

proc chainCombinator(p: var Parser, expr: Expr, sp: Span,
                     ck: CombKind): Expr =
  ## `recv <name> {…}` — the combinators taking a receiver and a struct
  ## payload: `bake` (fix a slot) and `with` (copy, replace, same type).
  ## Which one is decided HERE, once, and carried as a CombKind — downstream
  ## stages match on the node, never on a callee spelling.
  discard p.advance()
  let arg = p.parsePrimaryExpr()
  Expr(span: sp, kind: exkCombinator, comb: ck, combRecv: expr, combArg: arg)

proc chainBake(p: var Parser, expr: Expr, sp: Span): Expr =
  ## `recv bake {slot: v}` — fix a record slot, as a combinator node.
  p.chainCombinator(expr, sp, ckBake)

proc chainBuiltinCall(p: var Parser, expr: Expr, sp: Span): Expr =
  ## `name(args)` for one of the paren builtins: a call with its arguments
  ## listed positionally.
  discard p.advance()
  Expr(span: sp, kind: exkCall, callee: expr,
       args: p.parseCommaList(tkRParen))

proc chainSend(p: var Parser, expr: Expr, sp: Span): Expr =
  ## `ActorType send handler {payload}` — a direct send to an actor
  ## singleton. The brace is the handler's message payload, optional for a
  ## no-arg `on`.
  ##
  ## The receiver may be INSTANTIATED — `Box[int] send put {v: 1}` — because an
  ## actor is one singleton per instantiation (#18). Without this the bracket
  ## broke the send recognition outright and the line parsed as
  ## `put(send(Box[int]), {v: 1})`, three nested calls that meant nothing.
  discard p.advance()                    # eat `send`
  let handler = p.expectName("Expected handler name after 'send'").value
  var payload: Expr = nil
  if p.current().kind == tkLBrace: payload = p.parsePrimaryExpr()
  var actorName = ""
  var actorArgs: seq[Type]
  if expr.kind == exkBracket:
    actorName = expr.brReceiver.name
    for a in expr.brArgs: actorArgs.add(typeOfTypeExpr(a))
  else:
    actorName = expr.name
  Expr(span: sp, kind: exkSend, sendActor: actorName,
       sendActorArgs: actorArgs, sendHandler: handler, sendPayload: payload)

proc isSendStep(p: Parser, expr: Expr): bool =
  ## Is the next step `send handler` on an actor name (or a generic actor's
  ## instantiation `Box[int]`)?
  if not (p.current().kind == tkIdent and p.current().value == "send" and
          p.peek().kind == tkIdent):
    return false
  expr.kind == exkVar or
    (expr.kind == exkBracket and expr.brReceiver != nil and
     expr.brReceiver.kind == exkVar)

proc isMergeStep(p: Parser, expr: Expr): bool =
  ## `{a, b} merge` — a struct literal receiver is the whole trigger. With
  ## any other receiver `merge` stays an ordinary name, which it was before
  ## the combinators became nodes and still is.
  p.current().kind == tkIdent and p.current().value == "merge" and
    expr != nil and expr.kind == exkStruct

proc isWithStep(p: Parser): bool =
  ## `with` is a soft keyword: only a `{` after it makes it the update
  ## combinator, so `with` stays available as an ordinary name.
  p.current().kind == tkIdent and p.current().value == "with" and
    p.peek().kind == tkLBrace

proc isAliasStep(p: Parser): bool =
  ## Is the next step `alias(...)`?
  p.current().kind == tkIdent and p.current().value == "alias" and
    p.peek().kind == tkLParen

proc isBuiltinCall(p: Parser, expr: Expr): bool =
  ## Is the next step a parenthesised call to one of the paren builtins?
  p.current().kind == tkLParen and expr.kind == exkVar and
    expr.name in ParenBuiltins

proc isEffectAnnotation(p: Parser): bool =
  ## Is the next token a one-word attribute bracket like `[unsafe]` — an
  ## annotation on the expression, not an index?
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
    if p.isWithStep(): return p.chainCombinator(expr, sp, ckWith)
    if p.isMergeStep(expr):
      discard p.advance()
      return Expr(span: sp, kind: exkCombinator, comb: ckMerge,
                  combRecv: expr, combArg: nil)
    # `a mod b` / `a div b` are word-operators in Nim, Pascal and Python, and
    # neither is one here — `%` and `/i` are. Without this they parse as a
    # postfix CALL (`mod(a)`) and the right operand is dropped on the floor,
    # typechecking clean and emitting silently wrong code, which is the worst
    # possible answer to a spelling someone reasonably reached for.
    if p.current().value in ["mod", "div"]:
      p.reportError("`" & p.current().value & "` is not an operator in Tuck" &
                    spellingHint(p.current().value) &
                    " A bare word here parses as a postfix call and silently " &
                    "drops the right operand.",
                    dc = dcPaWordOperator)
    if p.current().value notin NonCallIdents:
      let called = p.parsePostfixCall(expr, sp)
      p.failIfChainAfterPayloadCall(called)
      return called
  of tkIntLit, tkFloatLit, tkStrLit:
    # A LITERAL cannot continue a chain. Calls are postfix, so an argument
    # precedes its callee — `5 double`, never `double 5`. Reaching here means
    # the argument was written AFTER the name, and without this the chain
    # simply ends: `double` becomes one statement and `5` another, the
    # argument silently dropped. That typechecked clean and emitted
    # `tuck_double` and `5` as two dead statements.
    p.reportError(
      "`" & exprName(expr) & " " & p.current().value &
      "` is a call written backwards. Calls are POSTFIX in Tuck — the " &
      "argument comes first: write `" & p.current().value & " " &
      exprName(expr) & "`, or `{field: " & p.current().value & "} " &
      exprName(expr) & "` to name the payload field.",
      dc = dcPaCallSyntax)
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

const OpPrecedences = {
  tkPlus: (1, boAdd), tkMinus: (1, boSub),
  tkStar: (2, boMul), tkPercent: (2, boMod),
  tkSlashInt: (2, boDivInt), tkSlashFloat: (2, boDivFloat),
  tkEq: (0, boEq), tkNeq: (0, boNeq),
  tkLt: (0, boLt), tkGt: (0, boGt), tkLte: (0, boLe), tkGte: (0, boGe),
  tkAnd: (-1, boAnd), tkOr: (-1, boOr), tkXor: (-1, boXor),
  tkRange: (-2, boRangeIncl), tkRangeLt: (-2, boRangeExcl),
}.toTable()
  ## Each binary operator token's precedence (higher binds tighter) and the
  ## BinOp it builds. A const: it used to be rebuilt as a fresh Table on every
  ## binary expression parsed.

const BoolOps = {boAnd, boOr, boXor}
  ## The boolean operators, which share one precedence level (TK-PA16).

proc failIfMixedBoolOps(p: var Parser, op: BinOp, operand: Expr) =
  ## `and`, `or` and `xor` do not rank against each other, so an operand of
  ## one that is ANOTHER of them, written without parentheses, is refused.
  ## The same operator repeated (`a and b and c`) groups either way and is
  ## fine.
  if operand == nil or operand.kind != exkBinary: return
  if operand.binOp notin BoolOps or operand.binOp == op: return
  if cast[pointer](operand) in p.grouped: return
  p.reportError("`" & opStr(op) & "` and `" & opStr(operand.binOp) &
                "` are mixed without parentheses — write which pairs first, " &
                "e.g. `(a and b) or c` or `a and (b or c)`",
                operand.span.line, operand.span.col, dc = dcPaMixedBoolOps)

proc parseBinaryExpr(p: var Parser, minPrecedence = 0): Expr =
  ## Precedence climbing over the binary operators: arithmetic binds tightest,
  ## then comparisons, then `and`/`or`/`xor`, then ranges. Operands are chain
  ## expressions.
  var left = p.parseChainExpr()

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
    if currKind in OpPrecedences:
      let (prec, op) = OpPrecedences[currKind]
      if prec >= minPrecedence:
        discard p.advance()
        let right = if currKind in {tkAnd, tkOr, tkXor}: p.parseExpr() else: p.parseBinaryExpr(prec + 1)
        if op in BoolOps:
          p.failIfMixedBoolOps(op, left)
          p.failIfMixedBoolOps(op, right)
        left = Expr(span: left.span, kind: exkBinary, binOp: op, left: left, right: right)
      else:
        break
    else:
      break
  return left

proc parseSelectExpr(p: var Parser): Expr =
  ## A task-body `on select:` as an exkSelect node: one `| source arg ->
  ## {bind}: body` arm per line.
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
    # An arm takes a BLOCK or a single expression, exactly as a match arm does
    # (parseMatchArm, same two lines). A one-expression arm reads well for
    # `-> {}: return {code: 2}`; anything that actually handles the wakeup
    # wants statements, and forcing those into a helper was the language
    # telling the author to decompose for the parser's convenience rather
    # than for the reader's.
    let body = if p.current().kind == tkNewline: p.parseBlock()
               else: p.parseExpr()
    arms.add(SelectArm(source: source, arg: arg, binding: binding,
                       body: body, span: armSp))
    if p.current().kind == tkNewline:
      discard p.advance()
  discard p.expect(tkDedent)
  return Expr(span: sp, kind: exkSelect, selArms: arms)

proc parseBinding(p: var Parser, sp: Span, mutable: bool): Expr =
  ## `let name = value` / `var name = value`.
  discard p.advance()
  # expectName, not a bare expect(tkIdent): it names the WORD that
  # collided when a reserved one is used as a variable (`var pending = ...`
  # reported "Expected variable name" while pointing straight at a perfectly
  # good-looking name, which reads as a parser fault rather than a naming one).
  let name = p.expectName("Expected variable name").value
  # `let name: T = value` — the type is OPTIONAL and inference is still the
  # normal case. It exists for the values that carry no type of their own: an
  # empty list (TK-TY20) and a nullary generic call have nothing to infer
  # from, and before this the only way to name their type was a fn whose
  # RETURN type said it.
  var declType: Type = nil
  if p.current().kind == tkColon and parseTypeHook != nil:
    discard p.advance()
    declType = parseTypeHook(p)
  discard p.expect(tkAssign)
  Expr(span: sp, kind: exkAssign, assignVal: p.parseExpr(), isDecl: true,
       isMutable: mutable, declType: declType,
       target: Expr(span: sp, kind: exkVar, name: name))

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
  ## `if cond: block` with its `elif`/`else` chain. `elif` re-enters here, so
  ## it lands in `elseBranch` as a nested `if`.
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

proc parseDiscardExpr(p: var Parser, sp: Span): Expr =
  ## A bare `discard`, with nothing before it, is a pure no-op statement.
  ## Dropping a VALUE is spelled `<expr> discard` instead (see parseBlock) —
  ## postfix, like every other Tuck construct that acts on a value already
  ## in hand (`{payload} fnName`, chains, `.fn {args}`); a leading `discard
  ## <expr>` would read backwards against that grain.
  discard p.advance()
  Expr(span: sp, kind: exkDiscard, discardVal: nil)

proc isTypeTestArm(p: Parser): bool =
  ## `Flac f ->` (or `Flac f:`): a Capitalized name, a binding name, then the
  ## arm's separator — a type test on an interface value. Recognised in a
  ## `match` arm only: a two-column decision row (`| Ready idle ->`) has the
  ## same tokens and means two values.
  let head = p.current()
  head.kind == tkIdent and head.value.len > 0 and
    head.value[0] in {'A'..'Z'} and p.peek(1).kind in {tkIdent, tkAttr} and
    p.peek(2).kind in {tkArrow, tkColon}

proc parseTypeTest(p: var Parser): Pattern =
  ## `Flac f`: the object the value must hold, and the name it is bound to.
  let sp = p.getSpan()
  let testType = p.advance().value
  let bindAs = p.expectName("Expected the name to bind the " &
                                   testType & " to").value
  Pattern(span: sp, kind: pkTypeTest, testType: testType, bindAs: bindAs)

proc parseMatchArm(p: var Parser): MatchArm =
  ## `| Pat -> body` and `Pat: body` are the same arm. The arrow form matches
  ## decision tables and select arms, so one shape reads across every
  ## construct that dispatches on a pattern.
  let arrowForm = p.current().kind == tkPipe
  if arrowForm: discard p.advance()
  let pat = if p.isTypeTestArm(): p.parseTypeTest() else: p.parsePattern()
  if arrowForm: discard p.expect(tkArrow) else: discard p.expect(tkColon)
  # arm body: a single expression on the same line, or an indented block
  let body = if p.current().kind == tkNewline: p.parseBlock()
             else: p.parseExpr()
  result = MatchArm(pattern: pat, body: body, span: p.getSpan())
  if p.current().kind == tkNewline: discard p.advance()

proc parseMatchExpr(p: var Parser, sp: Span): Expr =
  ## `match subject:` and its indented arms, one per line.
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
  ## `for x in xs:` / `for i, x in xs:` iterates; any other `for cond:` is a
  ## while-style loop and becomes exkWhile.
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

proc parseResourceOp(p: var Parser, sp: Span, op: ExprKind): Expr =
  ## The two registry operations, spec §7.4 — ONE parser, because they are one
  ## shape:
  ##
  ##     acquire <raw>,    <kind>     # register; yields ?<Kind>Handle
  ##     finish  <handle>, <kind>     # release intent; yields nothing
  ##
  ## Symmetric by construction rather than by discipline: same keyword
  ## position, same operand order, same trailing kind name, and one proc that
  ## cannot let the two drift apart.
  ##
  ## `finish` names the kind even though the handle's TYPE already determines
  ## the table, and that redundancy is the feature: a release is read far more
  ## often than it is written, and the reader should not have to find the
  ## declaration of `sock` to learn which registry is touched. The checker
  ## verifies the two agree (TK-RS04), so the second source of truth cannot
  ## drift from the first. On `acquire` the kind is not redundant at all — a
  ## raw fd says nothing about which table it belongs in — which is the
  ## deeper reason the pair reads the same way.
  let word = if op == exkAcquire: "acquire" else: "finish"
  let operand = if op == exkAcquire: "<raw>" else: "<handle>"
  discard p.advance()            # eat the keyword
  let arg = p.parseExpr()
  discard p.expect(tkComma,
    "`" & word & "` names the kind too: `" & word & " " & operand & ", <kind>`")
  let kind = p.expectName("Expected a resource kind name after ','").value
  if op == exkAcquire:
    Expr(span: sp, kind: exkAcquire, acquireRef: arg, acquireKind: kind)
  else:
    Expr(span: sp, kind: exkFinish, finishHandle: arg, finishKind: kind)

proc parseDeferExpr(p: var Parser, sp: Span): Expr =
  ## `defer:` then an indented block (spec §7.4) — statements held back until
  ## the enclosing scope exits, LIFO.
  ##
  ## A block only, never `defer: stmt` on one line. The one-liner is what
  ## makes a defer easy to miss on a skim, and a construct whose whole job is
  ## to run somewhere other than where it is written is the last one that
  ## should be easy to miss.
  discard p.advance()          # eat `defer`
  discard p.expect(tkColon)
  if p.current().kind notin {tkNewline, tkEOF}:
    p.reportError("`defer` takes an indented block, not a single line. The " &
                  "body runs at scope exit rather than here, which is worth " &
                  "a line of its own.", line = sp.line, col = sp.col)
  Expr(span: sp, kind: exkDefer, deferBody: p.parseBlock())

proc contextualStmt(p: var Parser, sp: Span): Expr =
  ## The statement forms whose opening word the LEXER does not tokenize —
  ## `defer:`, `acquire`, `finish`. The expression-level twin of
  ## parser.contextualDecl, and it exists for the same two reasons: each is
  ## recognised by SPELLING rather than by token kind, and each is GATED on
  ## what follows so an ordinary variable of that name still reads as one.
  ##
  ## nil means "none of these" — the `as*` convention typecheck.nim uses for
  ## an ordered interpretation that may decline.
  ##
  ## The gates:
  ##   `defer`   + `:`            — it opens a block and nothing else does
  ##   `acquire` / `finish` + a NAME or `{` — Tuck calls are postfix
  ##                               (`{payload} fn`), so two bare identifiers in
  ##                               a row are not an expression in any other
  ##                               construct. `return finish` and `finish + 1`
  ##                               still read `finish` as an ordinary name.
  if p.current().kind != tkIdent: return nil
  case p.current().value
  of "defer":
    if p.peek().kind == tkColon: return p.parseDeferExpr(sp)
  of "finish":
    if p.peek().kind in {tkIdent, tkLBrace}:
      return p.parseResourceOp(sp, exkFinish)
  of "acquire":
    if p.peek().kind in {tkIdent, tkLBrace}:
      return p.parseResourceOp(sp, exkAcquire)
  else: discard
  nil

proc parseExpr*(p: var Parser): Expr =
  ## One statement or expression, dispatched on its first token: bindings,
  ## control flow, `return`/`discard`/`...`, contextual statements, else a
  ## binary expression (possibly an assignment).
  let sp = p.getSpan()
  let curr = p.current()
  if curr.kind == tkOn and p.peek().kind == tkSelect:
    return p.parseSelectExpr()
  let contextual = p.contextualStmt(sp)
  if contextual != nil: return contextual

  case curr.kind
  of tkLet, tkVar: return p.parseBinding(sp, mutable = curr.kind == tkVar)
  of tkIf, tkElif: return p.parseIfExpr(sp)
  of tkReturn: return p.parseReturnExpr(sp)
  of tkDiscard: return p.parseDiscardExpr(sp)
  of tkTripleDot:
    discard p.advance()
    return Expr(span: sp, kind: exkTripleDot)
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

proc looksLikeWhileAttempt(p: Parser): bool =
  ## `while` is not a Tuck keyword — an ordinary, unreserved identifier — so
  ## `while cond:` parses `while` as a bare name and fails somewhere inside
  ## `cond`, with no hint the real spelling is `for cond:`. Detected by shape
  ## rather than by treating `while` as reserved: a `:` follows before the
  ## line ends, at bracket depth 0 (so `while` used as an ordinary value in a
  ## record/call literal on the same line, e.g. `{a: while}`, never trips
  ## this — only the specific "opens a block" shape does).
  if p.current().kind != tkIdent or p.current().value != "while": return false
  var depth = 0
  var i = 1
  while true:
    let t = p.peek(i)
    case t.kind
    of tkNewline, tkEOF: return false
    of tkLParen, tkLBracket, tkLBrace: inc depth
    of tkRParen, tkRBracket, tkRBrace: dec depth
    of tkColon:
      if depth == 0: return true
    else: discard
    inc i

proc parseStatementExpr(p: var Parser): Expr =
  ## One statement: an expression, optionally suffixed with `discard` to
  ## drop its value — postfix, matching Tuck's own grain (`{payload}
  ## fnName`, chains, `.fn {args}`): the value comes first, what happens to
  ## it after. A LEADING bare `discard` (nothing to drop) is a separate,
  ## unrelated case, handled by parseDiscardExpr inside parseExpr itself.
  if p.looksLikeWhileAttempt():
    p.reportError("Tuck has no 'while' — write 'for " & p.peek(1).value &
                  " ...:' instead", dc = dcPaNoWhile)
  let e = p.parseExpr()
  if p.current().kind == tkDiscard:
    let dsp = p.getSpan()
    discard p.advance()
    return Expr(span: dsp, kind: exkDiscard, discardVal: e)
  e

proc parseBlock*(p: var Parser): Expr =
  ## An indented block, OR — when the body continues on the same line — a
  ## single expression (ruling R2/R3: `let x = if c: 1 else: 2`). Returning
  ## the bare expression rather than wrapping it in a one-statement block
  ## keeps the value obvious to the checker and both emitters.
  let sp = p.getSpan()
  if p.current().kind notin {tkNewline, tkEOF}:
    return p.parseStatementExpr()
  discard p.expect(tkNewline)
  while p.current().kind == tkNewline:
    discard p.advance()
  if p.current().kind != tkIndent:
    p.reportError("A ':' opened a block with nothing inside it. Write " &
                  "'discard' if doing nothing here is intentional.",
                  line = sp.line, col = sp.col, dc = dcPaEmptyBlock)
  discard p.expect(tkIndent)
  var stmts: seq[Expr]
  while p.current().kind != tkDedent and p.current().kind != tkEOF:
    if p.current().kind == tkNewline:
      discard p.advance()
      continue
    stmts.add(p.parseStatementExpr())
    if p.current().kind == tkNewline:
      discard p.advance()
  discard p.expect(tkDedent)
  if stmts.len == 0:
    p.reportError("A ':' opened a block with nothing inside it. Write " &
                  "'discard' if doing nothing here is intentional.",
                  line = sp.line, col = sp.col, dc = dcPaEmptyBlock)
  return Expr(span: sp, kind: exkBlock, stmts: stmts)

