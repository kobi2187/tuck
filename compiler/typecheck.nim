# compiler/typecheck.nim
# Bidirectional type checker: synthesize (pull types up) + check (push types down).
# Fail-fast: raises SemanticError on the first type error.
# Undeclared symbols synthesize Unknown, which is compatible with everything,
# so sketch code keeps compiling while declared code is checked strictly.
import ast, semantics, lowering, tables, strutils, sets

const UnknownName = "<unknown>"

proc unknownType(sp: Span): Type =
  Type(span: sp, kind: tkNamed, name: UnknownName)

proc isUnknown(t: Type): bool =
  t == nil or (t.kind == tkNamed and t.name == UnknownName)

const NumericNames = ["int", "i8", "i16", "i32", "i64",
                      "u8", "u16", "u32", "u64", "usize",
                      "f32", "f64", "float"].toHashSet

proc isNumeric(t: Type): bool =
  t != nil and t.kind == tkNamed and t.name in NumericNames

proc fail(msg: string, span: Span) =
  let err = newException(SemanticError, msg & " at line " & $span.line & ":" & $span.col)
  err.line = span.line
  err.col = span.col
  raise err

type
  Binding = tuple[typ: Type, isVar: bool]
  FnSig = tuple[params: seq[Param], ret: Type]
  TypeChecker = object
    module: Module
    fnSigs: Table[string, FnSig]
    typeDecls: Table[string, Type]
    scopes: seq[Table[string, Binding]]
    currentRet: Type
    currentFn: string
    pendingFns: Table[string, Span]
    implementedFns: HashSet[string]

proc pushScope(tc: var TypeChecker) = tc.scopes.add(initTable[string, Binding]())
proc popScope(tc: var TypeChecker) = discard tc.scopes.pop()

proc bindName(tc: var TypeChecker, name: string, typ: Type, isVar: bool) =
  tc.scopes[^1][name] = (typ, isVar)

proc lookup(tc: TypeChecker, name: string): tuple[found: bool, b: Binding] =
  for i in countdown(tc.scopes.high, 0):
    if tc.scopes[i].hasKey(name):
      return (true, tc.scopes[i][name])
  return (false, (Type(nil), false))

# Resolve a named type to its declared body (aliases, one level at a time).
proc resolve(tc: TypeChecker, t: Type, depth = 0): Type =
  if t == nil or depth > 10: return t
  if t.kind == tkNamed and tc.typeDecls.hasKey(t.name):
    return tc.resolve(tc.typeDecls[t.name], depth + 1)
  return t

# `!T` / `?T` / `!?T` parse as tkApp with a tkNamed base of "!", "?" or "!?".
proc unwrapEffect(t: Type): Type =
  if t != nil and t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
     t.base.name in ["!", "?", "!?"] and t.args.len == 1:
    return unwrapEffect(t.args[0])
  return t

# Field list of a type, resolving named/union/rename via lowering's helper.
proc fieldsOf(tc: TypeChecker, t: Type): seq[FieldDef] =
  if t == nil: return @[]
  getFieldsForType(tc.module, t)

proc typeName(t: Type): string =
  if t == nil: return "void"
  case t.kind
  of tkNamed: t.name
  of tkRecord:
    var parts: seq[string]
    for f in t.fields: parts.add(f.name & ": " & typeName(f.typ))
    "{" & parts.join(", ") & "}"
  of tkApp:
    if t.base != nil and t.base.kind == tkNamed and t.base.name in ["!", "?", "!?"]:
      t.base.name & typeName(t.args[0])
    else:
      var parts: seq[string]
      for a in t.args: parts.add(typeName(a))
      typeName(t.base) & "[" & parts.join(", ") & "]"
  of tkSum: "sum type"
  of tkUnion: "union type"
  else: "<type>"

proc compatible(tc: TypeChecker, actual, expected: Type): bool =
  let a = unwrapEffect(actual)
  let e = unwrapEffect(expected)
  if isUnknown(a) or isUnknown(e): return true
  if e.kind == tkNamed and e.name in ["void", "unit", "Self", "fn"]: return true
  if a.kind == tkNamed and a.name in ["void", "unit", "Self", "fn"]: return true

  # Nominal fast path
  if a.kind == tkNamed and e.kind == tkNamed:
    if a.name == e.name: return true
    if isNumeric(a) and isNumeric(e): return true  # ponytail: loose numeric widening; tighten with distinct types later
    # One side may be an alias for a record — fall through to structural
    let ra = tc.resolve(a)
    let re = tc.resolve(e)
    if ra != a or re != e: return tc.compatible(ra, re)
    return false

  # Structural: expected record => subset matching (spec 2.5)
  let eFields = if e.kind == tkRecord: e.fields else: tc.fieldsOf(e)
  if eFields.len > 0 or e.kind == tkRecord:
    let aFields = if a.kind == tkRecord: a.fields else: tc.fieldsOf(a)
    if aFields.len == 0 and a.kind != tkRecord:
      return false  # known non-record vs record
    for ef in eFields:
      var found = false
      for af in aFields:
        if af.name == ef.name:
          if not tc.compatible(af.typ, ef.typ): return false
          found = true
          break
      if not found: return false
    return true

  if a.kind == tkApp and e.kind == tkApp:
    if not tc.compatible(a.base, e.base): return false
    if a.args.len == e.args.len:
      for i in 0 ..< a.args.len:
        if not tc.compatible(a.args[i], e.args[i]): return false
    return true

  # Sum types and the rest: nominal only, handled above; unknown shapes pass
  return a.kind == e.kind

proc synthesize(tc: var TypeChecker, e: Expr): Type

proc check(tc: var TypeChecker, e: Expr, expected: Type, what: string) =
  if e == nil or expected == nil: return
  let actual = tc.synthesize(e)
  if not tc.compatible(actual, expected):
    fail("Type Error: " & what & " expects " & typeName(expected) &
         " but got " & typeName(actual), e.span)

# Match a single call argument against declared params.
# Tuck convention: one struct-shaped payload whose fields map to params by name.
proc checkCallArgs(tc: var TypeChecker, fnName: string, sig: FnSig, e: Expr) =
  let params = sig.params
  if e.args.len == 1 and params.len > 0:
    let arg = e.args[0]
    var argFields: seq[tuple[name: string, typ: Type, span: Span]] = @[]
    var shapeKnown = false
    if arg.kind == exkStruct:
      shapeKnown = true
      for f in arg.fields:
        argFields.add((f[0], tc.synthesize(f[1]), f[1].span))
    else:
      let t = tc.synthesize(arg)
      if not isUnknown(t):
        let fs = tc.fieldsOf(t)
        if fs.len > 0:
          shapeKnown = true
          for f in fs: argFields.add((f.name, f.typ, arg.span))
        elif params.len == 1:
          # Single scalar param: direct positional pass (e.g. `9 addOne`)
          if not tc.compatible(t, params[0].typ):
            fail("Type Error: argument to '" & fnName & "' expects " &
                 typeName(params[0].typ) & " but got " & typeName(t), arg.span)
          return
    if not shapeKnown: return  # Unknown payload — let it flow
    for p in params:
      if p.typ != nil and p.typ.kind == tkNamed and p.typ.name == "Self": continue
      var found = false
      for af in argFields:
        if af.name == p.name:
          if not tc.compatible(af.typ, p.typ):
            fail("Type Error: field '" & p.name & "' of call to '" & fnName &
                 "' expects " & typeName(p.typ) & " but got " & typeName(af.typ), af.span)
          found = true
          break
      if not found:
        fail("Type Error: call to '" & fnName & "' is missing required field '" &
             p.name & ": " & typeName(p.typ) & "'", e.span)
  elif e.args.len == params.len:
    for i in 0 ..< params.len:
      if params[i].typ != nil and params[i].typ.kind == tkNamed and
         params[i].typ.name == "Self": continue
      let t = tc.synthesize(e.args[i])
      if not tc.compatible(t, params[i].typ):
        fail("Type Error: argument " & $(i+1) & " to '" & fnName & "' expects " &
             typeName(params[i].typ) & " but got " & typeName(t), e.args[i].span)
  else:
    for a in e.args: discard tc.synthesize(a)

proc synthesize(tc: var TypeChecker, e: Expr): Type =
  if e == nil: return unknownType(Span())
  case e.kind
  of exkLit:
    let name = case e.litKind
      of lkInt: "int"
      of lkFloat: "float"
      of lkStr: "str"
      of lkBool: "bool"
      of lkUnit: "unit"
    Type(span: e.span, kind: tkNamed, name: name)
  of exkVar:
    let (found, b) = tc.lookup(e.name)
    if found: b.typ else: unknownType(e.span)
  of exkField:
    let recvT = tc.resolve(tc.synthesize(e.receiver))
    let fields = tc.fieldsOf(recvT)
    if fields.len > 0:
      for f in fields:
        if f.name == e.fieldName: return f.typ
      # Known record, missing field: the payoff error.
      # Sum types carry variant fields we don't track per-variant in v1 — only
      # flag when the receiver is a plain record.
      if recvT.kind == tkRecord:
        fail("Type Error: no field '" & e.fieldName & "' on type " & typeName(recvT), e.span)
    unknownType(e.span)
  of exkStruct:
    var fs: seq[FieldDef]
    for f in e.fields:
      fs.add(FieldDef(name: f[0], typ: tc.synthesize(f[1]), span: f[1].span))
    Type(span: e.span, kind: tkRecord, fields: fs)
  of exkList:
    var elemT = unknownType(e.span)
    for item in e.items:
      let t = tc.synthesize(item)
      if isUnknown(elemT): elemT = t
    Type(span: e.span, kind: tkApp,
         base: Type(span: e.span, kind: tkNamed, name: "Seq"), args: @[elemT])
  of exkCall:
    let calleeName = if e.callee != nil and e.callee.kind == exkVar: e.callee.name else: ""
    if calleeName in ["bake", "alias"]:
      for a in e.args: discard tc.synthesize(a)
      return unknownType(e.span)
    if calleeName != "" and tc.fnSigs.hasKey(calleeName):
      let sig = tc.fnSigs[calleeName]
      tc.checkCallArgs(calleeName, sig, e)
      return sig.ret
    if e.callee != nil and e.callee.kind != exkVar:
      discard tc.synthesize(e.callee)
    for a in e.args: discard tc.synthesize(a)
    unknownType(e.span)
  of exkBinary:
    let lt = tc.synthesize(e.left)
    let rt = tc.synthesize(e.right)
    case e.binOp
    of boAdd, boSub, boMul, boDiv, boMod:
      if not isUnknown(lt) and not isUnknown(rt) and not tc.compatible(lt, rt):
        fail("Type Error: arithmetic between " & typeName(lt) & " and " &
             typeName(rt), e.span)
      if isUnknown(lt): rt else: lt
    of boEq, boNeq, boLt, boGt, boLe, boGe:
      if not isUnknown(lt) and not isUnknown(rt) and not tc.compatible(lt, rt):
        fail("Type Error: comparison between " & typeName(lt) & " and " &
             typeName(rt), e.span)
      Type(span: e.span, kind: tkNamed, name: "bool")
    of boAnd, boOr, boXor:
      Type(span: e.span, kind: tkNamed, name: "bool")
  of exkUnary:
    let t = tc.synthesize(e.operand)
    if e.unaryOp == uoNot: Type(span: e.span, kind: tkNamed, name: "bool") else: t
  of exkBlock:
    tc.pushScope()
    var last = unknownType(e.span)
    for s in e.stmts:
      last = tc.synthesize(s)
    tc.popScope()
    last
  of exkIf:
    let condT = tc.synthesize(e.cond)
    if not isUnknown(condT) and not tc.compatible(condT,
        Type(span: e.span, kind: tkNamed, name: "bool")):
      fail("Type Error: if condition must be bool, got " & typeName(condT), e.cond.span)
    let thenT = tc.synthesize(e.thenBranch)
    discard tc.synthesize(e.elseBranch)
    thenT
  of exkMatch:
    discard tc.synthesize(e.subject)
    for arm in e.arms:
      tc.pushScope()
      # v1: pattern-bound names enter scope as Unknown
      if arm.pattern != nil and arm.pattern.kind == pkVar:
        tc.bindName(arm.pattern.name, unknownType(arm.pattern.span), false)
      discard tc.synthesize(arm.body)
      tc.popScope()
    unknownType(e.span)
  of exkFor:
    discard tc.synthesize(e.iterable)
    tc.pushScope()
    if e.iter != nil and e.iter.kind == pkVar:
      tc.bindName(e.iter.name, unknownType(e.iter.span), false)
    discard tc.synthesize(e.body)
    tc.popScope()
    Type(span: e.span, kind: tkNamed, name: "unit")
  of exkAssign:
    let valT = tc.synthesize(e.assignVal)
    if e.isDecl and e.target != nil and e.target.kind == exkVar:
      tc.bindName(e.target.name, valT, e.isMutable)
    else:
      let targetT = tc.synthesize(e.target)
      if not tc.compatible(valT, targetT):
        fail("Type Error: cannot assign " & typeName(valT) & " to " &
             typeName(targetT), e.span)
    Type(span: e.span, kind: tkNamed, name: "unit")
  of exkReturn:
    if e.returnVal != nil and tc.currentRet != nil:
      tc.check(e.returnVal, tc.currentRet, "return value of '" & tc.currentFn & "'")
    elif e.returnVal != nil:
      discard tc.synthesize(e.returnVal)
    Type(span: e.span, kind: tkNamed, name: "unit")
  of exkRaise:
    discard tc.synthesize(e.raiseVal)
    Type(span: e.span, kind: tkNamed, name: "unit")
  of exkChain:
    let baseT = tc.synthesize(e.base)
    # Spec 2.3: `..` mutation only on var bindings
    if e.base != nil and e.base.kind == exkVar:
      var hasMutation = false
      for step in e.steps:
        if step.op == coDotDot: hasMutation = true
      if hasMutation:
        let (found, b) = tc.lookup(e.base.name)
        if found and not b.isVar:
          fail("Type Error: cannot mutate '" & e.base.name &
               "' with '..' — it was declared with 'let'; use 'var'", e.span)
    for step in e.steps:
      discard tc.synthesize(step.arg)
    baseT
  of exkQualified, exkImport:
    unknownType(e.span)

proc collectSigs(tc: var TypeChecker, decls: seq[Decl]) =
  for d in decls:
    if d == nil: continue
    case d.kind
    of dkFn:
      tc.fnSigs[d.name] = (d.fnParams, d.fnReturnType)
      # Stale-pending check, order-independent: implemented + still pending = error
      if d.isPending:
        if d.name in tc.implementedFns:
          fail("Pending Error: '" & d.name & "' is implemented — remove it from the pending block", d.span)
        tc.pendingFns[d.name] = d.span
      elif d.fnBody != nil:
        if tc.pendingFns.hasKey(d.name):
          fail("Pending Error: '" & d.name & "' is implemented — remove it from the pending block", d.span)
        tc.implementedFns.incl(d.name)
    of dkTask: tc.fnSigs[d.name] = (d.taskParams, d.taskReturnType)
    of dkType:
      if d.typeBody != nil: tc.typeDecls[d.name] = d.typeBody
    of dkObject: tc.collectSigs(d.objMembers)
    of dkMixin: tc.collectSigs(d.mixinMembers)
    of dkActor: tc.collectSigs(d.handlers)
    else: discard

proc checkFnBody(tc: var TypeChecker, name: string, params: seq[Param],
                 ret: Type, body: Expr) =
  tc.pushScope()
  for p in params:
    # Params bound mutable: `set` functions legitimately use `..` on them
    tc.bindName(p.name, p.typ, true)
  tc.currentRet = ret
  tc.currentFn = name
  discard tc.synthesize(body)
  tc.currentRet = nil
  tc.currentFn = ""
  tc.popScope()

proc checkDecl(tc: var TypeChecker, d: Decl) =
  if d == nil: return
  case d.kind
  of dkFn: tc.checkFnBody(d.name, d.fnParams, d.fnReturnType, d.fnBody)
  of dkTask: tc.checkFnBody(d.name, d.taskParams, d.taskReturnType, d.taskBody)
  of dkExpr: discard tc.synthesize(d.expr)
  of dkObject:
    tc.pushScope()
    for f in d.objFields: tc.bindName(f.name, f.typ, true)
    for m in d.objMembers: tc.checkDecl(m)
    tc.popScope()
  of dkMixin:
    for m in d.mixinMembers: tc.checkDecl(m)
  of dkActor:
    tc.pushScope()
    for f in d.actorFields: tc.bindName(f.name, f.typ, true)
    for h in d.handlers: tc.checkDecl(h)
    tc.popScope()
  of dkStaticAssert: discard tc.synthesize(d.assertExpr)
  else: discard

proc sigStr(d: Decl): string =
  var parts: seq[string]
  for p in d.fnParams:
    parts.add(p.name & ": " & typeName(p.typ))
  result = d.name & "({" & parts.join(", ") & "})"
  if d.fnReturnType != nil:
    result.add(" -> " & typeName(d.fnReturnType))

proc collectPending(decls: seq[Decl], acc: var seq[string]) =
  for d in decls:
    if d == nil: continue
    case d.kind
    of dkFn:
      if d.isPending:
        acc.add(sigStr(d) & "   line " & $d.span.line)
    of dkObject: collectPending(d.objMembers, acc)
    of dkMixin: collectPending(d.mixinMembers, acc)
    of dkActor: collectPending(d.handlers, acc)
    else: discard

# The compile-time TODO list: every debug build prints what is still unimplemented.
proc pendingReport*(m: Module): seq[string] =
  collectPending(m.decls, result)

proc typecheckModule*(m: Module) =
  var tc = TypeChecker(module: m,
                       fnSigs: initTable[string, FnSig](),
                       typeDecls: initTable[string, Type]())
  tc.pushScope()  # module-level scope: top-level let/var visible across decls
  tc.collectSigs(m.decls)
  for d in m.decls:
    tc.checkDecl(d)
