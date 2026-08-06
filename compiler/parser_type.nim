# compiler/parser_type.nim
#
# Type-expression parsing: parseType and its helpers (paren/brace/primary type
# forms, type-use attribute brackets, effect harvesting). Sits above the
# expression layer in the parser DAG — it calls parseExpr for attribute values
# (e.g. [align: 2]) but nothing calls back into it except the declaration layer.
import strutils, tables
import ast
import ../lexer
import parser_base
import parser_expr        # attribute values are ordinary expressions
import parser_stringify   # attr value → string (toString)

proc parseType*(p: var Parser): Type   # internal recursion (paren/primary/self)

proc parseTypeUseAttrs(p: var Parser): seq[TypeAttr] =
  while p.current().kind != tkRBracket and p.current().kind != tkEOF:
    let attrSp = p.getSpan()
    let attrName = p.expectAttrName("Expected attribute name").value
    if attrName == "error":
      # [error: FsError | NetError] — one attr per listed enum
      discard p.expect(tkColon)
      result.add(TypeAttr(name: "error",
        value: p.expectMemberName("Expected error enum name").value, span: attrSp))
      while p.current().kind == tkPipe:
        discard p.advance()
        result.add(TypeAttr(name: "error",
          value: p.expectMemberName("Expected error enum name after '|'").value, span: attrSp))
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
  # `{A, B}` or `{A = 10, B = 20}` (explicit values, for C enums) vs a record
  let isEnum = p.peek(2).kind in {tkComma, tkRBrace, tkAssign}
  discard p.advance()
  if isEnum:
    var variants: seq[VariantDef]
    while p.current().kind != tkRBrace and p.current().kind != tkEOF:
      let vSp = p.getSpan()
      let name = p.expect(tkIdent, "Expected tag name in enum").value
      # `= N` pins the tag's numeric value. Required for C enums, whose
      # values are rarely 0,1,2 — a mis-numbered tag is silently the wrong
      # constant at the ABI boundary.
      var val = ""
      if p.current().kind == tkAssign:
        discard p.advance()
        if p.current().kind == tkMinus:
          discard p.advance()
          val = "-"
        val.add(p.expect(tkIntLit, "Expected integer after '=' in enum").value)
      variants.add(VariantDef(name: name, fields: @[], value: val, span: vSp))
      if p.current().kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBrace)
    return Type(span: sp, kind: tkSum, variants: variants, transitions: @[], attrs: @[])
  else:
    var fields: seq[FieldDef]
    while p.current().kind != tkRBrace and p.current().kind != tkEOF:
      let fSp = p.getSpan()
      let name = p.expectMemberName("Expected field name in record definition").value
      discard p.expect(tkColon)
      let typ = p.parseType()
      fields.add(FieldDef(name: name, typ: typ, attrs: @[], span: fSp))
      if p.current().kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBrace)
    return Type(span: sp, kind: tkRecord, fields: fields, attrs: @[])

# --- `Name`, `Name[args]`, `Name [attrs]` ----------------------------------
#
# One bracket after a type name is either ATTRIBUTES or TYPE ARGUMENTS, and
# the reserved words settle it: an attribute name belongs to the language, so
# it can never be a user's type parameter. `Box[error]` is therefore an
# attribute bracket — and rejected, which is correct.

proc bracketHoldsAttrs(p: Parser): bool =
  ## `[sealed]` — a reserved name. `[count: 4]` — valued, and a type argument
  ## is never followed by a colon. Anything else is a type argument.
  let first = p.peek(1)
  first.kind == tkAttr or (first.kind == tkIdent and p.peek(2).kind == tkColon)

proc meantAsTypeArg(p: Parser, nameTok: Token): bool =
  ## Did the user plainly mean `Box[error]` as a type argument? Only when the
  ## bracket is TIGHT against a Capitalized name: a spaced bracket is the
  ## ordinary attribute position (`-> !Temperature [io]`, `u16 [saturating]`).
  let brk = p.tokens[p.cursor - 1]
  brk.line == nameTok.line and
    brk.column == nameTok.column + nameTok.value.len and
    p.peek(1).kind == tkRBracket and
    nameTok.value.len > 0 and nameTok.value[0] in {'A'..'Z'}

proc rejectReservedTypeArg(p: var Parser, nameTok: Token, attr: string) =
  p.reportError("`" & nameTok.value & "[" & attr & "]` — '" & attr &
    "' is a reserved attribute name and cannot be a type argument. Rename " &
    "it to something Capitalized and unreserved, e.g. `" & nameTok.value &
    "[Err]`.")

proc parseTypeArgs(p: var Parser, sp: Span, base: Type): Type =
  ## `Name[A, B]`. A SECOND bracket after the arguments is attributes —
  ## `Array[64, u8] [count: 8]`: args say what the type IS, attrs how it behaves.
  var args: seq[Type]
  while p.current().kind != tkRBracket and p.current().kind != tkEOF:
    args.add(p.parseType())
    if p.current().kind == tkComma:
      discard p.advance()
  discard p.expect(tkRBracket)
  result = Type(span: sp, kind: tkApp, base: base, args: args)
  if p.current().kind == tkLBracket:
    discard p.advance()
    result.attrs = p.parseTypeUseAttrs()

proc parseNamedType(p: var Parser, sp: Span): Type =
  let nameTok = p.advance()
  var base = Type(span: sp, kind: tkNamed, name: nameTok.value)
  if p.current().kind != tkLBracket: return base
  let attrs = p.bracketHoldsAttrs()
  let first = p.peek(1)
  discard p.advance()  # eat "["
  if not attrs: return p.parseTypeArgs(sp, base)
  if first.kind == tkAttr and p.meantAsTypeArg(nameTok):
    p.rejectReservedTypeArg(nameTok, first.value)
  base.attrs = p.parseTypeUseAttrs()
  base

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
    return p.parseNamedType(sp)

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

