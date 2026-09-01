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
export genType        # re-exported: this file's public face is the backend

type
  CodegenCtx = object
    definedVars: HashSet[string]
    fieldVars: HashSet[string]
    indent: int
    module: Module
    hoisted: seq[string]  # named decls hoisted out of field positions (inline enums)
    typeSection: seq[string]  # object type headers — emitted with the types,
                              # ahead of every proc (Nim needs decl-before-use)
    retWrapped: bool      # current fn returns !T/?T → returns auto-wrap
    retInnerNim: string   # Nim type of the payload (for terr[T])
    retInnerT: Type       # payload Tuck type (typed struct-literal emission)
    retInvName: string    # fn returns an invariant-carrying type: validate at return sites
    tmpCounter: int
    inTask: bool          # emitting a task body — [io] calls become async yields
    errPolicy: string     # from the errors declaration; "" = strict
    realModules: Table[string, Module]  # imported modules emitted as own Nim files
    currentParams: seq[FieldDef]  # enclosing fn's params — `input` rebuilds them
    moduleName: string    # error codes hash over "module/Enum.Variant"
    recordNames: HashSet[string]     # names of record types in `module` (O(1) lookup)
    invariantNames: HashSet[string]  # names of invariant-carrying types in `module`
    actorNames: HashSet[string]      # names of dkActor decls in `module`
    taskNames: HashSet[string]       # names of dkTask decls in `module`
    # Answers for the three questions genConstruction asks about EVERY call:
    # is the callee a [saturating] type, an extern with an invariant-carrying
    # return, an extern with an [emit: "..."] name. Each used to be a full
    # decl scan per call expression — together 16% of a whole compile.
    saturatingTypes: Table[string, Type]  # name -> underlying type
    externInvRets: Table[string, string]  # extern fn -> invariant ret type
    externEmits: Table[string, string]    # extern fn -> [emit: "..."] name
    indexBuilt: bool                 # the sets above are populated?

proc indexTypeDecl(ctx: var CodegenCtx, d: Decl) =
  ## The three things a `type` contributes to the index.
  if d.typeBody == nil: return
  if d.typeBody.kind == tkRecord:
    ctx.recordNames.incl(d.name)
  for member in d.typeMembers:
    if member.kind == dkExpr:
      ctx.invariantNames.incl(d.name)
      break
  # `[saturating]` is the ATTRIBUTE, not the `distinct` keyword — see
  # ast_query.saturatingType, whose answer this caches.
  if d.typeBody.kind == tkNamed:
    for a in d.typeBody.attrs:
      if a.name == "saturating":
        ctx.saturatingTypes[d.name] = d.typeBody
        break

proc indexExterns(ctx: var CodegenCtx) =
  ## Externs are a SECOND pass: an extern's invariant-carrying return type is
  ## looked up in invariantNames, which the first pass has to finish filling
  ## (a type may be declared after the extern that returns it).
  for d in ctx.module.decls:
    if d == nil or d.kind != dkExtern: continue
    for mem in d.mixinMembers:
      if mem.kind != dkFn or not mem.isExtern: continue
      if mem.externEmit != "":
        ctx.externEmits[mem.name] = mem.externEmit
      if mem.fnReturnType != nil and mem.fnReturnType.kind == tkNamed and
         mem.fnReturnType.name in ctx.invariantNames:
        ctx.externInvRets[mem.name] = mem.fnReturnType.name

proc buildDeclIndex(ctx: var CodegenCtx) =
  ## Populate the name sets for `module` once, so per-node type queries are O(1)
  ## instead of a full decl scan each call (the emit hot path is O(n) fns each
  ## checking their param/return type names — a linear scan there is O(n²)).
  if ctx.indexBuilt: return
  for d in ctx.module.decls:
    if d == nil: continue
    case d.kind
    # An object constructs exactly like a record — `{name: "rex"} Dog` is named
    # fields, not positional — so it belongs in the same set. Without this,
    # construction emitted `tuck_Dog("rex")` and Nim rejected it.
    of dkObject: ctx.recordNames.incl(d.name)
    of dkType: ctx.indexTypeDecl(d)
    of dkActor: ctx.actorNames.incl(d.name)
    of dkTask: ctx.taskNames.incl(d.name)
    # Everything else contributes no NAME to this index. Listed rather than
    # left to `else`, so a new DeclKind that should be indexed is a compile
    # error here instead of a lookup that quietly returns false.
    of dkFn, dkMixin, dkExtern, dkPending, dkPool, dkFnSig, dkRegistry,
       dkRegister, dkExpr, dkConst, dkStaticAssert, dkErrors, dkImport,
       dkSelect, dkSatisfies, dkInterface, dkWhen: discard
  ctx.indexExterns()
  ctx.indexBuilt = true

proc satisfiersOf*(ctx: CodegenCtx, iface: string): seq[Decl] =
  ## Whole-program satisfier set — see codegen_common.satisfiersOf.
  satisfiersOf(ctx.module, ctx.realModules, iface)

proc isRecordTypeFast(ctx: var CodegenCtx, name: string): bool =
  ctx.buildDeclIndex()
  name in ctx.recordNames

proc hasInvariantsFast(ctx: var CodegenCtx, name: string): bool =
  ctx.buildDeclIndex()
  name in ctx.invariantNames

proc saturatingTypeFast(ctx: var CodegenCtx, name: string): Type =
  ## ast_query.saturatingType's answer, from the index. genConstruction asks
  ## this for EVERY call; the scanning version was 10% of a whole compile.
  ctx.buildDeclIndex()
  ctx.saturatingTypes.getOrDefault(name, nil)

proc externInvRetFast(ctx: var CodegenCtx, fnName: string): string =
  ## ast_query.externInvRet's answer, from the index.
  ctx.buildDeclIndex()
  ctx.externInvRets.getOrDefault(fnName, "")

proc externEmitNameFast(ctx: var CodegenCtx, fnName: string): string =
  ## externEmitName's answer, from the index.
  ctx.buildDeclIndex()
  ctx.externEmits.getOrDefault(fnName, "")

proc isActorType(ctx: var CodegenCtx, name: string): bool =
  ctx.buildDeclIndex()
  name in ctx.actorNames

proc isTaskName(ctx: var CodegenCtx, name: string): bool =
  ## Reads the index built once in buildDeclIndex, not a per-call scan of
  ## ctx.module.decls — this is called from genConstruction, once per call
  ## and a scan there is the same O(fns x calls) mistake fixed for lowering and
  ## the effect checker's task-spawn check.
  ctx.buildDeclIndex()
  name in ctx.taskNames

proc taskRetType(ctx: CodegenCtx, name: string): string =
  ## The Nim return type of a declared task, for its result slot.
  for d in ctx.module.decls:
    if d != nil and d.kind == dkTask and d.name == name:
      return if d.taskReturnType != nil: genType(d.taskReturnType) else: "void"
  "void"

# Field type emission. Nim forbids anonymous enums in field positions, so an
# inline sum type is hoisted to a named enum `<Parent><Field>Kind`.
proc fieldType(ctx: var CodegenCtx, parent: string, f: FieldDef): string =
  if f.typ != nil and f.typ.kind == tkSum:
    var allNoFields = true
    for v in f.typ.variants:
      if v.fields.len > 0: allNoFields = false
    if allNoFields and f.typ.variants.len > 0:
      let enumName = parent & f.name.capitalize() & "Kind"
      var tags: seq[string]
      for v in f.typ.variants: tags.add(v.name)
      ctx.hoisted.add("type " & enumName & "* = enum " & tags.join(", "))
      return enumName
  return genType(f.typ)

# Does this declared type carry invariant predicates? (block members are
# dkExpr decls; production sites append a validate() call — spec 4.7)
# spec 4.1: `[saturating]` clamps instead of wrapping. The ATTRIBUTE decides,
# not the `distinct` keyword — `type X = u16 [saturating]` and
# `distinct X = u16 [saturating]` mean the same thing (user ruling).
# Returns the underlying Nim integer type, or "" when not saturating.
proc saturatingBase(ctx: var CodegenCtx, name: string): string =
  let t = ctx.saturatingTypeFast(name)
  if t == nil: "" else: genType(t)

proc externEmitName(ctx: var CodegenCtx, fnName: string): string =
  ## The Nim/C proc name to emit for an extern with `[emit: "..."]`, or "" if
  ## it uses its Tuck name (the default).
  ctx.externEmitNameFast(fnName)

# module::fn — a real imported module rides Nim's own namespacing; a
# sketch-pending qualified name maps to its mangled stub (genPendingStub).
proc cCallbackSig(m: Module): string =
  ## The name of a C-callback fnsig declared in an extern block, or "".
  ## ponytail: first one wins — one C callback type per module covers every
  ## real header so far; key by param types when a second one shows up.
  for mem in m.externMembers():
    if mem.kind == dkFnSig and mem.sigIsCCallback: return mem.name
  ""

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

proc bangInfo(t: Type): tuple[wrapped: bool, inner: string, innerT: Type] =
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
    # `ActorType.field` — an actor is a singleton; read its public field off
    # the rt-owned instance (main's waitUntil predicates read state this way)
    if ctx.isActorType(e.receiver.name):
      return actorSingletonName(e.receiver.name) & "." & e.fieldName
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

proc genFnBody(ctx: var CodegenCtx, e: Expr, ind: string): string =
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

proc genDecl*(ctx: var CodegenCtx, d: Decl): string

# Pending stub: logs on invocation, returns the zero value (Nim zero-inits result).
# The walking skeleton runs; the compile-time PENDING report nags until implemented.
proc genPendingStub(d: Decl): string =
  # Tuck call sites pass one whole payload struct; the Tuck checker already
  # verified its shape against the pending signature. The Nim stub is generic
  # so any payload representation is absorbed.
  let fnNameSanitized = d.name.replace(".", "_").replace("::", "_")
  let retTypeStr = if d.fnReturnType != nil: genType(d.fnReturnType) else: "void"
  let paramStr = if d.fnParams.len > 0: "[T](payload: T)" else: "()"
  return "proc " & fnNameSanitized & "*" & paramStr & ": " & retTypeStr &
         " =\n  stderr.writeLine(\"TUCK PENDING: " & d.name & " invoked (not implemented)\")\n"

# Implicit return: the value flowing at the end of a fn body is its result.
# Rewrite the tail statement into an explicit return so the existing return
# emission (auto-wrap, typed literals) handles it. Control-flow tails keep
# explicit returns for now (checker enforces branch agreement).
proc decisionRows(ctx: var CodegenCtx, d: Decl): (seq[seq[string]], seq[string]) =
  ## The table's rows as (pattern strings per column, emitted body).
  var pats: seq[seq[string]]
  var bodies: seq[string]
  for s in d.fnBody.stmts:
    if s.kind != exkMatch or s.arms.len == 0: continue
    let pat = s.arms[0].pattern
    var row: seq[string]
    for el in (if pat != nil and pat.kind == pkTuple: pat.elems else: @[pat]):
      row.add(genPatternStr(el))
    pats.add(row)
    bodies.add(ctx.genExpr(s.arms[0].body))
  (pats, bodies)

proc genPackedTable(ctx: var CodegenCtx, d: Decl, header: string,
                    domains: seq[seq[string]], comboCount: int): string =
  ## Bitmask/packed path (spec 6.1): when every column is enumerable the whole
  ## table becomes one `case` over an integer key — no comparison chains at
  ## runtime. The last group is the `else`, so the case is total.
  let (rowPats, bodies) = ctx.decisionRows(d)
  let groups = groupByOutcome(domains, comboCount, rowPats, bodies)
  var lines = @["  case " & packedKeyExpr(d, domains, comboCount) &
                "   # packed decision key"]
  for gi, g in groups:
    if gi == groups.len - 1:
      lines.add("  else: return " & g.outcome)
    else:
      var ks: seq[string]
      for k in g.keys: ks.add($k)
      lines.add("  of " & ks.join(", ") & ": return " & g.outcome)
  header & "\n" & lines.join("\n") & "\n"

proc genConditionChain(ctx: var CodegenCtx, d: Decl, header: string): string =
  ## Fallback when some column is not enumerable: an if/elif chain comparing
  ## each param against its pattern. A row of all-`_` becomes the `else`.
  var lines: seq[string]
  for idx, s in d.fnBody.stmts:
    let arm = s.arms[0]
    var conds: seq[string]
    for i, pat in arm.pattern.elems:
      let patStr = genPatternStr(pat)
      if patStr != "_": conds.add(d.fnParams[i].name & " == " & patStr)
    let body = ctx.genExpr(arm.body)
    if conds.len == 0:
      lines.add("  else:\n    return " & body)
    else:
      let prefix = if idx == 0: "if " else: "elif "
      lines.add("  " & prefix & conds.join(" and ") & ":\n    return " & body)
  header & "\n" & lines.join("\n") & "\n"

proc genDecisionFn(ctx: var CodegenCtx, d: Decl, fnNameSanitized: string): string =
  ## A decision table compiles to one of two shapes: a packed `case` when
  ## every column is enumerable, an if/elif chain otherwise.
  var params: seq[string]
  for p in d.fnParams:
    params.add(p.name & ": " & genType(p.typ))
  let retTypeStr = if d.fnReturnType != nil: genType(d.fnReturnType) else: "void"
  let header = "proc " & fnNameSanitized & "*(" & params.join(", ") & "): " &
               retTypeStr & " ="
  let (domains, allEnum, comboCount) = columnDomains(ctx.module, d)
  if allEnum and comboCount > 0 and comboCount <= MaxPackedCombos:
    return ctx.genPackedTable(d, header, domains, comboCount)
  ctx.genConditionChain(d, header)

proc genFnDecl(ctx: var CodegenCtx, d: Decl): string =
    if d.isPending:
      return genPendingStub(d)
    ctx.currentParams = @[]
    for p in d.fnParams:
      ctx.currentParams.add(FieldDef(name: p.name, typ: p.typ, span: p.span))
    let fnNameSanitized = d.name.replace(".", "_")
    if d.isDecision or d.isDecisionTable():
      return ctx.genDecisionFn(d, fnNameSanitized)

    var params: seq[string]
    for p in d.fnParams:
      # PARAMS ARE NEVER `var`. In Nim, `var` on a parameter is not write
      # permission — it is a by-reference pass — so emitting it for every
      # record param meant a callee could write through to the CALLER's
      # record, which spec §7.1 says is impossible. A fn that read like a
      # preview (`{acct, fee} afterFee`) silently withdrew the money.
      #
      # Dropping it is free: verified in the emitted C, a `var Big` param and
      # a plain `Big` param have byte-identical signatures (both `Big*`) —
      # Nim already passes a large object by hidden reference. Only the write
      # permission goes away, which is the whole point.
      #
      # A mutator does not need it either: it returns the updated record and
      # the caller assigns it back (`server = withDefaults(server)`), which is
      # what codegen_odin.nim's fnParamList has always relied on — that
      # backend never emitted a pointer here, and rejected the same programs
      # Nim silently accepted.
      #
      # The exception is `self` in an object member, emitted by genMemberFn
      # below: that mutates state the object OWNS (spec §5.1).
      params.add(p.name & ": " & genType(p.typ))
    let retTypeStr = if d.fnReturnType != nil: genType(d.fnReturnType) else: "void"
    # Generic fns pass their type params straight through — Nim monomorphizes
    let genericStr = if d.fnGenerics.len > 0: "[" & d.fnGenerics.join(", ") & "]" else: ""
    let inlineStr = if d.isInline: " {.inline.}" else: ""
    let header = "proc " & fnNameSanitized & "*" & genericStr & "(" & params.join(", ") & "): " & retTypeStr & inlineStr & " ="
    let oldVars = ctx.definedVars
    for p in d.fnParams:
      ctx.definedVars.incl(p.name)
    let oldIndent = ctx.indent
    let (bw, binner, binnerT) = bangInfo(d.fnReturnType)
    ctx.retWrapped = bw
    ctx.retInnerNim = binner
    ctx.retInnerT = binnerT
    ctx.retInvName =
      if not bw and d.fnReturnType != nil and d.fnReturnType.kind == tkNamed and
         ctx.hasInvariantsFast(d.fnReturnType.name): d.fnReturnType.name
      else: ""
    injectTailReturn(d.fnBody, retTypeStr)
    let bodyStr = ctx.genFnBody(d.fnBody, "  ".repeat(ctx.indent))
    ctx.indent = oldIndent
    ctx.retWrapped = false
    ctx.definedVars = oldVars
    return header & "\n" & bodyStr & "\n"

# Object member fn (or a mixin fn materialized by `+ mixin`): the object
# rides as a mutable `self` first parameter; the contract placeholder type
# `Self` resolves to the object. Emits via a shallow copy — the shared AST
# stays untouched for the other backend.
proc genMemberFn(ctx: var CodegenCtx, m: Decl, objName: string): string =
  ## lowering.normalizeSelf has already given the member its `self`
  ## parameter and resolved `Self` to the object. What is left here is the
  ## one thing that is a NIM question: self is mutable, spelled `var T`, so
  ## a mutation reaches the caller's value.
  var params = m.fnParams
  for i in 0 ..< params.len:
    if params[i].name == "self":
      params[i].typ = Type(span: m.span, kind: tkNamed,
                           name: "var " & objName)
  let copy = Decl(span: m.span, kind: dkFn, name: m.name, fnParams: params,
                  fnReturnType: m.fnReturnType, fnBody: m.fnBody,
                  fnEffects: m.fnEffects, fnGenerics: m.fnGenerics)
  ctx.genFnDecl(copy)

# --- dkType sum-type branch helpers ---

proc genTransitionProcs(d: Decl, kindName: string, hasPayload: bool): string =
      var canLines: seq[string]
      canLines.add("proc canTransition*(frm, to: " & kindName & "): bool =")
      canLines.add("  case frm")
      for v in d.typeBody.variants:
        let allowed = allowedTransitions(d.typeBody, v.name)
        if allowed.len > 0:
          canLines.add("  of " & v.name & ": to in {" & allowed.join(", ") & "}")
        else:
          canLines.add("  of " & v.name & ": false")
      var res = canLines.join("\n") & "\n"
      let kindOf = if hasPayload: ".kind" else: ""
      res.add("proc transitionTo*(self: var " & d.name & ", target: " & d.name & ") =\n" &
              "  if not canTransition(self" & kindOf & ", target" & kindOf & "):\n" &
              "    raise newException(ValueError, \"Invalid transition \" & $self" & kindOf &
              " & \" -> \" & $target" & kindOf & ")\n" &
              "  self = target\n")
      return res

proc genSumType(ctx: var CodegenCtx, d: Decl): string =
      let hasPayload = sumHasPayload(d.typeBody)
      let hasTransitions = d.typeBody.transitions.len > 0
      if not hasPayload and not hasTransitions:
        # plain enum (also what decision tables key over)
        var tags: seq[string]
        for v in d.typeBody.variants:
          tags.add(if v.value != "": v.name & " = " & v.value else: v.name)
        return "type " & d.name & "* = enum " & tags.join(", ") & "\n"

      var res = ""
      var kindName = d.name
      if hasPayload:
        # tagged union: kind enum + object variant; each variant's payload is
        # a tuple field named after the variant (no cross-branch name clashes)
        kindName = d.name & "Kind"
        var tags: seq[string]
        for v in d.typeBody.variants: tags.add(v.name)
        res.add("type " & kindName & "* = enum " & tags.join(", ") & "\n")
        res.add("type " & d.name & "* = object\n  case kind*: " & kindName & "\n")
        for v in d.typeBody.variants:
          if v.fields.len == 0:
            res.add("  of " & v.name & ": discard\n")
          else:
            var parts: seq[string]
            for f in v.fields:
              parts.add(f.name & ": " & genType(f.typ))
            res.add("  of " & v.name & ": " & v.name.toLowerAscii() &
                    "*: tuple[" & parts.join(", ") & "]\n")
      else:
        res.add("type " & d.name & "* = enum ")
        var tags: seq[string]
        for v in d.typeBody.variants: tags.add(v.name)
        res.add(tags.join(", ") & "\n")

      if hasTransitions:
        # transition matrix: pure predicate + checked assignment
        res.add(genTransitionProcs(d, kindName, hasPayload))
      return res

proc genRecordType(ctx: var CodegenCtx, d: Decl): string =
      var fieldsStr: seq[string]
      for f in d.typeBody.fields:
        fieldsStr.add("  " & f.name & "*: " & ctx.fieldType(d.name, f))
      let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: "  discard"
      let tGen = if d.generics.len > 0: "[" & d.generics.join(", ") & "]" else: ""
      # A C struct (declared inside `extern [c, header: ...]`) must DECLARE the
      # foreign type, not define a second one: Nim #includes the header, so a
      # plain object would be a distinct C type with identical layout and the
      # C compiler rejects the call ("cannot convert struct <anonymous>").
      # Mirrors how Nim's own posix module binds `struct timespec`. `bycopy`
      # keeps it passed by value, which is the C signature's contract.
      if d.typeExternHeader != "":
        # A FIELDLESS extern type is an opaque handle: `typedef struct Foo Foo;`
        # with no definition in the header. Its size is unknown, so it can only
        # ever be held as a pointer — `bycopy` would ask C for a size it does
        # not have ("unknown type size"). The alias is what callers name.
        if d.typeBody.fields.len == 0:
          return "type " & d.name & "Obj {.importc: \"" & d.name & "\", header: \"" &
                 d.typeExternHeader & "\", incompleteStruct.} = object\n" &
                 "type " & d.name & "* = ptr " & d.name & "Obj\n"
        return "type " & d.name & "* {.importc: \"" & d.name & "\", header: \"" &
               d.typeExternHeader & "\", bycopy.} = object\n" & fieldsBody & "\n"
      # Tier 1 records are value types (spec §7.1) — plain object, not ref
      var res = "type " & d.name & "*" & tGen & " = object\n" & fieldsBody & "\n"
      var invariantChecks: seq[string]
      var checkCtx = CodegenCtx(definedVars: initHashSet[string](), fieldVars: initHashSet[string](), indent: 0)
      for f in d.typeBody.fields:
        checkCtx.fieldVars.incl(f.name)
      for member in d.typeMembers:
        if member.kind == dkExpr:
          let condStr = checkCtx.genExpr(member.expr)
          # NOT `assert`: `-d:release` strips it outright, which is exactly
          # the build where a violated invariant means corrupt data.
          # ROADMAP's 2026-08-25 ruling 5 says invariants stay on in release,
          # opt-out only — `tuckNoInvariants` is that opt-out, independent of
          # `release`/`danger` (mirrors the D backend's `tuckNoInvariants`).
          invariantChecks.add("  if not (" & condStr & "): tuckInvariantFailed(\"" &
                              condStr.replace("\"", "'") & "\", \"" & d.name & "\")")
      if invariantChecks.len > 0:
        res.add("\nproc validate*(self: " & d.name & ") =\n  when not defined(tuckNoInvariants):\n" &
                invariantChecks.join("\n").indent(2) & "\n")
      # manager types carry functionality: member fns join the catalog
      for member in d.typeMembers:
        if member.kind == dkFn:
          res.add("\n" & ctx.genDecl(member) & "\n")
      return res

proc genAliasType(d: Decl): string =
      let typeBodyStr = genType(d.typeBody)
      if isDistinctAlias(d.typeBody):
        # Nim distinct + borrowed ops: same bits, incompatible type
        var res = "type " & d.name & "* = distinct " & typeBodyStr & "\n"
        for op in ["+", "-", "*", "div", "mod"]:
          res.add("proc `" & op & "`*(a, b: " & d.name & "): " & d.name & " {.borrow.}\n")
        for op in ["==", "<", "<="]:
          res.add("proc `" & op & "`*(a, b: " & d.name & "): bool {.borrow.}\n")
        res.add("proc `$`*(a: " & d.name & "): string {.borrow.}\n")
        return res
      let aGen = if d.generics.len > 0: "[" & d.generics.join(", ") & "]" else: ""
      return "type " & d.name & "*" & aGen & " = " & typeBodyStr & "\n"

proc genMsgTypes(handlers: seq[ActorMsgHandler], hasShutdown: bool,
                 msgEnumName, msgTypeName: string): string =
  ## The message-kind enum + the message envelope object. Handler params ride
  ## in the envelope, deduped by name across handlers.
  var enumVariants: seq[string]
  for h in handlers:
    enumVariants.add("msg" & h.name.capitalize())
  if hasShutdown:
    enumVariants.add("msgShutdown")   # sent as `Actor send shutdown {}`
  var msgFields: seq[string]
  var seen = initHashSet[string]()
  for h in handlers:
    for p in h.params:
      if p.name notin seen:
        seen.incl(p.name)
        msgFields.add("  " & p.name & "*: " & genType(p.typ))
  let enumStr = "type " & msgEnumName & "* = enum " & enumVariants.join(", ") & "\n"
  let envelopeStr = "type " & msgTypeName & "* = object\n  kind*: " & msgEnumName & "\n" &
                    (if msgFields.len > 0: msgFields.join("\n") & "\n" else: "")
  enumStr & envelopeStr

proc genActorState(ctx: var CodegenCtx, d: Decl, msgTypeName, queueSize: string,
                   hasShutdown: bool): string =
  ## The actor's ref-object state: declared fields + mailbox (+ `finished` flag,
  ## which the shutdown arm sets to make the drain go inert).
  var fieldsStr: seq[string]
  for f in d.actorFields:
    fieldsStr.add("  " & f.name & "*: " & ctx.fieldType(d.name, f))
  fieldsStr.add("  mailbox*: Mailbox[" & msgTypeName & ", " & queueSize & "]")
  if hasShutdown:
    fieldsStr.add("  finished*: bool")
  "type " & d.name & "* = ref object\n" & fieldsStr.join("\n") & "\n"

proc genActorDispatch(ctx: CodegenCtx, d: Decl, msgTypeName: string,
                      handlers: seq[ActorMsgHandler], shutdownBody: Expr,
                      hasShutdown: bool): string =
  ## The `handleMsg` proc: a case over the message kind. Runs in its own ctx so
  ## handler bodies see the actor's fields as field vars; realModules/module are
  ## inherited so qualified calls (e.g. sys::exit) resolve as `module.fn`.
  var hctx = CodegenCtx(definedVars: initHashSet[string](),
                        fieldVars: initHashSet[string](), indent: 2,
                        realModules: ctx.realModules, module: ctx.module,
                        moduleName: ctx.moduleName)
  for f in d.actorFields:
    hctx.fieldVars.incl(f.name)
  # a block body self-indents; a single-expression arm body needs the arm indent
  proc armBody(e: Expr): string =
    let raw = hctx.genExpr(e)
    if e != nil and e.kind == exkBlock: raw else: "    " & raw
  var handlerCases: seq[string]
  for h in handlers:
    var caseBody = ""
    for p in h.params:
      caseBody.add("    let " & p.name & " = msg." & p.name & "\n")
    handlerCases.add("  of msg" & h.name.capitalize() & ":\n" & caseBody & armBody(h.body))
  if hasShutdown:
    # run the shutdown body, then mark finished so the drain goes inert; a
    # `return` in the arm body is a no-op statement here.
    handlerCases.add("  of msgShutdown:\n" & armBody(shutdownBody) & "\n    self.finished = true")
  "proc handleMsg*(self: " & d.name & ", msg: " & msgTypeName & ") =\n  case msg.kind\n" &
    handlerCases.join("\n") & "\n"

proc genActorDrain(msgTypeName, drainName, singleton: string, hasShutdown: bool): string =
  ## The drain closure: dequeue every pending msg, dispatch, report progress.
  ## The scheduler registers this; it never sees the concrete Msg type.
  result =
    "proc " & drainName & "(): bool {.gcsafe.} =\n" &
    "  {.cast(gcsafe).}:\n" &
    "    result = false\n"
  if hasShutdown:
    result.add("    if " & singleton & ".finished: return\n")
  result.add(
    "    var m: " & msgTypeName & "\n" &
    "    while dequeue(" & singleton & ".mailbox, m):\n" &
    "      handleMsg(" & singleton & ", m)\n" &
    "      result = true\n")

proc genActor(ctx: var CodegenCtx, d: Decl): string =
  let queueSize = actorQueueSize(d)
  let (handlers, shutdownBody, hasShutdown) = collectHandlers(d)
  let msgEnumName = d.name & "MsgKind"
  let msgTypeName = d.name & "Msg"

  if handlers.len == 0 and not hasShutdown:
    # No handlers: an empty enum is invalid Nim. Emit just the state object.
    var bareFields: seq[string]
    for f in d.actorFields:
      bareFields.add("  " & f.name & "*: " & ctx.fieldType(d.name, f))
    let bareBody = if bareFields.len > 0: bareFields.join("\n") else: "  discard"
    return "type " & d.name & "* = ref object\n" & bareBody & "\n"

  let singleton = actorSingletonName(d.name)   # spec §9: one global per actor
  let drainName = "drain" & d.name
  let msgTypes = genMsgTypes(handlers, hasShutdown, msgEnumName, msgTypeName)
  let stateStr = genActorState(ctx, d, msgTypeName, queueSize, hasShutdown)
  let dispatchStr = genActorDispatch(ctx, d, msgTypeName, handlers, shutdownBody, hasShutdown)
  let singletonStr = "let " & singleton & "* = " & d.name & "()\n"
  let drainStr = genActorDrain(msgTypeName, drainName, singleton, hasShutdown)
  # auto-registration hook: main's prologue calls registerActors()
  let registerStr = "proc registerActor" & d.name & "*() =\n" &
                    "  tuckStartActor(" & drainName & ")\n"

  msgTypes & "\n" & stateStr & "\n" & singletonStr & "\n" & dispatchStr & "\n" &
    drainStr & "\n" & registerStr

proc genRegistry(ctx: var CodegenCtx, d: Decl): string =
    let msgEnumName = d.name & "Kind"
    var enumVariants: seq[string]
    var fieldsStr: seq[string]
    var seenFields = initHashSet[string]()
    for v in d.variants:
      enumVariants.add(v.name)
      for f in v.fields:
        if f.name notin seenFields:
          seenFields.incl(f.name)
          fieldsStr.add("  " & f.name & "*: " & genType(f.typ))

    let enumStr = "type " & msgEnumName & "* = enum " & enumVariants.join(", ") & "\n"
    let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: ""
    let typeStr = "type " & d.name & "* = ref object\n    kind*: " & msgEnumName & "\n" & fieldsBody & "\n"
    let globalVarStr = "var latest" & d.name & "*: " & d.name & "\n\n"

    # Forward-declare handler procs: raise procs call them before their definition
    var fwdDeclsStr = ""
    var raiseProcsStr = ""
    for v in d.variants:
      var params: seq[string]
      var assignParts: seq[string]
      for f in v.fields:
        params.add(f.name & ": " & genType(f.typ))
        assignParts.add(f.name & ": " & f.name)
      let paramStr = params.join(", ")
      let assignStr = if assignParts.len > 0: ", " & assignParts.join(", ") else: ""

      let handlerName = d.name & "." & v.name
      let handlerNameSanitized = d.name & "_" & v.name
      var handlerCalls: seq[string]
      for decl in ctx.module.decls:
        if decl.kind == dkFn and decl.name == handlerName:
          var argNames: seq[string]
          for f in v.fields: argNames.add(f.name)
          handlerCalls.add("  " & handlerNameSanitized & "(" & argNames.join(", ") & ")")
          let retStr = if decl.fnReturnType != nil: genType(decl.fnReturnType) else: "void"
          fwdDeclsStr.add("proc " & handlerNameSanitized & "*(" & paramStr & "): " & retStr & "\n")

      let handlerInvokes = if handlerCalls.len > 0: handlerCalls.join("\n") else: "  discard"
      raiseProcsStr.add("proc raise_" & d.name & "_" & v.name & "*(" & paramStr & ") =\n  latest" & d.name & " = " & d.name & "(kind: " & v.name & assignStr & ")\n" & handlerInvokes & "\n\n")

    return enumStr & typeStr & "\n" & globalVarStr & fwdDeclsStr & raiseProcsStr

proc genObjectDecl(ctx: var CodegenCtx, d: Decl): string =
  ## A manager object: its fields land in the type section, its members and
  ## anything composed into it come back as top-level procs.
  var fields: seq[string]
  for f in d.objFields:
    fields.add("  " & f.name & "*: " & ctx.fieldType(d.name, f))
  var members = ""
  for member in d.objMembers:
    # lowering.composeObject has already merged every RESOLVED `+ X`. What
    # can still reach here is one that named nothing declared — a sketch.
    if isCompositionEntry(member):
      members.add("# + " & member.expr.operand.name & " (undeclared — sketch)\n")
    elif member.kind == dkFn:
      members.add(ctx.genMemberFn(member, d.name) & "\n")
    else:
      members.add(ctx.genDecl(member) & "\n")
  let body = if fields.len > 0: fields.join("\n") else: "  discard"
  # manager objects hold var state but are Tier 1 value types too
  ctx.typeSection.add("type " & d.name & "* = object\n" & body)
  members

proc genTaskDecl(ctx: var CodegenCtx, d: Decl): string =
  ## A task is a fn whose body runs on the scheduler: inside it, [io] calls
  ## become async yields (ctx.inTask), which is the only reason it is not
  ## just genFnDecl.
  ctx.currentParams = @[]
  var params: seq[string]
  for p in d.taskParams:
    ctx.currentParams.add(FieldDef(name: p.name, typ: p.typ, span: p.span))
    params.add(p.name & ": " & genType(p.typ))
  let retTypeStr = if d.taskReturnType != nil: genType(d.taskReturnType) else: "void"
  let header = "proc " & d.name & "*(" & params.join(", ") & "): " &
               retTypeStr & " ="
  let oldVars = ctx.definedVars
  for p in d.taskParams: ctx.definedVars.incl(p.name)
  let oldIndent = ctx.indent
  let oldInTask = ctx.inTask
  (ctx.retWrapped, ctx.retInnerNim, ctx.retInnerT) = bangInfo(d.taskReturnType)
  injectTailReturn(d.taskBody, retTypeStr)
  ctx.inTask = true
  # A task lowers to a proc, so its body needs no scope of its own either.
  let bodyStr = ctx.genFnBody(d.taskBody, "  ".repeat(ctx.indent))
  ctx.inTask = oldInTask
  ctx.indent = oldIndent
  ctx.retWrapped = false
  ctx.definedVars = oldVars
  header & "\n" & bodyStr & "\n"

proc bitAccessMode(f: FieldDef): string =
  ## An unmarked field is readable AND writable; marking one direction opts
  ## out of the other.
  var hasRead, hasWrite = false
  for a in f.attrs:
    if a.name == "read": hasRead = true
    elif a.name == "write": hasWrite = true
  if hasRead and not hasWrite: "ReadOnly"
  elif hasWrite and not hasRead: "WriteOnly"
  else: "ReadWrite"

proc genRegister(d: Decl): string =
  ## Memory-mapped register. Nim has a `registerMMIO` macro that takes the
  ## bit layout directly, so this backend hands it the fields — the Odin
  ## backend, which has no such macro, lowers the same declaration to named
  ## masks plus accessor procs.
  var fields: seq[string]
  for f in d.regFields:
    let bitVal = f.typ.name.replace("bit ", "").replace("bits ", "")
    fields.add("  " & f.name & ": bit(" & bitVal & ", " & bitAccessMode(f) & ")")
  "registerMMIO(" & d.name & ", " & d.regAddress & "):\n" &
    fields.join("\n") & "\n"

proc declaredErrNames(ctx: CodegenCtx): seq[string] =
  ## Every "module/Enum.Variant" this module declares. Error enums are
  ## FIELDLESS sums; one with payload fields is an ordinary sum type.
  for td in ctx.module.decls:
    if td == nil or td.kind != dkType: continue
    if td.typeBody == nil or td.typeBody.kind != tkSum: continue
    var fieldless = true
    for v in td.typeBody.variants:
      if v.fields.len > 0: fieldless = false
    if not fieldless: continue
    for v in td.typeBody.variants:
      result.add(errNameFor(ctx.module, ctx.moduleName, td.writtenName, v.name))

proc genErrNameTable(errNames: seq[string]): string =
  ## A reverse table (hash -> "module/Enum.Variant") so a report can name the
  ## error rather than print its code.
  result = "proc tuckErrName*(code: uint16): string =\n  case code\n"
  for n in errNames:
    result.add("  of errCode(\"" & n & "\"): \"" & n & "\"\n")
  result.add("  else: \"code \" & $code\n")

proc genErrHandlerBody(ctx: var CodegenCtx, handler: Decl): string =
  ## The user's handler body, with `code` and `site` in scope as its params.
  let savedVars = ctx.definedVars
  ctx.definedVars.incl("code")
  ctx.definedVars.incl("site")
  # A handler body is a PROC body — genFnBody, not genIndented, so it does not
  # get the `if true:` scope that a nested block needs.
  result = ctx.genFnBody(handler.fnBody, "  ".repeat(ctx.indent))
  ctx.definedVars = savedVars
  if result.strip() == "" or result.strip() == "discard": result = ""

proc genErrHandler(ctx: var CodegenCtx, d: Decl): string =
  ## Global handler: rt logger first (errors are always visible), then the
  ## user's handler body.
  let errNames = ctx.declaredErrNames()
  if errNames.len > 0: result.add(genErrNameTable(errNames))
  result.add("proc tuck_unhandled*(code: uint16, site: string) =\n" &
             "  tuckReportUnhandled(code, site)\n")
  if errNames.len > 0:
    result.add("  stderr.writeLine(\"TUCK ERROR NAME: \" & tuckErrName(code))\n")
  if d.errHandler != nil and d.errHandler.fnBody != nil:
    let body = ctx.genErrHandlerBody(d.errHandler)
    if body != "": result.add(body & "\n")


proc genImportcBinding(m: Decl): string =
  ## A C-imported fn. [emit: "c_fn"] sets the importc name; else the Tuck name.
  var params: seq[string]
  for prm in m.fnParams:
    params.add(prm.name & ": " & genType(prm.typ))
  let retStr = if m.fnReturnType != nil: genType(m.fnReturnType) else: "void"
  let cName = if m.externEmit != "": m.externEmit else: m.name
  "proc " & m.name & "*(" & params.join(", ") & "): " & retStr &
    " {.importc: \"" & cName & "\", header: \"" & m.externHeader & "\".}\n"

proc genMixinMember(ctx: var CodegenCtx, m: Decl): string =
  ## One member of a mixin/extern/pending block.
  if m.kind in {dkType, dkFnSig}:
    # a C struct or callback signature declared in the extern block — genDecl
    # routes them to the importc/header and cdecl forms
    return ctx.genDecl(m) & "\n"
  if m.kind != dkFn: return ""
  if m.isPending: return genPendingStub(m) & "\n"
  if not m.isExtern:
    # interface contract (sig only, no body): nothing to emit — the
    # implementing types provide the code
    if m.fnBody == nil or takesSelf(m): return ""
    # a mixin is a named bucket of functions (spec 5.1) — emit them
    return ctx.genDecl(m) & "\n"
  if m.externHeader != "": return genImportcBinding(m)
  ""   # rt-implemented: tuck_rt provides it, nothing to emit here

proc genMixinBlock(ctx: var CodegenCtx, d: Decl): string =
  ## All three kinds carry members and emit per-member. dkPending emits stubs;
  ## dkExtern emits nothing for rt-implemented fns (tuck_rt provides them) and
  ## importc bindings for C-imported ones; a real mixin's fns are materialised
  ## onto the objects that compose it.
  for m in d.mixinMembers:
    result.add(ctx.genMixinMember(m))

proc genDecl*(ctx: var CodegenCtx, d: Decl): string =
  if d == nil: return ""
  if d.kind == dkType and d.span.file.startsWith(ImportedTypeMarker):
    return ""  # defined in its own module; the Nim import brings it in
  case d.kind
  of dkFn:
    return ctx.genFnDecl(d)
  of dkType:
    if d.typeBody != nil:
      if d.typeBody.kind == tkSum:
        return ctx.genSumType(d)
      elif d.typeBody.kind == tkRecord:
        return ctx.genRecordType(d)
      else:
        return genAliasType(d)
    return ""
  of dkObject:
    return ctx.genObjectDecl(d)
  of dkActor:
    return ctx.genActor(d)
  of dkTask:
    return ctx.genTaskDecl(d)

  of dkExpr:
    return ctx.genExpr(d.expr)
  of dkConst:
    # explicit static block: the backend evaluates the initializer at
    # compile time (pure computation — the checker already enforced purity)
    return "const " & d.name & " = static:\n  " & ctx.genExpr(d.constVal)
  of dkRegister: return genRegister(d)
  of dkRegistry:
    return ctx.genRegistry(d)
  of dkPool:
    # spec 7.2: one static instance; acquire/release are the rt's generic
    # procs, reached as `Pool.acquire` -> `acquire(Pool)`.
    return "var " & d.name & "* = ObjectPool[" & genType(d.poolElem) & ", " &
           $d.poolCount & "]()"
  of dkImport:
    return ""  # emitNim adds the Nim import line
  of dkStaticAssert:
    return "static: assert(" & ctx.genExpr(d.assertExpr) & ")"
  of dkErrors: return ctx.genErrHandler(d)
  of dkMixin, dkExtern, dkPending: return ctx.genMixinBlock(d)
  of dkFnSig:
    # `fnsig NAME = {params} -> ret` → a Nim closure proc type. Named delegate
    # for slots/callbacks; call shape already checked by the type checker.
    var params: seq[string]
    for prm in d.sigParams:
      params.add(prm.name & ": " & genType(prm.typ))
    let retStr = if d.sigReturn != nil and not
                    (d.sigReturn.kind == tkNamed and d.sigReturn.name == "void"):
                   genType(d.sigReturn)
                 else: "void"
    # A C callback must be a BARE function pointer with the C calling
    # convention. Nim's default {.closure.} is a (proc, env) pair — the C
    # compiler rejects it outright ("cannot convert struct <anonymous> to
    # int (*)(int, int)"), and a captured environment has nowhere to live on
    # the C side anyway, so C callbacks are necessarily non-capturing.
    let conv = if d.sigIsCCallback: "{.cdecl.}" else: "{.closure.}"
    let sGen = if d.sigGenerics.len > 0: "[" & d.sigGenerics.join(", ") & "]" else: ""
    return "type " & d.name & "*" & sGen & " = proc(" & params.join(", ") &
           "): " & retStr & " " & conv & "\n"
  of dkInterface:
    # An interface value is a VARIANT over the types that satisfy it: a tag
    # plus the object itself, copied in (spec §5.3). Copy, not a pointer to
    # the original — that is the same rule as every other value in Tuck, and
    # it is what makes returning one, storing one in a field, and collecting
    # them all just work with no lifetime questions.
    #
    # A variant rather than `array[max(sizeof), byte]` + copyMem: Tuck objects
    # hold `str` and `Seq`, which the backend manages, and a byte blit never
    # adjusts the refcount — the source's destructor would free the payload out
    # from under the copy. The variant lets Nim generate the right copy and
    # destroy per branch.
    #
    # The tag replaces the function table entirely: dispatch is a `case`
    # calling the concrete member fn directly, so there are no thunks and the
    # optimizer can see through it.
    let sats = ctx.satisfiersOf(d.name)
    if sats.len == 0:
      # Declared but nothing satisfies it — still a legal declaration, and
      # there is no value to represent.
      return "# interface " & d.name & ": no satisfying types\n"
    var tags: seq[string]
    var branches: seq[string]
    for s in sats:
      let tag = d.name & "_is_" & s.name
      tags.add(tag)
      branches.add("  of " & tag & ": " & s.name & "Val*: " & s.name)
    result = "type " & d.name & "Tag* = enum " & tags.join(", ") & "\n\n"
    result.add("type " & d.name & "* = object\n" &
               "  case tag*: " & d.name & "Tag\n" &
               branches.join("\n") & "\n")
    return result
  else:
    return "# [codegen] ignored decl kind " & $d.kind & "\n"

proc newCodegenCtx(m: Module, realModules: Table[string, Module],
                   moduleName: string): CodegenCtx =
  result = CodegenCtx(definedVars: initHashSet[string](), indent: 0, module: m,
                      realModules: realModules, moduleName: moduleName)
  for d in m.decls:
    if d != nil and d.kind == dkErrors:
      result.errPolicy = d.policyName

proc genDeclsOfKind(ctx: var CodegenCtx, m: Module, kinds: set[DeclKind]): string =
  for d in m.decls:
    if d == nil or d.kind notin kinds: continue
    let code = ctx.genDecl(d)
    if code != "": result.add(code & "\n")

proc genDeclsExcept(ctx: var CodegenCtx, m: Module, kinds: set[DeclKind]): string =
  for d in m.decls:
    if d == nil or d.kind in kinds: continue
    let code = ctx.genDecl(d)
    if code != "": result.add(code & "\n")

proc genOrderedDecls(ctx: var CodegenCtx, m: Module): string =
  ## Nim needs decl-before-use; Tuck is order-independent. So: type
  ## declarations first, then everything else in source order — object type
  ## headers land in ctx.typeSection during that pass and join the type block.
  ##
  ## Interfaces come LAST in the type block: an interface variant names the
  ## object types it wraps, and those headers only reach typeSection during
  ## the body pass.
  var typePart = ctx.genDeclsOfKind(m, {dkType, dkFnSig})
  let body = ctx.genDeclsExcept(m, {dkType, dkFnSig, dkInterface})
  for ts in ctx.typeSection:
    typePart.add(ts & "\n\n")
  typePart.add(ctx.genDeclsOfKind(m, {dkInterface}))
  typePart & body

proc genRtExport(m: Module): string =
  ## rt-implemented extern fns: importers reach them as <module>.<fn>, so the
  ## module re-exports the runtime that actually defines them. tuck_rt is the
  ## single facade — it re-exports tuck_async, so async externs (waitUntil,
  ## openSource, ...) resolve through this one export.
  for mem in m.externFns():
    if mem.externHeader == "": return "export tuck_rt\n"
  ""

proc genImplImports(m: Module): string =
  ## `impl: nim "..."` — a header-less extern whose bodies live somewhere
  ## other than tuck_rt. Imported AND re-exported for the same reason tuck_rt
  ## is: importers reach these fns as <module>.<fn>. This is what lets the
  ## stdlib grow without editing the compiler's own runtime.
  ##
  ## Nim exports by MODULE NAME, not by path: `export std/strutils` is a
  ## syntax error, `export strutils` is what re-exports it.
  var seen: seq[string]
  for mem in m.externFns():
    if mem.externHeader != "": continue
    for (backend, module) in mem.externImpl:
      if backend != "nim" or module in seen: continue
      seen.add(module)
      result.add("import " & module & "\nexport " &
                 module.rsplit('/', 1)[^1] & "\n")

proc linkPragma(lib: string): string =
  ## Vendored C source uses {.compile.}, which places the object WITH the rest
  ## so it links regardless of order — a static .a through {.passL.} does NOT
  ## work, because Nim emits passL flags ahead of the object files and an
  ## archive only contributes members resolving already-pending symbols.
  ## A path links verbatim; a bare name gets -l.
  if lib.endsWith(".c"): "{.compile: \"" & lib & "\".}\n"
  elif '/' in lib or lib.endsWith(".a") or lib.endsWith(".so"):
    "{.passL: \"" & lib & "\".}\n"
  else: "{.passL: \"-l" & lib & "\".}\n"

proc genLinkFlags(m: Module): string =
  ## C-extern link flags. `{.passL.}` is a module pragma, so linking is
  ## settled in the emitted source — the driver needs no per-library plumbing.
  var seen: seq[string]
  for mem in m.externFns():
    let lib = mem.externLib
    if lib == "" or lib in seen: continue
    seen.add(lib)
    result.add(linkPragma(lib))

proc genModuleImports(m: Module, realModules: Table[string, Module]): string =
  for d in m.decls:
    if d != nil and d.kind == dkImport and d.name in realModules:
      result.add("import " & d.name & "\n")

proc emitNim*(m: Module, rtImport = "../compiler/tuck_rt",
              realModules = initTable[string, Module](),
              moduleName = "main"): string =
  var ctx = newCodegenCtx(m, realModules, moduleName)
  let body = ctx.genOrderedDecls(m)
  # Nim resolves mutual type references only within ONE `type` block, and each
  # emit site writes its own — so `type A = {b: Seq[B]}` + `type B = {a: Seq[A]}`
  # (finite and legal, Seq is a handle) failed with `undeclared identifier`.
  # Odin and D resolve module-wide and never had this.
  # ponytail: one pragma instead of merging 11 emit sites into a single block;
  # do that if codeReordering ever bites.
  result = "{.experimental: \"codeReordering\".}\n"
  result.add("import " & rtImport & "\n")
  result.add(genRtExport(m))
  result.add(genImplImports(m))
  result.add(genLinkFlags(m))
  result.add(genModuleImports(m, realModules))
  result.add("\n")
  for h in ctx.hoisted:
    result.add(h & "\n")
  if ctx.hoisted.len > 0: result.add("\n")
  result.add(body)