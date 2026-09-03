# compiler/codegen.nim
#
# STAGE 8 OF THE PIPELINE — the tree becomes Nim source text.
# (codegen_odin.nim is this file's twin, emitting Odin instead.)
#
# This is the least mysterious stage: walk the tree, print strings. By the time
# code reaches here every hard question has been answered — types check,
# effects add up, names cannot collide, the fancy constructs are lowered away.
# What is left is transcription.
#
# THE SHAPE OF A CODE GENERATOR, and why the long `case` statements stay long.
#
# genExpr and genDecl are each one big `case` over node kinds, one arm per
# kind. They are long, and they are deliberately NOT split up. The reason is
# that Nim errors on a `case` that misses an enum value — so the day someone
# adds a node kind to ast.nim, the compiler immediately names every backend
# that has not handled it yet. Break the dispatch into smaller procs and that
# error becomes a silent gap that ships.
#
# The rule this codebase follows: LENGTH IS NOT THE PROBLEM, NESTING IS. A flat
# 200-line dispatch where every arm is one line is easy to read. A 40-line proc
# nested four deep is not. So the dispatch stays whole and the arms delegate to
# small named procs — genFnDecl, genObjectDecl, genTaskDecl, and so on.
#
# WHAT IS SHARED WITH THE ODIN BACKEND, AND WHAT IS NOT.
#
# Shared, in codegen_common.nim: logic that has nothing to do with which
# language is being emitted — errNameFor, actorSingletonName, lookupFnParams.
# These were byte-identical copies in both backends and had no business being
# duplicated.
#
# NOT shared, on purpose: anything whose difference IS the target syntax.
# genObjectDecl exists in both files because Nim spells it `type X = object`
# and Odin spells it `X :: struct {}`. A shared abstraction over that would
# need a mini templating layer, which is harder to read than two honest copies.
# Share the logic; never share the syntax.
#
# WORTH READING: genFnDecl's decision-table path. When every input column has a
# small enumerable set of values, an entire table of rules collapses into ONE
# `case` over a packed integer key — every combination resolved at compile time
# and grouped by outcome, so the running program does zero comparisons. When a
# column is not enumerable it falls back to a plain if/elif chain. That is a
# real optimization at a size you can actually read: do the work now so the
# program does not do it later.
import ast, strutils, sets, tables, options
import resolution
import ast_query
import codegen_common
import codegen_type   # genType: Tuck type -> Nim type text
import codegen_table  # decision-table combinatorics (spec 6.1)
import ./ast_query
import ./codegen_ctx
export genType        # re-exported: this file's public face is the backend



# module::fn — a real imported module rides Nim's own namespacing; a
# sketch-pending qualified name maps to its mangled stub (genPendingStub).

proc genQualified(ctx: CodegenCtx, e: Expr): string =
  let modName = if e.modulePath.len > 0: e.modulePath[0] else: ""
  if modName == "":
    # `:name` — a bare fn reference. Feeding one to a C function pointer needs
    # the C calling convention; a cast is enough, so ordinary Tuck fns stay
    # ordinary Nim procs instead of every fn carrying a {.cdecl.} it rarely
    # needs. Non-capturing is guaranteed: Tuck fns are top-level.
    let cb = cCallbackSig(ctx.module)
    if cb != "": return "cast[" & cb & "](" & e.qualName & ")"
    return e.qualName
  elif modName in ctx.realModules: modName & "." & e.qualName
  else: modName & "_" & e.qualName

proc genExpr*(ctx: var CodegenCtx, e: Expr): string

# The bigger genExpr arms live as their own procs so the dispatch `case` reads
# as a routing table; each takes the ctx + node and recomputes its own indent.
proc genExprAssign(ctx: var CodegenCtx, e: Expr): string
proc genExprMatch(ctx: var CodegenCtx, e: Expr): string
proc genExprChain(ctx: var CodegenCtx, e: Expr): string
proc genChainIntoTemp(ctx: var CodegenCtx, e: Expr): (string, string)
proc genExprSend(ctx: var CodegenCtx, e: Expr): string
proc genExprSelect(ctx: var CodegenCtx, e: Expr): string

# Type-directed explosion: a record-typed VAR as the whole payload
# (`p advance`) explodes to the fn's params by field name, in param order —
# same subset matching the checker verified. Fields come from the checker's
# ty stamp on the arg node.
# expr bake {slot: :fn, arg: v, ...} — rebuild the context struct with slots
# filled / values overridden / new fields added. Nim monomorphizes fn-typed
# params downstream, so calls through baked slots are direct.
proc genBake(ctx: var CodegenCtx, e: Expr): string =
  var recv = ctx.genExpr(e.args[0])
  var prefix = ""
  if e.args[0].kind != exkVar:
    ctx.tmpCounter.inc
    let tmp = "tuckBake" & $ctx.tmpCounter
    prefix = "let " & tmp & " = " & recv & "; "
    recv = tmp
  let recvFields = recordFieldNames(ctx.module, semLayer.typeFor(e.args[0]))
  var parts: seq[string]
  for fname in recvFields:
    var overridden = ""
    for (name, valExpr) in e.args[1].fields.items:
      if name == fname: overridden = ctx.genExpr(valExpr)
    parts.add(fname & ": " & (if overridden != "": overridden
                              else: recv & "." & fname))
  for (name, valExpr) in e.args[1].fields.items:
    if name notin recvFields:
      parts.add(name & ": " & ctx.genExpr(valExpr))
  if parts.len == 0: return recv  # unknown receiver shape — pass through
  if prefix == "": "(" & parts.join(", ") & ")"
  else: "(" & prefix & "(" & parts.join(", ") & "))"

# {a, b} merge — flatten: one struct carrying the union of the members'
# fields (collisions rejected by the checker).
proc genMerge(ctx: var CodegenCtx, e: Expr): string =
  var parts: seq[string]
  var prefix = ""
  for (mname, mexpr) in e.args[0].fields.items:
    var recv = ctx.genExpr(mexpr)
    if mexpr.kind != exkVar:
      ctx.tmpCounter.inc
      let tmp = "tuckMerge" & $ctx.tmpCounter
      prefix.add("let " & tmp & " = " & recv & "; ")
      recv = tmp
    for f in recordFieldNames(ctx.module, semLayer.typeFor(mexpr)):
      parts.add(f & ": " & recv & "." & f)
  if parts.len == 0: return ctx.genExpr(e.args[0])  # sketch members
  if prefix == "": "(" & parts.join(", ") & ")"
  else: "(" & prefix & "(" & parts.join(", ") & "))"

# expr alias(old: new, ...) — rebuild the record with renamed fields:
# (new1: x.old1, new2: x.old2, ...). Non-var receivers bind to a temp first
# (no double evaluation).
proc genAlias(ctx: var CodegenCtx, e: Expr): string =
  var recv = ctx.genExpr(e.args[0])
  var prefix = ""
  if e.args[0].kind != exkVar:
    ctx.tmpCounter.inc
    let tmp = "tuckAlias" & $ctx.tmpCounter
    prefix = "let " & tmp & " = " & recv & "; "
    recv = tmp
  var parts: seq[string]
  for (oldName, newExpr) in e.args[1].fields.items:
    parts.add(newExpr.name & ": " & recv & "." & oldName)
  if prefix == "": "(" & parts.join(", ") & ")"
  else: "(" & prefix & "(" & parts.join(", ") & "))"

proc explodeRecordArg(ctx: var CodegenCtx, e: Expr, calleeStr: string): string =
  # ponytail: exkVar args only — repeating any other expr risks double
  # evaluation; bind-to-temp lowering when a real case shows up
  if e.args.len != 1 or e.args[0].kind != exkVar: return ""
  # Same O(1)-vs-scan tradeoff as genConstruction's struct-literal branch: prefer
  # checker's own resolution when it recorded one.
  let params = if semLayer.callParamsFor(e).len > 0: semLayer.callParamsFor(e)
               else: lookupFnParams(ctx.module, calleeStr)
  if params.len == 0: return ""
  let fields = recordFieldNames(ctx.module, semLayer.typeFor(e.args[0]))
  if fields.len == 0: return ""
  # The checker already decided which field feeds each param (they may differ
  # in name, having been matched by type); prefer its mapping over re-deriving.
  let resolved = semLayer.argFieldsFor(e)
  var parts: seq[string]
  for i, paramName in params:
    let fieldName = if i < resolved.len and resolved[i].len > 0: resolved[i]
                    else: paramName
    if fieldName notin fields: return ""  # not a payload match — leave as-is
    parts.add(ctx.genExpr(e.args[0]) & "." & fieldName)
  return calleeStr & "(" & parts.join(", ") & ")"


# {payload} Type.Variant — construction of a payload-carrying sum type
# (object variant: kind enum + per-variant payload tuple). Fieldless-only
# sums are plain Nim enums, where Type.Variant is already valid — returns ""
# and the caller falls through to plain emission.
proc sumVariantCtor(ctx: var CodegenCtx, typeName, variantName: string,
                    payload: Expr): string =
  let found = payloadSumVariant(ctx.module, typeName, variantName)
  if found.isNone: return ""
  let v = found.get
  if v.fields.len == 0 or payload == nil:
    return typeName & "(kind: " & variantName & ")"
  # payload tuple in DECLARED field order
  var parts: seq[string]
  for f in v.fields:
    var valStr = ""
    for pf in payload.fields:
      if pf[0] == f.name: valStr = ctx.genExpr(pf[1])
    parts.add(f.name & ": " & valStr)
  typeName & "(kind: " & variantName & ", " &
    variantName.toLowerAscii() & ": (" & parts.join(", ") & "))"

proc bangInfo*(t: Type): tuple[wrapped: bool, inner: string, innerT: Type] =
  if t != nil and t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
     t.base.name in ["!", "?", "!?"] and t.args.len == 1:
    let inner = genType(t.args[0])
    return (true, (if inner == "void": "tuple[]" else: inner), t.args[0])
  return (false, "", nil)

# exkCall (module-less overload): record construction (with invariant
# validate() insertion) or plain call.
# Every exkCall, whatever produced it: record and sum-variant construction, the
# alias/bake/merge builtins, payload explosion, and the plain call.
#
# This was two procs — genConstruction for calls straight out of genExpr, genCall
# for ones the checker synthesised (postfix `.fn`, chain steps). They mirrored
# each other closely enough to read as copies, and had drifted: one knew about
# generic instantiation and invariant validation, the other about qualified
# callees and the by-type argument mapping. Fixing "the" bug in the wrong twin
# was easy and silent, so they are one proc now.
proc genericCtorName(ctx: var CodegenCtx, e: Expr, base: string): string =
  ## A generic type: the checker's ty stamp carries the inferred instantiation.
  let t = semLayer.typeFor(e)
  if t == nil or t.kind != tkApp or t.base == nil or
     t.base.kind != tkNamed or t.base.name != base: return base
  var gparts: seq[string]
  for a in t.args: gparts.add(genType(a))
  base & "[" & gparts.join(", ") & "]"

proc isRecordConstruction(ctx: var CodegenCtx, e: Expr): bool =
  e.args.len == 1 and e.args[0].kind == exkStruct and
    e.callee != nil and e.callee.kind == exkVar and
    ctx.isRecordTypeFast(e.callee.name)

proc genRecordCtor(ctx: var CodegenCtx, e: Expr): string =
  ## Record construction takes NAMED fields, not positional.
  var parts: seq[string]
  for f in e.args[0].fields:
    parts.add(f.name & ": " & ctx.genExpr(f.value))
  let ctor = ctx.genericCtorName(e, e.callee.name) & "(" & parts.join(", ") & ")"
  if not ctx.hasInvariantsFast(e.callee.name): return ctor
  # production site: construction — validate before the value flows on
  ctx.tmpCounter.inc
  let tmp = "tuckInv" & $ctx.tmpCounter
  "(let " & tmp & " = " & ctor & "; validate(" & tmp & "); " & tmp & ")"

proc asSumVariantCall(ctx: var CodegenCtx, e: Expr): string =
  ## `Type.Variant {payload}` — a kind-tagged construction, not a call.
  if e.callee == nil or e.callee.kind != exkField or
     e.callee.receiver == nil or e.callee.receiver.kind != exkVar: return ""
  let payload = if e.args.len == 1 and e.args[0].kind == exkStruct: e.args[0]
                else: nil
  ctx.sumVariantCtor(e.callee.receiver.name, e.callee.fieldName, payload)

proc expectedParamNames(ctx: var CodegenCtx, e: Expr,
                        calleeStr: string): seq[string] =
  ## Param order lives with the fn, not with the literal, so the payload's
  ## fields are matched to params rather than taken positionally.
  ##
  ## Three sources, in order: a QUALIFIED callee's params live in the other
  ## module and must be looked up there; otherwise the checker's own
  ## resolution (semLayer.callParamsFor, set in checkCallArgs) answers in
  ## O(1); the decl-list scan is the last resort for calls the checker left
  ## unresolved, and is a scan per call expression, so it must stay last.
  if e.callee != nil and e.callee.kind == exkQualified and
     e.callee.modulePath.len > 0 and e.callee.modulePath[0] in ctx.realModules:
    return lookupFnParams(ctx.realModules[e.callee.modulePath[0]],
                          e.callee.qualName)
  if semLayer.callParamsFor(e).len > 0: return semLayer.callParamsFor(e)
  lookupFnParams(ctx.module, calleeStr)

proc payloadFieldArg(ctx: var CodegenCtx, payload: Expr,
                     fieldName: string): string =
  ## The value supplied for one param, or nil when the payload lacks it.
  for f in payload.fields:
    if f.name == fieldName: return ctx.genExpr(f.value)
  "nil"

proc genPayloadArgs(ctx: var CodegenCtx, e: Expr,
                    calleeStr: string): seq[string] =
  ## A payload's fields, ordered to match the callee's params.
  let expected = ctx.expectedParamNames(e, calleeStr)
  if expected.len == 0:
    for f in e.args[0].fields: result.add(ctx.genExpr(f.value))
    return
  # The checker's mapping wins: it matches by name first and then by type, so
  # a field may feed a param it shares no name with.
  let resolved = semLayer.argFieldsFor(e)
  for i, paramName in expected:
    let fieldName = if i < resolved.len and resolved[i].len > 0: resolved[i]
                    else: paramName
    result.add(ctx.payloadFieldArg(e.args[0], fieldName))

proc genCallArgs(ctx: var CodegenCtx, e: Expr, calleeStr: string): seq[string] =
  if e.args.len == 1 and e.args[0].kind == exkStruct:
    return ctx.genPayloadArgs(e, calleeStr)
  for a in e.args: result.add(ctx.genExpr(a))

proc asCombinatorCall(ctx: var CodegenCtx, e: Expr,
                      calleeStr: string): string =
  ## The compile-time combinators, each of which rewrites the call rather than
  ## emitting one. Any that declines returns "" and the call proceeds.
  if calleeStr == "alias" and e.args.len == 2 and e.args[1].kind == exkStruct:
    return ctx.genAlias(e)
  if calleeStr == "bake" and e.args.len == 2 and e.args[1].kind == exkStruct:
    return ctx.genBake(e)
  if calleeStr == "merge" and e.args.len == 1 and e.args[0].kind == exkStruct:
    return ctx.genMerge(e)
  if calleeStr notin ["bake", "alias"]:
    return ctx.explodeRecordArg(e, calleeStr)
  ""

proc genSaturatingCtor(satBase, calleeStr, arg: string): string =
  ## spec 4.1: constructing a [saturating] type clamps instead of wrapping.
  ## The guard runs on a WIDER intermediate, so the value is checked against
  ## the type's real bounds rather than after it has already wrapped.
  let unsigned = satBase.startsWith("uint")
  let widen = if unsigned: "uint64" else: "int64"
  let satFn = if unsigned: "tuckSat" else: "tuckSatI"
  calleeStr & "(" & satFn & "[" & satBase & "](" & widen & "(" & arg & ")))"

proc genSpawnCall(ctx: var CodegenCtx, calleeStr, call: string): string =
  ## Calling a task SCHEDULES it as a coroutine — it runs concurrently, main
  ## drives it via tuckRun (spec §9.2). Fire-and-forget for now;
  ## result-returning task calls are a later pass.
  ##
  ## `discard` only when there is something to discard: a `-> void` task
  ## emitted `discard tuck_serve(...)` over a void proc, which Nim rejects with
  ## "expression has no type (or is ambiguous)". So the most natural
  ## fire-and-forget task — one that returns nothing — was the one shape that
  ## did not compile.
  let body = if ctx.taskRetType(calleeStr) == "void": call
             else: "discard " & call
  "tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}: " & body & "))"

proc genValidatedCall(ctx: var CodegenCtx, call: string): string =
  ## Extern boundary: the returned value validates on entry.
  ctx.tmpCounter.inc
  let tmp = "tuckInv" & $ctx.tmpCounter
  "(let " & tmp & " = " & call & "; validate(" & tmp & "); " & tmp & ")"

proc genPlainCall(ctx: var CodegenCtx, calleeStr: string,
                  args: seq[string]): string =
  ## An ordinary call, wrapped by whatever the callee is: a spawned task, an
  ## invariant-validating extern, or neither.
  ##
  ## extern [emit: "..."] renames the emitted call to the real runtime/C proc.
  let emitName = ctx.externEmitName(calleeStr)
  let callName = if emitName != "": emitName else: calleeStr
  let call = callName & "(" & args.join(", ") & ")"
  if ctx.isTaskName(calleeStr): return ctx.genSpawnCall(calleeStr, call)
  if ctx.externInvRetFast(calleeStr) != "": return ctx.genValidatedCall(call)
  call

proc genCallWithArgs(ctx: var CodegenCtx, calleeStr: string,
                     args: seq[string]): string =
  ## The emission forms, once the arguments are built.
  if calleeStr == "bake": return args[0] & "(" & args[1..^1].join(", ") & ")"
  if calleeStr == "alias": return args[0]
  let satBase = ctx.saturatingBase(calleeStr)
  if satBase != "" and args.len == 1:
    return genSaturatingCtor(satBase, calleeStr, args[0])
  ctx.genPlainCall(calleeStr, args)

proc genConstruction(ctx: var CodegenCtx, e: Expr): string =
  if ctx.isRecordConstruction(e): return ctx.genRecordCtor(e)
  let variant = ctx.asSumVariantCall(e)
  if variant != "": return variant
  let calleeStr = ctx.genExpr(e.callee)
  let combinator = ctx.asCombinatorCall(e, calleeStr)
  if combinator != "": return combinator
  let args = ctx.genCallArgs(e, calleeStr)
  ctx.genCallWithArgs(calleeStr, args)

# exkReturn emission: auto-wrapped tok()/terr() results, typed struct
# literals, invariant-carrying returns, or a plain return.
proc genReturn(ctx: var CodegenCtx, e: Expr): string =
  if e.returnVal == nil:
    if ctx.retWrapped and ctx.retInnerNim == "tuple[]": return "return tokVoid()"
    else: return "return"
  elif ctx.retWrapped:
    let v = e.returnVal
    if v.kind == exkRaise:
      return ctx.genExpr(v)  # err X already emits the full error return
    elif v.kind == exkField and v.receiver != nil and v.receiver.kind == exkVar and
       v.receiver.name == "Error":
      # Error.name → app-wide 16-bit code, hashed at Nim compile time
      return "return terr[" & ctx.retInnerNim & "](errCode(\"" & v.fieldName & "\"))"
    elif v.kind == exkStruct and ctx.retInnerT != nil and ctx.retInnerT.kind == tkRecord:
      # Typed literal: cast numeric fields to the declared payload field type
      # so `return {value: 42}` matches tuple[value: uint16]
      var parts: seq[string]
      for f in v.fields:
        var fieldNim = ""
        for fd in ctx.retInnerT.fields:
          if fd.name == f.name: fieldNim = genType(fd.typ)
        let ex = ctx.genExpr(f.value)
        if fieldNim != "" and fieldNim notin ["int", "float", "string", "bool"] and
           (fieldNim.startsWith("uint") or fieldNim.startsWith("int") or
            fieldNim.startsWith("float")):
          parts.add(f.name & ": " & fieldNim & "(" & ex & ")")
        else:
          parts.add(f.name & ": " & ex)
      return "return tok((" & parts.join(", ") & "))"
    else:
      return "return tok(" & ctx.genExpr(v) & ")"
  elif ctx.retInvName != "":
    # production site: return value of an invariant-carrying type
    ctx.tmpCounter.inc
    let tmp = "tuckInv" & $ctx.tmpCounter
    return "return (let " & tmp & " = " & ctx.genExpr(e.returnVal) & "; validate(" &
      tmp & "); " & tmp & ")"
  else: return "return " & ctx.genExpr(e.returnVal)

proc genIndented(ctx: var CodegenCtx, e: Expr): string =
  ## Emit a nested body one level deeper, restoring the indent afterwards.
  ## Twin of codegen_odin's genIndented.
  let saved = ctx.indent
  ctx.indent += 1
  result = ctx.genExpr(e)
  ctx.indent = saved

proc genInterfaceWrap(e: Expr, ifaceName, objName: string): string =
  ## A concrete object entering an interface slot is COPIED into the variant
  ## (spec §5.3): `Animal(tag: Animal_is_Dog, DogVal: d)`. The backend
  ## generates the right copy for managed fields, and the value owns its data
  ## — so it can be returned, stored in a field, or collected with no lifetime
  ## question. Mutation through it hits the copy, which is the same rule
  ## records and actor messages already follow.
  ##
  ## The wrapped expression is a variable (the only form the checker marks),
  ## so its name is emitted directly rather than re-entering genExpr, which
  ## would see the same mark and recurse forever.
  ifaceName & "(tag: " & ifaceName & "_is_" & objName & ", " &
    objName & "Val: " & e.name & ")"

proc genLit(e: Expr): string =
  case e.litKind
  of lkStr: "\"" & e.litValue & "\""
  else: e.litValue

proc genInputPayload(ctx: CodegenCtx): string =
  ## `input` — the whole incoming payload, rebuilt as a tuple.
  var parts: seq[string]
  for p in ctx.currentParams: parts.add(p.name & ": " & p.name)
  "(" & parts.join(", ") & ")"

proc genVar(ctx: var CodegenCtx, e: Expr): string =
  ## A bare name: a checker-stamped call, a payload, a field, or a plain
  ## variable.
  if semLayer.hasCall(e): ctx.genExpr(semLayer.call(e))
  elif e.name == "...": "discard"   # pending hole
  elif e.name == "input" and ctx.currentParams.len > 0: ctx.genInputPayload()
  elif e.name in ctx.fieldVars: "self." & e.name
  else: e.name

proc genIfaceDispatch(ctx: var CodegenCtx, e: Expr,
                      ic: tuple[iface, member: string], ind: string): string =
  ## Dispatch is a `case` on the tag calling the concrete member fn directly —
  ## no function table, no thunk, and the optimizer can see through it.
  ## Emitted as a Nim case EXPRESSION so it composes anywhere a value is
  ## expected.
  ##
  ## A member fn takes `self: var T`, so each branch binds a mutable copy of
  ## the payload rather than passing the field of an immutable value. Mutation
  ## hits that copy, which is the semantics: an interface value OWNS its data.
  let recv = ctx.genExpr(e.receiver)
  var extra = ""
  if e.dotArg != nil: extra = ", " & ctx.genExpr(e.dotArg)
  var arms: seq[string]
  for s in ctx.satisfiersOf(ic.iface):
    arms.add(ind & "  of " & ic.iface & "_is_" & s.name & ":\n" &
             ind & "    var tmp = " & recv & "." & s.name & "Val\n" &
             ind & "    " & ic.member & "(tmp" & extra & ")")
  if arms.len == 0: return ""
  "(block:\n" & ind & "  case " & recv & ".tag\n" & arms.join("\n") & ")"

proc isInputField(ctx: CodegenCtx, e: Expr): bool =
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



proc genFieldAccess(ctx: var CodegenCtx, e: Expr, ind: string): string =
  ## A `.name` access: a payload field, interface dispatch, a resolved call, a
  ## sum-variant construction, an actor singleton's field, or a plain read.
  if ctx.isInputField(e): return e.fieldName
  # Which implementations are POSSIBLE was fixed at the wrap sites (the demand
  # set); which one runs is the tag, read here at the call.
  let ic = semLayer.ifaceCallOf(e)
  if ic.member != "": return ctx.genIfaceDispatch(e, ic, ind)
  # A `..` chain feeding this call was already hoisted into a temp by
  # lowering.hoistChainCalls — the receiver here can never be exkChain.
  if semLayer.hasCall(e): return ctx.genConstruction(semLayer.call(e))
  if e.receiver != nil and e.receiver.kind == exkVar:
    # bare Type.Variant of a payload sum: kind-tagged construction
    let ctor = ctx.sumVariantCtor(e.receiver.name, e.fieldName, nil)
    if ctor != "": return ctor
  if e.receiver != nil and e.receiver.kind == exkActorRef:
    # `ActorType.field` — an actor is a singleton; read its public field off
    # the rt-owned instance (main's waitUntil predicates read state this way)
    return actorSingletonName(e.receiver.refName) & "." & e.fieldName
  # A PAYLOAD sum stores each variant's fields in a field named after the
  # variant, so `s.length` on `Line({length: int})` is `s.line.length`.
  # Emitting the bare name produced an undeclared field, which is why a
  # payload sum typechecked and then failed to build.
  let sumName = payloadSumTypeName(ctx.module, semLayer.typeFor(e.receiver))
  if sumName != "":
    let owner = variantOwningField(ctx.module, sumName, e.fieldName)
    if owner != "":
      return ctx.genExpr(e.receiver) & "." & owner.toLowerAscii() & "." &
             e.fieldName
  ctx.genExpr(e.receiver) & "." & e.fieldName

proc genCallExpr(ctx: var CodegenCtx, e: Expr): string =
  ## An [io] call is a suspend point (the effect marker IS the async
  ## annotation). Cooperative-yield first cut: yield so other tasks progress,
  ## then perform the call. (Real fd-await lands with the async externs.)
  let base = ctx.genConstruction(e)
  if semLayer.isAsync(e) and ctx.inTask: "(tuckYield(); " & base & ")"
  else: base

proc genStruct(ctx: var CodegenCtx, e: Expr): string =
  var parts: seq[string]
  for f in e.fields: parts.add(f.name & ": " & ctx.genExpr(f.value))
  "(" & parts.join(", ") & ")"

proc genList(ctx: var CodegenCtx, e: Expr): string =
  var items: seq[string]
  for it in e.items: items.add(ctx.genExpr(it))
  "@[" & items.join(", ") & "]"

proc genCallResolved(ctx: var CodegenCtx, e: Expr): string =
  ## Indexing resolved to an at() call; a type application never reaches
  ## codegen, so an unresolved bracket emits nothing.
  if semLayer.hasCall(e): ctx.genExpr(semLayer.call(e)) else: ""

proc loopVarNames(iter: Pattern): string =
  ## The name(s) a `for` binds. Nim's `for a, b in xs` needs both spelled out.
  if iter == nil: return "_"
  if iter.kind == pkVar: return iter.name
  if iter.kind != pkTuple: return "_"
  var names: seq[string]
  for el in iter.elems:
    names.add(if el.kind == pkVar: el.name else: "_")
  names.join(", ")

proc genFor(ctx: var CodegenCtx, e: Expr, ind: string): string =
  let iterStr = loopVarNames(e.iter)
  let iterable = ctx.genExpr(e.iterable)
  ind & "for " & iterStr & " in " & iterable & ":\n" & ctx.genIndented(e.body)

proc genWhile(ctx: var CodegenCtx, e: Expr, ind: string): string =
  let condStr = if e.whileCond == nil: "true" else: ctx.genExpr(e.whileCond)
  ind & "while " & condStr & ":\n" & ctx.genIndented(e.whileBody)

proc nimBinOp(op: BinOp): string =
  ## Nim's `/` is ALWAYS float, even for int operands — that was bug B3.
  ## Integer divide is the `div` keyword.
  case op
  of boAdd: "+"
  of boSub: "-"
  of boMul: "*"
  of boDivInt: "div"
  of boDivFloat: "/"
  of boMod: "mod"
  of boEq: "=="
  of boNeq: "!="
  of boLt: "<"
  of boGt: ">"
  of boLe: "<="
  of boGe: ">="
  of boAnd: "and"
  of boOr: "or"
  of boXor: "xor"
  of boRangeIncl: ".."
  of boRangeExcl: "..<"

proc genBinary(ctx: var CodegenCtx, e: Expr): string =
  if isStringConcat(e):
    return "tuckConcat(" & ctx.genExpr(e.left) & ", " & ctx.genExpr(e.right) & ")"
  "(" & ctx.genExpr(e.left) & " " & nimBinOp(e.binOp) & " " &
    ctx.genExpr(e.right) & ")"

proc genUnary(ctx: var CodegenCtx, e: Expr): string =
  let opStr = case e.unaryOp
              of uoNeg: "-"
              of uoNot: "not "
              else: ""
  opStr & ctx.genExpr(e.operand)

proc genDroppedResult(ctx: var CodegenCtx, s: Expr, stmtCode: string): string =
  ## continue/exit policy: a dropped result routes to the global handler.
  ctx.tmpCounter.inc
  let tn = "tuckDrop" & $ctx.tmpCounter
  let site = semLayer.shortcut(s)
  let onErr = if ctx.errPolicy == "exit":
                "(tuck_unhandled(" & tn & ".err, \"" & site & "\"); quit(1))"
              else:
                "tuck_unhandled(" & tn & ".err, \"" & site & "\")"
  "(let " & tn & " = " & stmtCode & "; (if not " & tn & ".ok: " & onErr & "))"

proc isCallOnChain(s: Expr): bool =
  ## `self ..loadEp {n} .startAudio` — a resolved call whose receiver is a
  ## chain. The chain lowers to statements, so the whole thing is multi-line.
  s.kind == exkField and s.receiver != nil and
    s.receiver.kind == exkChain and semLayer.hasCall(s)

proc isChainBinding(s: Expr): bool =
  ## `var b = a ..setN {5}` — the chain runs into a temp above the binding.
  s.kind == exkAssign and s.assignVal != nil and s.assignVal.kind == exkChain

proc ownsItsLayout(s: Expr): bool =
  ## Nodes that carry their own indentation.
  ##
  ## A `.fn` call whose RECEIVER is a chain belongs here too — though
  ## lowering.hoistChainCalls now rewrites that shape away before codegen
  ## ever sees it, so isCallOnChain is permanently false in practice and
  ## kept only as a second guard. Left out, genStmt added its own prefix on
  ## top of the chain's and produced 8 spaces against the block's 4 — which
  ## Nim rejects as invalid indentation.
  s.kind in {exkIf, exkBlock, exkChain, exkFor, exkWhile} or
    isCallOnChain(s) or isChainBinding(s)

proc stmtValueDropped(ctx: var CodegenCtx, s: Expr): bool =
  ## A call in STATEMENT position whose value nothing consumes. Nim rejects
  ## a bare expression with a type ("has to be used (or discarded)"), so it
  ## needs an explicit `discard` — `{self: c} bump` as its own line used to
  ## emit code that did not compile.
  ##
  ## Only a plain call: a chain lays itself out, and the errors-policy path
  ## has already wrapped its own drop site by the time this is asked.
  if s == nil or s.kind != exkCall: return false
  if semLayer.shortcut(s) != "": return false   # errors policy owns this one
  # A TASK call in statement position is already wrapped in tuckSpawn(...),
  # which is a void expression — discarding it is the very "no type (or is
  # ambiguous)" error this proc exists to avoid, just one level out. The
  # task's own return type says nothing about the emitted statement.
  if s.callee != nil and s.callee.kind == exkVar and
     ctx.isTaskName(s.callee.name): return false
  let t = semLayer.typeFor(s)
  if t == nil: return false
  # `discard` over a void call is itself an error in Nim, so the question is
  # whether there is anything TO discard.
  not (t.kind == tkNamed and t.name in ["void", "unit", UnknownName])

proc genStmt(ctx: var CodegenCtx, s: Expr, ind: string): string =
  ## One statement of a block, indented unless it lays itself out.
  var code = ctx.genExpr(s)
  if code != "" and semLayer.shortcut(s) != "":
    code = ctx.genDroppedResult(s, code)
  elif code != "" and ctx.stmtValueDropped(s):
    code = "discard " & code
  if code == "": return ""
  if ownsItsLayout(s): code else: ind & "  " & code

proc genStmts(ctx: var CodegenCtx, e: Expr, ind: string): string =
  ## The statements of a block, indented one level, with no scope around them.
  let saved = ctx.indent
  ctx.indent += 1
  var lines: seq[string]
  for s in e.stmts:
    let code = ctx.genStmt(s, ind)
    if code != "": lines.add(code)
  ctx.indent = saved
  lines.join("\n")

proc genFnBody*(ctx: var CodegenCtx, e: Expr, ind: string): string =
  ## A fn's body needs NO scope of its own — the proc already is one. Emitting
  ## the `if true:` that genBlock uses for nested blocks wrapped 79 of the 124
  ## blocks across the examples in a construct that did nothing.
  if e == nil or e.kind != exkBlock: return ctx.genExpr(e)
  result = ctx.genStmts(e, ind)
  if result.len == 0: result = ind & "  discard"

proc genBlock(ctx: var CodegenCtx, e: Expr, ind: string): string =
  ## A NESTED block — one that introduces a scope inside a fn.
  ##
  ## `if true:` not `block:` — a Nim `block` captures unlabeled `break`, which
  ## must reach the enclosing loop instead. Scoping is identical.
  ##
  ## A fn body is not this: it goes through genFnBody, which skips the wrapper
  ## because the proc supplies the scope.
  let body = ctx.genStmts(e, ind)
  if body.len == 0: return ind & "discard"
  ind & "if true:\n" & body

proc genUnindented(ctx: var CodegenCtx, e: Expr): string =
  ## Emit an expression with no indentation — for a value position, where a
  ## leading run of spaces would land in the middle of an expression.
  let saved = ctx.indent
  ctx.indent = 0
  result = ctx.genExpr(e)
  ctx.indent = saved

proc genValueIf(ctx: var CodegenCtx, e: Expr, condStr: string): string =
  ## R2: an if whose branches are single expressions (not blocks) IS a value.
  ## Nim spells that `if c: a else: b` on one line; the indented statement form
  ## would emit a nested block where an expression is expected.
  "(if " & condStr & ": " & ctx.genUnindented(e.thenBranch) & " else: " &
    ctx.genUnindented(e.elseBranch) & ")"

proc genIf(ctx: var CodegenCtx, e: Expr, ind: string): string =
  let condStr = ctx.genExpr(e.cond)
  if isValueIf(e): return ctx.genValueIf(e, condStr)
  let thenStr = ctx.genIndented(e.thenBranch)
  let elseStr = if e.elseBranch != nil:
                  "\n" & ind & "else:\n" & ctx.genIndented(e.elseBranch)
                else: ""
  ind & "if " & condStr & ":\n" & thenStr & elseStr

proc genRaise(ctx: var CodegenCtx, e: Expr): string =
  ## `err X` — early-return an error result.
  let rv = e.raiseVal
  if isErrEnumRef(ctx.module, rv):
    let name = errNameFor(ctx.module, ctx.moduleName, rv.receiver.writtenName,
                          rv.fieldName)
    return "return terr[" & ctx.retInnerNim & "](errCode(\"" & name & "\"))"
  "return terr[" & ctx.retInnerNim & "](uint16(" & ctx.genExpr(rv) & "))"

proc genExpr*(ctx: var CodegenCtx, e: Expr): string =
  if e == nil: return ""
  let ind = "  ".repeat(ctx.indent)
  let w = semLayer.wrapOf(e)
  if w.objName != "" and e.kind == exkVar:
    let (ifaceName, objName) = resolveWrapNames(ctx.module, w.iface, w.objName)
    return genInterfaceWrap(e, ifaceName, objName)
  case e.kind
  of exkLit: genLit(e)
  of exkVar: ctx.genVar(e)
  of exkActorRef, exkRegisterRef, exkRegistryRef, exkPoolRef, exkMixinRef:
    e.refName
  of exkField: ctx.genFieldAccess(e, ind)
  of exkQualified: genQualified(ctx, e)
  of exkCall: ctx.genCallExpr(e)
  of exkStruct: ctx.genStruct(e)
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
  of exkAssign: ctx.genExprAssign(e)
  of exkMatch: ctx.genExprMatch(e)
  of exkReturn: ctx.genReturn(e)
  of exkRaise: ctx.genRaise(e)
  of exkDiscard:
    # Nim's own `discard` is the identical construct, spelling and all.
    if e.discardVal != nil: "discard " & ctx.genExpr(e.discardVal)
    else: "discard"
  of exkChain: ctx.genExprChain(e)
  of exkSend: ctx.genExprSend(e)
  of exkSelect: ctx.genExprSelect(e)
  of exkImport: ""  # imports are declarations, never expression position

proc genExprAssign(ctx: var CodegenCtx, e: Expr): string =
  # `let r = {args} task` — a RESULT-bound task call: schedule the task with
  # a result slot and await it (the caller yields if it's a coroutine, or
  # drives the runtime if it's main). Distinct from a statement-position task
  # call, which is fire-and-forget (concurrent).
  if e.assignVal != nil and e.assignVal.kind == exkCall and
     e.assignVal.callee != nil and e.assignVal.callee.kind == exkVar and
     ctx.isTaskName(e.assignVal.callee.name):
    let tname = e.assignVal.callee.name
    let ret = ctx.taskRetType(tname)
    # emit the raw call expression (args) by temporarily disabling the
    # fire-and-forget spawn wrap: build the call directly
    var argParts: seq[string]
    if e.assignVal.args.len == 1 and e.assignVal.args[0].kind == exkStruct:
      let expected = lookupFnParams(ctx.module, tname)
      for pn in expected:
        for f in e.assignVal.args[0].fields:
          if f.name == pn: argParts.add(ctx.genExpr(f.value)); break
    let rawCall = tname & "(" & argParts.join(", ") & ")"
    let slot = "tuckSlot" & $ctx.tmpCounter
    ctx.tmpCounter.inc
    let spawn = "(let " & slot & " = newAsyncResult[" & ret & "](); " &
                "spawnResult(" & slot & ", proc(): " & ret &
                " {.closure, gcsafe.} = ({.cast(gcsafe).}: " & rawCall &
                ")); awaitResult(" & slot & "))"
    if e.target.kind == exkVar and e.target.name notin ctx.definedVars and
       e.target.name notin ctx.fieldVars:
      ctx.definedVars.incl(e.target.name)
      return "var " & e.target.name & " = " & spawn
    return ctx.genExpr(e.target) & " = " & spawn
  # A chain being BOUND is consumed, so it runs into a temp and leaves its
  # base alone — `var b = a ..setN {n: 5}` must not touch `a`. The statements
  # are hoisted above the binding, which then reads the temp.
  var prelude = ""
  var valSrc = e.assignVal
  if valSrc != nil and valSrc.kind == exkChain:
    let (stmts, tmp) = ctx.genChainIntoTemp(valSrc)
    prelude = stmts & "\n" & stmts.indentPrefix
    valSrc = Expr(span: valSrc.span, kind: exkVar, name: tmp)
  let targetStr = ctx.genExpr(e.target)
  let valStr = ctx.genExpr(valSrc)
  if e.target.kind == exkVar:
    let name = e.target.name
    if name notin ctx.definedVars and name notin ctx.fieldVars:
      ctx.definedVars.incl(name)
      return prelude & "var " & name & " = " & valStr
  prelude & targetStr & " = " & valStr

proc genExprMatch(ctx: var CodegenCtx, e: Expr): string =
  if e.subject == nil: return "discard"
  let ind = "  ".repeat(ctx.indent)
  var subjectStr = ctx.genExpr(e.subject)
  # A PAYLOAD-carrying sum emits as a tagged union, so the case dispatches
  # on the discriminant. Without this it emitted `case s` over an object,
  # which Nim rejects ("selector must be of an ordinal type") — and a
  # payload sum therefore typechecked and then failed to build.
  if payloadSumTypeName(ctx.module, semLayer.typeFor(e.subject)) != "":
    subjectStr = subjectStr & ".kind"
  var cases: seq[string]
  var errMatch = false
  var hasWild = false
  for arm in e.arms:
    if arm.pattern != nil and arm.pattern.kind == pkWild: hasWild = true
    if arm.pattern != nil and arm.pattern.kind == pkVar and
       "." in arm.pattern.name:
      errMatch = true
  for arm in e.arms:
    var patStr = genPatternStr(arm.pattern)
    if arm.pattern != nil and arm.pattern.kind == pkVar and
       "." in arm.pattern.name:
      # checker-qualified error variant: compare against the hashed id
      let dot = arm.pattern.name.find(".")
      patStr = "errCode(\"" & errNameFor(ctx.module, ctx.moduleName,
        arm.pattern.name[0 ..< dot], arm.pattern.name[dot+1 .. ^1]) & "\")"
    # Arms sit one level in from the `case`, and a BLOCK body one level
    # further. Both must be derived from ctx.indent — a match nested in a
    # fn body is not at column 0, and a block body self-indents from the
    # same counter, so hardcoding the widths mismatched the two.
    if arm.body != nil and arm.body.kind == exkBlock:
      let oldIndent = ctx.indent
      ctx.indent += 1          # body lines land under the `of`
      let bodyStr = ctx.genExpr(arm.body)
      ctx.indent = oldIndent
      cases.add(ind & "of " & patStr & ":\n" & bodyStr)
    else:
      let bodyStr = ctx.genExpr(arm.body)
      cases.add(ind & "of " & patStr & ":\n" & ind & "  " & bodyStr)
  if errMatch and not hasWild:
    # the code space is uint16 — the declared variants never cover it
    cases.add(ind & "else: discard")
  "(case " & subjectStr & "\n" & cases.join("\n") & ")"


proc chainSteps(ctx: var CodegenCtx, e: Expr, into: string): string =
  ## The chain's steps, each assigning through `into`.
  ##
  ## `into` is the base var when NOTHING CONSUMES the chain's result (the
  ## builder form, which updates the base), or a fresh temp when something
  ## does and the base must be left alone.
  let ind = "  ".repeat(ctx.indent)
  let baseStr = ctx.genExpr(e.base)
  var lines: seq[string]
  for step in e.steps:
    if semLayer.stepCall(step) != nil:
      let call = threadReceiver(semLayer.stepCall(step), e.base, into, baseStr)
      lines.add(ind & into & " = " & ctx.genConstruction(call))
    else:
      var valStr = ""
      if isSingleFieldPayload(step.arg):
        valStr = ctx.genExpr(soleFieldValue(step.arg))
      lines.add(ind & into & "." & step.target.name & " = " & valStr)
  # mutation site: an invariant-carrying var re-validates after the chain
  if e.base != nil and semLayer.typeFor(e.base) != nil and
     semLayer.typeFor(e.base).kind == tkNamed and
     ctx.hasInvariantsFast(semLayer.typeFor(e.base).name):
    lines.add(ind & "validate(" & into & ")")
  lines.join("\n")

proc genChainIntoTemp(ctx: var CodegenCtx, e: Expr): (string, string) =
  ## A chain in VALUE position: copy the base into a temp, run the steps on
  ## the temp, and hand back (statements, tempName) so the caller can use the
  ## result without the base being touched.
  ##
  ## A caller that wants the pre-chain value simply keeps its own var — the
  ## base is never written here.
  let ind = "  ".repeat(ctx.indent)
  ctx.tmpCounter.inc
  let tmp = "tuckChain" & $ctx.tmpCounter
  let seed = ind & "var " & tmp & " = " & ctx.genExpr(e.base)
  (seed & "\n" & ctx.chainSteps(e, tmp), tmp)

proc genExprChain(ctx: var CodegenCtx, e: Expr): string =
  ## A chain whose result NOTHING CONSUMES: the steps assign through the base
  ## var, so the builder updates it.
  ##
  ##   server ..withDefaults ..port {8080}   ->  server = withDefaults(server)
  ##                                             server.port = 8080
  ##
  ## What decides this is whether the chain feeds something — a `.call`, a
  ## binding, an argument — not how the source is laid out. A chain split over
  ## several lines but ending in a `.call` still feeds that call, and goes
  ## through genChainIntoTemp instead.
  ##
  ## Emitting this form in value position produced
  ## `var b =     a = tuck_setN(a, 5)` — an assignment inside an assignment,
  ## which Nim rejects, and which clobbered the base as well.
  ctx.chainSteps(e, ctx.genExpr(e.base))

proc genExprSend(ctx: var CodegenCtx, e: Expr): string =
  # `ActorType send handler {payload}` — enqueue a Msg to the actor's
  # singleton mailbox, then wake the scheduler. The message envelope mirrors
  # genActor: kind = msg<Handler>, fields from the payload struct.
  let singleton = actorSingletonName(e.sendActor)
  let msgType = e.sendActor & "Msg"
  let variant = "msg" & capitalize(e.sendHandler)
  var ctorArgs = "kind: " & variant
  if e.sendPayload != nil and e.sendPayload.kind == exkStruct:
    for f in e.sendPayload.fields:
      ctorArgs.add(", " & f.name & ": " & ctx.genExpr(f.value))
  let ind = repeat("  ", ctx.indent)
  # statement form: enqueue + notify on two lines at the current indent
  "discard enqueue(" & singleton & ".mailbox, " & msgType & "(" & ctorArgs &
    "))\n" & ind & "tuckNotifySend()"

proc selectTimeoutMs(ctx: var CodegenCtx, arm: SelectArm): string =
  ## The `timeout` arm's deadline as a plain int of milliseconds.
  ##
  ## `timeout {5.ms}` passes a duration payload; the runtime wants an int, so
  ## a single-field `{dur}` struct unwraps to its duration and converts. A
  ## bare `timeout 30` is already an int literal and passes through.
  let ms = ctx.genExpr(soleFieldValue(arm.arg))
  if arm.arg != nil and arm.arg.kind == exkLit: ms
  else: "int(" & ms & ")"

proc genExprSelect(ctx: var CodegenCtx, e: Expr): string =
  # task `on select` (spec §9.3), first cut: exactly a `read <fd>` arm and a
  # `timeout <ms>` arm race via tuckAwaitReadOrTimeout — true = fd readable
  # (run the read body), false = deadline (run the timeout body).
  # Classified, not string-compared: `timeout.5s` is not `timeout`, and the
  # bare compare that missed it is what dropped whole handler bodies into a
  # `discard`. The checker now REFUSES any arm this cannot lower
  # (failIfUnlowerableArm), so the fallback below is unreachable for a
  # checked program and stays only as a belt for direct codegen callers.
  var readArm, timeoutArm: ptr SelectArm = nil
  for arm in e.selArms.mitems:
    case arm.sourceKind
    of sskRead: readArm = addr arm
    of sskTimeout: timeoutArm = addr arm
    of sskTimeoutTyped, sskOther: discard   # refused by the checker
  let ind = repeat("  ", ctx.indent)
  if readArm != nil and timeoutArm != nil:
    let fd = ctx.genExpr(readArm.arg)
    let ms = ctx.selectTimeoutMs(timeoutArm[])
    ctx.indent += 1
    let innerInd = repeat("  ", ctx.indent)
    # arm bodies (a return/expr) don't self-indent — prepend the branch indent
    let readBody = innerInd & ctx.genExpr(readArm.body)
    let toBody = innerInd & ctx.genExpr(timeoutArm.body)
    ctx.indent -= 1
    "if tuckAwaitReadOrTimeout(" & fd & ", " & ms & "):\n" & readBody &
      "\n" & ind & "else:\n" & toBody
  else:
    # Unreachable for a checked program — failIfUnlowerableArm rejects these
    # before emission. Kept as a visible marker rather than silence.
    ind & "discard  # select: only read+timeout arms supported (first cut)"

# Declaration codegen (genDecl and everything it dispatches to — fn/object/
# actor/registry/register/mixin/decision-table/err-handler) now lives in
# codegen_decl.nim, imported above.

# Implicit return: the value flowing at the end of a fn body is its result.
# Rewrite the tail statement into an explicit return so the existing return
# emission (auto-wrap, typed literals) handles it. Control-flow tails keep
# explicit returns for now (checker enforces branch agreement).





# Object member fn (or a mixin fn materialized by `+ mixin`): the object
# rides as a mutable `self` first parameter; the contract placeholder type
# `Self` resolves to the object. Emits via a shallow copy — the shared AST
# stays untouched for the other backend.

# --- dkType sum-type branch helpers ---
