# compiler/codegen_odin.nim
# Odin backend. Mirrors codegen.nim (the Nim backend) construct for
# construct: !T/?T result auto-wrap, record construction with invariant
# validation, payload sum types,
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
import twin_calls  # which calls take the moved twin — decided in prepare
from lowering_seqcopy import needsDup, recordDupFields
from ast_ops import pathOf
from os import getEnv

let DebugInPlace = not defined(release) and getEnv("TUCK_DEBUG_INPLACE").len > 0
  ## Read ONCE at module init. `genAssign` runs per assignment in the
  ## program, and an environment lookup there is a syscall-shaped cost on
  ## the hot path of every build.

import record_shape  # what a combinator PRODUCES, decided once for all backends
import codegen_odin_util  # ctx-free helpers: lib specs, err codes, pure AST predicates
export odinLibSpec
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
  ## codegen_common.recordArgFields, printed: `f(p.a, p.b)`, or "" when the
  ## call is not a record variable standing for its payload.
  let fields = recordArgFields(ctx.res, ctx.module, ctx.realModules, e)
  if fields.isNone: return ""
  let recv = ctx.genOdinExpr(e.args[0])
  var parts: seq[string]
  for f in fields.get: parts.add(recv & "." & f)
  calleeStr & "(" & parts.join(", ") & ")"

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
  if ctx.res.typeFor(e) != nil:
    declFields = getFieldsForType(ctx.res, ctx.module, ctx.res.typeFor(e))
  var allKnown = declFields.len > 0
  for f in declFields:
    if hasMissingType(f.typ): allKnown = false
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
    if ft == nil: raise newException(ValueError, "Odin: struct literal field has no type")
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
# The four record combinators share one emitter; what each PRODUCES is
# decided in record_shape.nim. Odin's part is only its own syntax: a struct
# literal takes `name = value`, and a structural shape lands on a hoisted
# TRec struct rather than an anonymous tuple.
#
# ponytail: exkVar receivers only. A non-var receiver would need a temp and
# this backend has no expression-position `let`, so it declines and the call
# proceeds as a plain one — exactly what the four hand-written procs did.
proc renderShape(ctx: var OdinCodegenCtx, s: RecordShape): string =
  if s.ctor == ckPassThrough: return ""
  for r in s.receivers:
    if r.kind != exkVar or ctx.res.typeFor(r) == nil: return ""
  var parts: seq[string]
  for f in s.fields:
    let value = case f.src
                of vsExpr: ctx.genOdinExpr(f.value)
                of vsProject: ctx.genOdinExpr(f.fromExpr) & "." & f.fromField
    parts.add(f.name & " = " & value)
  if parts.len == 0: return ""
  if s.ctor == ckStructural:
    return ctx.recStructName(s.declFields) & "{" & parts.join(", ") & "}"
  let ctor = s.typeName & "{" & parts.join(", ") & "}"
  # a rebuilt record is a production site too: its invariants must hold
  if s.invariantsOwed: return "__validated_" & s.typeName & "(" & ctor & ")"
  ctor


proc asSumVariantCall(ctx: var OdinCodegenCtx, e: Expr): string =
  ## `Type.Variant {payload}` — a kind-tagged construction, not a call.
  if e.callee == nil or e.callee.kind != exkField or
     e.callee.receiver == nil or e.callee.receiver.kind != exkVar: return ""
  let payload = if e.args.len == 1 and e.args[0].kind == exkStruct: e.args[0]
                else: nil
  ctx.sumVariantCtor(e.callee.receiver.name, e.callee.fieldName, payload)

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
  let t = ctx.res.typeFor(e)
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
  if ctx.index.hasInvariants(e.callee.name):
    # production site: construction — validate before the value flows on
    return "__validated_" & e.callee.name & "(" & ctor & ")"
  ctor

proc genCallArgs(ctx: var OdinCodegenCtx, e: Expr): seq[string] =
  ## ponytail: pass records BY VALUE. A mutating callee would need `^T` and
  ## `&x` at the call site, but Odin proc params aren't addressable, so
  ## `&param` is a hard error — and Tuck's mutators already return the updated
  ## value, which the chain emitter assigns back. Revisit if a real in-place
  ## mutator shows up that the return-and-assign shape can't express.
  ##
  ## A payload's arguments are call_args.payloadArgs's, printed; anything
  ## else as written.
  let args = if e.isPayloadCall:
               payloadArgs(ctx.res, ctx.module, ctx.realModules, e)
             else: e.args
  for a in args: result.add(ctx.genOdinExpr(a))

const RtByPointer = ["acquire", "release", "alloc", "reset", "enqueue",
                     "dequeue", "hasRoom", "initMailbox", "tuckArraySetAt"]
  ## Runtime intrinsics whose receiver they MUTATE, so it goes in by pointer.
  ## `tuckArraySetAt` joins this list, not RtByValue below, because Odin's
  ## fixed `[N]T` is a real value type — unlike `[dynamic]T`/`[]T`, whose
  ## header aliases the backing store even passed by value. Mutating a
  ## by-value `[N]T` parameter would mutate a copy and the caller would
  ## never see it.

const RtByValue = ["at", "setAt", "tuckAt", "tuckSetAt", "tuckArrayAt",
                   "toStr", "tuckConcat", "errCode", "push", "joinStr",
                   "fromBytes", "bitAnd", "bitOr", "bitXor", "bitNot",
                   "shiftLeft", "shiftRight",
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

proc genOdinCombinator(ctx: var OdinCodegenCtx, e: Expr): string =
  ctx.renderShape(shapeOf(ctx.module, ctx.res, e))

proc asCombinatorCall(ctx: var OdinCodegenCtx, e: Expr,
                      calleeStr: string): string =
  ## The compile-time combinators, each of which rewrites the call rather than
  ## emitting one. Any that declines returns "" and the call proceeds.
  let builtin = ctx.asParenBuiltinOdin(e, calleeStr)
  if builtin != "": return builtin
  if isRecordConstruction(ctx.module, e): return ctx.genRecordCtor(e)
  return ctx.explodeRecordArg(e, calleeStr)

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
  let satT = ctx.index.saturatingType(calleeStr)
  if satT != nil and args.len == 1:
    return ctx.genSaturatingCtor(satT, calleeStr, args[0])
  let invRet = ctx.index.externInvRet(calleeStr)
  if invRet != "":
    # extern boundary: the returned value validates on entry
    return "__validated_" & invRet & "(" & calleeStr & "(" &
           args.join(", ") & "))"
  if calleeStr == "echo": return "fmt.println(" & args.join(", ") & ")"
  let rt = genRtCall(calleeStr, args)
  if rt != "": return rt
  ""

proc findCalleeDecl(ctx: var OdinCodegenCtx, e: Expr): Decl =
  ## Find the callee declaration, checking local first, then imported modules.
  var d = ctx.res.declFor(e)
  if d == nil and e.callee != nil:
    let want = (if e.callee.kind == exkVar: e.callee.name else: e.callee.qualName)
    d = ctx.module.findFn(want)
    if d == nil:
      for _, im in ctx.realModules:
        d = im.findFn(want)
        if d != nil: break
  return d

proc odinTypeArgs(ctx: var OdinCodegenCtx, e: Expr): seq[string] =
  ## Odin declares a type param no parameter mentions as a leading
  ## `$E: typeid`, which makes the type an ARGUMENT — so the call has to pass
  ## it. Unlike Nim's `[C, E]` and D's `!(C, E)`, only the UN-INFERRED ones are
  ## passed, in declaration order, because the rest Odin still deduces from the
  ## values. Without this Odin reported "Parameter 'c' of type '$C' is missing
  ## in procedure call" — it had matched the value against the typeid slot.
  let targs = ctx.res.callTypeArgsFor(e)
  if targs.len == 0: return @[]
  let d = findCalleeDecl(ctx, e)
  if d == nil or d.kind != dkFn or d.fnGenerics.len != targs.len: return @[]
  for i, g in d.fnGenerics:
    var mentioned = false
    for p in d.fnParams:
      if typeMentionsName(p.typ, g):
        mentioned = true
        break
    if not mentioned: result.add(ctx.odinType(targs[i]))

proc genOdinActorWaitOn(ctx: var OdinCodegenCtx, e: Expr): string =
  ## `Actor.waitUntil {pred: :p}` -> `rt.tuckWaitOn(<Actor>Slot, p)`. The
  ## checker rewrote the member call into `waitUntil(<actorRef>, pred)`, so the
  ## actor is still named in arg 0. Twin of the Nim genActorWaitOn.
  if not isActorWaitOn(e): return ""
  "rt.tuckWaitOn(" & actorSlotName(e.args[0].refName) & ", " &
    ctx.genOdinExpr(e.args[1]) & ")"

proc genOdinCall(ctx: var OdinCodegenCtx, e: Expr): string =
  let waitOn = ctx.genOdinActorWaitOn(e)
  if waitOn != "": return waitOn
  let variant = ctx.asSumVariantCall(e)
  if variant != "": return variant
  var calleeStr = ctx.genOdinExpr(e.callee)
  let member = memberCallee(ctx.res, ctx.module, e)
  if member != "": calleeStr = member
  let combinator = ctx.asCombinatorCall(e, calleeStr)
  if combinator != "": return combinator
  var args = ctx.genCallArgs(e)
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
  if ctx.index.isTaskName(calleeStr) and args.len == 0:
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
  # A call that may take its first argument destructively, in ANY position —
  # the assignment emitters catch their own two shapes upstream of here, and
  # `return f(x, ...)` is the one nothing else reaches.
  return (if callsTwin(e): movedName(calleeStr) else: calleeStr) &
         "(" & (ctx.odinTypeArgs(e) & args).join(", ") & ")"

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
  if owner != "": return ctx.qualifyEnumOwner(owner) & "." & patStr
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
proc genOdinBareReturn(ctx: OdinCodegenCtx): string =
  ## A `return` with no value: absent (?T/!?T), void success (!void), or a
  ## plain Odin `return` otherwise.
  if ctx.retWrapped and ctx.retAbsentCapable: "return rt.tnone(" & ctx.retInnerOdin & ")"
  elif ctx.retWrapped and ctx.retInnerOdin == "rt.TuckUnit": "return rt.tokVoid()"
  else: "return"

proc genOdinReturn(ctx: var OdinCodegenCtx, e: Expr): string =
  if e.returnVal == nil:
    return ctx.genOdinBareReturn()
  elif ctx.retWrapped:
    let v = e.returnVal
    if v.kind == exkRaise:
      return ctx.genRaise(v)  # err X already emits the full error return
    elif isResultCarrierType(ctx.res.typeFor(v)):
      # Already a carrier: pass it through rather than wrapping it twice.
      return "return " & ctx.genOdinExpr(v)
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
  elif ctx.retInvName != "" and not validatesItself(ctx.module, e.returnVal):
    # production site: return value of an invariant-carrying type.
    # `validatesItself` keeps a construction from being wrapped twice — it
    # already validated at the construction site, on this same value.
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

proc detectMatchPatterns(e: Expr, ctx: var OdinCodegenCtx): tuple[errMatch, hasWild, overEnum: bool] =
  ## Analyze match arms to detect error patterns, wildcards, and enum tags.
  var errMatch = false
  var hasWild = false
  var overEnum = false
  for arm in e.arms:
    if arm.pattern != nil and arm.pattern.kind == pkWild:
      hasWild = true
    if arm.pattern != nil and arm.pattern.kind == pkVar and "." in arm.pattern.name:
      errMatch = true
    elif arm.pattern != nil and
         enumTagOwner(ctx.module, genPatternStr(arm.pattern)) != "":
      overEnum = true
  return (errMatch, hasWild, overEnum)

proc odinSwitchPrefix(errMatch, hasWild, overEnum: bool): string =
  ## Determine the switch statement prefix based on match characteristics.
  ## #partial is needed for enum exhaustiveness when a wildcard is present.
  if hasWild and overEnum: "#partial switch (" else: "switch ("

proc genMatchStmt(ctx: var OdinCodegenCtx, e: Expr): string =
  let sumName = payloadSumTypeName(ctx.module, ctx.res.typeFor(e.subject))
  if sumName != "": return ctx.genPayloadUnionMatch(e, sumName)
  let ind = "  ".repeat(ctx.indent)
  let subjectStr = ctx.genOdinExpr(e.subject)
  var cases: seq[string]
  let oldIndent = ctx.indent
  ctx.indent += 1
  let (errMatch, hasWild, overEnum) = detectMatchPatterns(e, ctx)
  for arm in e.arms:
    let patStr = genPatternStr(arm.pattern)
    let bodyStr = ctx.genOdinExpr(arm.body)
    var caseVal = ""
    if arm.pattern != nil and arm.pattern.kind == pkVar and
       "." in arm.pattern.name:
      let dot = arm.pattern.name.find(".")
      caseVal = errCodeLit(errNameFor(ctx.module, ctx.moduleName, arm.pattern.name[0 ..< dot],
                                          arm.pattern.name[dot+1 .. ^1]))
    # Odin's catch-all is a BARE `case:` — `default` is not a keyword there,
    # so `default: break;` parsed as a variable declaration ("Missing variable
    # type or initialization"). Nothing caught it because the only error
    # match in the corpus was built on Nim alone.
    let caseLabel = if patStr == "_": "case:"
                    elif caseVal != "": "case " & caseVal & ":"
                    else: "case " & ctx.patternValue(patStr) & ":"
    if arm.body != nil and arm.body.kind == exkBlock:
      cases.add(ind & caseLabel & "\n" & bodyStr)
    else:
      cases.add(ind & caseLabel & " " & bodyStr & ";")
  if errMatch and not hasWild:
    cases.add(ind & "case:  // no arm; the fn's own fallthrough answers")
  ctx.indent = oldIndent
  let sw = odinSwitchPrefix(errMatch, hasWild, overEnum)
  return ind & sw & subjectStr & ")\n" & ind & "{\n" &
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
  ## A nested body is its own SCOPE, so a name declared inside it is gone
  ## afterwards. `definedVars` decides declaration-vs-assignment and was keyed
  ## by bare name with no scope: a second `let lead` in a SIBLING branch saw
  ## the name present and emitted an assignment to a variable the first branch
  ## had taken out of scope. Restoring the set makes emitted scoping match
  ## Tuck's — the codegen twin of the checker's name-keyed shadow bug.
  let saved = ctx.indent
  let savedVars = ctx.definedVars
  ctx.indent += 1
  result = ctx.genOdinExpr(e)
  ctx.indent = saved
  ctx.definedVars = savedVars

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

const OdinWidthNames = ["u8", "u16", "u32", "u64",
                        "i8", "i16", "i32", "i64", "f32"]

proc genLit(ctx: var OdinCodegenCtx, e: Expr): string =
  case e.litKind
  of lkStr: "\"" & escapeStringLit(e.litValue) & "\""
  of lkInt, lkFloat:
    # A bare Odin literal is `int` (or `f64`), and Odin does not convert
    # between it and a fixed-width type implicitly: `return rt.tok(0)` in an
    # `-> i64?` fn is "Cannot assign 'TuckResult($T=int)' to
    # 'TuckResult($T=i64)'". So a literal in an INFERRED position spells its
    # own width, the same reason Nim gets a `'u64` suffix and D an `L` — and
    # from the same source, the width the checker settled on in synthLit.
    let t = ctx.res.typeFor(e)
    if t != nil and t.kind == tkNamed and t.name in OdinWidthNames:
      return t.name & "(" & e.litValue & ")"
    e.litValue
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
  if ctx.res.hasCall(e): return ctx.genOdinExpr(ctx.res.call(e))
  if isInputRef(e, ctx.currentParams): return ctx.genInputPayload()
  if e.name == "self" and ctx.ptrSelf: return "self^"  # member fn: deref
  if e.name in ctx.fieldVars: return ctx.fieldPrefix & e.name
  if e.name in ctx.definedVars: return e.name
  # bare enum tag: qualify with its declared owner (Odin has no module-global
  # enum members the way Nim does)
  let owner = enumTagOwner(ctx.module, e.name)
  if owner != "": return ctx.qualifyEnumOwner(owner) & "." & e.name
  # A variant of an INLINE sum (`state: {Red, Green} = Red`) has no owner to
  # qualify with; Odin's implicit selector names it, the target being typed.
  let t = ctx.res.typeFor(e)
  if t != nil and t.kind == tkSum:
    for v in t.variants:
      if v.name == e.name: return "." & e.name
  let foreign = ctx.qualifiedForeignFn(e.name)
  if foreign != "": return foreign
  e.name

proc genIfaceCall(ctx: var OdinCodegenCtx, e: Expr): string =
  ## A call through an interface value, lowered (lowering_iface): switch on
  ## the tag and print each arm's member call. An immediately-called closure,
  ## because Odin has no switch EXPRESSION and a call site needs a value —
  ## typed with the CALL's type. It said `-> int` whatever the member
  ## returned, so a member returning `str` did not compile (#40).
  let recv = ctx.genOdinExpr(e.dispatchRecv)
  let t = ctx.res.typeFor(e)
  let isVoid = t == nil or (t.kind == tkNamed and t.name == "void")
  var arms: seq[string]
  for arm in e.dispatchArms:
    arms.add("\t\tcase ." & e.dispatchIface & "_is_" & arm.satisfier & ":\n" &
             "\t\t\t" & arm.bindName & " := v." & arm.satisfier & "Val\n" &
             "\t\t\t" & (if isVoid: "" else: "return ") &
             ctx.genOdinExpr(arm.call))
  if arms.len == 0: return ""
  let sig = if isVoid: "" else: " -> " & ctx.odinType(t)
  # The tag is always one of the arms; the panic is what Odin's "missing
  # return" asks for, and what a corrupt value deserves.
  let tail = if isVoid: "" else: "\tpanic(\"unreachable interface tag\")\n"
  "(proc(v: " & e.dispatchIface & ")" & sig & " {\n\tswitch v.tag {\n" &
    arms.join("\n") & "\n\t}\n" & tail & "})(" & recv & ")"

proc boundVariantField(ctx: OdinCodegenCtx, e: Expr): string =
  ## Inside `switch v in value`, a payload field belongs to the BOUND
  ## variant, not to the subject — Odin's union has no discriminant field to
  ## reach past. "" when this is not that situation.
  if ctx.unionBind == "" or e.receiver == nil or
     e.receiver.kind != exkVar: return ""
  if payloadSumTypeName(ctx.module, ctx.res.typeFor(e.receiver)) == "":
    return ""
  ctx.unionBind & "." & e.fieldName

proc importedTypeMember(ctx: OdinCodegenCtx, e: Expr): string =
  ## `Order.Before` where `Order` came from an IMPORTED module: the type lives
  ## in that module's package and has to be reached through it, exactly as
  ## importedTypeQualifier already does in TYPE position. "" when the receiver
  ## is not an imported type name.
  if e.receiver == nil or e.receiver.kind != exkVar: return ""
  let origin = moduleDeclaringType(ctx.module, e.receiver.name)
  if origin.len == 0: return ""
  let pkg = origin.replace("-", "_")
  if pkg == ctx.moduleName.replace("-", "_"): return ""
  pkg & "." & e.receiver.name & "." & e.fieldName

proc fieldByReceiverKind(ctx: var OdinCodegenCtx, e: Expr): string =
  ## The two `.name` readings decided by what the RECEIVER is rather than by
  ## what the field is: a bare `Type.Variant` construction, and a register
  ## field (a raw pointer with no real field, so reading it means calling the
  ## getter genRegister emitted). "" when the receiver is neither.
  if e.receiver == nil: return ""
  case e.receiver.kind
  of exkVar:
    # The payload, if any, arrives as `.fn {args}`'s dotArg — passing nil here
    # silently dropped every field a `Type.Variant {payload}` supplied.
    ctx.sumVariantCtor(e.receiver.name, e.fieldName, e.dotArg)
  of exkRegisterRef:
    let prefix = registerAccessorPrefix(ctx.module, e.receiver.refName,
                                        e.fieldName)
    if prefix == "": "" else: prefix & "_get()"
  else: ""

proc assertedVariantField(ctx: var OdinCodegenCtx, e: Expr): string =
  ## Reading a payload field of a union-typed value OUTSIDE a type switch.
  ##
  ## Odin's union carries no discriminant field to reach past, so the variant
  ## has to be ASSERTED: `x.(Shape_Rect).w`. Which variant it is comes from the
  ## same question the other two backends ask — who declares this field —
  ## except they can spell the answer as a plain `.rect.w` because they have a
  ## tag field and Odin does not.
  ##
  ## This became reachable when a payload-sum local started being declared at
  ## the UNION type (see unionDeclType). Before that the local was typed as the
  ## variant struct, so a direct `.w` worked and `switch v in x` did not.
  if e.receiver == nil: return ""
  let sumName = payloadSumTypeName(ctx.module, ctx.res.typeFor(e.receiver))
  if sumName == "": return ""
  let owner = variantOwningField(ctx.module, sumName, e.fieldName)
  if owner == "": return ""
  ctx.genOdinExpr(e.receiver) & ".(" & sumName & "_" & owner & ")." & e.fieldName

proc genFieldAccess(ctx: var OdinCodegenCtx, e: Expr, ind: string): string =
  ## A `.name` access: interface dispatch, an actor singleton's field, a
  ## status test, a resolved call, a sum-variant construction, or a plain read.
  doAssert ctx.res.ifaceCallOf(e).member == "",
    "codegen_odin: an interface call reached the emitter unlowered (lowering_iface)"
  # A CHECKER-RESOLVED CALL FIRST, before the actor-field read below. Nim's
  # genFieldAccess has always tested hasCall first; Odin tested the actor
  # branch first, so `Actor.waitUntil {pred: :p}` — a static member call whose
  # receiver is an actor — emitted `Singleton.waitUntil` as though it were a
  # field read, and Odin answered "has no field 'waitUntil'".
  if ctx.res.hasCall(e): return ctx.genOdinCall(ctx.res.call(e))
  # `Counter.total` reads the actor SINGLETON's field, not a type's.
  if e.receiver != nil and e.receiver.kind == exkActorRef:
    return actorSingletonName(e.receiver.refName) & "." & e.fieldName
  if isResultStatusTest(e):
    # parenthesised: a guard may negate it (`!r.ok`), and `!x == y` would
    # otherwise bind the `!` to the receiver alone
    return "(" & ctx.genOdinExpr(e.receiver) & ".status == .Ok)"
  if isInputField(e, ctx.currentParams): return e.fieldName
  if isLenOnSized(ctx.res, e): return "len(" & ctx.genOdinExpr(e.receiver) & ")"
  let byRef = ctx.fieldByReceiverKind(e)
  if byRef != "": return byRef
  let bound = ctx.boundVariantField(e)
  if bound != "": return bound
  let asserted = ctx.assertedVariantField(e)
  if asserted != "": return asserted
  let imported = ctx.importedTypeMember(e)
  if imported != "": return imported
  ctx.genOdinExpr(e.receiver) & "." & e.fieldName

proc genCallResolved(ctx: var OdinCodegenCtx, e: Expr): string =
  ## Indexing resolved to an at() call; a type application never reaches
  ## codegen, so an unresolved bracket emits nothing.
  if ctx.res.hasCall(e): ctx.genOdinExpr(ctx.res.call(e)) else: ""

proc genList(ctx: var OdinCodegenCtx, e: Expr): string =
  ## `[dynamic]T{a, b}` — the element type SPELLED OUT, not inferred.
  ##
  ## A bare `{a, b}` works where context supplies the type (a struct literal's
  ## field), and nowhere else: `var xs = [1, 2]` emitted `tuck_a := {1, 2}`
  ## and Odin reported "Missing type in compound literal". The checker has
  ## already stamped this node's type, so naming it costs nothing and is
  ## correct in both positions.
  var parts: seq[string]
  for item in e.items: parts.add(ctx.genOdinExpr(item))
  let t = ctx.res.typeFor(e)
  let prefix = if t == nil or (seqElem(t) == nil and not isFixedArray(t)): ""
               else: ctx.odinType(t)
  prefix & "{" & parts.join(", ") & "}"

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
  ## `for <cond>:` (and bare `loop:`) — Odin has ONE loop keyword and `while`
  ## is not it: the emitted `while (c)` was "Undeclared name: while.
  ## Suggestion: Did you mean 'for'?". Nim and D both accept `while`, which
  ## is why nothing in the corpus caught it — Tuck's conditional loop had
  ## never been built on Odin.
  ##
  ## A condition-less `loop:` is Odin's bare `for { }`, not `for true { }`.
  let bodyStr = ctx.genIndented(e.whileBody)
  if e.whileCond == nil:
    return ind & "for {\n" & bodyStr & "\n" & ind & "}"
  ind & "for " & ctx.genOdinExpr(e.whileCond) & " {\n" & bodyStr &
    "\n" & ind & "}"

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
  # A payload sum is a union, and Odin refuses to compare one that is not
  # "simply comparable" — which any recursive sum is not, its edges being
  # dynamic arrays. Odin has no operator overloading, so the comparison is a
  # generated PROC (genSumEqProc) and the call site routes to it.
  if e.binOp in {boEq, boNeq}:
    let sumName = payloadSumTypeName(ctx.module, ctx.res.typeFor(e.left))
    if sumName != "":
      let call = sumName & "_eq(" & ctx.genOdinExpr(e.left) & ", " &
                 ctx.genOdinExpr(e.right) & ")"
      return if e.binOp == boEq: call else: "(!" & call & ")"
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
  let tn = ctx.freshName("tuckDrop")
  let site = ctx.res.shortcut(s)
  let onErr = if ctx.errPolicy == "exit":
                UnhandledHandlerName & "(" & tn & ".err, \"" & site &
                  "\"); panic(\"unhandled error\")"
              else:
                UnhandledHandlerName & "(" & tn & ".err, \"" & site & "\")"
  ind & "\t" & tn & " := " & stmtCode & "\n" &
    ind & "\tif " & tn & ".status != .Ok { " & onErr & " }"

proc genRoutedStmt(ctx: var OdinCodegenCtx, s: Expr, stmtCode,
                   ind: string): string =
  ## Route an unanswered error to the global handler.
  ##
  ## Two shapes, because a BINDING is not an expression: capturing
  ## `r := f()` in a temp would emit `tuckDrop1 := r := f()`. A binding
  ## already names its value, so it is tested in place.
  ##
  ## It is also tested for `.Err` and not `!= .Ok`: a binding only reaches
  ## here as the `!?T` case where `if r.ok:` answered ABSENCE and left the
  ## error open, and an absence the author handled must not fire the handler.
  if s.kind != exkAssign or s.target == nil or s.target.kind != exkVar:
    return ctx.genDroppedResult(s, stmtCode, ind)
  let site = ctx.res.shortcut(s)
  let name = s.target.name
  let onErr = if ctx.errPolicy == "exit":
                UnhandledHandlerName & "(" & name & ".err, \"" & site &
                  "\"); panic(\"unhandled error\")"
              else:
                UnhandledHandlerName & "(" & name & ".err, \"" & site & "\")"
  ind & "\t" & stmtCode & "\n" &
    ind & "\tif " & name & ".status == .Err { " & onErr & " }"

proc isTaskArgsBind(ctx: var OdinCodegenCtx, e: Expr): bool =
  ## `let r = {args} someTask` — binding a task's result awaits it (spec
  ## §9.2), and the task takes real arguments (a nullary task call is the
  ## OTHER case, already spawned via genOdinCall's isTaskName branch).
  e.kind == exkAssign and e.assignVal != nil and
    e.assignVal.kind == exkCall and e.assignVal.callee != nil and
    e.assignVal.callee.kind == exkVar and
    ctx.index.isTaskName(e.assignVal.callee.name) and e.assignVal.args.len > 0

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
  let argParts = ctx.genCallArgs(e.assignVal)
  doAssert argParts.len == params.len,
    "odin: task " & tname & " takes " & $params.len & " param(s), and its " &
    "call supplies " & $argParts.len
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
  if ctx.isTaskArgsBind(s): return true
  s.kind in {exkIf, exkFor, exkWhile, exkBlock, exkDefer}

proc genStmt(ctx: var OdinCodegenCtx, s: Expr, ind: string): string =
  ## One statement of a block, indented unless it lays itself out.
  var ownsLayout = s.kind == exkMatch and s.subject != nil
  var code = if ownsLayout: ctx.genMatchStmt(s) else: ctx.genOdinExpr(s)
  if code != "" and ctx.res.shortcut(s) != "":
    code = ctx.genRoutedStmt(s, code, ind)
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

proc genDefer(ctx: var OdinCodegenCtx, e: Expr, ind: string): string =
  ## `defer:` (spec §7.4). Odin has `defer` natively, with the same scope-exit
  ## LIFO order, and its block form takes braces — so the body is emitted as a
  ## brace-delimited block rather than genBlock's braceless run of statements.
  if e.deferBody == nil or e.deferBody.kind != exkBlock: return ""
  let body = ctx.genBlock(e.deferBody, ind)
  if body.len == 0: return ""
  ind & "defer {\n" & body & "\n" & ind & "}"

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

proc genOdinAssignTarget(ctx: var OdinCodegenCtx, e: Expr): string =
  ## Emitting an assignment TARGET. A bracket index must address the element
  ## IN PLACE: the read path resolves `xs[i]` to a tuckAt() call, which
  ## returns a COPY, so `xs[i].f = v` assigned into a temporary and the
  ## backend rejected it ("cannot be assigned to") after the checker had
  ## passed it clean. Direct indexing is what every backend spells here, and
  ## it keeps its own bounds check.
  ##
  ## Only the bracket case diverges; anything else defers to the normal
  ## emitter, which knows about field vars, stamped calls and the rest.
  if e == nil: return ""
  if not hasBracketBase(e): return ctx.genOdinExpr(e)
  case e.kind
  of exkBracket:
    ctx.genOdinExpr(e.brReceiver) & "[" &
      ctx.genOdinExpr(e.brArgs[0]) & "]"
  of exkField:
    ctx.genOdinAssignTarget(e.receiver) & "." & e.fieldName
  else: ctx.genOdinExpr(e)

proc movedAssignTarget(ctx: OdinCodegenCtx, t: Expr): string =
  ## The emitted spelling of an assignment target, for the two FAST PATHS
  ## below: the in-place append and the MOVED twin. Both bypass the field
  ## handling in the normal assign path, so both must qualify the target
  ## themselves.
  ##
  ## They did not, and the asymmetry is what made it hard to see: the
  ## right-hand side is built by the ordinary expression emitter, which DOES
  ## add the `self.`, so an actor handler emitted `st = f(self.st, ...)` —
  ## qualified on the right, bare on the left. Rejected here and by D; Nim
  ## was correct only because its backend never takes this path. EV-9.
  if t != nil and t.kind == exkVar and t.name in ctx.fieldVars:
    ctx.fieldPrefix & t.name
  else: t.name

proc copyIfSeq(ctx: var OdinCodegenCtx, valStr: string, e: Expr): string =
  ## A bare Seq being bound to a name. `[dynamic]T` assignment copies the
  ## HEADER, so both names then view one buffer — where a Tuck `Seq`
  ## assignment copies. lowering_seqcopy decides which sites need a real copy
  ## (the same analysis the D backend uses for its `.dup`); this prints Odin's.
  # No exception for a read through a MOVED twin's parameter — see the D
  # emitter's copy of this note (codegen_d.nim, `dupIfSeq`).
  if needsDup(ctx.res, e): "rt.tuckSeqCopy(" & valStr & ")"
  else: valStr

proc seqFieldFixups(ctx: var OdinCodegenCtx, target: string, e: Expr): string =
  ## A RECORD carrying Seq fields: the struct copy is field-for-field, so each
  ## Seq field's copy is a header aliasing the source. Emitted as statements
  ## AFTER the assignment rather than around the value: Odin's procedure
  ## literal does not capture locals, so the expression form D uses
  ## (`(){ ... }()`) reports `Undeclared name` for the very value it wraps.
  for f in recordDupFields(ctx.res, e):
    result.add("; " & target & "." & f & " = rt.tuckSeqCopy(" &
               target & "." & f & ")")

proc unionDeclType(ctx: var OdinCodegenCtx, e: Expr): string =
  ## The union type name, when this value belongs to a payload sum.
  ##
  ## Odin's tagged union has no tag FIELD — a variant simply IS its own struct
  ## type — so `x := Node_Block{...}` declares x as the STRUCT. A later
  ## `switch v in x` then reports "Invalid type for this type switch
  ## expression, got 'tuck_Node_Block'". Naming the union in the declaration is
  ## what puts the value into it; the other backends carry a `.kind` field and
  ## never had the question.
  let t = ctx.res.typeFor(e)
  if t == nil or t.kind != tkNamed: return ""
  let d = findDecl(ctx.module, dkType, t.name)
  if d == nil or d.typeBody == nil or d.typeBody.kind != tkSum: return ""
  if not sumHasPayload(d.typeBody): return ""
  t.name

proc withAssignValidate(ctx: var OdinCodegenCtx, e: Expr,
                        stmt: string): string =
  ## A field assignment is a mutation site and re-validates, exactly as a `..`
  ## chain step does. One shared decision across the backends, so they cannot
  ## drift on WHICH sites check — see codegen_common.assignInvariantOwner.
  result = stmt
  let owner = assignInvariantOwner(ctx.res, e)
  if owner != "" and ctx.index.hasInvariants(owner):
    result.add("\n" & "  ".repeat(ctx.indent) & "validate_" & owner & "(" &
               ctx.genOdinExpr(e.target.receiver) & ")")

proc ownedCopy(ctx: OdinCodegenCtx, valStr: string, val: Expr): string =
  ## A `str` literal the ownership pass decided this body must OWN, printed
  ## as a heap copy: the local it is assigned to frees each old value at
  ## its overwrite, and a literal is static storage (`copyToOwn`, step 5).
  if val == nil or not val.id.isSet or val.id notin ctx.owned.copyToOwn:
    return valStr
  doAssert val.kind == exkLit and val.litKind == lkStr,
    "ownership marked a non-literal to copy: " & $val.kind
  "rt.tuckStrOwned(" & valStr & ")"

proc scopeFrees(ctx: OdinCodegenCtx, name: string): string =
  ## The `defer delete`s a declaration of `name` carries.
  ##
  ## SHARED, because there are two paths that declare a local and only one of
  ## them used to run this. `genAssign`'s threaded-call branch returns early
  ## with `x := f_moved(y)` and never reaches `genOdinVarDecl`, which is
  ## exactly the shape `relight`'s intermediates have — so the frees were
  ## computed, correct, and emitted nowhere.
  let ind = "  ".repeat(ctx.indent)
  if name in ctx.owned.freeAtScopeExit:
    for slot in ctx.owned.freeAtScopeExit[name]:
      let path = if slot.len == 0: name else: name & "." & slot
      result.add("\n" & ind & "defer delete(" & path & ")")

proc genOdinVarDecl(ctx: var OdinCodegenCtx, e: Expr, valStr: string): string =
  ## The first assignment to a name, which DECLARES it.
  ctx.definedVars.incl(e.target.name)
  # A STATED type wins over both `:=` inference and the union-naming case:
  # the author wrote it precisely because the value cannot say what it is.
  let stated = if e.declType != nil: ctx.odinType(e.declType) else: ""
  let ut = if stated != "": stated else: ctx.unionDeclType(e.assignVal)
  let decl = if ut == "": e.target.name & " := " & valStr
             else: e.target.name & ": " & ut & " = " & valStr
  let fixups = ctx.seqFieldFixups(e.target.name, e.assignVal)
  # A local the ownership pass frees at scope exit — a heap slot, or a `str`
  # this body allocated (ownership_str) — gets its `defer` here. `defer`
  # rather than a free at the last use, because a defer needs no POSITION:
  # Odin runs it on every path out of the block. See EV-20.
  decl & ctx.scopeFrees(e.target.name) & fixups

proc reportInPlaceBypass(ctx: var OdinCodegenCtx, e: Expr, appended: Expr) =
  ## ITEM 4, MEASURED — see thoughts/ssa-mirror-design.md, Stage C.
  when not defined(release):
    # ITEM 4, MEASURED. `markSeqCopies` marks this binding as needing a copy
    # — it is a call, and a call is not `exclusivelyOwned` — and then the
    # fast paths below bypass `copyIfSeq` entirely and never look at the
    # mark. So `afterBinding`'s "it was not exclusive, therefore the binding
    # copied it, therefore it is fresh" is unbacked at exactly these sites.
    # Twelve of them across the corpus and both applications; see
    # thoughts/ssa-mirror-design.md, Stage C.
    if DebugInPlace:
      let threadedDbg = threadedCall(e)
      if (appended != nil or threadedDbg != nil) and
         (needsDup(ctx.res, e.assignVal) or
          recordDupFields(ctx.res, e.assignVal).len > 0):
        echo "INPLACE-BYPASS ", pathOf(e.target), " at ",
             e.span.line, ":", e.span.col

proc genThreadedAssign(ctx: var OdinCodegenCtx, e, threaded: Expr): string =
  ## `x = f(x)` calling the MOVED twin, with no fix-up copies after it.
  let base = ctx.genOdinExpr(threaded.callee)
  # A DECLARATION introduces the name, so Odin wants `:=`; a reassignment
  # wants `=`. selfThreadedCall accepts both shapes now, and this is the
  # only place the difference shows.
  let isNew = e.isDecl and e.target.name notin ctx.definedVars and
              e.target.name notin ctx.fieldVars
  if isNew: ctx.definedVars.incl(e.target.name)
  ctx.movedAssignTarget(e.target) & (if isNew: " := " else: " = ") &
    movedName(base) & "(" & ctx.genCallArgs(threaded).join(", ") & ")" &
    (if isNew: ctx.scopeFrees(e.target.name) else: "")

proc genReassign(ctx: var OdinCodegenCtx, e: Expr, valStr: string): string =
  ## An assignment to something that already exists.
  if e.target.kind == exkField and e.target.receiver != nil and
     e.target.receiver.kind == exkRegisterRef:
    let prefix = registerAccessorPrefix(ctx.module, e.target.receiver.refName,
                                        e.target.fieldName)
    if prefix != "": return prefix & "_set(" & valStr & ")"
  let tgt = ctx.genOdinAssignTarget(e.target)
  # THE OLD VALUE DIES HERE. A `defer` cannot reach this: it fires once, and
  # a loop abandons one buffer per iteration. Step 5 of the ownership pass.
  #
  # AFTER THE NEW VALUE IS BUILT, not before: `xs = {k: xs[0]} f` reads the
  # old value to make the new one, and freeing first handed it freed memory
  # (57 where Nim and D compute 8). The new value is fresh — step 5 only
  # fires when every value assigned is — so freeing the old one once it
  # exists can never free the new one.
  var pre = ""
  var value = valStr
  if e.target.kind == exkVar and e.target.name in ctx.owned.freeBeforeOverwrite:
    let next = ctx.freshName("tuckNext")
    let ind = "  ".repeat(ctx.indent)
    pre = next & " := " & valStr & "\n" & ind & "delete(" & tgt & ")\n" & ind
    value = next
  ctx.withAssignValidate(e, pre & tgt & " = " & value &
                            ctx.seqFieldFixups(tgt, e.assignVal))

proc genAssign(ctx: var OdinCodegenCtx, e: Expr): string =
  ## First assignment to a name DECLARES it (`:=`); later ones assign (`=`).
  if ctx.isTaskArgsBind(e):
    return ctx.genOdinTaskArgsBind(e, "  ".repeat(ctx.indent))
  # An append assigned back to its own argument is an in-place append.
  let appended = selfAppendValue(ctx.res, e)
  reportInPlaceBypass(ctx, e, appended)
  if appended != nil:
    return "append(&" & ctx.movedAssignTarget(e.target) & ", " &
           ctx.genOdinExpr(appended) & ")"
  # Same fact one level up: a threaded-container call assigned back over its
  # own argument calls the MOVED twin, and needs no fix-up copies after it.
  let threaded = threadedCall(e)
  if threaded != nil: return ctx.genThreadedAssign(e, threaded)
  let valStr = ctx.ownedCopy(ctx.copyIfSeq(ctx.genOdinExpr(e.assignVal),
                                          e.assignVal), e.assignVal)
  if e.target.kind == exkVar and e.target.name notin ctx.definedVars and
     e.target.name notin ctx.fieldVars:
    return ctx.genOdinVarDecl(e, valStr)
  ctx.genReassign(e, valStr)

proc genReturnStmt(ctx: var OdinCodegenCtx, e: Expr): string =
  ## `return err X` is the raise, not a wrapped return value.
  if e.returnVal != nil and e.returnVal.kind == exkRaise:
    ctx.genOdinExpr(e.returnVal)
  else:
    ctx.genOdinReturn(e)

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
  # One arm is a plain await, not a race — see codegen.nim's genSelect for
  # why this is its own case rather than the marker below (issue #56).
  # SEQUENTIAL, not nested — see codegen.nim's genSelect.
  if readArm != nil and timeoutArm == nil:
    return "rt.tuckAwaitRead(" & ctx.genOdinExpr(readArm.arg) & ")\n" &
           ind & ctx.genOdinExpr(readArm.body)
  if timeoutArm != nil and readArm == nil:
    return "rt.tuckSleep(" & ctx.odinSelectTimeoutMs(timeoutArm[]) & ")\n" &
           ind & ctx.genOdinExpr(timeoutArm.body)
  if readArm == nil or timeoutArm == nil:
    return ind & "// select: no lowerable arm (checker should have refused)"
  let fd = ctx.genOdinExpr(readArm.arg)
  let ms = ctx.odinSelectTimeoutMs(timeoutArm[])
  let readBody = ctx.genBranch(readArm.body, ind)
  let toBody = ctx.genBranch(timeoutArm.body, ind)
  "if rt.tuckAwaitReadOrTimeout(" & fd & ", " & ms & ") {\n" & readBody &
    "\n" & ind & "} else {\n" & toBody & "\n" & ind & "}"

proc genOrdinal(ctx: var OdinCodegenCtx, e: Expr): string =
  ## An enum converts to its ordinal with `int(x)`; a bool does not convert
  ## at all in Odin, so it is a ternary.
  let t = ctx.res.typeFor(e.ordinalOf)
  let v = ctx.genOdinExpr(e.ordinalOf)
  if t != nil and t.kind == tkNamed and t.name == "bool": "(" & v & " ? 1 : 0)"
  else: "int(" & v & ")"

proc genOdinExpr*(ctx: var OdinCodegenCtx, e: Expr): string =
  if e == nil: return ""
  let ind = "  ".repeat(ctx.indent)
  let w = ctx.res.wrapOf(e)
  if w.objName != "" and e.kind == exkVar:
    return ctx.genInterfaceWrap(e, w)
  case e.kind
  of exkLit: ctx.genLit(e)
  of exkVar: ctx.genVar(e)
  of exkActorRef, exkRegisterRef, exkRegistryRef, exkPoolRef, exkMixinRef:
    e.refName
  of exkField: ctx.genFieldAccess(e, ind)
  of exkQualified: genQualified(ctx, e)
  of exkCall: ctx.genOdinCall(e)
  of exkCombinator: ctx.genOdinCombinator(e)
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
  of exkTripleDot: ""   # `...` outside a fn body: a no-op statement
  of exkChain:
    raiseAssert "codegen_odin: a `..` chain reached the emitter; " &
      "lowering_chains rewrites every one into statements"
  of exkSend: ctx.genSend(e)
  of exkSelect: ctx.genOdinSelect(e, ind)
  of exkDefer: ctx.genDefer(e, ind)
  of exkFinish:
    "rt.finishResource(&" & resourceTableName(e.finishKind) & ", " &
      ctx.genOdinExpr(e.finishHandle) & ")"
  of exkAcquire:
    "rt.acquireResource(&" & resourceTableName(e.acquireKind) & ", i64(" &
      ctx.genOdinExpr(e.acquireRef) & "), " & escape(acquireSite(e, ctx.moduleName)) & ")"
  of exkImport: ""  # imports are declarations, never expression position
  of exkOrdinal: ctx.genOrdinal(e)
  of exkIfaceCall: ctx.genIfaceCall(e)
  of exkValidate:
    "validate_" & ctx.res.typeFor(e.validated).name & "(" &
      ctx.genOdinExpr(e.validated) & ")"

# Declaration codegen (genOdinDecl and everything it dispatches to --
# fn/object/actor/registry/register/mixin/err-handler) now
# lives in codegen_odin_decl.nim, imported above.
# Shared emission core: hoisted decls + members inside one Beef type.


# A library module (import target). Odin has no static classes: a module is
# a package, and a qualified ref (`fs::readFile`) becomes `fs.readFile` via
# the import alias, so the declarations sit at top level here too.
