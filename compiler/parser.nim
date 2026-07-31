# compiler/parser.nim
#
# STAGE 2 OF THE PIPELINE — tokens become a tree. This file handles
# DECLARATIONS: the top level of a program (fn, type, actor, task, mixin,
# pending blocks, extern blocks, decision tables).
#
# Tokens are a flat list, but programs nest: a fn holds statements, a statement
# holds expressions, expressions hold more expressions. The parser builds the
# tree that mirrors that nesting — the AST (Abstract Syntax Tree, defined in
# ast.nim).
#
# "Abstract" means it drops whatever does not change meaning: the parentheses
# you added for readability, the whitespace, the comments. `2 + 3 * 4` becomes
# a tree that already KNOWS the multiply binds tighter, without needing
# parentheses to say so. Precedence stops being a question once it is shape.
#
# WHERE THIS FILE SITS. The grammar splits into layers, each using only the
# ones below it:
#
#   parser_base      peek / advance / expect / error reporting
#      ^
#   parser_expr      expressions and patterns — the recursive core
#      ^
#   parser_type      type expressions: int, {a: int}, !str, Seq[int]
#      ^
#   parser (here)    declarations, and the module as a whole
#
# The one-way dependency is what stops mutual recursion from becoming a knot,
# and it tells you where new syntax belongs: a new type form goes in
# parser_type, a new operator in parser_expr, a new top-level keyword here.
#
# A RULE THIS CODEBASE HOLDS TO: every language construct gets its OWN node
# kind. When `on select` was added it got real exkSelect / dkSelect nodes,
# rather than being encoded as a `match` with a fake subject. Reusing an
# existing node shape is always tempting and always costs more later, because
# every downstream stage then has to know the trick and special-case it.
#
# What this stage does NOT do: it does not care whether anything is CORRECT.
# `"hello" + 5` parses fine — it is well-formed syntax. Rejecting it is the
# typechecker's job. A parser only decides whether the shape is legal.
import strutils, tables
import ast
import ../lexer
import parser_base
export parser_base
import parser_stringify
export parser_stringify
import parser_expr        # expression + pattern grammar (the recursive core)
export parser_expr
import parser_type        # type-expression grammar
export parser_type

# Forward declaration (parseExpr/parsePattern/parseBlock from parser_expr,
# parseType from parser_type)
proc parseDecl*(p: var Parser): Decl
proc parseTypeDecl(p: var Parser, sp: Span): Decl   # extern blocks take types
proc parseFnSigDecl(p: var Parser, sp: Span): Decl  # ...and C callback sigs

# `(params)` — a fn/task/decision/sig parameter list. Each param is either
# brace-destructured (`{a: T, b: U}`, one entry per field) or bare
# (`name: Type`), with a bare `self` (no `: Type`) special-cased to `Self`.
# The same list shape was open-coded at four call sites (parseSigBlock,
# parseTaskDecl, parseFnDecl, parseDecisionDecl); this is that shape, once.
proc parseBraceParams(p: var Parser, pSp: Span, params: var seq[Param]) =
  ## Parses one `{a: T, b: U}` destructured group, appending each field as
  ## its own Param sharing the group's span. Assumes the opening `{`.
  discard p.advance()
  while p.current().kind != tkRBrace and p.current().kind != tkEOF:
    let paramName = p.expect(tkIdent, "Expected parameter name").value
    discard p.expect(tkColon)
    let paramType = p.parseType()
    params.add(Param(name: paramName, typ: paramType, span: pSp))
    if p.current().kind == tkComma:
      discard p.advance()
  discard p.expect(tkRBrace)

proc parseBareParam(p: var Parser, pSp: Span): Param =
  ## Parses one `name: Type` param. A bare `self` (no `: Type` follows) is
  ## the implicit-Self special case: it types itself as `Self`.
  let paramName = p.expect(tkIdent, "Expected parameter name").value
  if paramName == "self" and p.current().kind != tkColon:
    return Param(name: paramName, typ: Type(span: pSp, kind: tkNamed, name: "Self"), span: pSp)
  discard p.expect(tkColon)
  Param(name: paramName, typ: p.parseType(), span: pSp)

proc parseOneParam(p: var Parser, params: var seq[Param]) =
  ## Parses one param, brace-destructured or bare, appending to `params`.
  let pSp = p.getSpan()
  if p.current().kind == tkLBrace:
    parseBraceParams(p, pSp, params)
  else:
    params.add(parseBareParam(p, pSp))

proc parseParamListBody(p: var Parser): seq[Param] =
  ## Parses the comma-separated params between `(` and `)`, not including
  ## the parens themselves.
  if p.current().kind == tkRParen: return
  while true:
    parseOneParam(p, result)
    if p.current().kind != tkComma: break
    discard p.advance()

proc parseParamList(p: var Parser): seq[Param] =
  ## Parses a full `(params)` list, as used by fn/task/decision/sig decls.
  discard p.expect(tkLParen)
  result = parseParamListBody(p)
  discard p.expect(tkRParen)

# Maps an effect-marker identifier (`io`, `no_alloc`, ...) to its
# EffectMarker, or returns false for anything else. The `[...]` effect
# bracket has three callers (parseSigBlock, parseTaskDecl, parseFnDecl) and
# each wraps this same name->marker mapping in its own handling of
# `error:`/`emit:` sub-clauses and its own reaction to an unrecognized name
# (silently ignore vs. report an error) — those reactions differ enough
# between callers that forcing them into one loop would need a mode flag,
# so only the mapping itself is shared.
proc effectMarkerFromName(name: string, marker: var EffectMarker): bool =
  case name
  of "io": marker = emIo
  of "no_alloc": marker = emNoAlloc
  of "irq_safe": marker = emIrqSafe
  of "unsafe": marker = emUnsafe
  of "may_block": marker = emMayBlock
  of "stack": marker = emStack
  of "priority": marker = emPriority
  else: return false
  return true

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
    # `type Name = {...}` inside an extern block: the C struct this library's
    # functions take. Declaring it HERE (rather than outside) is what marks it
    # foreign — the backends must then declare the C type instead of defining
    # a layout-compatible duplicate, which the C compiler rejects.
    if p.current().kind == tkType:
      result.add(p.parseTypeDecl(p.getSpan()))
      if p.current().kind == tkNewline:
        discard p.advance()
      continue
    # `fnsig Name = {...} -> T` inside an extern block: a C function pointer
    # the library calls back through.
    if p.current().kind == tkFnsig:
      result.add(p.parseFnSigDecl(p.getSpan()))
      if p.current().kind == tkNewline:
        discard p.advance()
      continue
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
    let params = parseParamList(p)
    var retType: Type
    if p.current().kind == tkArrow:
      discard p.advance()
      retType = p.parseType()
    var sigEffects: seq[EffectMarker]
    var sigErrTypes: seq[string]
    var sigEmit = ""
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
        if effName == "emit":
          # [emit: "nimProc"] — the exact runtime/C proc name to emit
          discard p.expect(tkColon)
          sigEmit = p.expect(tkStrLit, "Expected proc name string after 'emit:'").value
          if p.current().kind == tkComma: discard p.advance()
          continue
        var marker: EffectMarker
        if effectMarkerFromName(effName, marker):
          sigEffects.add(marker)
        if p.current().kind == tkComma:
          discard p.advance()
      discard p.expect(tkRBracket)
    result.add(Decl(span: spDecl, kind: dkFn, name: name, fnParams: params,
                    fnGenerics: sigGenerics,
                    fnReturnType: retType, fnEffects: sigEffects, fnBody: nil,
                    fnErrorTypes: sigErrTypes, externEmit: sigEmit))
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
  let params = parseParamList(p)
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
      if not effectMarkerFromName(effName, eff):
        p.reportError("Unknown effect marker: " & effName, effSp.line, effSp.col)
      effects.add(eff)
      if p.current().kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBracket)
  discard p.expect(tkColon)
  let body = p.parseBlock()
  return Decl(span: sp, kind: dkTask, name: name, taskParams: params, taskReturnType: retType, taskEffects: effects, taskBody: body)

# type Name[T] [attrs] = alias | : body (fields / | variants / transitions / invariant:)
# fnsig NAME = {params} -> ret — a named function-signature type (spec D#10c).
# params read exactly like a fn's ({a: int, b: int}); ret accepts anything a fn
# returns (a {struct}, a bare type, void, or !T/?T). NAME then usable as a type.
proc parseFnSigDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()  # eat `fnsig`
  let name = p.expect(tkIdent, "Expected fnsig name").value
  discard p.expect(tkAssign)
  # params: a brace record `{a: T, b: U}` (or `{}` for none) — reuse parseType,
  # which yields a tkRecord, then lift its fields to named Params.
  let paramsType = p.parseType()
  var params: seq[Param]
  if paramsType.kind == tkRecord:
    for f in paramsType.fields:
      params.add(Param(name: f.name, typ: f.typ, span: f.span))
  else:
    p.reportError("fnsig params must be a `{name: type, ...}` record")
  discard p.expect(tkArrow)
  let ret = p.parseType()
  if p.current().kind == tkNewline:
    discard p.advance()
  return Decl(span: sp, kind: dkFnSig, name: name, sigParams: params, sigReturn: ret)

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
    # `on select:` — wait on multiple event sources (spec §9.3). Direct
    # dkSelect node (no exkMatch reuse). Phase B: each arm's source is a
    # message handler name; `-> {binding}` binds the payload; `: body` runs.
    discard p.advance() # eat "on"
    discard p.advance() # eat "select"
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
      # source is a bare message name, or a dotted event source like
      # `timer.1s` / `timeout.5s` / `resp.ok` (timers/readiness — parsed now,
      # given meaning in a later phase). Consume up to the arrow.
      var source = p.expect(tkIdent, "Expected a select source").value
      while p.current().kind in {tkDot, tkIdent, tkIntLit} and
            p.current().kind != tkArrow:
        source.add(p.advance().value)
      discard p.expect(tkArrow)
      # `-> {name: Type, ...}` typed binding — the arm IS the message decl.
      # `shutdown` (reserved) and empty-payload arms use `-> {}`.
      var binding: seq[Param]
      if p.current().kind == tkLBrace:
        discard p.advance()
        while p.current().kind != tkRBrace and p.current().kind != tkEOF:
          let bn = p.expect(tkIdent, "Expected binding name").value
          var bt: Type = nil
          if p.current().kind == tkColon:
            discard p.advance()
            bt = p.parseType()
          binding.add(Param(name: bn, typ: bt, span: armSp))
          if p.current().kind == tkComma: discard p.advance()
        discard p.expect(tkRBrace)
      discard p.expect(tkColon)
      let body = p.parseExpr()
      arms.add(SelectArm(source: source, binding: binding, body: body, span: armSp))
      if p.current().kind == tkNewline:
        discard p.advance()
    discard p.expect(tkDedent)
    return Decl(span: sp, kind: dkSelect, selectArms: arms)

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
  let params = parseParamList(p)
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
      if not effectMarkerFromName(effName, eff):
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
  let params = parseParamList(p)
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
  var lib = ""
  if p.current().kind == tkLBracket:
    discard p.advance()
    while p.current().kind != tkRBracket and p.current().kind != tkEOF:
      let key = p.expect(tkIdent, "Expected 'c', 'header' or 'lib' in extern attributes").value
      if key == "header":
        discard p.expect(tkColon)
        header = p.expect(tkStrLit, "Expected header path string").value
      elif key == "lib":
        # bare library name — each backend decorates it natively ("z" ->
        # Nim `-lz`, Odin `system:z`). Not a linker flag, so it stays portable.
        discard p.expect(tkColon)
        lib = p.expect(tkStrLit, "Expected library name string after 'lib:'").value
      # "c" is the target marker; nothing to store
      if p.current().kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBracket)
  let decls = p.parseSigBlock("extern")
  for d in decls:
    if d.kind == dkType:
      # a C struct, not a C function: it carries the header so the backend
      # declares the foreign type instead of defining its own copy
      d.typeExternHeader = header
      continue
    if d.kind == dkFnSig:
      # a C function pointer: needs the C calling convention, not Nim's
      # default closure (a two-word proc+env pair C cannot receive)
      d.sigIsCCallback = true
      continue
    d.isExtern = true
    d.externHeader = header
    d.externLib = lib
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
    # spec 7.2: `pool Name = ElemType [count: N]` — N slots of an arbitrary
    # element type. Reuses the `X = <type> [attrs]` shape; the name denotes
    # the POOL, not a value of the element type.
    discard p.advance() # eat "pool"
    let name = p.expect(tkIdent, "Expected pool name").value
    if p.current().kind != tkAssign:
      p.reportError("A pool declares its element type: " &
        "`pool " & name & " = <ElementType> [count: N]`")
    discard p.advance() # eat "="
    let elem = p.parseType()
    var count = 0
    for a in elem.attrs:
      if a.name == "count":
        try: count = parseInt(a.value)
        except ValueError:
          p.reportError("pool '" & name & "': count must be a whole number, " &
                        "got '" & a.value & "'")
    if count <= 0:
      p.reportError("pool '" & name & "' needs a slot count: " &
        "`pool " & name & " = <ElementType> [count: N]`. A pool without a " &
        "count has no static footprint, which is the point of a pool.")
    # the count is the POOL's knob, not part of the element type
    var elemAttrs: seq[TypeAttr]
    for a in elem.attrs:
      if a.name != "count": elemAttrs.add(a)
    elem.attrs = elemAttrs
    if p.current().kind == tkNewline: discard p.advance()
    return Decl(span: sp, kind: dkPool, name: name,
                poolElem: elem, poolCount: count)

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

  of tkFnsig:
    return p.parseFnSigDecl(sp)

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
