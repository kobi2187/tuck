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
    let paramName = p.expectMemberName("Expected parameter name").value
    discard p.expect(tkColon)
    let paramType = p.parseType()
    params.add(Param(name: paramName, typ: paramType, span: pSp))
    if p.current().kind == tkComma:
      discard p.advance()
  discard p.expect(tkRBrace)

proc parseBareParam(p: var Parser, pSp: Span): Param =
  ## Parses one `name: Type` param. A bare `self` (no `: Type` follows) is
  ## the implicit-Self special case: it types itself as `Self`.
  let paramName = p.expectMemberName("Expected parameter name").value
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
    let attrName = p.expectAttrName("Expected attribute name").value
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
const MemberStarters = {tkFn, tkLet, tkVar, tkPending, tkOn, tkPlus}
  ## Tokens that begin a MEMBER of an object body rather than a field.

proc parsePendingHole(p: var Parser): Decl =
  ## `...` — an unwritten body. Compiles, does nothing.
  let sp = p.getSpan()
  discard p.advance()
  discard p.advance()
  if p.current().kind == tkNewline: discard p.advance()
  Decl(span: sp, kind: dkExpr, expr: Expr(span: sp, kind: exkVar, name: "..."))

proc isPendingHole(p: Parser): bool =
  p.current().kind == tkDotDot and p.peek(1).kind == tkDot

proc isSatisfiesLine(p: Parser): bool =
  ## Gated on an Ident following, so a FIELD named `satisfies: bool` still
  ## parses as a field.
  p.current().kind == tkIdent and p.current().value == "satisfies" and
    p.peek(1).kind == tkIdent

proc parseSatisfiesLine(p: var Parser, hasFields: bool): Decl =
  ## `satisfies I` (spec §5.2) — a body line beside the `+` composition lines.
  ## Collected as a dkExpr member because parseObjectBody is shared with
  ## dkActor and has no out-param; the dkObject arm sifts it into the
  ## `satisfies` field, exactly as `+ X` is sifted by isCompositionEntry.
  ##
  ## CONTRACTS COME FIRST: a `satisfies` line must precede the object's
  ## fields, so what the object PROMISES is visible before its data. Reading a
  ## body top-down then answers "what is this for" before "what does it hold",
  ## and the promise cannot hide below a long field list.
  let sSp = p.getSpan()
  if hasFields:
    p.reportError("`satisfies` must come before the object's fields — " &
                  "state the contract first, then the data", sSp.line, sSp.col)
  discard p.advance()
  let iname = p.expect(tkIdent,
                       "Expected interface name after 'satisfies'").value
  if p.current().kind == tkNewline: discard p.advance()
  Decl(span: sSp, kind: dkExpr, name: iname,
       expr: Expr(span: sSp, kind: exkVar, name: satisfiesMark))

proc parseObjectField(p: var Parser): FieldDef =
  ## `name: Type` — one field. A `= default` is parsed and dropped.
  let fSp = p.getSpan()
  let fName = p.expectMemberName("Expected field or member name in object").value
  discard p.expect(tkColon)
  let fType = p.parseType()
  if p.current().kind == tkAssign:
    discard p.advance()
    discard p.parseExpr()
  if p.current().kind == tkNewline: discard p.advance()
  FieldDef(name: fName, typ: fType, attrs: @[], span: fSp)

proc parseObjectBodyLine(p: var Parser, fields: var seq[FieldDef],
                         members: var seq[Decl]) =
  ## One line of an object or actor body: a pending hole, a member, an
  ## invariant block, a `satisfies` contract, or a field.
  if p.isPendingHole(): members.add(p.parsePendingHole())
  elif p.current().kind in MemberStarters: members.add(p.parseDecl())
  elif p.current().kind == tkAttr and p.current().value == "invariant":
    p.parseInvariantBlock(members)
  elif p.isSatisfiesLine():
    members.add(p.parseSatisfiesLine(fields.len > 0))
  else:
    fields.add(p.parseObjectField())

proc parseObjectBody(p: var Parser, fields: var seq[FieldDef],
                     members: var seq[Decl]) =
  discard p.expect(tkNewline)
  p.indentedBlock:
    p.parseObjectBodyLine(fields, members)

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

proc parseErrorTypes(p: var Parser, errTypes: var seq[string]) =
  ## `[error: E]` or `[error: E | F]` — the enums this fn may raise.
  discard p.expect(tkColon)
  errTypes.add(p.expectMemberName("Expected error enum name after 'error:'").value)
  while p.current().kind == tkPipe:
    discard p.advance()
    errTypes.add(p.expectMemberName("Expected error enum name after '|'").value)

proc parseEffectList(p: var Parser, effects: var seq[EffectMarker],
                     errTypes: var seq[string], emit: var string,
                     strict = true) =
  ## `[io, may_block]` — the effect markers, with the two valued attributes
  ## that share the bracket folded in: `error:` names the enums a fn may
  ## raise, `emit:` the exact runtime/C proc name to emit.
  ##
  ## `strict` reports an unknown marker. A SIGNATURE block passes false: its
  ## brackets also carry binding attributes the effect vocabulary does not
  ## know, and rejecting those here would break every extern declaration.
  if p.current().kind != tkLBracket: return
  discard p.advance()
  while p.current().kind notin {tkRBracket, tkEOF}:
    let effSp = p.getSpan()
    let effName = p.expectAttrName("Expected effect marker").value
    if effName == "error":
      p.parseErrorTypes(errTypes)
    elif effName == "emit":
      discard p.expect(tkColon)
      emit = p.expect(tkStrLit, "Expected proc name string after 'emit:'").value
    else:
      var marker: EffectMarker
      if effectMarkerFromName(effName, marker): effects.add(marker)
      elif strict:
        p.reportError("Unknown effect marker: " & effName, effSp.line, effSp.col)
    if p.current().kind == tkComma: discard p.advance()
  discard p.expect(tkRBracket)

proc parseSigGenerics(p: var Parser): seq[string] =
  ## `fn toStr[T](...)` — Uppercase-first idents, like fn declarations.
  if not (p.current().kind == tkLBracket and p.peek(1).kind == tkIdent and
          p.peek(1).value.len > 0 and p.peek(1).value[0] in {'A' .. 'Z'}): return
  discard p.advance()
  while p.current().kind notin {tkRBracket, tkEOF}:
    result.add(p.expect(tkIdent, "Expected type parameter").value)
    if p.current().kind == tkComma: discard p.advance()
  discard p.expect(tkRBracket)

proc parseSigName(p: var Parser, what: string): string =
  ## The declared name, possibly a module-qualified sketch stub
  ## (`fn http::get(...)`).
  ##
  ## `expectMemberName`, not `expect(tkIdent)`: a declared name is a name-only
  ## position, so an attribute word is just a name here — `fn error(...)` in a
  ## `pending:` block is the log level's verb, not the `[error: E]` attribute.
  result = p.expectMemberName(
                    "Expected function name in " & what & " declaration").value
  if p.current().kind != tkColonColon: return
  discard p.advance()
  result.add("::" & p.expect(tkIdent, "Expected identifier after '::'").value)

type
  SignatureTail = tuple[effects: seq[EffectMarker], errTypes: seq[string],
                        emit: string]
    ## What follows a signature's return type: its effect markers, the error
    ## enums it may raise, and the C/runtime proc name an extern binds to.
    ## Effects and error enums can arrive from the return type itself (`!T`
    ## harvests) or from the `[...]` bracket.

proc parseReturnType(p: var Parser): Type =
  ## `-> T`, absent on a fn that returns nothing.
  if p.current().kind != tkArrow: return nil
  discard p.advance()
  p.parseType()

proc parseSignatureTail(p: var Parser, retType: Type,
                        strict = true): SignatureTail =
  ## The effects and error enums, harvested from the return type and then
  ## from the attribute bracket.
  harvestEffects(retType, result.effects, result.errTypes)
  p.parseEffectList(result.effects, result.errTypes, result.emit, strict)

proc parseOptionalBody(p: var Parser): Expr =
  ## `: body`, absent on a body-less signature.
  if p.current().kind != tkColon: return nil
  discard p.advance()
  p.parseBlock()

proc parseSigFn(p: var Parser, what: string): Decl =
  ## One body-less `fn` signature.
  let spDecl = p.getSpan()
  discard p.expect(tkFn)
  let name = p.parseSigName(what)
  let generics = p.parseSigGenerics()
  let params = parseParamList(p)
  let retType = p.parseReturnType()
  let sig = p.parseSignatureTail(retType, strict = false)
  if p.current().kind == tkNewline: discard p.advance()
  Decl(span: spDecl, kind: dkFn, name: name, fnParams: params,
       fnGenerics: generics, fnReturnType: retType, fnEffects: sig.effects,
       fnBody: nil, fnErrorTypes: sig.errTypes, externEmit: sig.emit)

proc parseSigMember(p: var Parser, what: string): Decl =
  ## One member of a signature block.
  ##
  ## `type Name = {...}` inside an extern block declares the C struct this
  ## library's functions take. Declaring it HERE (rather than outside) is what
  ## marks it foreign — the backends must then declare the C type instead of
  ## defining a layout-compatible duplicate, which the C compiler rejects.
  ## `fnsig Name = {...} -> T` is a C function pointer the library calls back
  ## through.
  if p.current().kind == tkType:
    result = p.parseTypeDecl(p.getSpan())
  elif p.current().kind == tkFnsig:
    result = p.parseFnSigDecl(p.getSpan())
  else:
    return p.parseSigFn(what)
  if p.current().kind == tkNewline: discard p.advance()

# Body-less signature block: `: NEWLINE INDENT (fn name(params) -> ret [fx])* DEDENT`
# Shared by pending: (typed holes) and extern: (runtime / C implemented).
proc parseSigBlock(p: var Parser, what: string): seq[Decl] =
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  while p.current().kind == tkNewline:
    discard p.advance()
  var decls: seq[Decl]
  p.indentedBlock:
    decls.add(p.parseSigMember(what))
  decls

# registry Name: | Variant {fields} — global event registry (spec 10)
proc parseBraceFields(p: var Parser): seq[FieldDef] =
  ## `{name: Type, ...}` — a variant's payload fields.
  discard p.expect(tkLBrace)
  while p.current().kind notin {tkRBrace, tkEOF}:
    let fSp = p.getSpan()
    let fName = p.expectMemberName("Expected variant field name").value
    discard p.expect(tkColon)
    result.add(FieldDef(name: fName, typ: p.parseType(), attrs: @[], span: fSp))
    if p.current().kind == tkComma: discard p.advance()
  discard p.expect(tkRBrace)

proc parseVariant(p: var Parser, what: string): VariantDef =
  ## `| Name {field: Type}` — one variant of a sum type, or one event of a
  ## registry. Identical grammar either way; `what` only names the context in
  ## the diagnostic. The parens around the payload are optional.
  discard p.expect(tkPipe)
  let vSp = p.getSpan()
  let vName = p.expectMemberName("Expected variant name" & what).value
  let hasParens = p.current().kind == tkLParen
  if hasParens: discard p.advance()
  var vFields: seq[FieldDef]
  if p.current().kind == tkLBrace: vFields = p.parseBraceFields()
  if hasParens: discard p.expect(tkRParen)
  if p.current().kind == tkNewline: discard p.advance()
  VariantDef(name: vName, fields: vFields, span: vSp)

proc parseRegistryDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  let name = p.expectTypeName("registry").value
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  var variants: seq[VariantDef]
  p.indentedBlock:
    variants.add(p.parseVariant(" in registry"))
  Decl(span: sp, kind: dkRegistry, name: name, variants: variants)

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
      let effName = p.expectAttrName("Expected effect marker").value
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

proc parseGenericParams(p: var Parser): seq[string] =
  ## `type Box[T]` — generic params are Uppercase idents; attrs are lowercase,
  ## which is what tells `Box[T]` apart from `u16 [saturating]`.
  if not (p.current().kind == tkLBracket and p.peek(1).kind == tkIdent and
          p.peek(1).value.len > 0 and p.peek(1).value[0] in {'A'..'Z'}): return
  discard p.advance()
  while p.current().kind notin {tkRBracket, tkEOF}:
    result.add(p.expect(tkIdent, "Expected generic parameter name").value)
    if p.current().kind == tkComma: discard p.advance()
  discard p.expect(tkRBracket)

# type Name[T] [attrs] = alias | : body (fields / | variants / transitions / invariant:)
# fnsig NAME[T, ...] = {params} -> ret — a named function-signature type
# (spec D#10c). params read exactly like a fn's ({a: int, b: int}); ret
# accepts anything a fn returns (a {struct}, a bare type, void, or !T/?T).
# NAME then usable as a type, `Mapper[int, str]` once instantiated.
proc parseFnSigDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()  # eat `fnsig`
  let name = p.expectTypeName("fnsig").value
  let generics = p.parseGenericParams()
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
  return Decl(span: sp, kind: dkFnSig, name: name, sigGenerics: generics,
              sigParams: params, sigReturn: ret)

proc parseAliasBody(p: var Parser, sp: Span, name: string,
                    generics: seq[string], attrs: seq[TypeAttr]): Decl =
  ## `type X = <type>`. Attributes may sit on EITHER side of the `=`:
  ##   type X [packed] = u16      (collected before the `=`)
  ##   type X = u16 [saturating]  (collected by parseType, after it)
  ## Keep both — assigning here used to CLOBBER the trailing ones, which is
  ## why `[saturating]` was silently dropped.
  discard p.advance()
  let aliasType = p.parseType()
  if p.current().kind == tkNewline: discard p.advance()
  for a in attrs: aliasType.attrs.add(a)
  Decl(span: sp, kind: dkType, name: name, generics: generics,
       typeBody: aliasType)

proc parseTransition(p: var Parser): Transition =
  ## `From -> To` — one edge of a sum type's transition table.
  let tSp = p.getSpan()
  let fromState = p.expect(tkIdent, "Expected transition source state").value
  discard p.expect(tkArrow)
  let toState = p.expect(tkIdent, "Expected transition target state").value
  if p.current().kind == tkNewline: discard p.advance()
  Transition(`from`: fromState, to: toState, span: tSp)

proc parseTransitionsBlock(p: var Parser, transitions: var seq[Transition]) =
  discard p.advance()          # `transitions`
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  p.indentedBlock:
    transitions.add(p.parseTransition())

proc parseTypeField(p: var Parser): FieldDef =
  ## `name: Type` — one field of a record body. A `= default` is parsed and
  ## dropped: defaults are not carried on the type today.
  let fSp = p.getSpan()
  let fName = p.expectMemberName("Expected field or variant in type").value
  discard p.expect(tkColon)
  let fType = p.parseType()
  if p.current().kind == tkAssign:
    discard p.advance()
    discard p.parseExpr()
  if p.current().kind == tkNewline: discard p.advance()
  FieldDef(name: fName, typ: fType, attrs: @[], span: fSp)

proc parseTypeBodyLine(p: var Parser, variants: var seq[VariantDef],
                       transitions: var seq[Transition],
                       fields: var seq[FieldDef], members: var seq[Decl]) =
  ## One line of a type body: a variant, the transitions block, an invariant,
  ## or a field.
  if p.current().kind == tkPipe:
    variants.add(p.parseVariant(""))
  elif p.current().kind == tkIdent and p.current().value == "transitions":
    p.parseTransitionsBlock(transitions)
  elif p.current().kind == tkAttr and p.current().value == "invariant":
    p.parseInvariantBlock(members)
  else:
    fields.add(p.parseTypeField())

proc parseTypeDecl(p: var Parser, sp: Span): Decl =
  ## `type Name[T] [attrs]` — either an alias after `=`, or an indented body
  ## whose lines decide whether it is a SUM (any `| variant`) or a RECORD.
  discard p.advance()
  let name = p.expectTypeName("type").value
  let generics = p.parseGenericParams()
  var attrs: seq[TypeAttr]
  p.parseDeclAttrs(attrs)
  if p.current().kind == tkAssign:
    return p.parseAliasBody(sp, name, generics, attrs)
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  while p.current().kind == tkNewline: discard p.advance()
  var variants: seq[VariantDef]
  var transitions: seq[Transition]
  var fields: seq[FieldDef]
  var members: seq[Decl]
  p.indentedBlock:
    p.parseTypeBodyLine(variants, transitions, fields, members)
  let bodyType =
    if variants.len > 0:
      Type(span: sp, kind: tkSum, variants: variants,
           transitions: transitions, attrs: attrs)
    else:
      Type(span: sp, kind: tkRecord, fields: fields, attrs: attrs)
  Decl(span: sp, kind: dkType, name: name, generics: generics,
       typeBody: bodyType, typeMembers: members)

proc parseSelectSource(p: var Parser): string =
  ## A bare message name, or a dotted event source like `timer.1s` /
  ## `timeout.5s` / `resp.ok` (timers and readiness — parsed now, given
  ## meaning in a later phase). Consumed up to the arrow.
  result = p.expect(tkIdent, "Expected a select source").value
  while p.current().kind in {tkDot, tkIdent, tkIntLit} and
        p.current().kind != tkArrow:
    result.add(p.advance().value)

proc parseSelectBinding(p: var Parser, armSp: Span): seq[Param] =
  ## `-> {name: Type, ...}` typed binding — the arm IS the message decl.
  ## `shutdown` (reserved) and empty-payload arms use `-> {}`.
  if p.current().kind != tkLBrace: return
  discard p.advance()
  while p.current().kind notin {tkRBrace, tkEOF}:
    let bn = p.expect(tkIdent, "Expected binding name").value
    var bt: Type = nil
    if p.current().kind == tkColon:
      discard p.advance()
      bt = p.parseType()
    result.add(Param(name: bn, typ: bt, span: armSp))
    if p.current().kind == tkComma: discard p.advance()
  discard p.expect(tkRBrace)

proc parseSelectArm(p: var Parser): SelectArm =
  ## `| source -> {binding}: body` — one arm of an `on select`.
  let armSp = p.getSpan()
  discard p.expect(tkPipe)
  let source = p.parseSelectSource()
  discard p.expect(tkArrow)
  let binding = p.parseSelectBinding(armSp)
  discard p.expect(tkColon)
  let body = p.parseExpr()
  if p.current().kind == tkNewline: discard p.advance()
  SelectArm(source: source, binding: binding, body: body, span: armSp)

proc parseSelectDecl(p: var Parser, sp: Span): Decl =
  ## `on select:` — wait on multiple event sources (spec §9.3). A direct
  ## dkSelect node, NOT an exkMatch reuse: each arm's source is a message
  ## handler name, `-> {binding}` binds the payload, `: body` runs.
  discard p.advance() # eat "on"
  discard p.advance() # eat "select"
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  var arms: seq[SelectArm]
  p.indentedBlock:
    arms.add(p.parseSelectArm())
  Decl(span: sp, kind: dkSelect, selectArms: arms)

proc parseQualifiedName(p: var Parser): string =
  ## `name` or `Type.member` — a fn may be declared as a member.
  result = p.expect(tkIdent, "Expected function or event name").value
  while p.current().kind == tkDot:
    discard p.advance()
    result.add("." & p.expect(tkIdent,
                              "Expected qualified name component").value)

proc parseBracketedNames(p: var Parser, what: string): seq[string] =
  ## `[A, B, C]` — a comma-separated name list in brackets.
  if p.current().kind != tkLBracket: return
  discard p.advance()
  while p.current().kind notin {tkRBracket, tkEOF}:
    result.add(p.expect(tkIdent, "Expected " & what).value)
    if p.current().kind == tkComma: discard p.advance()
  discard p.expect(tkRBracket)

# fn name[T]({params}) -> ret [effects]: body — also `on select` arms and event handlers
proc parseFnDecl(p: var Parser, sp: Span): Decl =
  if p.current().kind == tkOn and p.peek(1).kind == tkSelect:
    return p.parseSelectDecl(sp)
  discard p.advance()
  # `fn inline name(...)` — codegen-attribute keyword slot after fn
  var isInline = false
  if p.current().kind == tkIdent and p.current().value == "inline" and
     p.peek(1).kind == tkIdent:
    isInline = true
    discard p.advance()
  let name = p.parseQualifiedName()
  let generics = p.parseBracketedNames("generic parameter name")
  let params = parseParamList(p)
  let retType = p.parseReturnType()
  let sig = p.parseSignatureTail(retType)
  let body = p.parseOptionalBody()
  Decl(span: sp, kind: dkFn, name: name, fnGenerics: generics,
       fnParams: params, fnReturnType: retType, fnEffects: sig.effects,
       fnBody: body, fnErrorTypes: sig.errTypes, isInline: isInline)

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
  let name = p.expectTypeName("arena").value
  var attrs: seq[TypeAttr]
  p.parseDeclAttrs(attrs)
  discard p.expect(tkColon)
  var members: seq[Decl]
  discard p.expect(tkNewline)
  while p.current().kind == tkNewline:
    discard p.advance()
  p.indentedBlock:
    members.add(p.parseDecl())
  let arenaType = Type(span: spArena, kind: tkRecord, fields: @[], attrs: attrs)
  return Decl(span: spArena, kind: dkType, name: name, generics: @[], typeBody: arenaType)

# register Name at 0xADDR: bit fields — type-safe MMIO (spec 8.1)
proc parseBitSpec(p: var Parser): string =
  ## `bit 0` or `bits 3..7` — the layout a register field occupies, kept as
  ## the field's type NAME so codegen can lower it per backend.
  var bitType = ""
  if p.current().kind == tkIdent: bitType = p.advance().value
  var bitVal = ""
  if p.current().kind == tkIntLit:
    bitVal = p.advance().value
    if p.current().kind == tkDotDot:
      bitVal.add("..")
      discard p.advance()
      if p.current().kind == tkIntLit:
        bitVal.add(p.advance().value)
  bitType & " " & bitVal

proc parseAccessAttrs(p: var Parser): seq[TypeAttr] =
  ## Optional `[read, write]` on a register field.
  if p.current().kind != tkLBracket: return
  discard p.advance()
  while p.current().kind notin {tkRBracket, tkEOF}:
    let sp = p.getSpan()
    let name = p.expect(tkIdent, "Expected access attribute").value
    result.add(TypeAttr(name: name, value: "", span: sp))
    if p.current().kind == tkComma: discard p.advance()
  discard p.expect(tkRBracket)

proc parseRegisterField(p: var Parser): FieldDef =
  ## `name: bits 3..7 [read]` — one field of a memory-mapped register.
  let fSp = p.getSpan()
  let fName = p.expect(tkIdent, "Expected register field name").value
  discard p.expect(tkColon)
  let bitSpec = p.parseBitSpec()
  let attrs = p.parseAccessAttrs()
  if p.current().kind == tkNewline: discard p.advance()
  FieldDef(name: fName, typ: Type(span: fSp, kind: tkNamed, name: bitSpec),
           attrs: attrs, span: fSp)

proc parseRegisterDecl(p: var Parser, sp: Span): Decl =
  discard p.advance() # eat "register"
  let name = p.expect(tkIdent, "Expected register name").value
  discard p.expect(tkIdent) # eat "at"
  let address = p.expect(tkIntLit, "Expected address literal").value
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  var fields: seq[FieldDef]
  p.indentedBlock:
    fields.add(p.parseRegisterField())
  Decl(span: sp, kind: dkRegister, name: name, regAddress: address,
       regFields: fields)

# errors [policy: strict|continue|exit]: on unhandled(...) (spec 4.9)
const ErrorPolicies = ["strict", "continue", "exit"]

proc parseErrorPolicy(p: var Parser): string =
  ## `[policy: strict|continue|exit]`. `continue` is a keyword since the loops
  ## ruling, so it is accepted here as a policy name too.
  discard p.expect(tkLBracket)
  let key = p.expect(tkIdent, "Expected 'policy' in errors declaration").value
  if key != "policy":
    p.reportError("errors declaration takes [policy: strict|continue|exit], " &
                  "got '" & key & "'")
  discard p.expect(tkColon)
  result = if p.current().kind == tkContinue: p.advance().value
           else: p.expect(tkIdent, "Expected policy name").value
  if result notin ErrorPolicies:
    p.reportError("Unknown error policy '" & result &
                  "' — use strict, continue or exit")
  discard p.expect(tkRBracket)

proc parseUnhandledHandler(p: var Parser): Decl =
  ## The block's one legal member: `on unhandled({code, site})`.
  if p.current().kind != tkColon: return nil
  discard p.advance()
  discard p.expect(tkNewline)
  while p.current().kind == tkNewline: discard p.advance()
  var handler: Decl = nil
  p.indentedBlock:
    let member = p.parseDecl()
    if member != nil and member.kind == dkFn and member.name == "unhandled":
      handler = member
    else:
      p.reportError("errors block allows only 'on unhandled({code, site})'")
  handler

proc parseErrorsDecl(p: var Parser, sp: Span): Decl =
  discard p.advance() # errors
  let policy = p.parseErrorPolicy()
  Decl(span: sp, kind: dkErrors, name: "errors", policyName: policy,
       errHandler: p.parseUnhandledHandler())

# extern: / extern [c, header: "x.h"]: — sigs implemented by tuck_rt or C
type
  ExternBinding = object
    ## Where an extern block's signatures are actually implemented.
    header: string   # a C header to include
    lib: string      # a bare library name, decorated per backend
    impls: seq[tuple[backend, module: string]]

proc parseImplList(p: var Parser): seq[tuple[backend, module: string]] =
  ## `impl: nim "std/strutils", odin "core:strings"` — which module in the
  ## BACKEND's own language implements these sigs. The backend tag is a bare
  ## ident; the path stays a string because it is foreign (Nim and Odin spell
  ## module paths differently, and Odin's use ':' internally).
  discard p.expect(tkColon)
  while p.current().kind == tkIdent:
    let backend = p.advance().value
    let module = p.expect(tkStrLit, "Expected a module path string after '" &
                          backend & "' in impl:").value
    result.add((backend: backend, module: module))
    # another backend pair follows only if a comma leads to one
    if not (p.current().kind == tkComma and p.peek(1).kind == tkIdent and
            p.peek(2).kind == tkStrLit): break
    discard p.advance()

proc parseExternAttr(p: var Parser, binding: var ExternBinding) =
  ## One `[c, header: "x.h", lib: "z", impl: ...]` entry. "c" is the target
  ## marker and stores nothing.
  let key = p.expect(tkIdent,
    "Expected 'c', 'header', 'lib' or 'impl' in extern attributes").value
  if key == "header":
    discard p.expect(tkColon)
    binding.header = p.expect(tkStrLit, "Expected header path string").value
  elif key == "lib":
    # bare library name — each backend decorates it natively ("z" -> Nim
    # `-lz`, Odin `system:z`). Not a linker flag, so it stays portable.
    discard p.expect(tkColon)
    binding.lib = p.expect(tkStrLit,
                           "Expected library name string after 'lib:'").value
  elif key == "impl":
    binding.impls = p.parseImplList()

proc parseExternBinding(p: var Parser): ExternBinding =
  if p.current().kind != tkLBracket: return
  discard p.advance()
  while p.current().kind notin {tkRBracket, tkEOF}:
    p.parseExternAttr(result)
    if p.current().kind == tkComma: discard p.advance()
  discard p.expect(tkRBracket)

proc applyExternBinding(d: Decl, binding: ExternBinding) =
  ## A C struct carries the header so the backend declares the foreign type
  ## instead of defining its own copy. A C function pointer needs the C
  ## calling convention, not Nim's default closure (a two-word proc+env pair
  ## C cannot receive). Everything else is a bound function.
  if d.kind == dkType:
    d.typeExternHeader = binding.header
  elif d.kind == dkFnSig:
    d.sigIsCCallback = true
  else:
    d.isExtern = true
    d.externHeader = binding.header
    d.externLib = binding.lib
    d.externImpl = binding.impls

proc parseExternDecl(p: var Parser, sp: Span): Decl =
  discard p.advance() # extern
  let binding = p.parseExternBinding()
  let decls = p.parseSigBlock("extern")
  for d in decls: applyExternBinding(d, binding)
  Decl(span: sp, kind: dkExtern, name: "extern", mixinMembers: decls)

proc parseExprDecl(p: var Parser, sp: Span): Decl =
  ## A top-level statement: `let`, `var`, or a bare expression.
  Decl(span: sp, kind: dkExpr, expr: p.parseExpr())

proc parsePoolCount(p: var Parser, name: string, elem: Type): int =
  ## The `[count: N]` attribute a pool needs. It is the POOL's knob, not part
  ## of the element type, so it is read here and stripped below.
  for a in elem.attrs:
    if a.name != "count": continue
    try: result = parseInt(a.value)
    except ValueError:
      p.reportError("pool '" & name & "': count must be a whole number, " &
                    "got '" & a.value & "'")
  if result <= 0:
    p.reportError("pool '" & name & "' needs a slot count: `pool " & name &
      " = <ElementType> [count: N]`. A pool without a count has no static " &
      "footprint, which is the point of a pool.")

proc withoutAttr(t: Type, name: string): Type =
  ## The same type with one attribute removed.
  result = t
  var kept: seq[TypeAttr]
  for a in t.attrs:
    if a.name != name: kept.add(a)
  result.attrs = kept

proc parsePoolDecl(p: var Parser, sp: Span): Decl =
  ## spec 7.2: `pool Name = ElemType [count: N]` — N slots of an arbitrary
  ## element type. Reuses the `X = <type> [attrs]` shape; the name denotes the
  ## POOL, not a value of the element type.
  discard p.advance() # eat "pool"
  let name = p.expectTypeName("pool").value
  if p.current().kind != tkAssign:
    p.reportError("A pool declares its element type: " &
      "`pool " & name & " = <ElementType> [count: N]`")
  discard p.advance() # eat "="
  let elem = p.parseType()
  let count = p.parsePoolCount(name, elem)
  if p.current().kind == tkNewline: discard p.advance()
  Decl(span: sp, kind: dkPool, name: name,
       poolElem: elem.withoutAttr("count"), poolCount: count)

proc parseImportDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  let modName = p.expectMemberName("Expected module name after 'import'").value
  Decl(span: sp, kind: dkImport, name: modName)

proc parsePendingDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  let decls = p.parseSigBlock("pending")
  for d in decls: d.isPending = true
  Decl(span: sp, kind: dkPending, name: "pending", mixinMembers: decls)

proc siftSatisfies(members: seq[Decl], sats: var seq[string]): seq[Decl] =
  ## Sift the `satisfies I` lines out of the member list into their own field,
  ## so no later pass has to know they were ever members.
  for m in members:
    if m != nil and m.kind == dkExpr and m.expr != nil and
       m.expr.kind == exkVar and m.expr.name == satisfiesMark:
      sats.add(m.name)
    else:
      result.add(m)

proc parseObjectDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  let name = p.expectTypeName("object").value
  discard p.expect(tkColon)
  var fields: seq[FieldDef]
  var members: seq[Decl]
  p.parseObjectBody(fields, members)
  var sats: seq[string]
  let realMembers = siftSatisfies(members, sats)
  Decl(span: sp, kind: dkObject, name: name, objFields: fields,
       satisfies: sats, objMembers: realMembers)

proc parseActorDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  let name = p.expectTypeName("actor").value
  var attrs: seq[TypeAttr]
  p.parseDeclAttrs(attrs)
  discard p.expect(tkColon)
  var fields: seq[FieldDef]
  var members: seq[Decl]
  p.parseObjectBody(fields, members)
  Decl(span: sp, kind: dkActor, name: name, attrs: attrs,
       actorFields: fields, handlers: members)

proc parseStaticAssertDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  Decl(span: sp, kind: dkStaticAssert, assertExpr: p.parseExpr())

proc parseDistinctDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  let name = p.expectTypeName("distinct type").value
  discard p.expect(tkAssign)
  let aliasType = p.parseType()
  var attrs = aliasType.attrs  # parseType may have consumed [suffix: ms]
  attrs.add(TypeAttr(name: "distinct", value: "", span: sp))
  p.parseDeclAttrs(attrs)
  aliasType.attrs = attrs
  if p.current().kind == tkNewline: discard p.advance()
  Decl(span: sp, kind: dkType, name: name, generics: @[], typeBody: aliasType)

proc parseInterfaceDecl(p: var Parser, sp: Span): Decl =
  ## A contract (spec §5.2): the body IS the requirement list, so it is exactly
  ## the body-less sig block `extern` and `pending` already use. Kept apart
  ## from a mixin because the two mean opposite things — a mixin's members are
  ## code to compose INTO an object, an interface's are requirements to check
  ## AGAINST one.
  discard p.advance()
  let name = p.expectTypeName("interface").value
  Decl(span: sp, kind: dkInterface, name: name,
       ifaceMembers: p.parseSigBlock("interface"))

proc parseMixinDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  let name = p.expectTypeName("mixin").value
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  var members: seq[Decl]
  p.indentedBlock:
    members.add(p.parseDecl())
  Decl(span: sp, kind: dkMixin, name: name, mixinMembers: members)

proc parseWhenDecl(p: var Parser, sp: Span): Decl =
  ## spec §8.3: `when TARGET == "value":` — compile-time platform selection.
  ## v1 supports exactly this one shape (TARGET compared against a single
  ## string literal); it is not a general compile-time boolean expression.
  ## Resolution (which block's decls actually reach the module) happens
  ## later, in modules.resolveWhenBlocks — see the dkWhen comment in ast.nim
  ## for why that has to be a separate, uncached pass.
  discard p.advance()  # eat 'when'
  let targetWord = p.expect(tkIdent, "Expected 'TARGET' after 'when' — " &
    "'when' only supports 'when TARGET == \"...\":'").value
  if targetWord != "TARGET":
    p.reportError("'when' only supports 'when TARGET == \"...\":' — got " &
                  "'when " & targetWord & "'")
  discard p.expect(tkEq, "Expected '==' after 'when TARGET'")
  let valTok = p.expect(tkStrLit,
    "Expected a string literal naming the target, e.g. " &
    "when TARGET == \"stm32f4\":")
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  var members: seq[Decl]
  p.indentedBlock:
    members.add(p.parseDecl())
  Decl(span: sp, kind: dkWhen, name: "when", whenTargetValue: valTok.value,
       whenDecls: members)

proc parseCompositionDecl(p: var Parser, sp: Span): Decl =
  ## `+ Name` — compose a mixin or record into the enclosing declaration.
  discard p.advance()
  let name = p.expect(tkIdent, "Expected composition name after '+'").value
  let target = Expr(span: sp, kind: exkVar, name: name)
  Decl(span: sp, kind: dkExpr,
       expr: Expr(span: sp, kind: exkUnary, unaryOp: uoComposition,
                  operand: target))

proc parseConstDecl(p: var Parser, sp: Span): Decl =
  ## `const name = <compile-time data>` — a declaration, not a statement.
  discard p.advance()
  let name = p.expect(tkIdent, "Expected constant name after 'const'").value
  discard p.expect(tkAssign)
  Decl(span: sp, kind: dkConst, name: name, constVal: p.parseExpr())

proc parseSatisfyTargets(p: var Parser): seq[string] =
  ## The contracts after the `:` — one name, or several separated by commas.
  ##
  ## No brackets: `satisfies Dog: Speaker, Mover`. The `:` already separates
  ## subject from contracts, so a bracket would only add noise — and `[...]`
  ## after a type name means ATTRIBUTES everywhere else in the grammar
  ## (parser_type's bracketHoldsAttrs), which this is not.
  result.add(p.expect(tkIdent, "Expected an interface name").value)
  while p.current().kind == tkComma:
    discard p.advance()
    result.add(p.expect(tkIdent,
                        "Expected an interface name after ','").value)

const TopLevelKeywords = "fn, type, object, actor, task, interface, mixin, " &
  "fnsig, registry, decision, pending, distinct, const, import, extern, " &
  "errors, register, pool, arena, satisfies, static_assert, when"
  ## Everything parseDecl accepts to OPEN a declaration — the tokenized
  ## keywords plus the contextual ones recognised in contextualDecl.

const ContextualOpeners = ["extern", "errors", "register", "pool", "arena",
                           "satisfies"]
  ## Declaration openers the lexer does not tokenize — recognised by NAME in
  ## contextualDecl. Kept beside it: a new one added there must be added here,
  ## or the top-level check rejects it before contextualDecl ever runs.

proc opensDeclaration(p: Parser): bool =
  ## Does this word open a declaration? Only the contextual openers can, since
  ## every other declaration starts with a real token.
  p.current().value in ContextualOpeners

proc failNotADeclaration(p: var Parser) =
  ## A word that opens no declaration. THE FIRST WORD DECIDES — a module's top
  ## level is declarations only, so there is nothing else this could become and
  ## no reason to read ahead to find out.
  ##
  ## The parser used to fall through to an EXPRESSION statement here and die
  ## further along at whatever punctuation came next: `typ Light:` reported
  ## "Expected an expression here, found `:`", blaming column 10 for a typo in
  ## column 1. Three fuzz findings were that one mistake (`ty=e Light:`,
  ## `typfn ight:`, `ac:`), each pointing at the wrong place.
  p.reportError("'" & p.current().value & "' does not start a declaration. " &
                "A module's top level holds declarations only, opened by one " &
                "of: " & TopLevelKeywords & ".", dc = dcPaNotADeclaration)

proc parseSatisfiesDecl(p: var Parser, sp: Span): Decl =
  ## `satisfies Obj: Iface` / `satisfies Obj: A, B, C` at TOP LEVEL (spec §5.2).
  ##
  ## A CALLING module attaches an object it did not declare to a contract it
  ## did not declare — so a library's type can be used through your interface
  ## without editing the library.
  ##
  ## KEYWORD FIRST, like every other declaration. The form used to be
  ## `Obj satisfies Iface`, which put the deciding word SECOND and made this
  ## the one top-level construct needing a two-token lookahead — parseDecl had
  ## to send every stray ident through parseIdentDecl to find out. The `:`
  ## separates subject from contract, so the list form needs no brackets.
  discard p.advance()                  # `satisfies`
  let objName = p.expect(tkIdent,
                         "Expected an object name after 'satisfies'").value
  discard p.expect(tkColon,
                   "Expected ':' after the object name — write " &
                   "`satisfies " & objName & ": Iface`")
  let targets = p.parseSatisfyTargets()
  if p.current().kind == tkNewline: discard p.advance()
  Decl(span: sp, kind: dkSatisfies, name: objName, satisfyTargets: targets)

proc contextualDecl(p: var Parser, sp: Span, handled: var bool): Decl =
  ## Declarations introduced by a CONTEXTUAL keyword — a plain ident the lexer
  ## does not tokenize, so the grammar recognises it here by name. Each is
  ## gated on what follows, which is what keeps a variable named `register`
  ## or `pool` parsing as an expression.
  handled = true
  if p.current().kind != tkIdent:
    handled = false
    return nil
  case p.current().value
  # extern: / extern [c, header: "uart.h"]: — signatures implemented by the
  # runtime (tuck_rt) or imported from C. No bodies, no stubs.
  of "extern":
    if p.peek().kind in {tkColon, tkLBracket}: return p.parseExternDecl(sp)
  # Global error policy (spec 4.9): errors [policy: strict|continue|exit]:
  of "errors":
    if p.peek().kind == tkLBracket: return p.parseErrorsDecl(sp)
  of "register": return p.parseRegisterDecl(sp)
  of "pool": return p.parsePoolDecl(sp)
  of "arena": return p.parseArenaDecl()
  # `satisfies Obj: Iface` (spec 5.2) — gated on the object name following, so
  # a variable or field named `satisfies` still parses as an expression.
  of "satisfies":
    if p.peek().kind == tkIdent: return p.parseSatisfiesDecl(sp)
  else: discard
  handled = false

proc parseDecl*(p: var Parser): Decl =
  let sp = p.getSpan()
  let curr = p.current()
  var handled = false
  let contextual = p.contextualDecl(sp, handled)
  if handled: return contextual
  case curr.kind
  of tkDecision:
    return p.parseDecisionDecl(sp)

  of tkFn, tkOn:
    return p.parseFnDecl(sp)

  of tkImport: return p.parseImportDecl(sp)
  of tkPending: return p.parsePendingDecl(sp)
  of tkType: return p.parseTypeDecl(sp)
  of tkObject: return p.parseObjectDecl(sp)
  of tkActor: return p.parseActorDecl(sp)
  of tkTask: return p.parseTaskDecl(sp)
  of tkFnsig: return p.parseFnSigDecl(sp)
  of tkRegistry: return p.parseRegistryDecl(sp)
  of tkStaticAssert: return p.parseStaticAssertDecl(sp)
  of tkDistinct: return p.parseDistinctDecl(sp)
  of tkInterface: return p.parseInterfaceDecl(sp)
  of tkMixin: return p.parseMixinDecl(sp)
  of tkPlus: return p.parseCompositionDecl(sp)
  of tkConst: return p.parseConstDecl(sp)
  of tkWhen: return p.parseWhenDecl(sp)
  of tkIdent: return p.parseExprDecl(sp)
  else: return p.parseExprDecl(sp)

proc failIfNotTopLevelStart(p: var Parser) =
  ## Can this token open a top-level declaration at all? Two ways it cannot,
  ## both reported HERE rather than deeper, where the parser would only be able
  ## to describe the symptom it tripped over.
  if p.current().kind == tkIndent:
    # Nothing above to nest inside — the declaration this line belongs to is
    # missing, or misspelled so no block was ever opened.
    p.reportError("This line is indented, but nothing is open above it.",
                  dc = dcPaStrayIndent)
  if p.current().kind == tkIdent and not p.opensDeclaration():
    p.failNotADeclaration()

proc parseModule*(p: var Parser): Module =
  ## THE FIRST WORD DECIDES. A module's top level is declarations only, so an
  ## opening word that names no declaration is rejected right here — no
  ## lookahead, no shape-matching, no parsing ahead to find out what it might
  ## have been.
  ##
  ## The check belongs to parseModule rather than parseDecl because parseDecl
  ## is shared: an arena body (parseArenaDecl) calls it for ordinary statements
  ## like `ScratchSpace.reset`, which are legal THERE and only illegal here.
  let sp = p.getSpan()
  var decls: seq[Decl]
  while p.current().kind != tkEOF:
    if p.current().kind == tkNewline:
      discard p.advance()
    else:
      p.failIfNotTopLevelStart()
      decls.add(p.parseDecl())
  result = Module(path: @[], decls: decls, span: sp)
  # identity for the semantic layer, assigned once at the parse boundary
  assignIds(result)
