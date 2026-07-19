# compiler/typecheck.nim
# Bidirectional type checker: synthesize (pull types up) + check (push types down).
# Fail-fast: raises SemanticError on the first type error.
# Undeclared symbols synthesize Unknown, which is compatible with everything,
# so sketch code keeps compiling while declared code is checked strictly.
import ast, semantics, lowering, tables, strutils, sets

# UnknownName now lives in ast.nim (codegen needs it for typed-AST checks)

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
  FnSig = tuple[params: seq[Param], ret: Type, generics: seq[string]]
  TypeChecker = object
    module: Module
    fnSigs: Table[string, FnSig]
    typeDecls: Table[string, Type]
    typeGenerics: Table[string, seq[string]]  # generic type decls: Box -> @["T"]
    currentGenerics: HashSet[string]          # type params of the fn body being checked
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
    currentErrTypes: seq[string]     # [error: A | B] of the fn being checked
    okNarrowed: HashSet[string]      # results guarded by `if x.ok` in scope:
                                     # .value is legal only under the guard
    varErrTypes: Table[string, seq[string]]  # result vars -> the declared
                                     # [error: ...] enums of the fn that
                                     # produced them (match r.err typing)
    loopDepth: int               # break/continue legality (innermost loop only)
    varVariants: Table[string, seq[string]]  # spec 4.4b: per-var possible-
                                     # variant SET for transitions-declared
                                     # types (Type@Variant). Forked/unioned
                                     # at branches; reassignments checked
                                     # against the transition table.

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

proc substituteTypeFwd(t: Type, b: Table[string, Type]): Type

# Field list of a type, resolving named/union/rename via lowering's helper.
# `Box[int]` resolves through the generic decl with T substituted.
proc fieldsOf(tc: TypeChecker, t: Type): seq[FieldDef] =
  if t == nil: return @[]
  if t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
     tc.typeGenerics.hasKey(t.base.name) and
     tc.typeGenerics[t.base.name].len == t.args.len:
    var b = initTable[string, Type]()
    let gs = tc.typeGenerics[t.base.name]
    for i in 0 ..< gs.len: b[gs[i]] = t.args[i]
    let body = tc.typeDecls[t.base.name]
    for f in getFieldsForType(tc.module, body):
      result.add(FieldDef(name: f.name, typ: substituteTypeFwd(f.typ, b), span: f.span))
    return
  getFieldsForType(tc.module, t)

# --- spec 4.4b: static transition checking --------------------------------
# A sum type with a `transitions:` block is TRACKED: every var of it carries
# the set of variants it could statically be in (Type@Variant in
# diagnostics). A reassignment that changes variant is checked against the
# table at compile time; branch/loop merges union the sets; anything
# unprovable is an error — never a silent runtime fallback.

proc transType(tc: TypeChecker, t: Type): string =
  ## the declared name of a transitions-carrying sum type, or ""
  if t == nil or t.kind != tkNamed or not tc.typeDecls.hasKey(t.name): return ""
  let body = tc.typeDecls[t.name]
  if body.kind == tkSum and body.transitions.len > 0: return t.name
  ""

proc allVariants(tc: TypeChecker, typeName: string): seq[string] =
  for v in tc.typeDecls[typeName].variants: result.add(v.name)

proc hasEdge(tc: TypeChecker, typeName, frm, to: string): bool =
  for tr in tc.typeDecls[typeName].transitions:
    if tr.`from` == frm and tr.to == to: return true
  false

proc checkTransSet(tc: var TypeChecker, typeName: string,
                   cur, next: seq[string], sp: Span) =
  # legal iff every target is reachable from EVERY member of the current set
  for to in next:
    for frm in cur:
      if frm == to: continue  # same-variant reassignment: payload refresh
      if not tc.hasEdge(typeName, frm, to):
        fail("Transition Error: " & typeName & " cannot go " & frm & " -> " &
             to & " (value is " & typeName & "@{" & cur.join("|") &
             "}; that edge is not in the transitions table)", sp)

# Which variant set an RHS provides. Traceability is syntactic:
# constructions give a singleton, var copies give the var's set, a fn whose
# every return is a traceable construction gives their union — anything
# else is the full set (all variants possible).
proc fnReturnVariants(tc: TypeChecker, fnName, typeName: string): seq[string]

proc exprVariants(tc: TypeChecker, typeName: string, e: Expr): seq[string] =
  if e == nil: return tc.allVariants(typeName)
  case e.kind
  of exkField:
    # bare Type.Variant (incl. [unsafe])
    if e.receiver != nil and e.receiver.kind == exkVar and
       e.receiver.name == typeName:
      return @[e.fieldName]
  of exkCall:
    # {payload} Type.Variant
    if e.callee != nil and e.callee.kind == exkField and
       e.callee.receiver != nil and e.callee.receiver.kind == exkVar and
       e.callee.receiver.name == typeName:
      return @[e.callee.fieldName]
    # {args} someFn — trace the callee's return sites
    if e.callee != nil and e.callee.kind == exkVar:
      return tc.fnReturnVariants(e.callee.name, typeName)
  of exkVar:
    if tc.varVariants.hasKey(e.name):
      return tc.varVariants[e.name]
  else: discard
  tc.allVariants(typeName)

proc scanReturns(tc: TypeChecker, typeName: string, e: Expr,
                 acc: var seq[string], exact: var bool) =
  if e == nil or not exact: return
  case e.kind
  of exkReturn:
    if e.returnVal == nil:
      exact = false
      return
    let vs = tc.exprVariants(typeName, e.returnVal)
    # only constructions count as traceable inside a body scan (var sets
    # are flow-dependent and this is a syntactic pre-pass)
    if vs.len == 1:
      for v in vs:
        if v notin acc: acc.add(v)
    else:
      exact = false
  of exkBlock:
    for s in e.stmts: tc.scanReturns(typeName, s, acc, exact)
  of exkIf:
    tc.scanReturns(typeName, e.thenBranch, acc, exact)
    tc.scanReturns(typeName, e.elseBranch, acc, exact)
  of exkMatch:
    for arm in e.arms: tc.scanReturns(typeName, arm.body, acc, exact)
  of exkFor:
    tc.scanReturns(typeName, e.body, acc, exact)
  of exkWhile:
    tc.scanReturns(typeName, e.whileBody, acc, exact)
  else: discard

proc fnReturnVariants(tc: TypeChecker, fnName, typeName: string): seq[string] =
  for d in tc.module.decls:
    if d != nil and d.kind == dkFn and d.name == fnName and
       d.fnReturnType != nil and d.fnReturnType.kind == tkNamed and
       d.fnReturnType.name == typeName and d.fnBody != nil:
      var acc: seq[string]
      var exact = true
      tc.scanReturns(typeName, d.fnBody, acc, exact)
      # the implicit tail return is a plain trailing expression
      if d.fnBody.kind == exkBlock and d.fnBody.stmts.len > 0:
        let last = d.fnBody.stmts[^1]
        if last.kind notin {exkReturn, exkIf, exkMatch, exkFor, exkWhile,
                            exkBreak, exkContinue, exkBlock, exkAssign}:
          let vs = tc.exprVariants(typeName, last)
          if vs.len == 1:
            for v in vs:
              if v notin acc: acc.add(v)
          else:
            exact = false
      if exact and acc.len > 0: return acc
      return tc.allVariants(typeName)
  tc.allVariants(typeName)

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

# Method form: `x .fn {args}` / `x ..fn {args}` — the receiver rides as the
# fn's FIRST parameter (checked structurally when the receiver type has no
# name), the braced struct fills the remaining parameters by name. Builds and
# returns the positional exkCall node (receiver, then declared-order args),
# ty-stamped with the fn's return type — codegen emits it as-is.
proc synthMethodCall(tc: var TypeChecker, fnName: string, receiver: Expr,
                     recvT: Type, argStruct: Expr, sp: Span): Expr =
  let sig = tc.fnSigs[fnName]
  if sig.params.len == 0:
    fail("Type Error: '" & fnName & "' takes no parameters — it cannot be " &
         "called as a method on " & typeName(recvT), sp)
  if not tc.compatible(recvT, sig.params[0].typ):
    fail("Type Error: '" & fnName & "' first parameter expects " &
         typeName(sig.params[0].typ) & " but the receiver is " &
         typeName(recvT), sp)
  var argFields: seq[(string, Expr)]
  if argStruct != nil:
    if argStruct.kind != exkStruct:
      fail("Type Error: arguments to '" & fnName &
           "' must be a struct literal: {name: value, ...}", argStruct.span)
    argFields = argStruct.fields
  var args: seq[Expr] = @[receiver]
  for i in 1 ..< sig.params.len:
    let p = sig.params[i]
    var found = false
    for f in argFields:
      if f[0] == p.name:
        let ft = tc.synthesize(f[1])
        if not tc.compatible(ft, p.typ):
          fail("Type Error: field '" & p.name & "' of call to '" & fnName &
               "' expects " & typeName(p.typ) & " but got " & typeName(ft),
               f[1].span)
        args.add(f[1])
        found = true
        break
    if not found:
      fail("Type Error: call to '" & fnName & "' is missing required field '" &
           p.name & ": " & typeName(p.typ) & "'", sp)
  result = Expr(span: sp, kind: exkCall,
                callee: Expr(span: sp, kind: exkVar, name: fnName), args: args)
  result.ty = sig.ret

proc synthFieldAccess(tc: var TypeChecker, e: Expr): Type =
  # Result introspection: .ok/.err/.value on a !T/?T value IS the handling —
  # unwrapping is a plain if, no special syntax
  if e.fieldName in ["ok", "err", "value"] and e.receiver != nil and
     e.receiver.kind in {exkVar, exkField}:
    let recvT = tc.synthesize(e.receiver)
    if isWrapper(recvT):
      case e.fieldName
      of "ok": return Type(span: e.span, kind: tkNamed, name: "bool")
      of "value":
        # unwrap is legal only under this result's `if x.ok` guard
        if e.receiver.kind != exkVar or e.receiver.name notin tc.okNarrowed:
          fail("Type Error: unhandled " & typeName(recvT) & " — read .value" &
               " inside an `if " &
               (if e.receiver.kind == exkVar: e.receiver.name else: "<result>") &
               ".ok` guard", e.span)
        return unwrapEffect(recvT)
      else: return unknownType(e.span)  # .err — code; enum-typed later
  # `slot.invoke {args}` — call through a baked fn slot (builtin; the slot's
  # signature is checked by Nim at instantiation — gradual here)
  if e.fieldName == "invoke":
    discard tc.synthesize(e.receiver)
    var callArgs: seq[Expr] = @[]
    if e.dotArg != nil:
      if e.dotArg.kind != exkStruct:
        fail("Type Error: invoke arguments must be a struct literal: " &
             "slot.invoke {a, b}", e.dotArg.span)
      discard tc.synthesize(e.dotArg)
      callArgs.add(e.dotArg)
    e.callNode = Expr(span: e.span, kind: exkCall, callee: e.receiver,
                       args: callArgs)
    return unknownType(e.span)
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
  for f in fields:
    if f.name == e.fieldName:
      if tc.fnSigs.hasKey(e.fieldName):
        fail("Type Error: '" & e.fieldName & "' is both a field here and a " &
             "declared fn — rename one; fields and fns share the call " &
             "namespace", e.span)
      if e.dotArg != nil:
        fail("Type Error: '" & e.fieldName & "' is a field of " &
             typeName(recvT) & " — fields take no arguments; to set it, " &
             "use '.." & e.fieldName & " {value}' on a var", e.span)
      return f.typ
  # Not a field — `x.name` resolves to a fn by lookup, not syntax.
  if tc.fnSigs.hasKey(e.fieldName):
    if e.dotArg != nil:
      # `.fn {args}` method form: receiver = first param, args fill the rest
      e.callNode = tc.synthMethodCall(e.fieldName, e.receiver, recvT,
                                       e.dotArg, e.span)
      return e.callNode.ty
    # bare `.fn` — same as a whitespace call: the receiver is the payload
    e.callNode = Expr(span: e.span, kind: exkCall,
                       callee: Expr(span: e.span, kind: exkVar, name: e.fieldName),
                       args: @[e.receiver])
    return tc.synthesize(e.callNode)
  # Known record, missing field, no matching fn: the payoff error.
  # Sum types carry variant fields we don't track per-variant in v1 — only
  # flag when the receiver is a plain record.
  if fields.len > 0 and recvT.kind == tkRecord:
    fail("Type Error: no field '" & e.fieldName & "' on type " & typeName(recvT), e.span)
  unknownType(e.span)

proc synthBinary(tc: var TypeChecker, e: Expr): Type =
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
  of boRangeIncl, boRangeExcl:
    for (t, side) in [(lt, e.left), (rt, e.right)]:
      if not isUnknown(t) and typeName(t) notin
         ["int", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64"]:
        fail("Type Error: range bounds must be integers, got " & typeName(t),
             side.span)
    Type(span: e.span, kind: tkNamed, name: "range")
  else:
    Type(span: e.span, kind: tkNamed, name: "bool")

# spec 4.4b: union two branch states — narrowing is never discarded,
# only widened to the union of what the branches could produce
proc mergeVariants(a, b: Table[string, seq[string]]): Table[string, seq[string]] =
  result = a
  for k, v in b:
    if result.hasKey(k):
      var merged = result[k]
      for x in v:
        if x notin merged: merged.add(x)
      result[k] = merged
    else:
      result[k] = v

proc synthIf(tc: var TypeChecker, e: Expr): Type =
  let condT = tc.synthesize(e.cond)
  if isWrapper(condT):
    fail("Type Error: unhandled " & typeName(condT) &
         " in condition — pass it to a handling function or propagate with '?'", e.cond.span)
  if not isUnknown(condT) and not tc.compatible(condT,
      Type(span: e.span, kind: tkNamed, name: "bool")):
    fail("Type Error: if condition must be bool, got " & typeName(condT), e.cond.span)
  # `if r.ok:` narrows r inside the then-branch ONLY — outside the guard
  # the value is still the wrapped type (strict, scope-limited)
  var guard = ""
  if e.cond != nil and e.cond.kind == exkField and e.cond.fieldName == "ok" and
     e.cond.receiver != nil and e.cond.receiver.kind == exkVar and
     e.cond.receiver.name notin tc.okNarrowed:
    guard = e.cond.receiver.name
  if guard != "": tc.okNarrowed.incl(guard)
  let entryVariants = tc.varVariants
  let thenT = tc.synthesize(e.thenBranch)
  let thenVariants = tc.varVariants
  if guard != "": tc.okNarrowed.excl(guard)
  tc.varVariants = entryVariants
  let elseT = tc.synthesize(e.elseBranch)
  tc.varVariants = mergeVariants(thenVariants, tc.varVariants)
  # Branches that produce values must agree on the type
  if e.elseBranch != nil and not isUnknown(thenT) and not isUnknown(elseT) and
     not tc.compatible(thenT, elseT) and not tc.compatible(elseT, thenT):
    fail("Type Error: if branches produce different types: " &
         typeName(thenT) & " vs " & typeName(elseT), e.span)
  if isUnknown(thenT): elseT else: thenT

proc synthMatch(tc: var TypeChecker, e: Expr): Type =
  let subjT = tc.synthesize(e.subject)
  # spec 4.4b: matching a tracked var narrows it to the arm's variant
  # inside that arm; the after-match state is the union of the arm exits
  var trackedVar = ""
  var trackedType = ""
  if e.subject != nil and e.subject.kind == exkVar:
    trackedType = tc.transType(subjT)
    if trackedType != "": trackedVar = e.subject.name
  # `match r.err` — arms are variants of the producer's declared error
  # enums: validated (typo/ambiguity) and rewritten to Enum.Variant so
  # codegen emits the hashed code constants
  var errEnums: seq[string]
  if e.subject != nil and e.subject.kind == exkField and
     e.subject.fieldName == "err" and e.subject.receiver != nil and
     e.subject.receiver.kind == exkVar and
     tc.varErrTypes.hasKey(e.subject.receiver.name):
    errEnums = tc.varErrTypes[e.subject.receiver.name]
  if errEnums.len > 0:
    for arm in e.arms.mitems:
      if arm.pattern == nil or arm.pattern.kind == pkWild: continue
      if arm.pattern.kind != pkVar:
        fail("Type Error: match over an error code takes variant names " &
             "of " & errEnums.join(" | ") & " (or _)", arm.span)
      let aname = arm.pattern.name
      if "." in aname: continue  # already qualified
      var owners: seq[string]
      for en in errEnums:
        if tc.typeDecls.hasKey(en) and tc.typeDecls[en].kind == tkSum:
          for v in tc.typeDecls[en].variants:
            if v.name == aname: owners.add(en)
      if owners.len == 0:
        fail("Type Error: '" & aname & "' is not a variant of " &
             errEnums.join(" | "), arm.span)
      if owners.len > 1:
        fail("Type Error: '" & aname & "' is ambiguous (" &
             owners.join(", ") & ") — qualify it: " & owners[0] & "." &
             aname, arm.span)
      arm.pattern = Pattern(span: arm.pattern.span, kind: pkVar,
                            name: owners[0] & "." & aname)
  let entryVariants = tc.varVariants
  var mergedExit: Table[string, seq[string]]
  var firstArm = true
  var armT = unknownType(e.span)
  for arm in e.arms:
    tc.varVariants = entryVariants
    tc.pushScope()
    var isVariantArm = false
    if arm.pattern != nil and arm.pattern.kind == pkVar:
      if trackedVar != "" and
         arm.pattern.name in tc.allVariants(trackedType):
        # variant pattern: narrow the subject, do NOT bind the name
        isVariantArm = true
        tc.varVariants[trackedVar] = @[arm.pattern.name]
      else:
        # v1: pattern-bound names enter scope as Unknown
        tc.bindName(arm.pattern.name, unknownType(arm.pattern.span), false)
    let t = tc.synthesize(arm.body)
    tc.popScope()
    if firstArm:
      mergedExit = tc.varVariants
      firstArm = false
    else:
      mergedExit = mergeVariants(mergedExit, tc.varVariants)
    if not isUnknown(t) and not isUnknown(armT) and
       not tc.compatible(t, armT) and not tc.compatible(armT, t):
      fail("Type Error: match arms produce different types: " &
           typeName(armT) & " vs " & typeName(t), arm.span)
    if isUnknown(armT): armT = t
  if not firstArm: tc.varVariants = mergedExit
  armT

proc synthChain(tc: var TypeChecker, e: Expr): Type =
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
  # Each `..name {args}` step either SETS a field (payload is the single
  # {value: X} sugar) or calls a mutator fn — receiver rides as the first
  # parameter, and the result is reassigned into the base var (an ordinary
  # var-reassignment type check, so the fn must return the receiver's type).
  # Either way the chain stays on the base var.
  let recvT = tc.resolve(baseT)
  let fields = tc.fieldsOf(recvT)
  for step in e.steps.mitems:
    var isField = false
    for f in fields:
      if f.name == step.target.name:
        isField = true
        if tc.fnSigs.hasKey(f.name):
          fail("Type Error: '" & f.name & "' is both a field here and a " &
               "declared fn — rename one; fields and fns share the call " &
               "namespace", step.span)
        # payload must be a bare value: {80} (sugar for {value: 80}) or a
        # bare var {name}. A named pair like {host: 80} is rejected —
        # setting several fields is a mutator fn's job.
        let okShape = step.arg != nil and step.arg.kind == exkStruct and
                      step.arg.fields.len == 1 and
                      (step.arg.fields[0][0] == "value" or
                       (step.arg.fields[0][1] != nil and
                        step.arg.fields[0][1].kind == exkVar and
                        step.arg.fields[0][1].name == step.arg.fields[0][0]))
        if not okShape:
          fail("Type Error: setting field '" & f.name & "' with '..' takes " &
               "one bare value: ..." & f.name & " {" & typeName(f.typ) &
               "} — to set several fields, use a mutator fn", step.span)
        let valExpr = step.arg.fields[0][1]
        let vt = tc.synthesize(valExpr)
        if not tc.compatible(vt, f.typ):
          fail("Type Error: field '" & f.name & "' of " & typeName(recvT) &
               " is " & typeName(f.typ) & " but got " & typeName(vt),
               valExpr.span)
        break
    if not isField:
      if tc.fnSigs.hasKey(step.target.name):
        var retT: Type
        if step.arg != nil:
          # braced args pin the method form: receiver = first param
          step.callNode = tc.synthMethodCall(step.target.name, e.base, recvT,
                                              step.arg, step.span)
          retT = step.callNode.ty
        else:
          # bare `..fn`: same type-directed resolution as any other call
          # (whole-bind the receiver, else its fields fill the params)
          step.callNode = Expr(span: step.span, kind: exkCall,
                                callee: Expr(span: step.span, kind: exkVar,
                                             name: step.target.name),
                                args: @[e.base])
          retT = tc.synthesize(step.callNode)
        if not tc.compatible(retT, baseT):
          fail("Type Error: cannot assign " & typeName(retT) & " to " &
               typeName(baseT) & " — a '..' mutator must return the " &
               "receiver's type", step.span)
        # spec 4.4b: a mutator reassignment on a tracked var is a transition
        if e.base != nil and e.base.kind == exkVar:
          let tn = tc.transType(baseT)
          if tn != "":
            let cur = if tc.varVariants.hasKey(e.base.name):
                        tc.varVariants[e.base.name]
                      else: tc.allVariants(tn)
            let next = tc.fnReturnVariants(step.target.name, tn)
            tc.checkTransSet(tn, cur, next, step.span)
            tc.varVariants[e.base.name] = next
      elif recvT.kind == tkRecord:
        fail("Type Error: no field or fn '" & step.target.name & "' on type " &
             typeName(recvT), step.span)
  baseT

proc check(tc: var TypeChecker, e: Expr, expected: Type, what: string) =
  if e == nil or expected == nil: return
  let actual = tc.synthesize(e)
  if not tc.compatible(actual, expected):
    fail("Type Error: " & what & " expects " & typeName(expected) &
         " but got " & typeName(actual), e.span)

# --- Generics: simple substitution, Nim/C# style. No variance, no HKTs. ---
# Type params are inferred at the call site by unifying declared param types
# against the payload's field types, then substituted into params and return.

proc substituteType(t: Type, b: Table[string, Type]): Type =
  if t == nil or b.len == 0: return t
  case t.kind
  of tkNamed:
    if b.hasKey(t.name): return b[t.name]
    t
  of tkApp:
    var args: seq[Type]
    for a in t.args: args.add(substituteType(a, b))
    Type(span: t.span, kind: tkApp, attrs: t.attrs,
         base: substituteType(t.base, b), args: args)
  of tkRecord:
    var fields: seq[FieldDef]
    for f in t.fields:
      fields.add(FieldDef(name: f.name, typ: substituteType(f.typ, b), span: f.span))
    Type(span: t.span, kind: tkRecord, attrs: t.attrs, fields: fields)
  else: t

proc substituteTypeFwd(t: Type, b: Table[string, Type]): Type =
  substituteType(t, b)

proc inferBindings(tc: TypeChecker, declared, actual: Type,
                   generics: seq[string], bindings: var Table[string, Type],
                   fnName: string, sp: Span) =
  if declared == nil or actual == nil or isUnknown(actual): return
  case declared.kind
  of tkNamed:
    if declared.name in generics:
      if bindings.hasKey(declared.name):
        if not tc.compatible(actual, bindings[declared.name]) or
           not tc.compatible(bindings[declared.name], actual):
          fail("Type Error: generic parameter '" & declared.name & "' of '" &
               fnName & "' bound to both " & typeName(bindings[declared.name]) &
               " and " & typeName(actual), sp)
      else:
        bindings[declared.name] = actual
  of tkApp:
    if actual.kind == tkApp and declared.args.len == actual.args.len:
      tc.inferBindings(declared.base, actual.base, generics, bindings, fnName, sp)
      for i in 0 ..< declared.args.len:
        tc.inferBindings(declared.args[i], actual.args[i], generics, bindings, fnName, sp)
  of tkRecord:
    let aFields = if actual.kind == tkRecord: actual.fields else: tc.fieldsOf(actual)
    for df in declared.fields:
      for af in aFields:
        if af.name == df.name:
          tc.inferBindings(df.typ, af.typ, generics, bindings, fnName, sp)
          break
  else: discard

# Match a single call argument against declared params.
# Tuck convention: one struct-shaped payload whose fields map to params by name.
proc checkCallArgs(tc: var TypeChecker, fnName: string, sig: FnSig, e: Expr,
                   bindings: var Table[string, Type]) =
  var params = sig.params
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
        # Whole-bind first: a single-param fn whose param accepts the value
        # whole takes it as-is (`9 addOne`, `server describe` where describe's
        # param is the Server itself). Only otherwise does the value's SHAPE
        # matter — its fields map onto the params by name (`p advance`).
        if params.len == 1:
          if sig.generics.len > 0:
            tc.inferBindings(params[0].typ, t, sig.generics, bindings, fnName, arg.span)
          let expected = substituteType(params[0].typ, bindings)
          if tc.compatible(t, expected):
            return
          if tc.fieldsOf(t).len == 0:
            fail("Type Error: argument to '" & fnName & "' expects " &
                 typeName(expected) & " but got " & typeName(t), arg.span)
        let fs = tc.fieldsOf(t)
        if fs.len > 0:
          shapeKnown = true
          for f in fs: argFields.add((f.name, f.typ, arg.span))
    if not shapeKnown: return  # Unknown payload — let it flow
    if sig.generics.len > 0:
      # Infer type-param bindings from the payload, then check against the
      # substituted signature (conflicts reported inside inferBindings)
      for p in params:
        for af in argFields:
          if af.name == p.name:
            tc.inferBindings(p.typ, af.typ, sig.generics, bindings, fnName, af.span)
            break
      var subst: seq[Param]
      for p in params:
        subst.add(Param(name: p.name, typ: substituteType(p.typ, bindings), span: p.span))
      params = subst
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

proc synthCall(tc: var TypeChecker, e: Expr): Type =
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
  if calleeName == "alias" and e.args.len == 2 and e.args[1].kind == exkStruct:
    # expr alias(old: new, ...) — restructure: same values, renamed fields.
    # The result is a REAL record type; consumers check against it.
    let recvT = tc.resolve(tc.synthesize(e.args[0]))
    let recvFields = tc.fieldsOf(recvT)
    var fields: seq[FieldDef]
    for (oldName, newExpr) in e.args[1].fields.items:
      var ft: Type = nil
      for rf in recvFields:
        if rf.name == oldName: ft = rf.typ
      if ft == nil and recvFields.len > 0:
        fail("Type Error: alias source field '" & oldName &
             "' does not exist on " & typeName(recvT), e.span)
      if newExpr == nil or newExpr.kind != exkVar:
        fail("Type Error: alias target must be a plain field name: " &
             oldName & ": newName", e.span)
      fields.add(FieldDef(name: newExpr.name,
                          typ: (if ft == nil: unknownType(e.span) else: ft),
                          span: e.span))
    return Type(span: e.span, kind: tkRecord, fields: fields)
  if calleeName == "merge" and e.args.len == 1 and e.args[0].kind == exkStruct:
    # {a, b} merge — flatten: the UNION of the member structs' fields
    # becomes one flat struct. Name collision = error (no silent shadowing).
    var fields: seq[FieldDef]
    for (mname, mexpr) in e.args[0].fields.items:
      let mt = tc.resolve(tc.synthesize(mexpr))
      if isUnknown(mt): continue  # sketch member — stays gradual
      let mfs = tc.fieldsOf(mt)
      if mfs.len == 0:
        fail("Type Error: merge member '" & mname & "' must be a struct, " &
             "got " & typeName(mt), mexpr.span)
      for f in mfs:
        for existing in fields:
          if existing.name == f.name:
            fail("Type Error: merge field '" & f.name &
                 "' collides between members", e.span)
        fields.add(f)
    if fields.len == 0: return unknownType(e.span)
    return Type(span: e.span, kind: tkRecord, fields: fields)
  if calleeName == "bake" and e.args.len == 2 and e.args[1].kind == exkStruct:
    # expr bake {slot: :fn, arg: value, ...} — compile-time partial
    # application: rebuild the context struct with slots filled (fn refs)
    # or argument values overridden; unknown names ADD a field.
    let recvT = tc.resolve(tc.synthesize(e.args[0]))
    var fields: seq[FieldDef]
    for rf in tc.fieldsOf(recvT):
      fields.add(rf)
    for (name, valExpr) in e.args[1].fields.items:
      let vt = tc.synthesize(valExpr)
      var found = false
      for f in fields.mitems:
        if f.name == name:
          found = true
          # a value override keeps the field's declared type; fn refs
          # (Unknown) pass gradually
          if not isUnknown(vt) and not tc.compatible(vt, f.typ):
            fail("Type Error: bake override '" & name & "' expects " &
                 typeName(f.typ) & " but got " & typeName(vt), valExpr.span)
          break
      if not found:
        fields.add(FieldDef(name: name, typ: vt, span: valExpr.span))
    if fields.len == 0: return unknownType(e.span)
    return Type(span: e.span, kind: tkRecord, fields: fields)
  if calleeName in ["bake", "alias"]:
    for a in e.args: discard tc.synthesize(a)
    return unknownType(e.span)
  if calleeName != "" and calleeName in tc.distinctNames:
    # Calling a distinct type's name converts from its base (Nim-native)
    for a in e.args: discard tc.synthesize(a)
    return Type(span: e.span, kind: tkNamed, name: calleeName)
  if calleeName != "" and tc.typeGenerics.hasKey(calleeName):
    # {value: 5} Box — infer the type params from the payload fields; the ty
    # stamp lets codegen emit the explicit Box[int](...) Nim needs
    let gs = tc.typeGenerics[calleeName]
    var bindings = initTable[string, Type]()
    if e.args.len == 1 and e.args[0].kind == exkStruct:
      let declFields = getFieldsForType(tc.module, tc.typeDecls[calleeName])
      for f in e.args[0].fields:
        let ft = tc.synthesize(f[1])
        for df in declFields:
          if df.name == f[0]:
            tc.inferBindings(df.typ, ft, gs, bindings, calleeName, f[1].span)
            break
    else:
      for a in e.args: discard tc.synthesize(a)
    var gargs: seq[Type]
    for g in gs:
      if not bindings.hasKey(g):
        fail("Type Error: cannot infer generic parameter '" & g & "' of '" &
             calleeName & "' from the construction payload", e.span)
      gargs.add(bindings[g])
    return Type(span: e.span, kind: tkApp,
                base: Type(span: e.span, kind: tkNamed, name: calleeName), args: gargs)
  if calleeName != "" and tc.typeDecls.hasKey(calleeName) and
     not tc.fnSigs.hasKey(calleeName):
    # {fields} TypeName — construction produces the declared type
    for a in e.args: discard tc.synthesize(a)
    return Type(span: e.span, kind: tkNamed, name: calleeName)
  if calleeName != "" and tc.fnSigs.hasKey(calleeName):
    let sig = tc.fnSigs[calleeName]
    var bindings = initTable[string, Type]()
    tc.checkCallArgs(calleeName, sig, e, bindings)
    if sig.generics.len == 0: return sig.ret
    # Unbound type params degrade to Unknown (gradual, like sketch code)
    for g in sig.generics:
      if not bindings.hasKey(g):
        bindings[g] = unknownType(e.span)
    return substituteType(sig.ret, bindings)
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

# Kind dispatch lives in synthesizeKind; synthesize stamps the result onto the
# node (typed AST — codegen reads e.ty for type-directed lowering)
proc synthesizeKind(tc: var TypeChecker, e: Expr): Type =
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
  of exkField: tc.synthFieldAccess(e)
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
  of exkCall: tc.synthCall(e)
  of exkBinary: tc.synthBinary(e)
  of exkUnary:
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
      # `err X` is a control-flow exit (early error return), never a drop
      if isWrapper(last) and not isImplicitReturn and s.kind != exkRaise:
        let site = tc.currentFn & " line " & $s.span.line
        if tc.errPolicy in ["continue", "exit"]:
          s.shortcutSite = site
          tc.unhandledSites.add(typeName(last) & " at " & site)
        else:
          tc.unhandledSites.add(typeName(last) & " discarded at " & site)
    tc.popScope()
    last
  of exkIf: tc.synthIf(e)
  of exkMatch: tc.synthMatch(e)
  of exkFor:
    discard tc.synthesize(e.iterable)
    tc.pushScope()
    if e.iter != nil and e.iter.kind == pkVar:
      tc.bindName(e.iter.name, unknownType(e.iter.span), false)
    elif e.iter != nil and e.iter.kind == pkTuple:
      # `for idx, item in xs:` — idx is int, item is the (unknown) elem type
      if e.iter.elems.len >= 1 and e.iter.elems[0].kind == pkVar:
        tc.bindName(e.iter.elems[0].name,
                    Type(span: e.iter.span, kind: tkNamed, name: "int"), false)
      if e.iter.elems.len >= 2 and e.iter.elems[1].kind == pkVar:
        tc.bindName(e.iter.elems[1].name, unknownType(e.iter.span), false)
    # spec 4.4b: the body is checked ONCE against the entry set (no
    # fixed-point simulation); after the loop the state is entry ∪ body-exit
    let entryVariants = tc.varVariants
    inc tc.loopDepth
    discard tc.synthesize(e.body)
    dec tc.loopDepth
    tc.varVariants = mergeVariants(entryVariants, tc.varVariants)
    tc.popScope()
    Type(span: e.span, kind: tkNamed, name: "unit")
  of exkWhile:
    if e.whileCond != nil:
      let ct = tc.synthesize(e.whileCond)
      if not isUnknown(ct) and typeName(ct) != "bool":
        fail("Type Error: loop condition must be bool, got " & typeName(ct),
             e.whileCond.span)
    let entryVariants = tc.varVariants
    inc tc.loopDepth
    discard tc.synthesize(e.whileBody)
    dec tc.loopDepth
    tc.varVariants = mergeVariants(entryVariants, tc.varVariants)
    Type(span: e.span, kind: tkNamed, name: "unit")
  of exkBreak:
    if tc.loopDepth == 0:
      fail("Control Flow Error: break outside of a loop", e.span)
    Type(span: e.span, kind: tkNamed, name: "unit")
  of exkContinue:
    if tc.loopDepth == 0:
      fail("Control Flow Error: continue outside of a loop", e.span)
    Type(span: e.span, kind: tkNamed, name: "unit")
  of exkAssign:
    if e.isDecl and e.target != nil and e.target.kind == exkVar:
      let valT = tc.synthesize(e.assignVal)
      tc.bindName(e.target.name, valT, e.isMutable)
      # spec 4.4b: a fresh binding of a tracked type starts at the RHS's set
      let tn = tc.transType(valT)
      if tn != "":
        tc.varVariants[e.target.name] = tc.exprVariants(tn, e.assignVal)
      # a result binding remembers its producer's declared error enums,
      # so `match r.err` can be typed
      if isWrapper(valT) and e.assignVal != nil and
         e.assignVal.kind == exkCall and e.assignVal.callee != nil and
         e.assignVal.callee.kind == exkVar:
        for fd in tc.module.decls:
          if fd != nil and fd.kind == dkFn and
             fd.name == e.assignVal.callee.name and
             fd.fnErrorTypes.len > 0:
            tc.varErrTypes[e.target.name] = fd.fnErrorTypes
    else:
      let targetT = tc.synthesize(e.target)
      # spec 4.4b: the RHS of a checked transition assignment may construct
      # a non-initial sealed variant — the transition IS the legal path
      # (static analogue of the old transitionTo-chain exemption)
      let trackedAssign = e.target != nil and e.target.kind == exkVar and
                          tc.transType(targetT) != ""
      let prevCtx = tc.transitionCtx
      if trackedAssign: tc.transitionCtx = true
      let valT = tc.synthesize(e.assignVal)
      tc.transitionCtx = prevCtx
      if not tc.compatible(valT, targetT):
        fail("Type Error: cannot assign " & typeName(valT) & " to " &
             typeName(targetT), e.span)
      # spec 4.4b: a reassignment that changes variant IS a transition —
      # checked against the table, no user-written transitionTo needed
      if e.target != nil and e.target.kind == exkVar:
        let tn = tc.transType(targetT)
        if tn != "":
          let cur = if tc.varVariants.hasKey(e.target.name):
                      tc.varVariants[e.target.name]
                    else: tc.allVariants(tn)
          let next = tc.exprVariants(tn, e.assignVal)
          tc.checkTransSet(tn, cur, next, e.span)
          tc.varVariants[e.target.name] = next
    Type(span: e.span, kind: tkNamed, name: "unit")
  of exkReturn:
    if e.returnVal != nil and tc.currentRet != nil:
      tc.check(e.returnVal, tc.currentRet, "return value of '" & tc.currentFn & "'")
    elif e.returnVal != nil:
      discard tc.synthesize(e.returnVal)
    Type(span: e.span, kind: tkNamed, name: "unit")
  of exkRaise:
    # `err X` — an error value of the current fn's fallible result type.
    # X is a variant of a declared [error: E] enum (qualified E.V or bare V),
    # or a dynamic re-raise of an existing code (err resp.err).
    if tc.currentRet == nil or not isWrapper(tc.currentRet):
      fail("Type Error: 'err' raises into a fallible result, so '" &
           tc.currentFn & "' must declare a !T return type", e.span)
    let rv = e.raiseVal
    if rv != nil and rv.kind == exkVar:
      if tc.currentErrTypes.len == 0:
        fail("Type Error: 'err " & rv.name & "' needs a declared error type" &
             " — add [error: <Enum>] to '" & tc.currentFn & "'", e.span)
      var owners: seq[string]
      for en in tc.currentErrTypes:
        if tc.typeDecls.hasKey(en) and tc.typeDecls[en].kind == tkSum:
          for v in tc.typeDecls[en].variants:
            if v.name == rv.name: owners.add(en)
      if owners.len == 0:
        fail("Type Error: '" & rv.name & "' is not a variant of " &
             tc.currentErrTypes.join(" | "), e.span)
      if owners.len > 1:
        fail("Type Error: '" & rv.name & "' is ambiguous (" &
             owners.join(", ") & ") — qualify it: " & owners[0] & "." & rv.name,
             e.span)
      # resolve the shorthand for codegen: err V → err Enum.V
      e.raiseVal = Expr(span: rv.span, kind: exkField,
                        receiver: Expr(span: rv.span, kind: exkVar, name: owners[0]),
                        fieldName: rv.name)
    elif rv != nil and rv.kind == exkField and rv.receiver != nil and
         rv.receiver.kind == exkVar and tc.typeDecls.hasKey(rv.receiver.name) and
         tc.typeDecls[rv.receiver.name].kind == tkSum:
      let en = rv.receiver.name
      if tc.currentErrTypes.len > 0 and en notin tc.currentErrTypes:
        fail("Type Error: '" & tc.currentFn & "' raises " & en &
             " but declares [error: " & tc.currentErrTypes.join(" | ") & "]", e.span)
      var found = false
      for v in tc.typeDecls[en].variants:
        if v.name == rv.fieldName: found = true
      if not found:
        fail("Type Error: '" & rv.fieldName & "' is not a variant of " & en, e.span)
    else:
      discard tc.synthesize(rv)  # dynamic re-raise
    # control-flow exit: neutral type so branches/blocks don't see a wrapper
    Type(span: e.span, kind: tkNamed, name: "unit")
  of exkChain: tc.synthChain(e)
  of exkQualified, exkImport:
    unknownType(e.span)

proc synthesize(tc: var TypeChecker, e: Expr): Type =
  if e == nil: return unknownType(Span())
  result = tc.synthesizeKind(e)
  e.ty = result

proc collectSigs(tc: var TypeChecker, decls: seq[Decl]) =
  for d in decls:
    if d == nil: continue
    case d.kind
    of dkImport:
      tc.knownModules.incl(d.name)
    of dkFn:
      tc.fnSigs[d.name] = (d.fnParams, d.fnReturnType, d.fnGenerics)
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
    of dkTask: tc.fnSigs[d.name] = (d.taskParams, d.taskReturnType, @[])
    of dkType:
      if d.typeBody != nil:
        tc.typeDecls[d.name] = d.typeBody
        if d.generics.len > 0:
          tc.typeGenerics[d.name] = d.generics
        for a in d.typeBody.attrs:
          if a.name == "distinct":
            tc.distinctNames.incl(d.name)
      # manager types carry functionality: member fns join the catalog
      tc.collectSigs(d.typeMembers)
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
                 ret: Type, body: Expr, generics: seq[string] = @[]) =
  tc.pushScope()
  # Generic bodies are gradual: type params bind as Unknown (checked at the
  # call site via inference; Nim rechecks per instantiation)
  var gsub = initTable[string, Type]()
  for g in generics: gsub[g] = unknownType(Span())
  let savedVariants = tc.varVariants
  tc.varVariants = initTable[string, seq[string]]()
  for p in params:
    # Params bound mutable: `set` functions legitimately use `..` on them
    tc.bindName(p.name, substituteType(p.typ, gsub), true)
    # spec 4.4b: a param of a tracked type enters at the FULL variant set —
    # transitions on it need `match` narrowing first
    let ptn = tc.transType(p.typ)
    if ptn != "":
      tc.varVariants[p.name] = tc.allVariants(ptn)
  # `input` — the whole incoming payload as one struct (reserved keyword)
  if params.len > 0:
    var inputFields: seq[FieldDef]
    for p in params:
      inputFields.add(FieldDef(name: p.name, typ: substituteType(p.typ, gsub),
                               span: p.span))
    tc.bindName("input", Type(span: params[0].span, kind: tkRecord,
                              fields: inputFields), false)
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
  tc.varVariants = savedVariants
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
    tc.currentErrTypes = d.fnErrorTypes
    tc.checkFnBody(d.name, d.fnParams, d.fnReturnType, d.fnBody, d.fnGenerics)
    tc.currentErrTypes = @[]
  of dkTask:
    checkFallibleNeedsIo(d.name, d.taskReturnType, d.taskEffects, d.span)
    tc.checkFnBody(d.name, d.taskParams, d.taskReturnType, d.taskBody)
  of dkExpr: discard tc.synthesize(d.expr)
  of dkObject:
    tc.pushScope()
    for f in d.objFields: tc.bindName(f.name, f.typ, true)
    # member fns see the object itself as a mutable `self`
    tc.bindName("self", Type(span: d.span, kind: tkNamed, name: d.name), true)
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
  tc.pushScope()  # module-level scope: consts visible across decls
  tc.collectSigs(m.decls)
  # const declarations: Nim-static semantics — arbitrary PURE computation,
  # evaluated at compile time by the backend's const evaluator. Tuck rejects
  # only what would break there: [io] calls (pure only), record-type
  # constructions (records are reference values — not const-able), and
  # unknown callees. Bound before body checks so any fn can reference them.
  for d in m.decls:
    if d != nil and d.kind == dkConst:
      proc isIoFn(m: Module, name: string): bool =
        for fd in m.decls:
          if fd != nil and fd.kind == dkFn and fd.name == name:
            return emIo in fd.fnEffects
        false
      proc fnDeclared(m: Module, name: string): bool =
        for fd in m.decls:
          if fd != nil and fd.kind == dkFn and fd.name == name: return true
        false
      proc constCheck(tc: TypeChecker, m: Module, cname: string, e: Expr,
                      sp: Span) =
        if e == nil: return
        case e.kind
        of exkLit, exkQualified: discard  # literals; :fn refs
        of exkStruct:
          for f in e.fields: constCheck(tc, m, cname, f[1], sp)
        of exkList:
          for it in e.items: constCheck(tc, m, cname, it, sp)
        of exkUnary: constCheck(tc, m, cname, e.operand, sp)
        of exkBinary:
          constCheck(tc, m, cname, e.left, sp)
          constCheck(tc, m, cname, e.right, sp)
        of exkField:
          # unit sugar (5.ms) and field reads over const sub-expressions
          if e.receiver != nil: constCheck(tc, m, cname, e.receiver, sp)
          if e.receiver != nil and e.receiver.kind == exkLit and
             isIoFn(m, e.fieldName):
            fail("Const Error: 'const " & cname & "' must be pure — '" &
                 e.fieldName & "' is [io]", sp)
        of exkCall:
          for a in e.args: constCheck(tc, m, cname, a, sp)
          if e.callee != nil and e.callee.kind == exkVar:
            let callee = e.callee.name
            if callee in ["bake", "merge", "alias"]: discard
            elif tc.typeDecls.hasKey(callee) and
                 tc.typeDecls[callee].kind == tkRecord:
              fail("Const Error: 'const " & cname & "' cannot hold a " &
                   "record construction (records are reference values) — " &
                   "use a plain struct literal", sp)
            elif tc.distinctNames.contains(callee): discard  # base conversion
            elif isIoFn(m, callee):
              fail("Const Error: 'const " & cname & "' must be pure — '" &
                   callee & "' is [io]", sp)
            elif not fnDeclared(m, callee) and
                 not tc.typeDecls.hasKey(callee):
              fail("Const Error: 'const " & cname & "' needs declared pure " &
                   "fns — '" & callee & "' is unknown", sp)
          elif e.callee != nil and e.callee.kind == exkField:
            # {payload} Type.Variant — sum variants are value objects: fine
            discard
        else:
          fail("Const Error: 'const " & cname & "' must be a pure " &
               "compile-time expression", sp)
      constCheck(tc, m, d.name, d.constVal, d.span)
      tc.bindName(d.name, tc.synthesize(d.constVal), false)
  # Either/or namespace: a declared field name may not shadow a declared fn —
  # `.name` resolves by lookup, so a clash would silently change meaning.
  for d in m.decls:
    if d == nil: continue
    let declFields =
      case d.kind
      of dkType:
        if d.typeBody != nil and d.typeBody.kind == tkRecord: d.typeBody.fields
        else: @[]
      of dkObject: d.objFields
      of dkActor: d.actorFields
      else: @[]
    for f in declFields:
      if tc.fnSigs.hasKey(f.name):
        fail("Type Error: field '" & f.name & "' of '" & d.name & "' has " &
             "the same name as a declared fn — rename one; fields and fns " &
             "share the call namespace", d.span)
  for d in m.decls:
    # Module top level is declarations only — the runnable program lives in
    # `fn main`. (User ruling 2026-07-13: no top-level statements, not even
    # pure lets; `tuck build` without main = library.)
    if d != nil and d.kind == dkExpr:
      fail("Structure Error: top-level statements are not allowed — move " &
           "this into `fn main` (a module is declarations; main is the " &
           "program)", d.span)
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
                       generics: sig.generics,
                       isPending: tc.pendingFns.hasKey(name),
                       line: tc.pendingFns.getOrDefault(name).line))

# Whole-program checking, order-independent: pass 1 collects EVERY module's
# signatures; pass 2 checks bodies against the full picture. `mods` is
# dep-first with the entry module last (compiler/modules.nim order); the
# entry module's SHORTCUTS list is returned.
# `preSigs`: modules resolved from the signature index — typechecked in an
# earlier run and unchanged since, so only their signatures participate.
# Mirror of tuck_rt's errCode: FNV-1a over "module/Enum.Variant", folded to
# 16 bits. Used only for the program-wide collision check — a hash collision
# between two error names would silently alias two errors at runtime.
proc fnv16(name: string): uint16 =
  var h = 2166136261'u32
  for c in name:
    h = (h xor uint32(c)) * 16777619'u32
  uint16((h xor (h shr 16)) and 0xFFFF'u32)

proc checkErrCodeCollisions*(mods: seq[tuple[name, path: string, m: Module]]) =
  ## Every declared error id ("module/Enum.Variant") must hash uniquely
  ## across the whole program. The forward table is built here; a collision
  ## is a compile error with a rename pointer.
  var seen = initTable[uint16, string]()
  for (name, path, m) in mods:
    for d in m.decls:
      if d == nil or d.kind != dkType: continue
      if d.span.file.startsWith(ImportedTypeMarker): continue  # origin owns it
      if d.typeBody == nil or d.typeBody.kind != tkSum: continue
      for v in d.typeBody.variants:
        if v.fields.len > 0: continue  # error enums are fieldless
        let full = name & "/" & d.name & "." & v.name
        let code = fnv16(full)
        if seen.hasKey(code) and seen[code] != full:
          fail("Error Id Collision: '" & full & "' and '" & seen[code] &
               "' hash to the same 16-bit code (0x" & $code &
               ") — rename one variant", d.span)
        seen[code] = full

proc typecheckProgram*(mods: seq[tuple[name, path: string, m: Module]],
                       preSigs = initTable[string, seq[SigInfo]]()): seq[string] {.discardable.} =
  checkErrCodeCollisions(mods)
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
            extern[imp & "::" & si.name] = (si.params, si.ret, si.generics)
            if si.isPending:
              externPend[imp & "::" & si.name] = Span(line: si.line, col: 1)
    try:
      result = typecheckModule(m, extern, externPend)
    except SemanticError as err:
      err.msg = path & ":" & $err.line & ":" & $err.col & ": " & err.msg
      raise
