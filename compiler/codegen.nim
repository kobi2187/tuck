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
import record_shape  # what a combinator PRODUCES, decided once for all backends
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
  elif modName in ctx.realModules: nimModuleName(modName) & "." & e.qualName
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
# The four record combinators — bake / with / alias / merge — share one
# emitter. What each PRODUCES is decided in record_shape.nim, in terms no
# target knows about; all that is left here is how Nim spells a constructor
# call and a field access. This was four procs, and their Odin and D twins
# were eight more.
#
# Nim's structural shape is an anonymous tuple, so ckStructural ignores the
# declared field list the other two backends use to name a struct.
proc renderShape(ctx: var CodegenCtx, s: RecordShape, tag: string): string =
  if s.ctor == ckPassThrough: return ctx.genExpr(s.passThrough)
  # A receiver read once per field must not be EVALUATED once per field, so a
  # non-var receiver binds to a temp first. The temps come before the parts,
  # and the invariant temp after, which is the order the hand-written procs
  # allocated them in — the golden corpus pins it.
  var prefix = ""
  var bound: seq[(Expr, string)]
  for r in s.receivers:
    var text = ctx.genExpr(r)
    if r.kind != exkVar:
      ctx.tmpCounter.inc
      let tmp = tag & $ctx.tmpCounter
      prefix.add("let " & tmp & " = " & text & "; ")
      text = tmp
    bound.add (r, text)
  proc textOf(rs: seq[(Expr, string)], want: Expr): string =
    for (r, text) in rs:
      if r == want: return text
    ""
  var parts: seq[string]
  for f in s.fields:
    let value = case f.src
                of vsExpr: ctx.genExpr(f.value)
                of vsProject: textOf(bound, f.fromExpr) & "." & f.fromField
    parts.add(f.name & ": " & value)
  let ctorName = if s.ctor == ckNamedType: genType(s.namedType) else: ""
  var lit = ctorName & "(" & parts.join(", ") & ")"
  # a rebuilt record is a production site too: its invariants must hold
  if s.invariantsOwed:
    ctx.tmpCounter.inc
    let tmp = "tuckInv" & $ctx.tmpCounter
    lit = "(let " & tmp & " = " & lit & "; validate(" & tmp & "); " & tmp & ")"
  if prefix == "": lit else: "(" & prefix & lit & ")"

proc genCombinator(ctx: var CodegenCtx, e: Expr): string =
  ## The tag only names the temps, so the emitted text still says which
  ## combinator produced it.
  let tag = case e.comb
            of ckBake: "tuckBake"
            of ckWith: "tuckWith"
            of ckAlias: "tuckAlias"
            of ckMerge: "tuckMerge"
  ctx.renderShape(shapeOf(ctx.module, ctx.res, e), tag)

proc explodeRecordArg(ctx: var CodegenCtx, e: Expr, calleeStr: string): string =
  # ponytail: exkVar args only — repeating any other expr risks double
  # evaluation; bind-to-temp lowering when a real case shows up
  if e.args.len != 1 or e.args[0].kind != exkVar: return ""
  # Same O(1)-vs-scan tradeoff as genConstruction's struct-literal branch: prefer
  # checker's own resolution when it recorded one.
  let params = if ctx.res.callParamsFor(e).len > 0: ctx.res.callParamsFor(e)
               else: lookupFnParams(ctx.module, calleeStr)
  if params.len == 0: return ""
  let fields = recordFieldNames(ctx.res, ctx.module, ctx.res.typeFor(e.args[0]))
  if fields.len == 0: return ""
  # The checker already decided which field feeds each param (they may differ
  # in name, having been matched by type); prefer its mapping over re-deriving.
  let resolved = ctx.res.argFieldsFor(e)
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
    sumPayloadField(variantName) & ": (" & parts.join(", ") & "))"

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
  let t = ctx.res.typeFor(e)
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
  ## resolution (ctx.res.callParamsFor, set in checkCallArgs) answers in
  ## O(1); the decl-list scan is the last resort for calls the checker left
  ## unresolved, and is a scan per call expression, so it must stay last.
  if e.callee != nil and e.callee.kind == exkQualified and
     e.callee.modulePath.len > 0 and e.callee.modulePath[0] in ctx.realModules:
    return lookupFnParams(ctx.realModules[e.callee.modulePath[0]],
                          e.callee.qualName)
  if ctx.res.callParamsFor(e).len > 0: return ctx.res.callParamsFor(e)
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
  let resolved = ctx.res.argFieldsFor(e)
  for i, paramName in expected:
    let fieldName = if i < resolved.len and resolved[i].len > 0: resolved[i]
                    else: paramName
    result.add(ctx.payloadFieldArg(e.args[0], fieldName))

proc genCallArgs(ctx: var CodegenCtx, e: Expr, calleeStr: string): seq[string] =
  if e.args.len == 1 and e.args[0].kind == exkStruct:
    return ctx.genPayloadArgs(e, calleeStr)
  for a in e.args: result.add(ctx.genExpr(a))

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
  # A PRIMITIVE conversion — `{value: n} u64` — names a Tuck type, and the
  # backend's name for it is not the same word: `u64(n)` reached Nim as an
  # undeclared identifier because Nim spells it `uint64`. The same table
  # genType uses answers it; nimPrimitive returns its argument unchanged for
  # anything that is not a primitive, so a fn named like a type is unaffected.
  let prim = nimPrimitive(calleeStr)
  let callName = if emitName != "": emitName
                 elif ctx.isRuntimeExtern(calleeStr): "tuck_rt." & calleeStr
                 elif nimRtCallee(calleeStr) != calleeStr: nimRtCallee(calleeStr)
                 elif prim != calleeStr: prim
                 else: calleeStr
  let call = callName & "(" & args.join(", ") & ")"
  if ctx.isTaskName(calleeStr): return ctx.genSpawnCall(calleeStr, call)
  if ctx.externInvRetFast(calleeStr) != "": return ctx.genValidatedCall(call)
  call

proc genCallWithArgs(ctx: var CodegenCtx, calleeStr: string,
                     args: seq[string]): string =
  ## The emission forms, once the arguments are built.
  let satBase = ctx.saturatingBase(calleeStr)
  if satBase != "" and args.len == 1:
    return genSaturatingCtor(satBase, calleeStr, args[0])
  ctx.genPlainCall(calleeStr, args)

proc withTypeArgs(ctx: CodegenCtx, calleeStr: string, e: Expr): string =
  ## `tuck_firstOf` -> `tuck_firstOf[tuck_Row, int]` when the checker recorded
  ## type arguments for this call. It does so only where no backend can infer
  ## them — a type param mentioned by no parameter — so the explicit form
  ## appears exactly where Nim would otherwise say "cannot instantiate".
  let targs = ctx.res.callTypeArgsFor(e)
  if targs.len == 0: return calleeStr
  var parts: seq[string]
  for t in targs: parts.add(genType(t))
  calleeStr & "[" & parts.join(", ") & "]"

proc genActorWaitOn(ctx: var CodegenCtx, e: Expr): string =
  ## `Actor.waitUntil {pred: :p}` -> `tuckWaitOn(<Actor>Slot, p)`.
  ##
  ## The checker rewrote the member call into `waitUntil(<actorRef>, pred)`
  ## (asStaticMemberCall), so the actor is still named in arg 0 and codegen
  ## routes it to THAT actor's slot. Same shape as `Pool.acquire` reaching the
  ## runtime's acquire: the member name belongs to the ACTOR surface, not to a
  ## library the compiler had to learn by name.
  if e == nil or e.kind != exkCall or e.callee == nil: return ""
  if e.callee.kind != exkVar or e.callee.name != "waitUntil": return ""
  if e.args.len != 2 or e.args[0] == nil: return ""
  if e.args[0].kind != exkActorRef: return ""
  "tuckWaitOn(" & actorSlotName(e.args[0].refName) & ", " &
    ctx.genExpr(e.args[1]) & ")"

proc genConstruction(ctx: var CodegenCtx, e: Expr): string =
  let waitOn = ctx.genActorWaitOn(e)
  if waitOn != "": return waitOn
  if ctx.isRecordConstruction(e): return ctx.genRecordCtor(e)
  let variant = ctx.asSumVariantCall(e)
  if variant != "": return variant
  var calleeStr = ctx.genExpr(e.callee)
  # A member call emits QUALIFIED, matching the declaration. Derived from the
  # RECEIVER's type rather than the callee's name, because the name alone
  # cannot say which fn is meant once a top-level fn shares it (#50).
  if e.callee != nil and e.callee.kind == exkVar and e.args.len >= 1:
    let qualified = memberCalleeOf(ctx.module,
                                   memberOwner(ctx.module,
                                               ctx.res.typeFor(e.args[0])),
                                   e.callee.name)
    if qualified != "": calleeStr = qualified
  let combinator = ctx.explodeRecordArg(e, calleeStr)
  if combinator != "": return combinator
  let args = ctx.genCallArgs(e, calleeStr)
  ctx.genCallWithArgs(ctx.withTypeArgs(calleeStr, e), args)

# exkReturn emission: auto-wrapped tok()/terr() results, typed struct
# literals, invariant-carrying returns, or a plain return.
proc genReturnTypedLit(ctx: var CodegenCtx, v: Expr): string =
  ## `return {value: 42}` against a declared payload record: cast numeric
  ## fields to their declared Nim type so the literal matches
  ## `tuple[value: uint16]` instead of defaulting to `int`.
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
  "return tok((" & parts.join(", ") & "))"

proc genWrappedReturn(ctx: var CodegenCtx, v: Expr): string =
  ## `return` inside a fn declared `-> !T`/`-> ?T`: the value auto-wraps.
  if v.kind == exkRaise:
    return ctx.genExpr(v)  # err X already emits the full error return
  # ...unless it is already one. `return {..} writeFile` inside a fn that
  # itself returns `!void` is a PASS-THROUGH, not a value to wrap: wrapping
  # built TuckResult[TuckResult[tuple[]]], which typechecked clean here and
  # failed in the Nim compile. The checker's own type for the expression is
  # what tells the two apart.
  if isResultCarrierType(ctx.res.typeFor(v)):
    return "return " & ctx.genExpr(v)
  if v.kind == exkField and v.receiver != nil and v.receiver.kind == exkVar and
     v.receiver.name == "Error":
    # Error.name → app-wide 16-bit code, hashed at Nim compile time
    return "return terr[" & ctx.retInnerNim & "](errCode(\"" & v.fieldName & "\"))"
  if v.kind == exkStruct and ctx.retInnerT != nil and ctx.retInnerT.kind == tkRecord:
    return ctx.genReturnTypedLit(v)
  "return tok(" & ctx.genExpr(v) & ")"

proc genReturn(ctx: var CodegenCtx, e: Expr): string =
  if e.returnVal == nil:
    if ctx.retWrapped and ctx.retAbsentCapable:
      # `tnone[T]()` for a plain T (a bare generic param or an ordinary named
      # type) — but NOT when T's Nim text is itself a compound instantiation
      # like `array[N, T]`. In a file that also declares another
      # sufficiently generic-heavy fn (found with `?Array[N, T]` alongside a
      # `chunk[T]` doing nested Seq-of-Seq construction), Nim misread
      # `tnone[array[N, T]]()`'s brackets as an INDEX expression rather than
      # a generic instantiation — "type mismatch ... Expected [] on array" —
      # even though the identical file compiles fine with either piece
      # removed alone. Spelling out what `tnone[T]()` does internally
      # sidesteps the bracket ambiguity for exactly the compound case;
      # kept narrow because the plain-T form is otherwise unaffected and a
      # blanket switch reintroduces the same ambiguity from the other side.
      if '[' in ctx.retInnerNim:
        return "return TuckResult[" & ctx.retInnerNim & "](status: tsAbsent)"
      return "return tnone[" & ctx.retInnerNim & "]()"
    elif ctx.retWrapped and ctx.retInnerNim == "tuple[]": return "return tokVoid()"
    else: return "return"
  elif ctx.retWrapped:
    return ctx.genWrappedReturn(e.returnVal)
  elif ctx.retInvName != "" and not validatesItself(ctx.module, e.returnVal):
    # production site: return value of an invariant-carrying type.
    # `validatesItself` keeps a construction from being wrapped twice — it
    # already validated at the construction site, on this same value.
    ctx.tmpCounter.inc
    let tmp = "tuckInv" & $ctx.tmpCounter
    return "return (let " & tmp & " = " & ctx.genExpr(e.returnVal) & "; validate(" &
      tmp & "); " & tmp & ")"
  else: return "return " & ctx.genExpr(e.returnVal)

proc genIndented(ctx: var CodegenCtx, e: Expr): string =
  ## Emit a nested body one level deeper, restoring the indent afterwards.
  ## Twin of codegen_odin's genIndented.
  ## A nested body is its own SCOPE, so a name declared inside it is gone
  ## afterwards. `definedVars` is what decides declaration-vs-assignment, and
  ## it was keyed by bare name with no scope at all: a second `let lead` in a
  ## SIBLING branch saw the name already present and emitted an assignment to
  ## a variable the first branch had taken out of scope — "undeclared
  ## identifier: tuck_lead". Restoring the set afterwards makes the emitted
  ## scoping match Tuck's. (The same shape as the checker's name-keyed
  ## shadow bug; this is its codegen twin.)
  let saved = ctx.indent
  let savedVars = ctx.definedVars
  ctx.indent += 1
  result = ctx.genExpr(e)
  ctx.indent = saved
  ctx.definedVars = savedVars

proc genInterfaceWrap(inner, ifaceName, objName: string): string =
  ## A concrete object entering an interface slot is COPIED into the variant
  ## (spec §5.3): `Animal(tag: Animal_is_Dog, DogVal: d)`. The backend
  ## generates the right copy for managed fields, and the value owns its data
  ## — so it can be returned, stored in a field, or collected with no lifetime
  ## question. Mutation through it hits the copy, which is the same rule
  ## records and actor messages already follow.
  ##
  ## Takes the inner value ALREADY emitted: it is not always a bare name —
  ## `[{n: 1} A, {n: 2} B]` reaching a Seq[Rule] wraps two construction
  ## calls, and emitting `e.name` for those produced an empty field and an
  ## unwrapped element that Nim then typed as seq[tuck_A].
  ifaceName & "(tag: " & ifaceName & "_is_" & objName & ", " &
    objName & "Val: " & inner & ")"

const NimLitSuffix = {
  "u8": "'u8", "u16": "'u16", "u32": "'u32", "u64": "'u64",
  "i8": "'i8", "i16": "'i16", "i32": "'i32", "i64": "'i64",
}.toTable
  ## Nim's literal suffixes, for a literal whose width the checker settled but
  ## whose spelling would otherwise default to `int`. `int` itself is absent
  ## on purpose: it is Nim's default and suffixing every ordinary number would
  ## churn every golden for nothing.

proc genLit(ctx: CodegenCtx, e: Expr): string =
  case e.litKind
  of lkStr: "\"" & escapeStringLit(e.litValue) & "\""
  of lkInt:
    # An integer literal past the signed range is a u64 literal and has to say
    # so. Nim reads a bare one as `int` and refuses it — "number out of range:
    # '14695981039346656037'" — which is FNV-1a's offset basis, so every hash
    # constant in the stdlib lands here. Same shape as the D backend's `L`
    # suffix: a literal in an INFERRED position must carry its own width.
    const i64Max = "9223372036854775807"
    let digits = e.litValue.allCharsInSet({'0'..'9'})
    # Compare by LENGTH first: lexicographic order only agrees with numeric
    # order for equal-length digit strings, and "10000000000000000000" (20
    # digits) sorts BELOW i64Max (19) by first character.
    let tooBig = digits and (e.litValue.len > i64Max.len or
                             (e.litValue.len == i64Max.len and
                              e.litValue > i64Max))
    if tooBig: return e.litValue & "'u64"
    # Otherwise take the width the CHECKER settled on. A literal has no width
    # of its own — the place it is going does — so `fn f() -> u64: return 3`
    # must emit a uint64 literal or Nim reports "got 'int64' ... but expected
    # 'uint64'". synthLit reads the same expected-type channel to decide it.
    let t = ctx.res.typeFor(e)
    if t != nil and t.kind == tkNamed and t.name in NimLitSuffix:
      return e.litValue & NimLitSuffix[t.name]
    e.litValue
  else: e.litValue

proc genInputPayload(ctx: CodegenCtx): string =
  ## `input` — the whole incoming payload, rebuilt as a tuple.
  var parts: seq[string]
  for p in ctx.currentParams: parts.add(p.name & ": " & p.name)
  "(" & parts.join(", ") & ")"

proc genVar(ctx: var CodegenCtx, e: Expr): string =
  ## A bare name: a checker-stamped call, a payload, a field, or a plain
  ## variable.
  if ctx.res.hasCall(e): ctx.genExpr(ctx.res.call(e))
  elif e.name == "input" and ctx.currentParams.len > 0: ctx.genInputPayload()
  elif e.name in ctx.fieldVars: "self." & e.name
  else: nimRtCallee(e.name)

proc genIfaceExtraArgs(ctx: var CodegenCtx, memberDecl: Decl,
                       dotArg: Expr): string =
  ## The payload beyond `self`, splatted positionally to match the concrete
  ## member's own declared params — never packed into one Nim tuple, which is
  ## what the receiver's `encode(self, key, val)` signature actually expects.
  if dotArg == nil: return ""
  if memberDecl == nil: return ", " & ctx.genExpr(dotArg)
  var extra: seq[string]
  for i, pname in memberDecl.paramNames():
    if i == 0: continue  # self
    extra.add(ctx.payloadFieldArg(dotArg, pname))
  if extra.len == 0: return ""
  ", " & extra.join(", ")

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
  var arms: seq[string]
  for s in ctx.satisfiersOf(ic.iface):
    let extra = ctx.genIfaceExtraArgs(findObjectMember(s, ic.member), e.dotArg)
    # QUALIFIED, matching the declaration — the same name Odin and D have
    # always used here (memberProcName(s.name, ic.member)).
    arms.add(ind & "  of " & ic.iface & "_is_" & s.name & ":\n" &
             ind & "    var tmp = " & recv & "." & s.name & "Val\n" &
             ind & "    " & memberProcName(s.name, ic.member) &
             "(tmp" & extra & ")")
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

proc genTypeVariantCtor(ctx: var CodegenCtx, e: Expr): string =
  ## Bare Type.Variant of a payload sum when receiver is exkVar.
  if e.receiver == nil or e.receiver.kind != exkVar: return ""
  ctx.sumVariantCtor(e.receiver.name, e.fieldName, e.dotArg)

proc genPayloadSumField(ctx: var CodegenCtx, e: Expr): string =
  ## Field access on a payload sum, accounting for narrowing in match arms.
  let sumName = payloadSumTypeName(ctx.module, ctx.res.typeFor(e.receiver))
  if sumName == "": return ""
  let receiverStr = ctx.genExpr(e.receiver)
  var owner = ""
  if ctx.matchNarrowed.hasKey(receiverStr): owner = ctx.matchNarrowed[receiverStr]
  if owner == "": owner = variantOwningField(ctx.module, sumName, e.fieldName)
  if owner != "":
    return receiverStr & "." & sumPayloadField(owner) & "." & e.fieldName
  ""

proc genFieldAccess(ctx: var CodegenCtx, e: Expr, ind: string): string =
  ## A `.name` access: a payload field, interface dispatch, a resolved call, a
  ## sum-variant construction, an actor singleton's field, or a plain read.
  if ctx.isInputField(e): return e.fieldName
  let ic = ctx.res.ifaceCallOf(e)
  if ic.member != "": return ctx.genIfaceDispatch(e, ic, ind)
  if ctx.res.hasCall(e): return ctx.genConstruction(ctx.res.call(e))
  let ctor = ctx.genTypeVariantCtor(e)
  if ctor != "": return ctor
  if e.receiver != nil and e.receiver.kind == exkActorRef:
    return actorSingletonName(e.receiver.refName) & "." & e.fieldName
  if e.receiver != nil and e.receiver.kind == exkRegisterRef:
    let regPrefix = registerAccessorPrefix(ctx.module, e.receiver.refName,
                                           e.fieldName)
    if regPrefix != "": return regPrefix & "_get()"
  let sumField = ctx.genPayloadSumField(e)
  if sumField != "": return sumField
  ctx.genExpr(e.receiver) & "." & e.fieldName

proc genCallExpr(ctx: var CodegenCtx, e: Expr): string =
  ## An [io] call is a suspend point (the effect marker IS the async
  ## annotation). Cooperative-yield first cut: yield so other tasks progress,
  ## then perform the call. (Real fd-await lands with the async externs.)
  let base = ctx.genConstruction(e)
  if ctx.res.isAsync(e) and ctx.inTask: "(tuckYield(); " & base & ")"
  else: base

proc genStruct(ctx: var CodegenCtx, e: Expr): string =
  var parts: seq[string]
  for f in e.fields: parts.add(f.name & ": " & ctx.genExpr(f.value))
  "(" & parts.join(", ") & ")"

proc genList(ctx: var CodegenCtx, e: Expr): string =
  ## `@[a, b]` for a `Seq[T]` (Nim's dynamic seq), bare `[a, b]` for an
  ## `Array[N, T]` (Nim's fixed `array[N, T]`, which Nim itself infers as a
  ## STATIC array from a bracket literal with no `@`) — the checker already
  ## says which one this literal IS (synthList), so ask it rather than
  ## guessing. Getting this wrong is the bug that shipped once: a Seq-shaped
  ## `@[1, 2, 3, 4]` landed in a field declared `array[4, int]` and Nim
  ## rejected it outright.
  var items: seq[string]
  for it in e.items: items.add(ctx.genExpr(it))
  let t = ctx.res.typeFor(e)
  let isArray = t != nil and t.kind == tkApp and t.base != nil and
                t.base.kind == tkNamed and t.base.name == "Array"
  if isArray: "[" & items.join(", ") & "]"
  else: "@[" & items.join(", ") & "]"

proc genCallResolved(ctx: var CodegenCtx, e: Expr): string =
  ## Indexing resolved to an at() call; a type application never reaches
  ## codegen, so an unresolved bracket emits nothing.
  if ctx.res.hasCall(e): ctx.genExpr(ctx.res.call(e)) else: ""

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
  let site = ctx.res.shortcut(s)
  let onErr = if ctx.errPolicy == "exit":
                "(tuck_unhandled(" & tn & ".err, \"" & site & "\"); quit(1))"
              else:
                "tuck_unhandled(" & tn & ".err, \"" & site & "\")"
  "(let " & tn & " = " & stmtCode & "; (if not " & tn & ".ok: " & onErr & "))"

proc isCallOnChain(res: Resolution, s: Expr): bool =
  ## `self ..loadEp {n} .startAudio` — a resolved call whose receiver is a
  ## chain. The chain lowers to statements, so the whole thing is multi-line.
  s.kind == exkField and s.receiver != nil and
    s.receiver.kind == exkChain and res.hasCall(s)

proc isChainBinding(s: Expr): bool =
  ## `var b = a ..setN {5}` — the chain runs into a temp above the binding.
  s.kind == exkAssign and s.assignVal != nil and s.assignVal.kind == exkChain

proc ownsItsLayout(res: Resolution, s: Expr): bool =
  ## Nodes that carry their own indentation.
  ##
  ## A `.fn` call whose RECEIVER is a chain belongs here too — though
  ## lowering.hoistChainCalls now rewrites that shape away before codegen
  ## ever sees it, so isCallOnChain is permanently false in practice and
  ## kept only as a second guard. Left out, genStmt added its own prefix on
  ## top of the chain's and produced 8 spaces against the block's 4 — which
  ## Nim rejects as invalid indentation.
  s.kind in {exkIf, exkBlock, exkChain, exkFor, exkWhile, exkDefer} or
    isCallOnChain(res, s) or isChainBinding(s)

proc stmtValueDropped(ctx: var CodegenCtx, s: Expr): bool =
  ## A call in STATEMENT position whose value nothing consumes. Nim rejects
  ## a bare expression with a type ("has to be used (or discarded)"), so it
  ## needs an explicit `discard` — `{self: c} bump` as its own line used to
  ## emit code that did not compile.
  ##
  ## Only a plain call: a chain lays itself out, and the errors-policy path
  ## has already wrapped its own drop site by the time this is asked.
  if s == nil or s.kind != exkCall: return false
  if ctx.res.shortcut(s) != "": return false   # errors policy owns this one
  # A TASK call in statement position is already wrapped in tuckSpawn(...),
  # which is a void expression — discarding it is the very "no type (or is
  # ambiguous)" error this proc exists to avoid, just one level out. The
  # task's own return type says nothing about the emitted statement.
  if s.callee != nil and s.callee.kind == exkVar and
     ctx.isTaskName(s.callee.name): return false
  let t = ctx.res.typeFor(s)
  if t == nil: return false
  # `discard` over a void call is itself an error in Nim, so the question is
  # whether there is anything TO discard.
  not (t.kind == tkNamed and t.name in ["void", "unit"])

proc genBoundErrorRouted(ctx: var CodegenCtx, s: Expr, stmtCode,
                         ind: string): string =
  ## continue/exit policy on a BINDING whose error was never answered — the
  ## `!?T` case where `if r.ok:` settled absence and left the error open.
  ##
  ## `genDroppedResult` wraps a statement EXPRESSION in a temp, which a
  ## binding is not: wrapping one produced `let tuckDrop1 = var tuck_r = ...`.
  ## A binding already has a name, so the check reads it directly and needs no
  ## temp at all.
  let site = ctx.res.shortcut(s)
  let name = if s.target != nil and s.target.kind == exkVar: s.target.name
             else: ""
  if name == "": return stmtCode
  let onErr = if ctx.errPolicy == "exit":
                "(tuck_unhandled(" & name & ".err, \"" & site &
                  "\"); quit(1))"
              else:
                "tuck_unhandled(" & name & ".err, \"" & site & "\")"
  stmtCode & "\n" & ind & "  if " & name & ".status == tsErr: " & onErr

proc genStmt(ctx: var CodegenCtx, s: Expr, ind: string): string =
  ## One statement of a block, indented unless it lays itself out.
  var code = ctx.genExpr(s)
  if code != "" and ctx.res.shortcut(s) != "":
    code = if s.kind == exkAssign: ctx.genBoundErrorRouted(s, code, ind)
           else: ctx.genDroppedResult(s, code)
  elif code != "" and ctx.stmtValueDropped(s):
    code = "discard " & code
  if code == "": return ""
  if ownsItsLayout(ctx.res, s): code else: ind & "  " & code

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

proc genDefer(ctx: var CodegenCtx, e: Expr, ind: string): string =
  ## `defer:` (spec §7.4) — Nim spells it identically, scope-exit-ordered and
  ## LIFO, so this is a keyword and a body rather than a lowering. All three
  ## backends reach their own native defer for the same reason: nothing about
  ## scope exit needs re-implementing in Tuck.
  ##
  ## The body is always a block — `defer:` opens one, and the parser has no
  ## other form — so there is no inline arm to write.
  if e.deferBody == nil or e.deferBody.kind != exkBlock: return ind & "discard"
  let body = ctx.genStmts(e.deferBody, ind)
  if body.len == 0: return ind & "discard"
  ind & "defer:\n" & body

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
  let w = ctx.res.wrapOf(e)
  if w.objName != "" and e.id notin ctx.wrapping:
    let (ifaceName, objName) = resolveWrapNames(ctx.module, w.iface, w.objName)
    ctx.wrapping.incl(e.id)
    let inner = ctx.genExpr(e)
    ctx.wrapping.excl(e.id)
    return genInterfaceWrap(inner, ifaceName, objName)
  case e.kind
  of exkLit: ctx.genLit(e)
  of exkVar: ctx.genVar(e)
  of exkActorRef, exkRegisterRef, exkRegistryRef, exkPoolRef, exkMixinRef:
    e.refName
  of exkField: ctx.genFieldAccess(e, ind)
  of exkQualified: genQualified(ctx, e)
  of exkCall: ctx.genCallExpr(e)
  of exkCombinator: ctx.genCombinator(e)
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
  of exkTripleDot: "discard"   # `...` outside a fn body: a no-op statement
  of exkChain: ctx.genExprChain(e)
  of exkSend: ctx.genExprSend(e)
  of exkSelect: ctx.genExprSelect(e)
  of exkDefer: ctx.genDefer(e, ind)
  of exkFinish:
    # The kind names the table directly, so there is no dispatch and no
    # runtime cost to the redundancy the source spells out.
    "finish(" & resourceTableName(e.finishKind) & ", " &
      ctx.genExpr(e.finishHandle) & ")"
  of exkAcquire:
    # The acquire SITE is supplied here, from the span — the author never
    # writes it, and it is what makes the OPEN RESOURCES report able to say
    # WHERE a leaked handle came from.
    "acquire(" & resourceTableName(e.acquireKind) & ", int64(" &
      ctx.genExpr(e.acquireRef) & "), " & escape(acquireSite(e, ctx.moduleName)) & ")"
  of exkImport: ""  # imports are declarations, never expression position

proc hasBracketBase(e: Expr): bool =
  ## Does this target chain bottom out in an index?
  if e == nil: return false
  case e.kind
  of exkBracket: true
  of exkField: hasBracketBase(e.receiver)
  else: false

proc genAssignTarget(ctx: var CodegenCtx, e: Expr): string =
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
  if not hasBracketBase(e): return ctx.genExpr(e)
  case e.kind
  of exkBracket:
    ctx.genExpr(e.brReceiver) & "[" &
      ctx.genExpr(e.brArgs[0]) & "]"
  of exkField:
    ctx.genAssignTarget(e.receiver) & "." & e.fieldName
  else: ctx.genExpr(e)

proc genTaskAssignment(ctx: var CodegenCtx, e: Expr): string =
  ## Result-bound task call assignment with result slot and await.
  if e.assignVal == nil or e.assignVal.kind != exkCall or
     e.assignVal.callee == nil or e.assignVal.callee.kind != exkVar or
     not ctx.isTaskName(e.assignVal.callee.name):
    return ""
  let tname = e.assignVal.callee.name
  let ret = ctx.taskRetType(tname)
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
  ctx.genExpr(e.target) & " = " & spawn

proc genSelfAppendAssignment(ctx: var CodegenCtx, e: Expr): string =
  ## Self-append: `xs = {items: xs, ...} push` appends in place.
  let appended = selfAppendValue(ctx.res, e)
  if appended == nil: return ""
  e.target.name & ".add(" & ctx.genExpr(appended) & ")"

proc prepareChainBinding(ctx: var CodegenCtx, valSrc: Expr): tuple[prelude: string, valSrc: Expr] =
  ## Prepare chain binding: run statements into temp, return (stmts, temp).
  if valSrc == nil or valSrc.kind != exkChain:
    return ("", valSrc)
  let (stmts, tmp) = ctx.genChainIntoTemp(valSrc)
  let prelude = stmts & "\n" & stmts.indentPrefix
  (prelude, Expr(span: valSrc.span, kind: exkVar, name: tmp))

proc genVarDeclaration(ctx: var CodegenCtx, e: Expr, targetStr, valStr, prelude: string): string =
  ## Variable declaration with optional stated type.
  let name = e.target.name
  if name notin ctx.definedVars and name notin ctx.fieldVars:
    ctx.definedVars.incl(name)
    let declared = if e.declType != nil: ": " & genType(e.declType) else: ""
    return prelude & "var " & name & declared & " = " & valStr
  ""

proc genFieldWrite(ctx: var CodegenCtx, e: Expr,
                   prelude, targetStr, valStr: string): string =
  ## A field assignment is a MUTATION SITE, exactly as a `..` chain step is,
  ## and owes the same two things the chain has always paid:
  ##
  ##   1. A register field is a raw pointer with no real field, so writing it
  ##      means CALLING the setter. `REG.F = v` emitted `REG_F_get() = v` and
  ##      nim answered "cannot be assigned to" — the target was rendered with
  ##      the READ emitter, which is what a read of a register spells. Odin
  ##      and D already spelled the setter here (issue #39).
  ##   2. An invariant-carrying value re-validates after it is written. The
  ##      chain form did; the assignment form did not, on ANY backend, so
  ##      `t.celsius = -400` left a value breaking its own contract in plain
  ##      sight (issue #41).
  ##
  ## Both need the VALUE, so neither can live in `genAssignTarget`, which
  ## renders a target alone.
  if e.target != nil and e.target.kind == exkField and
     e.target.receiver != nil and e.target.receiver.kind == exkRegisterRef:
    let regPrefix = registerAccessorPrefix(ctx.module, e.target.receiver.refName,
                                           e.target.fieldName)
    if regPrefix != "":
      return prelude & regPrefix & "_set(" & valStr & ")"
  result = prelude & targetStr & " = " & valStr
  let owner = assignInvariantOwner(ctx.res, e)
  if owner != "" and ctx.hasInvariantsFast(owner):
    result.add("\n" & "  ".repeat(ctx.indent) & "validate(" &
               ctx.genExpr(e.target.receiver) & ")")

proc genExprAssign(ctx: var CodegenCtx, e: Expr): string =
  let taskResult = ctx.genTaskAssignment(e)
  if taskResult != "": return taskResult
  let appendResult = ctx.genSelfAppendAssignment(e)
  if appendResult != "": return appendResult
  let (prelude, valSrc) = ctx.prepareChainBinding(e.assignVal)
  let targetStr = ctx.genAssignTarget(e.target)
  let valStr = ctx.genExpr(valSrc)
  if e.target.kind == exkVar:
    let declResult = ctx.genVarDeclaration(e, targetStr, valStr, prelude)
    if declResult != "": return declResult
  ctx.genFieldWrite(e, prelude, targetStr, valStr)

proc matchArmHead(pat: Pattern, patStr: string): string =
  ## The branch label for one match arm. A WILDCARD is the catch-all, which
  ## Nim spells `else`, not `of _` — `_` is Nim's ignore-identifier and
  ## illegal as a branch label, so a `_` arm emitted code that would not
  ## compile ("the special identifier '_' is ignored in declarations") after
  ## the checker had passed it. Odin and D already emit `default:` here.
  if pat != nil and pat.kind == pkWild: "else" else: "of " & patStr

proc analyzeMatchArms(e: Expr): tuple[errMatch: bool, hasWild: bool] =
  ## Detect error matches and wildcard patterns in arms.
  var errMatch = false
  var hasWild = false
  for arm in e.arms:
    if arm.pattern != nil and arm.pattern.kind == pkWild:
      hasWild = true
    if arm.pattern != nil and arm.pattern.kind == pkVar and "." in arm.pattern.name:
      errMatch = true
  (errMatch, hasWild)

proc processMatchArm(ctx: var CodegenCtx, arm: MatchArm, patStr: var string,
                     subjectRecvStr: string, ind: string): string =
  ## Process one match arm, emitting its case branch with narrowing support.
  if arm.pattern != nil and arm.pattern.kind == pkVar and "." in arm.pattern.name:
    let dot = arm.pattern.name.find(".")
    patStr = "errCode(\"" & errNameFor(ctx.module, ctx.moduleName,
      arm.pattern.name[0 ..< dot], arm.pattern.name[dot+1 .. ^1]) & "\")"
  var narrowedKey = ""
  if arm.pattern != nil and arm.pattern.kind == pkVar and "." notin arm.pattern.name:
    narrowedKey = subjectRecvStr
    ctx.matchNarrowed[narrowedKey] = arm.pattern.name
  let armHead = matchArmHead(arm.pattern, patStr)
  var result: string
  if arm.body != nil and arm.body.kind == exkBlock:
    let oldIndent = ctx.indent
    ctx.indent += 1
    let bodyStr = ctx.genExpr(arm.body)
    ctx.indent = oldIndent
    result = ind & armHead & ":\n" & bodyStr
  else:
    let bodyStr = ctx.genExpr(arm.body)
    result = ind & armHead & ":\n" & ind & "  " & bodyStr
  if narrowedKey != "": ctx.matchNarrowed.del(narrowedKey)
  result

proc genExprMatch(ctx: var CodegenCtx, e: Expr): string =
  if e.subject == nil: return "discard"
  let ind = "  ".repeat(ctx.indent)
  var subjectStr = ctx.genExpr(e.subject)
  let subjectRecvStr = subjectStr
  if payloadSumTypeName(ctx.module, ctx.res.typeFor(e.subject)) != "":
    subjectStr = subjectStr & ".kind"
  let (errMatch, hasWild) = analyzeMatchArms(e)
  var cases: seq[string]
  for arm in e.arms:
    var patStr = genPatternStr(arm.pattern)
    cases.add(ctx.processMatchArm(arm, patStr, subjectRecvStr, ind))
  if errMatch and not hasWild:
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
    if ctx.res.stepCall(step) != nil:
      let call = threadReceiver(ctx.res.stepCall(step), e.base, into, baseStr)
      lines.add(ind & into & " = " & ctx.genConstruction(call))
    else:
      var valStr = ""
      if isSingleFieldPayload(step.arg):
        valStr = ctx.genExpr(soleFieldValue(step.arg))
      # A register field is a raw pointer with no real field — writing it
      # means calling the setter genRegister emitted for it, exactly as the
      # Odin and D backends do through the same shared helper.
      let regPrefix = registerAccessorPrefix(ctx.module, into,
                                             chainStepMember(step))
      if regPrefix != "":
        lines.add(ind & regPrefix & "_set(" & valStr & ")")
      else:
        lines.add(ind & into & "." & step.target.name & " = " & valStr)
  # mutation site: an invariant-carrying var re-validates after the chain
  if e.base != nil and ctx.res.typeFor(e.base) != nil and
     ctx.res.typeFor(e.base).kind == tkNamed and
     ctx.hasInvariantsFast(ctx.res.typeFor(e.base).name):
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
  var ctorArgs = TagField & ": " & variant
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
  # An arm body is a BLOCK or a single expression, so it is emitted the way a
  # match arm's is: a block indents itself, an expression gets the branch
  # indent prefixed. Emitting a block with the expression rule produced
  # "invalid indentation" the moment arms gained blocks.
  ## `nest` says whether the body sits inside a branch. The two-arm form
  ## lowers to `if:`/`else:` and its bodies are one level in; the one-arm form
  ## lowers to straight-line code — the await, then the body — and its body
  ## stays at the SAME level. Nesting a sequential body produced Nim's
  ## "invalid indentation".
  proc armBody(ctx: var CodegenCtx, body: Expr, ind: string,
               nest = true): string =
    if body != nil and body.kind == exkBlock:
      let saved = ctx.indent
      if nest: ctx.indent += 1
      result = ctx.genExpr(body)
      ctx.indent = saved
    elif nest:
      result = ind & "  " & ctx.genExpr(body)
    else:
      result = ind & ctx.genExpr(body)

  var readArm, timeoutArm: ptr SelectArm = nil
  for arm in e.selArms.mitems:
    case arm.sourceKind
    of sskRead: readArm = addr arm
    of sskTimeout: timeoutArm = addr arm
    of sskTimeoutTyped, sskOther: discard   # refused by the checker
  let ind = repeat("  ", ctx.indent)
  # A select with ONE arm is a plain await, not a race. Both single-arm forms
  # are natural to write — "await this read", "wait this long" — and both used
  # to fall to the marker below, which emitted `discard` and threw the arm's
  # body away: the task then answered with a zero-valued record instead of
  # what the arm returned (issue #56). Each runtime already had the primitive.
  # SEQUENTIAL, not nested: the await and the arm body are two statements at
  # the same level, so the body takes `ind` and not a deeper one. The two-arm
  # form indents its bodies only because they sit inside `if:`/`else:`.
  if readArm != nil and timeoutArm == nil:
    return "tuckAwaitRead(" & ctx.genExpr(readArm.arg) & ")\n" &
           ctx.armBody(readArm.body, ind, nest = false)
  if timeoutArm != nil and readArm == nil:
    return "tuckSleep(" & ctx.selectTimeoutMs(timeoutArm[]) & ")\n" &
           ctx.armBody(timeoutArm.body, ind, nest = false)
  if readArm != nil and timeoutArm != nil:
    let fd = ctx.genExpr(readArm.arg)
    let ms = ctx.selectTimeoutMs(timeoutArm[])
    let readBody = ctx.armBody(readArm.body, ind)
    let toBody = ctx.armBody(timeoutArm.body, ind)
    "if tuckAwaitReadOrTimeout(" & fd & ", " & ms & "):\n" & readBody &
      "\n" & ind & "else:\n" & toBody
  else:
    # Unreachable for a checked program — failIfUnlowerableArm rejects these
    # before emission. Kept as a visible marker rather than silence.
    ind & "discard  # select: no lowerable arm (checker should have refused)"

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
