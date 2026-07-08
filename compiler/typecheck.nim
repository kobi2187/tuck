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
    errPolicy: string            # strict (default) | continue | exit
    unhandledSites: seq[string]  # strict: error list; continue/exit: SHORTCUTS
    bodyBlock: Expr              # current fn's outermost block: its last stmt
                                 # is the implicit return, not a discard
    transitionCtx: bool          # constructing THROUGH transitionTo: sealed
                                 # non-initial variants are legal there
    distinctNames: HashSet[string]   # distinct types: nominal, never widened
    knownModules: HashSet[string]    # imported modules + qualified-pending prefixes

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
proc isWrapper(t: Type): bool =
  t != nil and t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
    t.base.name in ["!", "?", "!?"] and t.args.len == 1

proc unwrapEffect(t: Type): Type =
  if isWrapper(t):
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
  # Wrapper discipline: a bare T may flow where !T is expected (auto-wrap on
  # return), and !T matches !T — but a !T/?T value where bare T is expected is
  # an UNHANDLED error and never compatible. `or` / `?` unwrap explicitly.
  var a = actual
  var e = expected
  if isWrapper(a):
    if isWrapper(e):
      a = unwrapEffect(a)
      e = unwrapEffect(e)
    elif not isUnknown(e):
      return false
  else:
    e = unwrapEffect(e)
  if isUnknown(a) or isUnknown(e): return true
  if e.kind == tkNamed and e.name in ["void", "unit", "Self", "fn"]: return true
  if a.kind == tkNamed and a.name in ["void", "unit", "Self", "fn"]: return true

  # Nominal fast path
  if a.kind == tkNamed and e.kind == tkNamed:
    if a.name == e.name: return true
    # Distinct types are strictly nominal: no widening, no resolving through
    # to the base type. Milliseconds is not Microseconds is not u32.
    if a.name in tc.distinctNames or e.name in tc.distinctNames:
      return false
    if isNumeric(a) and isNumeric(e): return true  # loose numeric widening for primitives
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
    # Unit sugar: 5.ms is postfix application — ms is an ordinary function
    if e.receiver != nil and e.receiver.kind == exkLit and
       e.receiver.litKind in {lkInt, lkFloat} and tc.fnSigs.hasKey(e.fieldName):
      let sig = tc.fnSigs[e.fieldName]
      if sig.params.len == 1:
        let litT = tc.synthesize(e.receiver)
        if not tc.compatible(litT, sig.params[0].typ):
          fail("Type Error: argument to '" & e.fieldName & "' expects " &
               typeName(sig.params[0].typ) & " but got " & typeName(litT), e.span)
      return sig.ret
    # Variant construction: Type.Variant — sealed types only allow the
    # initial (first) variant directly; [unsafe] is the deserialization escape
    if e.receiver != nil and e.receiver.kind == exkVar and
       tc.typeDecls.hasKey(e.receiver.name):
      let declared = tc.typeDecls[e.receiver.name]
      if declared.kind == tkSum:
        var isVariant = false
        for v in declared.variants:
          if v.name == e.fieldName: isVariant = true
        if isVariant:
          var isSealed = false
          for a in declared.attrs:
            if a.name == "sealed": isSealed = true
          if isSealed and declared.variants.len > 0 and
             e.fieldName != declared.variants[0].name and not e.ctorUnsafe and
             not tc.transitionCtx:
            fail("Sealed Error: " & e.receiver.name & "." & e.fieldName &
                 " cannot be constructed directly — sealed types start at '" &
                 declared.variants[0].name & "'; reach '" & e.fieldName &
                 "' via transitions, or mark [unsafe] for deserialization", e.span)
          return Type(span: e.span, kind: tkNamed, name: e.receiver.name)
    let rawT = tc.synthesize(e.receiver)
    if isWrapper(rawT):
      fail("Type Error: unhandled " & typeName(rawT) &
           " — pass it to a handling function or propagate with '?' before accessing fields", e.span)
    let recvT = tc.resolve(rawT)
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
    var calleeName = ""
    if e.callee != nil and e.callee.kind == exkVar:
      calleeName = e.callee.name
    elif e.callee != nil and e.callee.kind == exkQualified:
      # module::fn — a KNOWN module (imported / pending-stubbed) is strict:
      # the fn must exist. An unknown prefix stays gradual, like any
      # undeclared identifier, so sketch code keeps compiling.
      let modName = if e.callee.modulePath.len > 0: e.callee.modulePath[0] else: ""
      calleeName = modName & "::" & e.callee.qualName
      if modName in tc.knownModules and not tc.fnSigs.hasKey(calleeName):
        fail("Type Error: module '" & modName & "' has no function '" &
             e.callee.qualName & "'", e.span)
    if calleeName in ["bake", "alias"]:
      for a in e.args: discard tc.synthesize(a)
      return unknownType(e.span)
    if calleeName != "" and calleeName in tc.distinctNames:
      # Calling a distinct type's name converts from its base (Nim-native)
      for a in e.args: discard tc.synthesize(a)
      return Type(span: e.span, kind: tkNamed, name: calleeName)
    if calleeName != "" and tc.fnSigs.hasKey(calleeName):
      let sig = tc.fnSigs[calleeName]
      tc.checkCallArgs(calleeName, sig, e)
      return sig.ret
    var calleeT = unknownType(e.span)
    if e.callee != nil and e.callee.kind != exkVar:
      # A construction fed by a transitionTo chain is a transition, not a
      # direct construction — sealed rules allow it (runtime matrix checks it)
      var viaTransition = false
      for a in e.args:
        if a != nil and a.kind == exkCall and a.callee != nil:
          if (a.callee.kind == exkVar and a.callee.name == "transitionTo") or
             (a.callee.kind == exkField and a.callee.fieldName == "transitionTo"):
            viaTransition = true
      let prevCtx = tc.transitionCtx
      if viaTransition: tc.transitionCtx = true
      calleeT = tc.synthesize(e.callee)  # variant constructions carry their type
      tc.transitionCtx = prevCtx
    for a in e.args: discard tc.synthesize(a)
    calleeT
  of exkBinary:
    let lt = tc.synthesize(e.left)
    # `or` is strictly boolean. Result structs flow whole; handling belongs to
    # the next function in the chain (prelude, eventually) or `?` propagation.
    let rt = tc.synthesize(e.right)
    for (t, side) in [(lt, e.left), (rt, e.right)]:
      if isWrapper(t):
        fail("Type Error: unhandled " & typeName(t) &
             " — pass it to a handling function or propagate with '?'", side.span)
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
    else:
      Type(span: e.span, kind: tkNamed, name: "bool")
  of exkUnary:
    if e.unaryOp == uoPropagate:
      let t = tc.synthesize(e.operand)
      if not isWrapper(t) and not isUnknown(t):
        fail("Type Error: '?' propagation needs a !T or ?T value, got " &
             typeName(t), e.span)
      if tc.currentRet == nil or not isWrapper(tc.currentRet):
        fail("Type Error: '?' propagates the error upward, so '" & tc.currentFn &
             "' must declare a !T return type", e.span)
      # Failure and absence propagate separately: the fn's wrapper must cover
      # the operand's ("!?" covers both).
      if isWrapper(t):
        let ok = tc.currentRet.base.name
        let opk = t.base.name
        let covered = (opk == "!" and ok in ["!", "!?"]) or
                      (opk == "?" and ok in ["?", "!?"]) or
                      (opk == "!?" and ok == "!?")
        if not covered:
          fail("Type Error: '?' on a " & opk & "T value cannot propagate " &
               "through '" & tc.currentFn & "' which returns " & ok &
               "T — the return type must cover it (use " &
               (if opk == "!?": "!?" else: opk) & "T or !?T)", e.span)
      return unwrapEffect(t)
    let t = tc.synthesize(e.operand)
    if e.unaryOp == uoNot: Type(span: e.span, kind: tkNamed, name: "bool") else: t
  of exkBlock:
    tc.pushScope()
    var last = unknownType(e.span)
    for s in e.stmts:
      last = tc.synthesize(s)
      # A dropped fallible result in statement position: the policy decides.
      # strict collects it as an error (ALL sites reported at the end);
      # continue/exit mark the site so codegen routes it to the handler.
      let isImplicitReturn = e == tc.bodyBlock and s == e.stmts[^1] and
                             tc.currentRet != nil
      if isWrapper(last) and not isImplicitReturn:
        let site = tc.currentFn & " line " & $s.span.line
        if tc.errPolicy in ["continue", "exit"]:
          s.shortcutSite = site
          tc.unhandledSites.add(typeName(last) & " at " & site)
        else:
          tc.unhandledSites.add(typeName(last) & " discarded at " & site)
    tc.popScope()
    last
  of exkIf:
    let condT = tc.synthesize(e.cond)
    if isWrapper(condT):
      fail("Type Error: unhandled " & typeName(condT) &
           " in condition — pass it to a handling function or propagate with '?'", e.cond.span)
    if not isUnknown(condT) and not tc.compatible(condT,
        Type(span: e.span, kind: tkNamed, name: "bool")):
      fail("Type Error: if condition must be bool, got " & typeName(condT), e.cond.span)
    let thenT = tc.synthesize(e.thenBranch)
    let elseT = tc.synthesize(e.elseBranch)
    # Branches that produce values must agree on the type
    if e.elseBranch != nil and not isUnknown(thenT) and not isUnknown(elseT) and
       not tc.compatible(thenT, elseT) and not tc.compatible(elseT, thenT):
      fail("Type Error: if branches produce different types: " &
           typeName(thenT) & " vs " & typeName(elseT), e.span)
    if isUnknown(thenT): elseT else: thenT
  of exkMatch:
    discard tc.synthesize(e.subject)
    var armT = unknownType(e.span)
    for arm in e.arms:
      tc.pushScope()
      # v1: pattern-bound names enter scope as Unknown
      if arm.pattern != nil and arm.pattern.kind == pkVar:
        tc.bindName(arm.pattern.name, unknownType(arm.pattern.span), false)
      let t = tc.synthesize(arm.body)
      tc.popScope()
      if not isUnknown(t) and not isUnknown(armT) and
         not tc.compatible(t, armT) and not tc.compatible(armT, t):
        fail("Type Error: match arms produce different types: " &
             typeName(armT) & " vs " & typeName(t), arm.span)
      if isUnknown(armT): armT = t
    armT
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
    of dkImport:
      tc.knownModules.incl(d.name)
    of dkFn:
      tc.fnSigs[d.name] = (d.fnParams, d.fnReturnType)
      if "::" in d.name:
        # qualified sketch stub legalizes its module prefix
        tc.knownModules.incl(d.name.split("::")[0])
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
      if d.typeBody != nil:
        tc.typeDecls[d.name] = d.typeBody
        for a in d.typeBody.attrs:
          if a.name == "distinct":
            tc.distinctNames.incl(d.name)
    of dkObject: tc.collectSigs(d.objMembers)
    of dkMixin: tc.collectSigs(d.mixinMembers)
    of dkActor: tc.collectSigs(d.handlers)
    of dkErrors:
      tc.errPolicy = d.policyName
      if d.policyName in ["continue", "exit"] and d.errHandler == nil:
        fail("Policy Error: errors [policy: " & d.policyName &
             "] needs an 'on unhandled({code, site})' handler", d.span)
    else: discard

# Pure functions are total: only [io]-marked functions (I/O, unknown input)
# may declare fallible !T returns. The pure core provably cannot fail.
proc checkFallibleNeedsIo(name: string, ret: Type, effects: seq[EffectMarker], span: Span) =
  if ret != nil and isWrapper(ret) and ret.base.name in ["!", "!?"] and
     emIo notin effects:
    fail("Effect Error: '" & name & "' returns " & typeName(ret) &
         " — fallible functions must be marked [io]; pure functions are total", span)

proc checkFnBody(tc: var TypeChecker, name: string, params: seq[Param],
                 ret: Type, body: Expr) =
  tc.pushScope()
  for p in params:
    # Params bound mutable: `set` functions legitimately use `..` on them
    tc.bindName(p.name, p.typ, true)
  tc.currentRet = ret
  tc.currentFn = name
  let prevBody = tc.bodyBlock
  tc.bodyBlock = body
  let bodyT = tc.synthesize(body)
  # Implicit return: the value flowing at the end of the body is the result.
  # Branch agreement (if/match) already unified branch types into bodyT.
  # unit/unknown tails mean explicit returns or sketch code — checked elsewhere.
  if ret != nil and body != nil and body.kind == exkBlock and body.stmts.len > 0:
    let lastKind = body.stmts[^1].kind
    if lastKind notin {exkReturn, exkRaise} and
       not isUnknown(bodyT) and
       not (bodyT.kind == tkNamed and bodyT.name in ["unit", "void"]) and
       not tc.compatible(bodyT, ret):
      fail("Type Error: '" & name & "' flows " & typeName(bodyT) &
           " out of its body but declares " & typeName(ret), body.stmts[^1].span)
  tc.bodyBlock = prevBody
  tc.currentRet = nil
  tc.currentFn = ""
  tc.popScope()

# --- Decision tables (spec 6.1): row width, unreachable rows, completeness ---

proc patCovers(a, b: Pattern): bool =
  # Does pattern a match everything pattern b matches? (per column)
  if a == nil or a.kind == pkWild: return true
  if b == nil or b.kind == pkWild: return false
  if a.kind != b.kind: return false
  case a.kind
  of pkVar: a.name == b.name
  of pkLit: a.litKind == b.litKind and a.litValue == b.litValue
  else: false

proc checkDecisionTable(tc: var TypeChecker, d: Decl) =
  if d.fnBody == nil or d.fnBody.kind != exkBlock or d.fnBody.stmts.len == 0:
    fail("Decision Error: decision table '" & d.name & "' has no rows", d.span)
  var rows: seq[tuple[pats: seq[Pattern], span: Span]]
  for s in d.fnBody.stmts:
    if s.kind != exkMatch or s.arms.len == 0: continue
    let pat = s.arms[0].pattern
    let pats = if pat != nil and pat.kind == pkTuple: pat.elems
               else: @[pat]
    if pats.len != d.fnParams.len:
      fail("Decision Error: row in '" & d.name & "' has " & $pats.len &
           " columns but the table declares " & $d.fnParams.len & " inputs", s.span)
    rows.add((pats, s.span))
    discard tc.synthesize(s.arms[0].body)
  # Enumerable domains (bool / fieldless sum types) get EXACT analysis:
  # every input combination is enumerated, so gaps and unreachable rows are
  # proven, not approximated. Open domains fall back to pairwise checks +
  # a mandatory catch-all row.
  var domains: seq[seq[string]]
  var allEnum = true
  var comboCount = 1
  for p in d.fnParams:
    let dom = enumDomain(tc.module, p.typ)
    if dom.len == 0: allEnum = false
    domains.add(dom)
    comboCount *= max(dom.len, 1)

  proc patValue(p: Pattern): string =
    if p == nil: return "_"
    case p.kind
    of pkWild: "_"
    of pkVar: p.name
    of pkLit: p.litValue
    else: "_"

  if allEnum and comboCount <= 4096:
    # Symbols in rows must be actual values of the column type
    for r in rows:
      for c in 0 ..< r.pats.len:
        let v = patValue(r.pats[c])
        if v != "_" and v notin domains[c]:
          fail("Decision Error: '" & v & "' is not a value of " &
               typeName(d.fnParams[c].typ) & " in table '" & d.name & "'", r.span)
    var rowUsed = newSeq[bool](rows.len)
    for combo in 0 ..< comboCount:
      # decode mixed-radix combo into one value per column
      var rem = combo
      var vals: seq[string]
      for c in countdown(domains.high, 0):
        vals.insert(domains[c][rem mod domains[c].len], 0)
        rem = rem div domains[c].len
      var hit = -1
      for i, r in rows:
        var matches = true
        for c in 0 ..< r.pats.len:
          let v = patValue(r.pats[c])
          if v != "_" and v != vals[c]:
            matches = false
            break
        if matches:
          hit = i
          break
      if hit == -1:
        var desc: seq[string]
        for c in 0 ..< vals.len:
          desc.add(d.fnParams[c].name & ": " & vals[c])
        fail("Decision Error: '" & d.name & "' has a gap — no row matches (" &
             desc.join(", ") & ")", d.span)
      rowUsed[hit] = true
    for i, used in rowUsed:
      if not used:
        fail("Decision Error: row " & $(i+1) & " of '" & d.name &
             "' is unreachable — earlier rows cover all its inputs", rows[i].span)
  else:
    # Unreachable: an earlier row covers this one in every column
    for j in 1 ..< rows.len:
      for i in 0 ..< j:
        var covered = true
        for c in 0 ..< rows[j].pats.len:
          if not patCovers(rows[i].pats[c], rows[j].pats[c]):
            covered = false
            break
        if covered:
          fail("Decision Error: row " & $(j+1) & " of '" & d.name &
               "' is unreachable — row " & $(i+1) & " already covers it", rows[j].span)
    # Open domains: completeness can't be proven, so require a catch-all row
    var lastAllWild = true
    for p in rows[^1].pats:
      if p != nil and p.kind != pkWild: lastAllWild = false
    if not lastAllWild:
      fail("Decision Error: '" & d.name & "' cannot be proven complete — " &
           "end the table with a catch-all row (all _)", d.span)

# --- Transition tables (spec 4.4): endpoints exist; sealed graph reachable ---

proc checkTransitions(tc: var TypeChecker, d: Decl) =
  let t = d.typeBody
  if t == nil or t.kind != tkSum or t.transitions.len == 0: return
  var variantNames = initHashSet[string]()
  for v in t.variants: variantNames.incl(v.name)
  for tr in t.transitions:
    if tr.`from` notin variantNames:
      fail("Transition Error: '" & tr.`from` & "' is not a variant of " & d.name, tr.span)
    if tr.to notin variantNames:
      fail("Transition Error: '" & tr.to & "' is not a variant of " & d.name, tr.span)
  var isSealed = false
  for a in t.attrs:
    if a.name == "sealed": isSealed = true
  if isSealed and t.variants.len > 0:
    # Every variant must be reachable from the initial (first) variant
    var reachable = [t.variants[0].name].toHashSet
    var grew = true
    while grew:
      grew = false
      for tr in t.transitions:
        if tr.`from` in reachable and tr.to notin reachable:
          reachable.incl(tr.to)
          grew = true
    for v in t.variants:
      if v.name notin reachable:
        fail("Transition Error: sealed type " & d.name & " variant '" & v.name &
             "' is unreachable from initial variant '" & t.variants[0].name & "'", v.span)

proc checkDecl(tc: var TypeChecker, d: Decl) =
  if d == nil: return
  case d.kind
  of dkFn:
    if d.isDecision:
      tc.checkDecisionTable(d)
      return
    checkFallibleNeedsIo(d.name, d.fnReturnType, d.fnEffects, d.span)
    tc.checkFnBody(d.name, d.fnParams, d.fnReturnType, d.fnBody)
  of dkTask:
    checkFallibleNeedsIo(d.name, d.taskReturnType, d.taskEffects, d.span)
    tc.checkFnBody(d.name, d.taskParams, d.taskReturnType, d.taskBody)
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
  of dkType: tc.checkTransitions(d)
  of dkErrors:
    if d.errHandler != nil: tc.checkDecl(d.errHandler)
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

# Same line format as pendingReport, from an index SigInfo (no AST needed).
proc sigLine*(si: SigInfo): string =
  var parts: seq[string]
  for p in si.params:
    parts.add(p.name & ": " & typeName(p.typ))
  result = si.name & "({" & parts.join(", ") & "})"
  if si.ret != nil:
    result.add(" -> " & typeName(si.ret))
  result.add("   line " & $si.line)

# Returns the SHORTCUTS list (continue/exit policies): each statement-position
# drop that will route to the global handler. Empty under strict — strict
# raises instead, listing every unhandled site at once (spec 4.9).
proc typecheckModule*(m: Module,
                      externSigs = initTable[string, FnSig](),
                      externPending = initTable[string, Span]()): seq[string] {.discardable.} =
  var tc = TypeChecker(module: m,
                       fnSigs: externSigs,
                       pendingFns: externPending,
                       typeDecls: initTable[string, Type](),
                       distinctNames: initHashSet[string](),
                       errPolicy: "strict")
  for qualName in externSigs.keys:
    if "::" in qualName:
      tc.knownModules.incl(qualName.split("::")[0])
  tc.pushScope()  # module-level scope: top-level let/var visible across decls
  tc.collectSigs(m.decls)
  for d in m.decls:
    tc.checkDecl(d)
  if tc.errPolicy == "strict" and tc.unhandledSites.len > 0:
    fail("Type Error: " & $tc.unhandledSites.len & " unhandled error result(s)" &
         " — bind, pass on, or propagate with '?' (policy: strict):\n  " &
         tc.unhandledSites.join("\n  "), m.span)
  if tc.errPolicy in ["continue", "exit"]:
    return tc.unhandledSites

# Signature export for the .tuck-cache index: same collection walk the
# checker uses (nested fns in objects/mixins/actors included).
proc moduleSigs*(m: Module): seq[SigInfo] =
  var tc = TypeChecker(module: m,
                       fnSigs: initTable[string, FnSig](),
                       typeDecls: initTable[string, Type](),
                       distinctNames: initHashSet[string](),
                       errPolicy: "strict")
  tc.collectSigs(m.decls)
  for name, sig in tc.fnSigs:
    result.add(SigInfo(name: name, params: sig.params, ret: sig.ret,
                       isPending: tc.pendingFns.hasKey(name),
                       line: tc.pendingFns.getOrDefault(name).line))

# Whole-program checking, order-independent: pass 1 collects EVERY module's
# signatures; pass 2 checks bodies against the full picture. `mods` is
# dep-first with the entry module last (compiler/modules.nim order); the
# entry module's SHORTCUTS list is returned.
# `preSigs`: modules resolved from the signature index — typechecked in an
# earlier run and unchanged since, so only their signatures participate.
proc typecheckProgram*(mods: seq[tuple[name, path: string, m: Module]],
                       preSigs = initTable[string, seq[SigInfo]]()): seq[string] {.discardable.} =
  var sigsByMod = initTable[string, Table[string, FnSig]]()
  var pendByMod = initTable[string, Table[string, Span]]()
  var importsByMod = initTable[string, seq[string]]()
  for (name, path, m) in mods:
    var tc = TypeChecker(module: m,
                         fnSigs: initTable[string, FnSig](),
                         typeDecls: initTable[string, Type](),
                         distinctNames: initHashSet[string](),
                         errPolicy: "strict")
    try:
      tc.collectSigs(m.decls)
    except SemanticError as err:
      err.msg = path & ":" & $err.line & ":" & $err.col & ": " & err.msg
      raise
    sigsByMod[name] = tc.fnSigs
    pendByMod[name] = tc.pendingFns
    var imps: seq[string]
    for d in m.decls:
      if d != nil and d.kind == dkImport: imps.add(d.name)
    importsByMod[name] = imps
  for (name, path, m) in mods:
    # importer sees imported fns under qualified keys only (no leakage)
    var extern = initTable[string, FnSig]()
    var externPend = initTable[string, Span]()
    for imp in importsByMod[name]:
      if sigsByMod.hasKey(imp):
        for fname, sig in sigsByMod[imp]:
          if "::" notin fname:
            extern[imp & "::" & fname] = sig
        for fname, sp in pendByMod.getOrDefault(imp):
          if "::" notin fname:
            externPend[imp & "::" & fname] = sp
      else:
        for si in preSigs.getOrDefault(imp):
          if "::" notin si.name:
            extern[imp & "::" & si.name] = (si.params, si.ret)
            if si.isPending:
              externPend[imp & "::" & si.name] = Span(line: si.line, col: 1)
    try:
      result = typecheckModule(m, extern, externPend)
    except SemanticError as err:
      err.msg = path & ":" & $err.line & ":" & $err.col & ": " & err.msg
      raise
