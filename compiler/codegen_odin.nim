# compiler/codegen_odin.nim
# Odin backend. Mirrors codegen.nim (the Nim backend) construct for
# construct: !T/?T result auto-wrap, record construction with invariant
# validation, decision tables (packed and chained), payload sum types,
# actors with message envelopes, registries, mixins/extern bindings,
# pending stubs, and qualified module references. Generated code links
# against compiler/tuck_rt.odin the way Nim output imports
# compiler/tuck_rt.nim.
#
# Started as a copy of codegen_beef.nim: both target value-type, no-GC
# languages, so ~1150 of its lines are AST logic that ports unchanged and
# only the emitted syntax differs. Keep the two diffable — a fix in one is
# usually a fix in the other.
import ast, lowering, strutils, sets, tables, options
import resolution
import ast_query
import codegen_common
import codegen_table  # decision-table combinatorics, shared with the Nim backend
import codegen_odin_util  # ctx-free helpers: lib specs, err codes, pure AST predicates
export odinLibSpec, odinErrCode
from mangle import mangleName
import ./codegen_odin_ctx

# Type emission, the ctx type, and the decl-shape fast lookups now live in
# codegen_odin_ctx.nim, imported above.







# Field type emission. An inline sum type is hoisted to a named enum
# `<Parent><Field>Kind` (the same name the Nim and Beef backends use).

# --- Shared declaration lookups (mirror codegen.nim) -----------------------

# hasInvariants / externInvRet / isRecordType / isErrEnumRef used to be
# copy-pasted here from codegen.nim (this backend began as a fork). They are
# backend-neutral questions about the AST, so they live in ast_query.

# fn param TYPES by position, for call sites deciding whether an arg needs
# the `ref` marker (mutable record param).



proc genOdinExpr*(ctx: var OdinCodegenCtx, e: Expr): string



# Type-directed explosion: a record-typed VAR as the whole payload
# (`p advance`) explodes to the fn's params by field name, in param order.
proc explodeRecordArg(ctx: var OdinCodegenCtx, e: Expr, calleeStr: string): string =
  if e.args.len != 1 or e.args[0].kind != exkVar: return ""
  # Prefers the checker's own resolution (semLayer.callParamsFor, set in
  # checkCallArgs) over a decl-list scan — mirrors the Nim backend's fix.
  let params = if semLayer.callParamsFor(e).len > 0: semLayer.callParamsFor(e)
               else: lookupFnParams(ctx.module, calleeStr)
  if params.len == 0: return ""
  let fields = recordFieldNames(ctx.module, semLayer.typeFor(e.args[0]))
  if fields.len == 0: return ""
  # The checker already decided which field feeds each param (they may differ
  # in name, having been matched by type); prefer its mapping over the name.
  let resolved = semLayer.argFieldsFor(e)
  var parts: seq[string]
  for i, paramName in params:
    let fieldName = if i < resolved.len and resolved[i].len > 0: resolved[i]
                    else: paramName
    if fieldName notin fields: return ""
    parts.add(ctx.genOdinExpr(e.args[0]) & "." & fieldName)
  return calleeStr & "(" & parts.join(", ") & ")"

# Positional construction of a hoisted record struct from a struct literal,
# in declared-field order, casting numeric fields to the declared type.
proc recCtorFromLiteral(ctx: var OdinCodegenCtx, declFields: seq[FieldDef],
                        litFields: seq[FieldInit]): string =
  let structName = recStructName(ctx, declFields)
  # Odin struct literals are named — `T{a = 1, b = 2}` — so a field the
  # literal omits simply stays zero-valued and needs no placeholder.
  var parts: seq[string]
  for fd in declFields:
    for f in litFields:
      if f.name == fd.name:
        let fieldOdin = ctx.odinType(fd.typ)
        let ex = ctx.genOdinExpr(f.value)
        # narrow numeric literals to the declared field width
        if fieldOdin notin ["int", "f64", "f32", "string", "bool"] and
           (fieldOdin.startsWith("u") or fieldOdin.startsWith("i") or
            fieldOdin.startsWith("f")):
          parts.add(fd.name & " = " & fieldOdin & "(" & ex & ")")
        else:
          parts.add(fd.name & " = " & ex)
        break
  return structName & "{" & parts.join(", ") & "}"

# Struct literal outside call/return contexts: use the checker's ty stamp to
# pick the record shape. Odin has no anonymous record type, so an unresolved
# shape hoists a named struct from the literal's own inferred field types.
proc genStructLit(ctx: var OdinCodegenCtx, e: Expr): string =
  var declFields: seq[FieldDef]
  if semLayer.typeFor(e) != nil:
    declFields = getFieldsForType(ctx.module, semLayer.typeFor(e))
  var allKnown = declFields.len > 0
  for f in declFields:
    if hasUnknownType(f.typ): allKnown = false
  if allKnown:
    return ctx.recCtorFromLiteral(declFields, e.fields)
  if e.fields.len == 1:
    let ft = inferLitType(e.fields[0].value)
    if ft != nil:
      return ctx.recCtorFromLiteral(@[FieldDef(name: e.fields[0].name, typ: ft)],
                                    e.fields)
    # no type information at all: sketch mode, emit the bare value
    return ctx.genOdinExpr(e.fields[0].value)
  # Multi-field sketch literal: infer each field's type and hoist a shape.
  # Odin has no anonymous struct type, so a bare `{a = 1}` is a hard error
  # ("missing type in compound literal") — every literal MUST land on a named
  # shape. A field whose type can't be inferred falls back to the runtime's
  # `any`, which keeps sketch code compiling the way the Nim backend does.
  var inferred: seq[FieldDef]
  for f in e.fields:
    var ft = inferLitType(f.value)
    if ft == nil: ft = Type(kind: tkNamed, name: UnknownName, span: e.span)
    inferred.add(FieldDef(name: f.name, typ: ft, span: e.span))
  return ctx.recCtorFromLiteral(inferred, e.fields)

# exkCall: record construction (with invariant validation and generic
# instantiation), payload explosion, named-param reordering, or a plain call.
# {payload} Type.Variant — construction of a payload-carrying sum type
# (kind + per-variant TRec struct field). Fieldless-only sums are plain Beef
# enums, where Type.Variant is already valid — returns "" to fall through.
proc sumVariantCtor(ctx: var OdinCodegenCtx, typeName, variantName: string,
                    payload: Expr): string =
  let found = payloadSumVariant(ctx.module, typeName, variantName)
  if found.isNone: return ""
  let v = found.get
  # Odin union: constructing a variant IS constructing its struct; the union
  # carries the tag itself, so there is no kind field to set and no
  # per-variant payload slot to name.
  let vName = typeName & "_" & v.name
  if v.fields.len == 0 or payload == nil:
    return vName & "{}"
  var vals: seq[string]
  for f in v.fields:
    for pf in payload.fields:
      if pf[0] == f.name:
        vals.add(f.name & " = " & ctx.genOdinExpr(pf[1]))
        break
  vName & "{" & vals.join(", ") & "}"

# expr bake {slot: value, ...} — rebuild the record with slots overridden.
# Ported from codegen.nim; neither Beef nor this backend had an arm for it,
# so `bake` used to fall through to a plain call and emit nonsense.
proc genOdinBake(ctx: var OdinCodegenCtx, e: Expr): string =
  if e.args[0].kind != exkVar: return ""  # ponytail: no expr-position temp
  let recv = ctx.genOdinExpr(e.args[0])
  let recvFields = recordFieldNames(ctx.module, semLayer.typeFor(e.args[0]))
  if recvFields.len == 0: return ""
  var declFields: seq[FieldDef]
  for f in getFieldsForType(ctx.module, semLayer.typeFor(e.args[0])):
    declFields.add(f)
  var parts: seq[string]
  for fname in recvFields:
    var overridden = ""
    for (name, valExpr) in e.args[1].fields.items:
      if name == fname: overridden = ctx.genOdinExpr(valExpr)
    parts.add(fname & " = " & (if overridden != "": overridden
                               else: recv & "." & fname))
  # a name the receiver doesn't have ADDS a field, so the shape grows
  for (name, valExpr) in e.args[1].fields.items:
    if name notin recvFields:
      parts.add(name & " = " & ctx.genOdinExpr(valExpr))
      var ft = inferLitType(valExpr)
      if ft == nil: ft = Type(kind: tkNamed, name: UnknownName, span: e.span)
      declFields.add(FieldDef(name: name, typ: ft, span: e.span))
  if parts.len == 0: return recv
  return ctx.recStructName(declFields) & "{" & parts.join(", ") & "}"

# expr alias(old: new, ...) — rebuild as the renamed TRec shape.
# ponytail: exkVar receivers only (no expr-position temp);
# falls back to pass-through otherwise.
proc genOdinAlias(ctx: var OdinCodegenCtx, e: Expr): string =
  if e.args[0].kind != exkVar or semLayer.typeFor(e.args[0]) == nil: return ""
  let recvFields = getFieldsForType(ctx.module, semLayer.typeFor(e.args[0]))
  if recvFields.len == 0: return ""
  var newFields: seq[FieldDef]
  var vals: seq[string]
  let recv = ctx.genOdinExpr(e.args[0])
  for (oldName, newExpr) in e.args[1].fields.items:
    var ft: Type = nil
    for rf in recvFields:
      if rf.name == oldName: ft = rf.typ
    if ft == nil or newExpr == nil or newExpr.kind != exkVar: return ""
    newFields.add(FieldDef(name: newExpr.name, typ: ft, span: e.span))
    vals.add(newExpr.name & " = " & recv & "." & oldName)
  let recName = ctx.recStructName(newFields)
  return recName & "{" & vals.join(", ") & "}"

# {a, b} merge — flatten into the union TRec shape (mirrors codegen.nim)
proc genOdinMerge(ctx: var OdinCodegenCtx, e: Expr): string =
  var newFields: seq[FieldDef]
  var vals: seq[string]
  for (mname, mexpr) in e.args[0].fields.items:
    if mexpr.kind != exkVar or semLayer.typeFor(mexpr) == nil: return ""
    let recv = ctx.genOdinExpr(mexpr)
    for f in getFieldsForType(ctx.module, semLayer.typeFor(mexpr)):
      newFields.add(f)
      vals.add(f.name & " = " & recv & "." & f.name)
  if newFields.len == 0: return ""
  return ctx.recStructName(newFields) & "{" & vals.join(", ") & "}"

proc asSumVariantCall(ctx: var OdinCodegenCtx, e: Expr): string =
  ## `Type.Variant {payload}` — a kind-tagged construction, not a call.
  if e.callee == nil or e.callee.kind != exkField or
     e.callee.receiver == nil or e.callee.receiver.kind != exkVar: return ""
  let payload = if e.args.len == 1 and e.args[0].kind == exkStruct: e.args[0]
                else: nil
  ctx.sumVariantCtor(e.callee.receiver.name, e.callee.fieldName, payload)

proc memberCalleeName(ctx: OdinCodegenCtx, e: Expr): string =
  ## A member call arrives as a bare-name callee with the receiver as args[0]
  ## (the checker's asFnByName rewrite). The DECLARATION emitted qualified, so
  ## the call has to match — derive the same name from the receiver's type.
  if e.callee == nil or e.callee.kind != exkVar or e.args.len < 1: return ""
  let owner = memberOwner(ctx.module, semLayer.typeFor(e.args[0]))
  if owner == "": return ""
  for d in ctx.module.decls:
    if d == nil or d.kind != dkObject or d.name != owner: continue
    for mem in d.objMembers:
      if mem != nil and mem.kind == dkFn and mem.name == e.callee.name:
        return memberProcName(owner, e.callee.name)
  ""

proc genericCtorName(ctx: var OdinCodegenCtx, e: Expr, base: string): string =
  ## A generic type: the checker's ty stamp carries the inferred instantiation.
  ##
  ## The base name is QUALIFIED first. A construction reaches text through
  ## `e.callee.name`, which never passes through odinType — so a type declared
  ## in an imported module was written bare (`tuck_Big{...}`) and Odin
  ## answered `Undeclared name`, while a fn from the same module qualified
  ## correctly. Odin never merges package scopes: a package member is ALWAYS
  ## `pkg.name`.
  let qbase = ctx.importedTypeQualifier(base)
  let t = semLayer.typeFor(e)
  if t == nil or t.kind != tkApp or t.base == nil or
     t.base.kind != tkNamed or t.base.name != base: return qbase
  var gparts: seq[string]
  for a in t.args: gparts.add(ctx.odinType(a))
  qbase & "(" & gparts.join(", ") & ")"

proc genRecordCtor(ctx: var OdinCodegenCtx, e: Expr): string =
  ## Odin struct literal: `Type{field = value, ...}`, a value not a pointer.
  ## Record construction takes NAMED fields, not positional.
  var parts: seq[string]
  for f in e.args[0].fields:
    parts.add(f.name & " = " & ctx.genOdinExpr(f.value))
  let ctor = ctx.genericCtorName(e, e.callee.name) & "{" & parts.join(", ") & "}"
  if hasInvariants(ctx.module, e.callee.name):
    # production site: construction — validate before the value flows on
    return "__validated_" & e.callee.name & "(" & ctor & ")"
  ctor

proc expectedParamNames(ctx: var OdinCodegenCtx, e: Expr,
                        calleeStr: string): seq[string] =
  ## Param order lives with the fn, not the literal — match by name. A
  ## qualified callee into a real module resolves in THAT module.
  if e.callee != nil and e.callee.kind == exkQualified and
     e.callee.modulePath.len > 0 and e.callee.modulePath[0] in ctx.realModules:
    return lookupFnParams(ctx.realModules[e.callee.modulePath[0]],
                          e.callee.qualName)
  if semLayer.callParamsFor(e).len > 0: return semLayer.callParamsFor(e)
  lookupFnParams(ctx.module, calleeStr)

proc payloadFieldArg(ctx: var OdinCodegenCtx, payload: Expr,
                     fieldName: string): string =
  ## The value supplied for one param, or an empty literal when the payload
  ## does not carry it.
  for f in payload.fields:
    if f.name == fieldName: return ctx.genOdinExpr(f.value)
  "{}"

proc genPayloadArgs(ctx: var OdinCodegenCtx, e: Expr,
                    calleeStr: string): seq[string] =
  ## A payload's fields, ordered to match the callee's params.
  let expected = ctx.expectedParamNames(e, calleeStr)
  if expected.len == 0:
    for f in e.args[0].fields: result.add(ctx.genOdinExpr(f.value))
    return
  # The checker's mapping wins: a field matched by TYPE carries its own name,
  # not the param's (see checkCallArgs / semLayer.argFieldsFor).
  let resolved = semLayer.argFieldsFor(e)
  for i, paramName in expected:
    let fieldName = if i < resolved.len and resolved[i].len > 0: resolved[i]
                    else: paramName
    result.add(ctx.payloadFieldArg(e.args[0], fieldName))

proc genCallArgs(ctx: var OdinCodegenCtx, e: Expr,
                 calleeStr: string): seq[string] =
  ## ponytail: pass records BY VALUE. A mutating callee would need `^T` and
  ## `&x` at the call site, but Odin proc params aren't addressable, so
  ## `&param` is a hard error — and Tuck's mutators already return the updated
  ## value, which the chain emitter assigns back. Revisit if a real in-place
  ## mutator shows up that the return-and-assign shape can't express.
  if e.args.len == 1 and e.args[0].kind == exkStruct:
    return ctx.genPayloadArgs(e, calleeStr)
  for a in e.args: result.add(ctx.genOdinExpr(a))

const RtByPointer = ["acquire", "release", "alloc", "reset", "enqueue",
                     "dequeue", "hasRoom", "initMailbox"]
  ## Runtime intrinsics whose receiver they MUTATE, so it goes in by pointer.

const RtByValue = ["at", "setAt", "toStr", "tuckConcat", "errCode",
                   "tuckSat", "tuckSatI", "tuckReportUnhandled"]
  ## Runtime intrinsics taking their arguments as-is. Beef reached these
  ## through `using static Rt`; Odin has no such import, so both lists
  ## qualify explicitly.

proc asParenBuiltinOdin(ctx: var OdinCodegenCtx, e: Expr,
                        calleeStr: string): string =
  ## `sizeof`/`alignof`/`offsetof` parse as ordinary calls
  ## (parser_expr.ParenBuiltins), the identical call syntax as C and as
  ## Tuck's own source — which is also valid Nim, so that backend's
  ## emission is right by coincidence. Odin's real spelling is
  ## `size_of(T)`/`align_of(T)` (a genuine builtin name, still call
  ## syntax — unlike D, which spells these as a postfix property), so this
  ## is a name rewrite, not a shape change. `offsetof` has no example to
  ## verify against and no verified Odin translation, so — mirroring
  ## codegen_d.nim's stance on the same gap — it is left alone here rather
  ## than guessed: "" falls through to a plain call, and the Odin compiler
  ## itself reports "undeclared name: offsetof" if one is ever emitted.
  ## "" when `calleeStr` names none of these, so the caller falls through
  ## to a plain call.
  if calleeStr == "sizeof" and e.args.len == 1:
    return "size_of(" & ctx.genOdinExpr(e.args[0]) & ")"
  if calleeStr == "alignof" and e.args.len == 1:
    return "align_of(" & ctx.genOdinExpr(e.args[0]) & ")"
  ""

proc asCombinatorCall(ctx: var OdinCodegenCtx, e: Expr,
                      calleeStr: string): string =
  ## The compile-time combinators, each of which rewrites the call rather than
  ## emitting one. Any that declines returns "" and the call proceeds.
  let builtin = ctx.asParenBuiltinOdin(e, calleeStr)
  if builtin != "": return builtin
  if calleeStr == "bake" and e.args.len == 2 and e.args[1].kind == exkStruct:
    return ctx.genOdinBake(e)
  if isRecordConstruction(ctx.module, e): return ctx.genRecordCtor(e)
  if calleeStr == "alias" and e.args.len == 2 and e.args[1].kind == exkStruct:
    return ctx.genOdinAlias(e)
  if calleeStr == "merge" and e.args.len == 1 and e.args[0].kind == exkStruct:
    return ctx.genOdinMerge(e)
  if calleeStr notin ["bake", "alias"]:
    return ctx.explodeRecordArg(e, calleeStr)
  ""

proc genSaturatingCtor(ctx: var OdinCodegenCtx, satT: Type,
                       calleeStr, arg: string): string =
  ## spec 4.1: constructing a [saturating] type CLAMPS instead of wrapping.
  ## Mirrors codegen.nim — the guard runs on a wider intermediate so the value
  ## is checked against the real bounds, not after it has wrapped.
  let satBase = ctx.odinType(satT)
  let unsigned = satBase.startsWith("u")
  let widen = if unsigned: "u64" else: "i64"
  let satFn = if unsigned: "rt.tuckSat" else: "rt.tuckSatI"
  calleeStr & "(" & satFn & "(" & satBase & ", " & widen & "(" & arg & ")))"

proc genRtCall(calleeStr: string, args: seq[string]): string =
  ## A runtime intrinsic, by pointer or by value.
  if calleeStr in RtByPointer and args.len > 0:
    let rest = if args.len > 1: ", " & args[1..^1].join(", ") else: ""
    return "rt." & calleeStr & "(&" & args[0] & rest & ")"
  if calleeStr in RtByValue:
    return "rt." & calleeStr & "(" & args.join(", ") & ")"
  ""

proc genCallWithArgs(ctx: var OdinCodegenCtx, e: Expr, calleeStr: string,
                     args: seq[string]): string =
  ## The emission forms, once the arguments are built.
  if calleeStr == "bake": return args[0] & "(" & args[1..^1].join(", ") & ")"
  if calleeStr == "alias": return args[0]
  let satT = ctx.module.saturatingType(calleeStr)
  if satT != nil and args.len == 1:
    return ctx.genSaturatingCtor(satT, calleeStr, args[0])
  let invRet = externInvRet(ctx.module, calleeStr)
  if invRet != "":
    # extern boundary: the returned value validates on entry
    return "__validated_" & invRet & "(" & calleeStr & "(" &
           args.join(", ") & "))"
  if calleeStr == "echo": return "fmt.println(" & args.join(", ") & ")"
  let rt = genRtCall(calleeStr, args)
  if rt != "": return rt
  ""

proc genOdinCall(ctx: var OdinCodegenCtx, e: Expr): string =
  let variant = ctx.asSumVariantCall(e)
  if variant != "": return variant
  var calleeStr = ctx.genOdinExpr(e.callee)
  let member = ctx.memberCalleeName(e)
  if member != "": calleeStr = member
  let combinator = ctx.asCombinatorCall(e, calleeStr)
  if combinator != "": return combinator
  var args = ctx.genCallArgs(e, calleeStr)
  # genOdinMemberFn gives EVERY member fn's self a pointer, `^T`,
  # unconditionally — not just the ones that mutate it — so every call
  # site has to pass `&receiver` to match, regardless of whether this
  # particular member reads or writes self. This call shape (a direct
  # `.fn {payload}` on a plain value, resolved via the checker's
  # synthMethodCall) was never reachable before a prior checker bug
  # rejected it outright, which is why the gap went unnoticed: every
  # PASSING member call so far reached its receiver through the chain
  # emitter instead, which threads an existing pointer through, never
  # needing to take one here.
  if member != "" and args.len > 0: args[0] = "&" & args[0]
  let emitted = ctx.genCallWithArgs(e, calleeStr, args)
  if emitted != "": return emitted
  if ctx.isTaskName(calleeStr) and args.len == 0:
    # Calling a task SCHEDULES it as a coroutine — it runs concurrently and
    # tuckRun drives it (spec §9.2). Mirrors the Nim backend, which has always
    # emitted tuckSpawn here.
    #
    # Without this the task body runs on the MAIN context, so the first
    # tuckAwaitRead inside it hits parkCurrent's "cannot await outside a
    # coroutine" panic. It went unnoticed because 28-async-task, the only Odin
    # task example, never awaits an fd — only tuckYield, which is legal
    # anywhere.
    #
    # NULLARY ONLY. Odin proc literals cannot capture (verified: "Undeclared
    # name: x" for a literal referencing an outer local), so a task WITH
    # arguments needs them marshalled through a heap context the thunk owns —
    # designed, not guessed. Until then a task with arguments still emits a
    # direct call, which is wrong the moment it awaits; see
    # thoughts/bugs-found-while-building-net.md.
    return "rt.tuckSpawn(proc() { " & calleeStr & "() })"
  return calleeStr & "(" & args.join(", ") & ")"

proc odinBangInfo*(ctx: var OdinCodegenCtx, t: Type):
    tuple[wrapped: bool, inner: string, innerT: Type] =
  if t != nil and t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
     t.base.name in ["!", "?", "!?"] and t.args.len == 1:
    let inner = ctx.odinType(t.args[0])
    return (true, (if inner == "void": "rt.TuckUnit" else: inner), t.args[0])
  return (false, "", nil)

# Comparison operand for a pattern value: enum tags need qualification (or
# Beef's `.Tag` inference prefix for hoisted inline enums); literals pass.
proc patternValue*(ctx: OdinCodegenCtx, patStr: string): string =
  if patStr.len == 0: return patStr
  let owner = enumTagOwner(ctx.module, patStr)
  if owner != "": return owner & "." & patStr
  if patStr[0] in {'A'..'Z'}: return "." & patStr
  patStr

# A match-arm result that is a bare enum tag needs the same treatment; the
# assignment/return target supplies the type for `.Tag` inference.
proc armValue*(ctx: var OdinCodegenCtx, e: Expr): string =
  if e != nil and e.kind == exkVar and e.name notin ctx.definedVars and
     e.name notin ctx.fieldVars and e.name.len > 0 and e.name[0] in {'A'..'Z'}:
    return ctx.patternValue(e.name)
  return ctx.genOdinExpr(e)

# exkRaise: err X — early-return an error result
proc genRaise(ctx: var OdinCodegenCtx, e: Expr): string =
  let rv = e.raiseVal
  let inner = if ctx.retInnerOdin != "": ctx.retInnerOdin else: "rt.TuckUnit"
  if isErrEnumRef(ctx.module, rv):
    "return rt.terr(" & inner & ", " &
      errCodeLit(errNameFor(ctx.module, ctx.moduleName, rv.receiver.writtenName, rv.fieldName)) & ")"
  else:
    "return rt.terr(" & inner & ", u16(" & ctx.genOdinExpr(rv) & "))"

# exkReturn emission: auto-wrapped tok()/terr() results, typed struct
# literals, invariant-carrying returns, or a plain return.
proc genOdinReturn(ctx: var OdinCodegenCtx, e: Expr): string =
  if e.returnVal == nil:
    if ctx.retWrapped and ctx.retInnerOdin == "rt.TuckUnit":
      return "return rt.tokVoid()"
    else: return "return"
  elif ctx.retWrapped:
    let v = e.returnVal
    if v.kind == exkRaise:
      return ctx.genRaise(v)  # err X already emits the full error return
    elif v.kind == exkField and v.receiver != nil and v.receiver.kind == exkVar and
       v.receiver.name == "Error":
      # Error.name → app-wide 16-bit code, hashed by the emitter
      return "return rt.terr(" & ctx.retInnerOdin & ", " &
             errCodeLit(v.fieldName) & ")"
    elif v.kind == exkStruct and ctx.retInnerT != nil and ctx.retInnerT.kind == tkRecord:
      # Typed literal: cast numeric fields to the declared payload field type
      return "return rt.tok(" & ctx.recCtorFromLiteral(ctx.retInnerT.fields, v.fields) & ")"
    else:
      return "return rt.tok(" & ctx.genOdinExpr(v) & ")"
  elif ctx.retInvName != "":
    # production site: return value of an invariant-carrying type
    return "return __validated_" & ctx.retInvName & "(" &
           ctx.genOdinExpr(e.returnVal) & ")"
  else: return "return " & ctx.genOdinExpr(e.returnVal)

# exkMatch in statement position: a real switch statement.
proc genPayloadUnionMatch(ctx: var OdinCodegenCtx, e: Expr,
                          sumName: string): string =
  ## A match over a PAYLOAD union. Odin's tagged union carries its own tag
  ## and has NO kind field, so the dispatch is `switch v in value` with the
  ## variant STRUCT types as case labels, and the payload is reached through
  ## the bound `v` (verified against the real Odin compiler before writing
  ## this — `Shape_Line` as a case, `v.length` inside it).
  ##
  ## This is why the Nim and D backends' `.kind` dispatch is not portable
  ## here: their case-object and tagged-struct both HAVE a discriminant
  ## field, and Odin's union does not.
  let ind = "  ".repeat(ctx.indent)
  let subjectStr = ctx.genOdinExpr(e.subject)
  var cases: seq[string]
  let oldIndent = ctx.indent
  let savedBind = ctx.unionBind
  ctx.indent += 1
  ctx.unionBind = "v"
  for arm in e.arms:
    let patStr = genPatternStr(arm.pattern)
    let bodyStr = ctx.genOdinExpr(arm.body)
    let caseLabel = if patStr == "_": "case:"
                    else: "case " & sumName & "_" & patStr & ":"
    if arm.body != nil and arm.body.kind == exkBlock:
      cases.add(ind & caseLabel & "\n" & bodyStr)
    else:
      cases.add(ind & caseLabel & " " & bodyStr & ";")
  ctx.indent = oldIndent
  ctx.unionBind = savedBind
  ind & "switch " & "v" & " in " & subjectStr & "\n" &
    ind & "{\n" & cases.join("\n") & "\n" & ind & "}"

proc genMatchStmt(ctx: var OdinCodegenCtx, e: Expr): string =
  let sumName = payloadSumTypeName(ctx.module, semLayer.typeFor(e.subject))
  if sumName != "": return ctx.genPayloadUnionMatch(e, sumName)
  let ind = "  ".repeat(ctx.indent)
  let subjectStr = ctx.genOdinExpr(e.subject)
  var cases: seq[string]
  let oldIndent = ctx.indent
  ctx.indent += 1
  var errMatch = false
  var hasWild = false
  for arm in e.arms:
    if arm.pattern != nil and arm.pattern.kind == pkWild: hasWild = true
    if arm.pattern != nil and arm.pattern.kind == pkVar and
       "." in arm.pattern.name: errMatch = true
  for arm in e.arms:
    let patStr = genPatternStr(arm.pattern)
    let bodyStr = ctx.genOdinExpr(arm.body)
    var caseVal = ""
    if arm.pattern != nil and arm.pattern.kind == pkVar and
       "." in arm.pattern.name:
      let dot = arm.pattern.name.find(".")
      caseVal = errCodeLit(errNameFor(ctx.module, ctx.moduleName, arm.pattern.name[0 ..< dot],
                                          arm.pattern.name[dot+1 .. ^1]))
    let caseLabel = if patStr == "_": "default:"
                    elif caseVal != "": "case " & caseVal & ":"
                    else: "case " & ctx.patternValue(patStr) & ":"
    if arm.body != nil and arm.body.kind == exkBlock:
      cases.add(ind & caseLabel & "\n" & bodyStr)
    else:
      cases.add(ind & caseLabel & " " & bodyStr & ";")
  if errMatch and not hasWild:
    cases.add(ind & "default: break;")
  ctx.indent = oldIndent
  return ind & "switch (" & subjectStr & ")\n" & ind & "{\n" &
         cases.join("\n") & "\n" & ind & "}"

# exkMatch in value position: a ternary chain (Beef has no switch expression).
proc genMatchExpr(ctx: var OdinCodegenCtx, e: Expr): string =
  let subjectStr = ctx.genOdinExpr(e.subject)
  var res = ""
  var closing = 0
  for i, arm in e.arms:
    let patStr = genPatternStr(arm.pattern)
    let bodyStr = ctx.armValue(arm.body)
    if patStr == "_" or i == e.arms.len - 1:
      res.add(bodyStr)
      break
    var cmpVal = ctx.patternValue(patStr)
    if arm.pattern != nil and arm.pattern.kind == pkVar and
       "." in arm.pattern.name:
      let dot = arm.pattern.name.find(".")
      cmpVal = errCodeLit(errNameFor(ctx.module, ctx.moduleName, arm.pattern.name[0 ..< dot],
                                         arm.pattern.name[dot+1 .. ^1]))
    res.add("((" & subjectStr & " == " & cmpVal & ") ? " &
            bodyStr & " : ")
    closing.inc
  res.add(")".repeat(closing))
  return res

proc genIndented*(ctx: var OdinCodegenCtx, e: Expr): string =
  ## Emit a nested body one level deeper, restoring the indent afterwards.
  ## Every block-owning construct needs this, and each used to spell out the
  ## save/increment/restore by hand.
  let saved = ctx.indent
  ctx.indent += 1
  result = ctx.genOdinExpr(e)
  ctx.indent = saved

proc genUnindented(ctx: var OdinCodegenCtx, e: Expr): string =
  ## Emit an expression with no indentation — for a value position, where a
  ## leading run of spaces would land in the middle of an expression.
  let saved = ctx.indent
  ctx.indent = 0
  result = ctx.genOdinExpr(e)
  ctx.indent = saved

proc genInterfaceWrap(ctx: var OdinCodegenCtx, e: Expr,
                      w: tuple[objName, iface: string]): string =
  ## A concrete object entering an interface slot is COPIED into the variant
  ## (spec §5.3). Mirrors the Nim backend: the value owns its data, so it can
  ## be returned or stored with no lifetime question — nothing borrows.
  let (ifaceName, objName) = resolveWrapNames(ctx.module, w.iface, w.objName)
  ifaceName & "{tag = ." & ifaceName & "_is_" & objName & ", " &
    objName & "Val = " & e.name & "}"

proc genLit(e: Expr): string =
  case e.litKind
  of lkStr: "\"" & e.litValue & "\""
  else: e.litValue

proc genInputPayload(ctx: var OdinCodegenCtx): string =
  ## `input` — the whole incoming payload, rebuilt as its TRec shape.
  var vals: seq[string]
  for p in ctx.currentParams: vals.add(p.name & " = " & p.name)
  ctx.recStructName(ctx.currentParams) & "{" & vals.join(", ") & "}"

proc qualifiedForeignFn(ctx: OdinCodegenCtx, name: string): string =
  ## An unqualified cross-module call (`0 exit` for `sys::exit`). Nim resolves
  ## this itself through the emitted `import`; Odin never merges package
  ## scopes, so the owning package has to be found and spelled out here.
  if ctx.module.declaresFn(name): return ""
  for modName, im in ctx.realModules:
    if im.declaresFn(name):
      return modName.replace("-", "_") & "." & name
  ""

proc genVar(ctx: var OdinCodegenCtx, e: Expr): string =
  ## A bare name: a checker-stamped call, a payload, a field, an enum tag, or
  ## a plain variable.
  if semLayer.hasCall(e): return ctx.genOdinExpr(semLayer.call(e))
  if e.name == "...": return ""  # pending hole: compiles, does nothing
  if e.name == "input" and ctx.currentParams.len > 0: return ctx.genInputPayload()
  if e.name == "self" and ctx.ptrSelf: return "self^"  # member fn: deref
  if e.name in ctx.fieldVars: return ctx.fieldPrefix & e.name
  if e.name in ctx.definedVars: return e.name
  # bare enum tag: qualify with its declared owner (Odin has no module-global
  # enum members the way Nim does)
  let owner = enumTagOwner(ctx.module, e.name)
  if owner != "": return owner & "." & e.name
  let foreign = ctx.qualifiedForeignFn(e.name)
  if foreign != "": return foreign
  e.name

proc genIfaceDispatch(ctx: var OdinCodegenCtx, e: Expr,
                      ic: tuple[iface, member: string]): string =
  ## A call through an interface value: switch on the tag the value carries and
  ## call the concrete member fn — no table, no thunk. Emitted as an
  ## immediately-called closure because Odin has no switch EXPRESSION, and a
  ## call site needs a value.
  let recv = ctx.genOdinExpr(e.receiver)
  var extra = ""
  if e.dotArg != nil: extra = ", " & ctx.genOdinExpr(e.dotArg)
  var arms: seq[string]
  for st in ctx.satisfiersOf(ic.iface):
    arms.add("\t\tcase ." & ic.iface & "_is_" & st.name & ":\n" &
             "\t\t\ttmp := v." & st.name & "Val\n" &
             "\t\t\treturn " & memberProcName(st.name, ic.member) &
             "(&tmp" & extra & ")")
  if arms.len == 0: return ""
  "(proc(v: " & ic.iface & ") -> int {\n\tswitch v.tag {\n" &
    arms.join("\n") & "\n\t}\n\treturn 0\n})(" & recv & ")"

proc isInputField(ctx: OdinCodegenCtx, e: Expr): bool =
  ## `input.x` — the incoming payload's field is just the param.
  e.receiver != nil and e.receiver.kind == exkVar and
    e.receiver.name == "input" and ctx.currentParams.len > 0

proc indentPrefix(code: string): string =
  ## The leading whitespace of the LAST line of an emitted block, so a
  ## statement appended after it lands at the same indent.
  let lastLine = code.rsplit('\n', 1)[^1]
  for ch in lastLine:
    if ch notin {' ', '\t'}: break
    result.add(ch)


proc boundVariantField(ctx: OdinCodegenCtx, e: Expr): string =
  ## Inside `switch v in value`, a payload field belongs to the BOUND
  ## variant, not to the subject — Odin's union has no discriminant field to
  ## reach past. "" when this is not that situation.
  if ctx.unionBind == "" or e.receiver == nil or
     e.receiver.kind != exkVar: return ""
  if payloadSumTypeName(ctx.module, semLayer.typeFor(e.receiver)) == "":
    return ""
  ctx.unionBind & "." & e.fieldName

proc genFieldAccess(ctx: var OdinCodegenCtx, e: Expr, ind: string): string =
  ## A `.name` access: interface dispatch, an actor singleton's field, a
  ## status test, a resolved call, a sum-variant construction, or a plain read.
  let ic = semLayer.ifaceCallOf(e)
  if ic.member != "": return ctx.genIfaceDispatch(e, ic)
  # `Counter.total` reads the actor SINGLETON's field, not a type's.
  if e.receiver != nil and e.receiver.kind == exkActorRef:
    return actorSingletonName(e.receiver.refName) & "." & e.fieldName
  if isResultStatusTest(e):
    # parenthesised: a guard may negate it (`!r.ok`), and `!x == y` would
    # otherwise bind the `!` to the receiver alone
    return "(" & ctx.genOdinExpr(e.receiver) & ".status == .Ok)"
  if ctx.isInputField(e): return e.fieldName
  # fieldName resolved to a fn call, not a field (checker-resolved). A `..`
  # chain feeding this call was already hoisted into a temp by
  # lowering.hoistChainCalls — the receiver here can never be exkChain.
  if semLayer.hasCall(e): return ctx.genOdinCall(semLayer.call(e))
  if e.receiver != nil and e.receiver.kind == exkVar:
    # bare Type.Variant of a payload sum: kind-tagged construction
    let ctor = ctx.sumVariantCtor(e.receiver.name, e.fieldName, nil)
    if ctor != "": return ctor
  if e.receiver != nil and e.receiver.kind == exkRegisterRef:
    # A register field is a raw pointer with no real field — reading it
    # means calling the getter genRegister already emitted for it.
    let prefix = registerAccessorPrefix(ctx.module, e.receiver.refName, e.fieldName)
    if prefix != "": return prefix & "_get()"
  let bound = ctx.boundVariantField(e)
  if bound != "": return bound
  ctx.genOdinExpr(e.receiver) & "." & e.fieldName

proc genCallResolved(ctx: var OdinCodegenCtx, e: Expr): string =
  ## Indexing resolved to an at() call; a type application never reaches
  ## codegen, so an unresolved bracket emits nothing.
  if semLayer.hasCall(e): ctx.genOdinExpr(semLayer.call(e)) else: ""

proc genList(ctx: var OdinCodegenCtx, e: Expr): string =
  ## Odin infers the element type from context: `{a, b}` as a compound literal.
  var parts: seq[string]
  for item in e.items: parts.add(ctx.genOdinExpr(item))
  "{" & parts.join(", ") & "}"

proc genFor(ctx: var OdinCodegenCtx, e: Expr, ind: string): string =
  ## Odin's range-for yields the index natively, so `for idx, item in xs:`
  ## needs no counter to maintain.
  let iterStr = ctx.genOdinExpr(e.iterable)
  let vars = if e.iter != nil and e.iter.kind == pkTuple and e.iter.elems.len == 2:
               genPatternStr(e.iter.elems[1]) & ", " &
                 genPatternStr(e.iter.elems[0])
             else: genPatternStr(e.iter)
  let bodyStr = ctx.genIndented(e.body)
  ind & "for " & vars & " in " & iterStr & " {\n" & bodyStr & "\n" & ind & "}"

proc genWhile(ctx: var OdinCodegenCtx, e: Expr, ind: string): string =
  let condStr = if e.whileCond == nil: "true" else: ctx.genOdinExpr(e.whileCond)
  ind & "while (" & condStr & ")\n" & ctx.genIndented(e.whileBody)

proc odinBinOp(op: BinOp): string =
  ## Odin's `/` follows the operand type (integer operands give integer
  ## division), so both divisions map to `/` here — the DIFFERENCE from Nim,
  ## which needs `div`, is exactly why the Tuck source has to say which one it
  ## means.
  case op
  of boAdd: "+"
  of boSub: "-"
  of boMul: "*"
  of boDivInt, boDivFloat: "/"
  of boMod: "%"
  of boEq: "=="
  of boNeq: "!="
  of boLt: "<"
  of boGt: ">"
  of boLe: "<="
  of boGe: ">="
  of boAnd: "&&"
  of boOr: "||"
  of boXor: "^"
  of boRangeIncl: "..="   # Odin spells inclusive ranges ..=
  of boRangeExcl: "..<"

proc genBinary(ctx: var OdinCodegenCtx, e: Expr): string =
  ## rt.tuckConcat — `concat` was the Beef runtime's name and never existed in
  ## the Odin one (tuckrt/tuck_rt.odin:87), so any string `+` emitted an
  ## undeclared call.
  if isStringConcat(e):
    return "rt.tuckConcat(" & ctx.genOdinExpr(e.left) & ", " &
           ctx.genOdinExpr(e.right) & ")"
  "(" & ctx.genOdinExpr(e.left) & " " & odinBinOp(e.binOp) & " " &
    ctx.genOdinExpr(e.right) & ")"

proc genUnary(ctx: var OdinCodegenCtx, e: Expr): string =
  let opStr = case e.unaryOp
              of uoNeg: "-"
              of uoNot: "!"
              else: ""
  opStr & ctx.genOdinExpr(e.operand)

proc genDroppedResult(ctx: var OdinCodegenCtx, s: Expr, stmtCode, ind: string): string =
  ## continue/exit policy: a dropped result routes to the global handler.
  ctx.tmpCounter.inc
  let tn = "tuckDrop" & $ctx.tmpCounter
  let site = semLayer.shortcut(s)
  let onErr = if ctx.errPolicy == "exit":
                "tuck_unhandled(" & tn & ".err, \"" & site &
                  "\"); panic(\"unhandled error\")"
              else:
                "tuck_unhandled(" & tn & ".err, \"" & site & "\")"
  ind & "\t" & tn & " := " & stmtCode & "\n" &
    ind & "\tif " & tn & ".status != .Ok { " & onErr & " }"

proc isTaskArgsBind(ctx: var OdinCodegenCtx, e: Expr): bool =
  ## `let r = {args} someTask` — binding a task's result awaits it (spec
  ## §9.2), and the task takes real arguments (a nullary task call is the
  ## OTHER case, already spawned via genOdinCall's isTaskName branch).
  e.kind == exkAssign and e.assignVal != nil and
    e.assignVal.kind == exkCall and e.assignVal.callee != nil and
    e.assignVal.callee.kind == exkVar and
    ctx.isTaskName(e.assignVal.callee.name) and e.assignVal.args.len > 0

proc genOdinTaskArgsBind(ctx: var OdinCodegenCtx, e: Expr, ind: string): string =
  ## Spawn a task that takes real arguments, and await its result.
  ##
  ## Odin has no closures (verified: a proc literal cannot read an outer
  ## local), so the Nim backend's approach — a closure capturing the call's
  ## actual arguments — has no equivalent. Arguments travel through
  ## context.user_ptr instead, into a per-signature wrapper hoisted once
  ## and shared by every call to this task.
  ##
  ## ONE env, ONE context.user_ptr layer: an earlier version had a generic
  ## rt.spawnResult marshal {slot, body} through context.user_ptr AND
  ## expected the caller's own wrapper to read ITS OWN args through the
  ## same slot — two layers sharing one slot collide, and it segfaulted
  ## inside the coroutine (found only by running it, not by typechecking).
  ## The env built here carries the task's arguments AND the result slot
  ## together, so exactly one wrapper does the whole job: read args, call
  ## the real task, write the slot.
  let tname = e.assignVal.callee.name
  let task = ctx.module.findFn(tname)
  let params = task.paramNames()
  let paramTypes = task.paramTypes()
  let retType = if task.taskReturnType != nil: ctx.odinType(task.taskReturnType)
                else: "void"
  let envName = "Env_" & tname
  let wrapName = "wrap_" & tname
  if tname notin ctx.taskArgsHoisted:
    ctx.taskArgsHoisted.incl(tname)
    var fields: seq[string]
    for i, p in params: fields.add("\t" & p & ": " & ctx.odinType(paramTypes[i]) & ",")
    fields.add("\tslot: ^rt.TuckAsyncResult(" & retType & "),")
    ctx.hoisted.add(envName & " :: struct {\n" & fields.join("\n") & "\n}")
    var argExprs: seq[string]
    for p in params: argExprs.add("e." & p)
    ctx.hoisted.add(wrapName & " :: proc() {\n" &
      "\te := (^" & envName & ")(context.user_ptr)\n" &
      "\te.slot.value = " & tname & "(" & argExprs.join(", ") & ")\n" &
      "\te.slot.done = true\n" &
      "\tfree(e)\n}")
  var argParts: seq[string]
  if e.assignVal.args.len == 1 and e.assignVal.args[0].kind == exkStruct:
    for pn in params:
      for f in e.assignVal.args[0].fields:
        if f.name == pn: argParts.add(ctx.genOdinExpr(f.value)); break
  let envVar = "env" & $ctx.tmpCounter
  let slotVar = "slot" & $ctx.tmpCounter
  let savedVar = "savedCtx" & $ctx.tmpCounter
  ctx.tmpCounter.inc
  var lines: seq[string]
  lines.add(ind & envVar & " := new(" & envName & ")")
  for i, pn in params:
    lines.add(ind & envVar & "." & pn & " = " & argParts[i])
  lines.add(ind & slotVar & " := rt.newAsyncResult(" & retType & ")")
  lines.add(ind & envVar & ".slot = " & slotVar)
  lines.add(ind & savedVar & " := context.user_ptr")
  lines.add(ind & "context.user_ptr = " & envVar)
  lines.add(ind & "rt.tuckSpawn(" & wrapName & ")")
  lines.add(ind & "context.user_ptr = " & savedVar)
  let targetName = e.target.name
  let assignOp = if e.target.kind == exkVar and targetName notin ctx.definedVars and
                    targetName notin ctx.fieldVars:
                   ctx.definedVars.incl(targetName)
                   " := "
                 else: " = "
  lines.add(ind & ctx.genOdinExpr(e.target) & assignOp & "rt.awaitResult(" &
            slotVar & ")")
  lines.join("\n")

proc ownsItsLayout(ctx: var OdinCodegenCtx, s: Expr): bool =
  ## Constructs that emit their own indentation and terminator.
  ##
  ## A `.fn` call over a chain receiver belongs here too — the chain lowers to
  ## statements, so the whole thing is multi-line and indents itself. Mirrors
  ## the Nim backend.
  if s.kind == exkField and s.receiver != nil and
     s.receiver.kind == exkChain and semLayer.hasCall(s):
    return true
  if ctx.isTaskArgsBind(s): return true
  s.kind in {exkIf, exkFor, exkWhile, exkBlock, exkChain}

proc genStmt(ctx: var OdinCodegenCtx, s: Expr, ind: string): string =
  ## One statement of a block, indented unless it lays itself out.
  var ownsLayout = s.kind == exkMatch and s.subject != nil
  var code = if ownsLayout: ctx.genMatchStmt(s) else: ctx.genOdinExpr(s)
  if code != "" and semLayer.shortcut(s) != "":
    code = ctx.genDroppedResult(s, code, ind)
    ownsLayout = true
  if code == "": return ""
  # Odin has no statement terminator
  if ctx.ownsItsLayout(s) or ownsLayout: code else: ind & "  " & code

proc genBlock(ctx: var OdinCodegenCtx, e: Expr, ind: string): string =
  ## No braces here: Odin's block-owning constructs (proc, if, for) emit their
  ## own `{`, and a bare nested block is rare enough not to need one.
  let saved = ctx.indent
  ctx.indent += 1
  var lines: seq[string]
  for s in e.stmts:
    let code = ctx.genStmt(s, ind)
    if code != "": lines.add(code)
  ctx.indent = saved
  lines.join("\n")

proc genTernary(ctx: var OdinCodegenCtx, e: Expr, condStr: string): string =
  ## R2: a value-position if becomes Odin's ternary. Odin has no
  ## if-expression, so the statement form cannot stand in — it is not legal
  ## where a value is expected.
  "(" & condStr & " ? " & ctx.genUnindented(e.thenBranch) & " : " &
    ctx.genUnindented(e.elseBranch) & ")"

proc genBranch(ctx: var OdinCodegenCtx, branch: Expr, ind: string): string =
  ## A branch body, indented by hand when it is a single statement rather than
  ## a block that indents itself.
  result = ctx.genIndented(branch)
  if branch != nil and branch.kind != exkBlock:
    result = ind & "  " & result

proc genIf(ctx: var OdinCodegenCtx, e: Expr, ind: string): string =
  ## Odin: no parens around the condition, braces mandatory.
  let condStr = ctx.genOdinExpr(e.cond)
  if isValueIf(e): return ctx.genTernary(e, condStr)
  let thenStr = ctx.genBranch(e.thenBranch, ind)
  var elseStr = ""
  if e.elseBranch != nil:
    elseStr = "\n" & ind & "} else {\n" & ctx.genBranch(e.elseBranch, ind)
  ind & "if " & condStr & " {\n" & thenStr & elseStr & "\n" & ind & "}"

proc genAssign(ctx: var OdinCodegenCtx, e: Expr): string =
  ## First assignment to a name DECLARES it (`:=`); later ones assign (`=`).
  if ctx.isTaskArgsBind(e):
    return ctx.genOdinTaskArgsBind(e, "  ".repeat(ctx.indent))
  let valStr = ctx.genOdinExpr(e.assignVal)
  if e.target.kind == exkVar and e.target.name notin ctx.definedVars and
     e.target.name notin ctx.fieldVars:
    ctx.definedVars.incl(e.target.name)
    return e.target.name & " := " & valStr
  if e.target.kind == exkField and e.target.receiver != nil and
     e.target.receiver.kind == exkRegisterRef:
    let prefix = registerAccessorPrefix(ctx.module, e.target.receiver.refName,
                                        e.target.fieldName)
    if prefix != "": return prefix & "_set(" & valStr & ")"
  ctx.genOdinExpr(e.target) & " = " & valStr

proc genReturnStmt(ctx: var OdinCodegenCtx, e: Expr): string =
  ## `return err X` is the raise, not a wrapped return value.
  if e.returnVal != nil and e.returnVal.kind == exkRaise:
    ctx.genOdinExpr(e.returnVal)
  else:
    ctx.genOdinReturn(e)

proc genChainStep(ctx: var OdinCodegenCtx, step: ChainStep, baseStr,
                  ind: string): string =
  ## One step: a mutator call reassigned into the base var, a register
  ## field's setter, or a field set.
  if semLayer.stepCall(step) != nil:
    return ind & baseStr & " = " & ctx.genOdinCall(semLayer.stepCall(step))
  let valStr = if isSingleFieldPayload(step.arg):
                 ctx.genOdinExpr(soleFieldValue(step.arg))
               else: ""
  let prefix = registerAccessorPrefix(ctx.module, baseStr, step.target.name)
  if prefix != "": return ind & prefix & "_set(" & valStr & ")"
  ind & baseStr & "." & step.target.name & " = " & valStr

proc genChainRevalidate(ctx: OdinCodegenCtx, e: Expr, baseStr,
                        ind: string): string =
  ## A mutation site: an invariant-carrying var re-validates after the chain.
  if e.base == nil: return ""
  let bt = semLayer.typeFor(e.base)
  if bt == nil or bt.kind != tkNamed or not hasInvariants(ctx.module, bt.name):
    return ""
  ind & "validate_" & bt.name & "(" & baseStr & ")"

proc genChain(ctx: var OdinCodegenCtx, e: Expr, ind: string): string =
  ## `x ..field {v} ..mutate {a}` — one plain statement per step.
  let baseStr = ctx.genOdinExpr(e.base)
  var lines: seq[string]
  for step in e.steps:
    lines.add(ctx.genChainStep(step, baseStr, ind))
  let revalidate = ctx.genChainRevalidate(e, baseStr, ind)
  if revalidate != "": lines.add(revalidate)
  lines.join("\n")

proc genSend(ctx: var OdinCodegenCtx, e: Expr): string =
  ## `Actor send handler {payload}` — enqueue an envelope on the singleton's
  ## mailbox, then wake the actor. A full ring drops (spec §9.1). The send
  ## helper genActor emitted takes the payload fields positionally after the
  ## actor pointer, in handler-param order.
  var sendArgs: seq[string]
  if e.sendPayload != nil and e.sendPayload.kind == exkStruct:
    for f in e.sendPayload.fields:
      sendArgs.add(ctx.genOdinExpr(f.value))
  let sep = if sendArgs.len > 0: ", " else: ""
  "send" & e.sendHandler.capitalize() & "_" & e.sendActor & "(&" &
    actorSingletonName(e.sendActor) & sep & sendArgs.join(", ") & ")"

proc odinSelectTimeoutMs(ctx: var OdinCodegenCtx, arm: SelectArm): string =
  ## The `timeout` arm's deadline as a plain int of milliseconds. Mirrors
  ## the Nim backend's selectTimeoutMs exactly: `timeout {5.ms}` passes a
  ## duration payload that unwraps to its single field; a bare `timeout 30`
  ## is already an int literal and passes through.
  let ms = ctx.genOdinExpr(soleFieldValue(arm.arg))
  if arm.arg != nil and arm.arg.kind == exkLit: ms
  else: "int(" & ms & ")"

proc genOdinSelect(ctx: var OdinCodegenCtx, e: Expr, ind: string): string =
  ## Task `on select` (spec §9.3): a `read <fd>` arm racing a `timeout <ms>`
  ## arm via rt.tuckAwaitReadOrTimeout — true means the fd won (run the read
  ## body), false means the deadline won. Mirrors the Nim backend's
  ## genExprSelect; the actor form of `on select` (message arms, no timing)
  ## is a SEPARATE construct lowered at the actor DECLARATION, not here —
  ## this arm only ever sees the task's read/timeout race.
  ##
  ## The checker's failIfUnlowerableArm already refuses any arm shape but
  ## these two before this is reached, so the fallback below is unreachable
  ## for a checked program and stays only as a visible marker.
  var readArm, timeoutArm: ptr SelectArm = nil
  for arm in e.selArms.mitems:
    case arm.sourceKind
    of sskRead: readArm = addr arm
    of sskTimeout: timeoutArm = addr arm
    of sskTimeoutTyped, sskOther: discard
  if readArm == nil or timeoutArm == nil:
    return ind & "// select: only read+timeout arms supported (first cut)"
  let fd = ctx.genOdinExpr(readArm.arg)
  let ms = ctx.odinSelectTimeoutMs(timeoutArm[])
  let readBody = ctx.genBranch(readArm.body, ind)
  let toBody = ctx.genBranch(timeoutArm.body, ind)
  "if rt.tuckAwaitReadOrTimeout(" & fd & ", " & ms & ") {\n" & readBody &
    "\n" & ind & "} else {\n" & toBody & "\n" & ind & "}"

proc genOdinExpr*(ctx: var OdinCodegenCtx, e: Expr): string =
  if e == nil: return ""
  let ind = "  ".repeat(ctx.indent)
  let w = semLayer.wrapOf(e)
  if w.objName != "" and e.kind == exkVar:
    return ctx.genInterfaceWrap(e, w)
  case e.kind
  of exkLit: genLit(e)
  of exkVar: ctx.genVar(e)
  of exkActorRef, exkRegisterRef, exkRegistryRef, exkPoolRef, exkMixinRef:
    e.refName
  of exkField: ctx.genFieldAccess(e, ind)
  of exkQualified: genQualified(ctx, e)
  of exkCall: ctx.genOdinCall(e)
  of exkStruct: ctx.genStructLit(e)
  of exkList: ctx.genList(e)
  of exkBracket, exkBracketAssign: ctx.genCallResolved(e)
  of exkFor: ctx.genFor(e, ind)
  of exkWhile: ctx.genWhile(e, ind)
  of exkBreak: "break"
  of exkContinue: "continue"
  of exkBinary: ctx.genBinary(e)
  of exkUnary: ctx.genUnary(e)
  of exkBlock: ctx.genBlock(e, ind)
  of exkIf: ctx.genIf(e, ind)
  of exkAssign: ctx.genAssign(e)
  of exkMatch: (if e.subject != nil: ctx.genMatchExpr(e) else: "")
  of exkReturn: ctx.genReturnStmt(e)
  of exkRaise: ctx.genRaise(e)
  of exkDiscard:
    # Odin has no `discard` keyword; `_ = expr` is its own native value-drop
    # (same construct Go uses). A bare `discard` has nothing to drop, so it
    # emits nothing — genStmt already skips an empty statement cleanly.
    if e.discardVal != nil: "_ = " & ctx.genOdinExpr(e.discardVal)
    else: ""
  of exkChain: ctx.genChain(e, ind)
  of exkSend: ctx.genSend(e)
  of exkSelect: ctx.genOdinSelect(e, ind)
  of exkImport: ""  # imports are declarations, never expression position

# Declaration codegen (genOdinDecl and everything it dispatches to --
# fn/object/actor/registry/register/mixin/decision-table/err-handler) now
# lives in codegen_odin_decl.nim, imported above.
# Shared emission core: hoisted decls + members inside one Beef type.







# A library module (import target). Odin has no static classes: a module is
# a package, and a qualified ref (`fs::readFile`) becomes `fs.readFile` via
# the import alias, so the declarations sit at top level here too.
