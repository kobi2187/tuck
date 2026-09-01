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

type
  OdinCodegenCtx = object
    definedVars: HashSet[string]
    fieldVars: HashSet[string]
    fieldPrefix: string   # "this." in methods, "self." in static validate procs
    indent: int
    module: Module
    hoisted: seq[string]  # named decls hoisted out of field positions
    recShapes: Table[string, string]  # record shape signature -> struct name
    modPrefix: string     # library modules prefix hoisted names (dedupe per project)
    retWrapped: bool      # current fn returns !T/?T -> returns auto-wrap
    retInnerOdin: string  # Odin type of the payload (for terr<T>)
    retInnerT: Type       # payload Tuck type (typed struct-literal emission)
    retInvName: string    # fn returns an invariant-carrying type: validate at return
    tmpCounter: int
    errPolicy: string     # from the errors declaration; "" = strict
    realModules: Table[string, Module]  # imported modules emitted as own Odin files
    staticAsserts: seq[string]  # collected into one `static this()` block
    moduleName: string    # error codes hash over "module/Enum.Variant"
    currentParams: seq[FieldDef]  # enclosing fn's params — `input` rebuilds them
    ptrSelf: bool         # inside a member fn: `self` is ^T and needs a deref
    fnAsParam: bool       # emitting a param list: a bare `fn` is `$T` there
    foreignLibs: Table[string, string]  # C libs bound by extern blocks:
                                        # alias -> import spec. Each needs a
                                        # `foreign import` at package top level
    implMods: Table[string, string]     # `impl: odin "..."` modules: alias ->
                                        # import spec. Odin has no unqualified
                                        # re-export, so each extern fn also gets
                                        # a local forwarder calling <alias>.<fn>
                                        # — call sites stay unqualified, as on
                                        # the Nim side
    actorNames: HashSet[string]  # dkActor decl names in `module`, built once
    actorNamesBuilt: bool
    unionBind: string   # inside `switch v in value`: the name bound to the
                        # matched variant. A payload field is read through
                        # IT, not off the subject — Odin's union has no
                        # discriminant field to reach past.
    taskNames: HashSet[string]   # dkTask decl names, same one-shot index
    taskNamesBuilt: bool
    taskArgsHoisted: HashSet[string]   # task names whose Env_/wrap_ pair is
                                       # already hoisted — one signature per
                                       # task, unlike anonymous records,
                                       # so the task's own name IS the key

proc isActorType(ctx: var OdinCodegenCtx, name: string): bool =
  ## O(1) after the first call. genOdinExpr's exkField arm asks this once per
  ## FIELD ACCESS in the whole program; a decl-list scan there is the same
  ## O(fns x accesses) mistake fixed for lowering, the effect checker's
  ## task-spawn check, and the Nim backend's isActorType/isTaskName.
  if not ctx.actorNamesBuilt:
    for d in ctx.module.decls:
      if d != nil and d.kind == dkActor: ctx.actorNames.incl(d.name)
    ctx.actorNamesBuilt = true
  name in ctx.actorNames

proc isTaskName(ctx: var OdinCodegenCtx, name: string): bool =
  ## Mirrors the Nim backend. Calling a task SCHEDULES it as a coroutine
  ## (spec §9.2); emitting a direct call instead runs its body on the main
  ## context, where the first tuckAwaitRead hits parkCurrent's
  ## "cannot await outside a coroutine" panic.
  if not ctx.taskNamesBuilt:
    for d in ctx.module.decls:
      if d != nil and d.kind == dkTask: ctx.taskNames.incl(d.name)
    ctx.taskNamesBuilt = true
  name in ctx.taskNames

# --- Type emission --------------------------------------------------------

proc odinType*(ctx: var OdinCodegenCtx, t: Type): string

# Record shapes become hoisted structs, giving every shape a stable nominal
# type for construction and field access. Odin needs no constructor: struct
# literals take named fields (`Name{a = 1, b = 2}`).
proc recStructName(ctx: var OdinCodegenCtx, fields: seq[FieldDef]): string =
  var sigParts: seq[string]
  var typeStrs: seq[string]
  for f in fields:
    let ts = ctx.odinType(f.typ)
    typeStrs.add(ts)
    sigParts.add(f.name & ":" & ts)
  let sig = sigParts.join(",")
  if sig in ctx.recShapes:
    return ctx.recShapes[sig]
  var nameParts: seq[string]
  for f in fields: nameParts.add(f.name)
  let name = "TRec_" & ctx.modPrefix & nameParts.join("_") & "_" &
             toHex(odinErrCode(sig))
  ctx.recShapes[sig] = name
  var res = name & " :: struct {\n"
  for i, f in fields:
    res.add("\t" & f.name & ": " & typeStrs[i] & ",\n")
  res.add("}")
  ctx.hoisted.add(res)
  return name

proc isOddBitWidth(name: string): bool =
  ## `u2`, `u12` — a width a decision table produced that no machine type has.
  name.len >= 2 and name[0] in {'u', 'i'} and
    name[1..^1].allCharsInSet({'0'..'9'})

proc roundedIntType(name: string): string =
  ## Odd bit widths round UP to the next real machine int.
  let bits = parseInt(name[1..^1])
  let base = if name[0] == 'u': "u" else: "i"
  if bits <= 8: base & "8"
  elif bits <= 16: base & "16"
  elif bits <= 32: base & "32"
  else: base & "64"

proc importedTypeQualifier(ctx: OdinCodegenCtx, name: string): string =
  ## A type declared in an IMPORTED module lives in that module's Odin
  ## package, so it must be referenced qualified (`time.Milliseconds`). Beef
  ## needed no such qualification — its modules were static classes in one
  ## namespace.
  for d in ctx.module.decls:
    if d == nil or d.kind != dkType or d.name != name: continue
    if not d.span.file.startsWith(ImportedTypeMarker & ":"): break
    let origin = d.span.file[ImportedTypeMarker.len + 1 .. ^1]
    let pkg = origin.replace("-", "_")
    if pkg != ctx.moduleName.replace("-", "_"): return pkg & "." & name
    break
  name

proc odinNamedFallback(ctx: OdinCodegenCtx, t: Type): string =
  ## A name the primitive table did not cover.
  if isOddBitWidth(t.name): roundedIntType(t.name)
  elif t.name == UnknownName: "any"  # sketch mode: no type information
  else: ctx.importedTypeQualifier(t.name)

proc odinTupleType(ctx: var OdinCodegenCtx, t: Type): string =
  if t.elems.len == 1: return ctx.odinType(t.elems[0])
  var parts: seq[string]
  for e in t.elems: parts.add(ctx.odinType(e))
  "(" & parts.join(", ") & ")"

proc odinAppType(ctx: var OdinCodegenCtx, t: Type): string =
  ## Odin puts the size BEFORE the element type: [N]T, not T[N].
  if t.base.kind == tkNamed:
    case t.base.name
    of "*":       # elem * count — sized array
      return "[" & ctx.odinType(t.args[1]) & "]" & ctx.odinType(t.args[0])
    of "Array":   # Array[count, elem]
      return "[" & ctx.odinType(t.args[0]) & "]" & ctx.odinType(t.args[1])
    of "!", "?", "!?":
      # errors are first-class values: !T / ?T / !?T lower to rt.TuckResult(T)
      if t.args.len == 1:
        let inner = ctx.odinType(t.args[0])
        return "rt.TuckResult(" &
               (if inner == "void": "rt.TuckUnit" else: inner) & ")"
    of "Seq":
      var parts: seq[string]
      for a in t.args: parts.add(ctx.odinType(a))
      return "[dynamic]" & parts.join(", ")
    else: discard
  var parts: seq[string]
  for a in t.args: parts.add(ctx.odinType(a))
  ctx.odinType(t.base) & "(" & parts.join(", ") & ")"

proc odinFuncType(ctx: var OdinCodegenCtx, t: Type): string =
  ## A resolved function reference (`:plus`) carries its real signature, so it
  ## emits a callable proc type rather than an opaque pointer.
  var ps: seq[string]
  for p in t.params: ps.add(ctx.odinType(p))
  let r = if t.result != nil and
             not (t.result.kind == tkNamed and t.result.name == "void"):
            " -> " & ctx.odinType(t.result)
          else: ""
  "proc(" & ps.join(", ") & ")" & r

proc odinType*(ctx: var OdinCodegenCtx, t: Type): string =
  if t == nil: return "void"
  case t.kind
  of tkNamed:
    case t.name
    # Tuck's fixed-width names ARE Odin's spelling (u8, i32, f64) — most of
    # this table is identity.
    # "void" stays the internal sentinel (lots of `retTypeStr != "void"`
    # checks depend on it); the `-> T` emission drops it instead.
    of "void": "void"
    of "u8": "u8"
    of "u16": "u16"
    of "u32": "u32"
    of "u64": "u64"
    of "i8": "i8"
    of "i16": "i16"
    of "i32": "i32"
    of "i64": "i64"
    of "int": "int"
    of "string", "str": "string"
    # C's char* — the FFI boundary type. Odin's `string` is a fat pointer
    # (ptr + len), not a NUL-terminated C string, so the two are distinct.
    of "cstring": "cstring"
    # C's uint8_t* — see codegen_type.nim for why this is builtin rather than a
    # user-declared extern type. `[^]u8` is Odin's multi-pointer: a pointer to
    # an unknown number of u8, indexable, no length carried. `[dynamic]u8`
    # (what Seq[u8] maps to) is a 40-byte struct, not a pointer.
    of "Buf": "[^]u8"
    of "bool": "bool"
    of "float": "f64"
    of "f32": "f32"
    of "f64": "f64"
    of "usize": "uint"
    of "Seq": "[dynamic]"
    of "Array": "[]"
    # A bare `fn` with no declared signature is a BAKE SLOT: the concrete
    # proc is filled in at the call site, so the param is polymorphic —
    # `$T` mirrors the Nim backend's `auto`. A NAMED fnsig lands in the
    # `else` branch below and keeps its own type name.
    #
    # As a struct FIELD there is no polymorphism to lean on, so it needs a
    # concrete callable. tkFunc above covers the case where the checker
    # resolved a `:name` reference and kept its signature; this is the
    # fallback for a slot that was never given one.
    of "fn": (if ctx.fnAsParam: "$T" else: "proc()")
    else: ctx.odinNamedFallback(t)
  of tkTuple: ctx.odinTupleType(t)
  of tkApp: ctx.odinAppType(t)
  of tkFunc: ctx.odinFuncType(t)
  of tkRecord:
    recStructName(ctx, t.fields)
  of tkSum:
    var allNoFields = true
    for v in t.variants:
      if v.fields.len > 0: allNoFields = false
    if allNoFields and t.variants.len > 0:
      # anonymous enum outside a field position: hoist under a shape name
      var tags: seq[string]
      for v in t.variants: tags.add(v.name)
      let name = "TEnum_" & ctx.modPrefix & toHex(odinErrCode(tags.join(",")))
      let decl = name & " :: enum { " & tags.join(", ") & " }"
      if decl notin ctx.hoisted: ctx.hoisted.add(decl)
      name
    else:
      "any"
  else:
    "rawptr"

# Field type emission. An inline sum type is hoisted to a named enum
# `<Parent><Field>Kind` (the same name the Nim and Beef backends use).
proc fieldType(ctx: var OdinCodegenCtx, parent: string, f: FieldDef): string =
  if f.typ != nil and f.typ.kind == tkSum:
    var allNoFields = true
    for v in f.typ.variants:
      if v.fields.len > 0: allNoFields = false
    if allNoFields and f.typ.variants.len > 0:
      let enumName = parent & f.name.capitalize() & "Kind"
      var tags: seq[string]
      for v in f.typ.variants: tags.add(v.name)
      ctx.hoisted.add(enumName & " :: enum { " & tags.join(", ") & " }")
      return enumName
  return ctx.odinType(f.typ)

# --- Shared declaration lookups (mirror codegen.nim) -----------------------

# hasInvariants / externInvRet / isRecordType / isErrEnumRef used to be
# copy-pasted here from codegen.nim (this backend began as a fork). They are
# backend-neutral questions about the AST, so they live in ast_query.

# fn param TYPES by position, for call sites deciding whether an arg needs
# the `ref` marker (mutable record param).
proc lookupFnParamTypes(m: Module, name: string): seq[Type] =
  m.findFn(name).paramTypes()

proc declaresFn(m: Module, name: string): bool =
  ## Does this module declare `name` as a callable? A bool, because a fn with
  ## no params is indistinguishable from "not found" in a param list.
  m.findFn(name) != nil

proc genQualified(ctx: OdinCodegenCtx, e: Expr): string =
  let modName = if e.modulePath.len > 0: e.modulePath[0] else: ""
  if modName == "":
    # Unqualified name. Nim gets this free — the emitted file `import`s the
    # module and Nim's own overload resolution finds it. Odin has no such
    # scope merge: a package member is ALWAYS `pkg.name`, so the qualifier
    # has to be resolved here. Local declarations win; only a name this
    # module does not declare is searched for among the imports.
    if not ctx.module.declaresFn(e.qualName):
      for modName, im in ctx.realModules:
        if im.declaresFn(e.qualName):
          return modName.replace("-", "_") & "." & e.qualName
    # Not found anywhere (a bare fn reference like `:plus`, a local, or a
    # builtin): the name stands alone. Prefixing an empty module produced
    # `_plus`, an undeclared name.
    return e.qualName
  elif modName in ctx.realModules: return modName.replace("-", "_") & "." & e.qualName
  else: return modName & "_" & e.qualName

proc genOdinExpr*(ctx: var OdinCodegenCtx, e: Expr): string

proc satisfiersOf*(ctx: OdinCodegenCtx, iface: string): seq[Decl] =
  ## Whole-program satisfier set — see codegen_common.satisfiersOf.
  satisfiersOf(ctx.module, ctx.realModules, iface)

proc memberProcName*(objName, memberName: string): string =
  ## Object member fns emit qualified: `Dog.noise` -> `tuck_Dog_noise`.
  ##
  ## Nim tolerated a bare `noise` because it overloads on the `self` parameter's
  ## type, so two objects' members were two overloads. Odin does not overload —
  ## two `noise :: proc` at package level is "Redeclaration of 'noise' in this
  ## scope", so `object Dog` and `object Cat` both having a `noise` emitted a
  ## package that could not compile. Qualifying is also what interfaces need:
  ## several types answering the same call is the whole point of a contract.
  objName & "_" & memberName

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

proc odinBangInfo(ctx: var OdinCodegenCtx, t: Type):
    tuple[wrapped: bool, inner: string, innerT: Type] =
  if t != nil and t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
     t.base.name in ["!", "?", "!?"] and t.args.len == 1:
    let inner = ctx.odinType(t.args[0])
    return (true, (if inner == "void": "rt.TuckUnit" else: inner), t.args[0])
  return (false, "", nil)

# Comparison operand for a pattern value: enum tags need qualification (or
# Beef's `.Tag` inference prefix for hoisted inline enums); literals pass.
proc patternValue(ctx: OdinCodegenCtx, patStr: string): string =
  if patStr.len == 0: return patStr
  let owner = enumTagOwner(ctx.module, patStr)
  if owner != "": return owner & "." & patStr
  if patStr[0] in {'A'..'Z'}: return "." & patStr
  patStr

# A match-arm result that is a bare enum tag needs the same treatment; the
# assignment/return target supplies the type for `.Tag` inference.
proc armValue(ctx: var OdinCodegenCtx, e: Expr): string =
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

proc genIndented(ctx: var OdinCodegenCtx, e: Expr): string =
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
  if e.receiver != nil and e.receiver.kind == exkVar and
     ctx.isActorType(e.receiver.name):
    return actorSingletonName(e.receiver.name) & "." & e.fieldName
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
    # A register field is a raw pointer with no real field — reading it
    # means calling the getter genRegister already emitted for it.
    let prefix = registerAccessorPrefix(ctx.module, e.receiver.name, e.fieldName)
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
     e.target.receiver.kind == exkVar:
    let prefix = registerAccessorPrefix(ctx.module, e.target.receiver.name,
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

proc genOdinDecl*(ctx: var OdinCodegenCtx, d: Decl): string

# Object member fn (or a mixin fn materialized by `+ mixin`): the object
# rides as a `ref self` first parameter (reassignment must reach the
# caller); `Self` resolves to the object. Shallow copy — the shared AST
# stays untouched for the other backend.
# ponytail: call sites don't take the address yet — nothing in the
# examples calls a member fn; wire it when one does.
proc genOdinMemberFn(ctx: var OdinCodegenCtx, m: Decl, objName: string): string =
  # lowering.normalizeSelf has already given the member its `self` parameter
  # and resolved `Self` to the object. What is left is the ODIN spelling:
  # self is a pointer, `^T`, so a mutation reaches the caller's value.
  var params = m.fnParams
  for i in 0 ..< params.len:
    if params[i].name == "self":
      params[i].typ = Type(span: m.span, kind: tkNamed, name: "^" & objName)
  let copy = Decl(span: m.span, kind: dkFn, name: memberProcName(objName, m.name),
                  fnParams: params,
                  fnReturnType: m.fnReturnType, fnBody: m.fnBody,
                  fnEffects: m.fnEffects, fnGenerics: m.fnGenerics)
  # `self` is a POINTER here, so every mention in the body needs a deref —
  # `self^` reads the value and `self^ = x` writes through to the caller.
  let oldPtrSelf = ctx.ptrSelf
  ctx.ptrSelf = true
  result = ctx.genOdinDecl(copy)
  ctx.ptrSelf = oldPtrSelf

# Pending stub: logs on invocation, returns the zero value.
proc genPendingStub(ctx: var OdinCodegenCtx, d: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  let fnNameSanitized = d.name.replace(".", "_").replace("::", "_")
  let retTypeStr = if d.fnReturnType != nil: ctx.odinType(d.fnReturnType) else: "void"
  let paramStr = if d.fnParams.len > 0: "(payload: $T)" else: "()"
  let retStr = if retTypeStr != "void": " -> " & retTypeStr else: ""
  var res = ind & fnNameSanitized & " :: proc" & paramStr & retStr & " {\n" &
            ind & "\tfmt.println(\"TUCK PENDING: " & d.name &
            " invoked (not implemented)\")\n"
  if retTypeStr != "void":
    res.add(ind & "\treturn {}\n")
  res.add(ind & "}\n")
  return res

# Odin rejects non-void procs that can fall off the end; append a zero-value
# `return {}` when the last statement doesn't guarantee a return (the checker
# enforces the real branch agreement). The block emitter no longer emits a
# closing brace, so this appends to the end of the body.
proc ensureTrailingReturn(bodyStr: string, body: Expr, blockIndent: int): string =
  if body == nil or body.kind != exkBlock: return bodyStr
  if body.stmts.len > 0 and body.stmts[^1].kind in {exkReturn, exkRaise}:
    return bodyStr
  return bodyStr & "\n" & "  ".repeat(blockIndent) & "  return {}"

# Implicit return: the value flowing at the end of a fn body is its result.
# Decision tables: packed single-switch when every column is enumerable,
# otherwise a first-match if/else chain (mirrors codegen.nim).
proc decisionHeader(ctx: var OdinCodegenCtx, d: Decl, ind: string): string =
  ## The proc signature a decision table compiles to.
  var params: seq[string]
  for p in d.fnParams:
    params.add(p.name & ": " & ctx.odinType(p.typ))
  let retT = if d.fnReturnType != nil: ctx.odinType(d.fnReturnType) else: "void"
  let retStr = if retT != "void": " -> " & retT else: ""
  ind & d.name.replace(".", "_") & " :: proc(" & params.join(", ") & ")" &
    retStr & " {"

proc columnOrdinal(domain: seq[string], paramName: string): string =
  ## A column's ordinal. NOT packedKeyExpr — that emits Nim's `ord()`; Odin
  ## needs int() and a bool ternary, which is the one part of this that is
  ## genuinely syntax.
  if domain == @["false", "true"]: "(" & paramName & " ? 1 : 0)"
  else: "int(" & paramName & ")"

proc packedKey(d: Decl, domains: seq[seq[string]], comboCount: int): string =
  ## Mixed radix over the ordinal of each column.
  var parts: seq[string]
  var stride = comboCount
  for c in 0 ..< domains.len:
    stride = stride div domains[c].len
    let ordExpr = columnOrdinal(domains[c], d.fnParams[c].name)
    parts.add(if stride > 1: ordExpr & " * " & $stride else: ordExpr)
  parts.join(" + ")

proc decisionRowPatterns(s: Expr): seq[string] =
  ## One row's column patterns, as their surface spelling.
  let pat = s.arms[0].pattern
  for el in (if pat != nil and pat.kind == pkTuple: pat.elems else: @[pat]):
    result.add(genPatternStr(el))

proc collectDecisionRows(ctx: var OdinCodegenCtx, d: Decl,
                         rowPats: var seq[seq[string]],
                         rowBodies: var seq[string]) =
  for s in d.fnBody.stmts:
    if s.kind != exkMatch or s.arms.len == 0: continue
    rowPats.add(decisionRowPatterns(s))
    rowBodies.add(ctx.armValue(s.arms[0].body))

proc genPackedDecision(ctx: var OdinCodegenCtx, d: Decl,
                       domains: seq[seq[string]], comboCount: int,
                       ind: string): string =
  ## Every column domain is enumerable, so the whole table collapses to one
  ## switch over a packed integer key (spec 6.1).
  var rowPats: seq[seq[string]]
  var rowBodies: seq[string]
  ctx.collectDecisionRows(d, rowPats, rowBodies)
  # first-match outcome for every combination, grouped by outcome
  let groups = groupByOutcome(domains, comboCount, rowPats, rowBodies)
  var lines: seq[string]
  lines.add(ind & "\tswitch " & packedKey(d, domains, comboCount) &
            " {   // packed decision key")
  for gi, g in groups:
    if gi == groups.len - 1:
      lines.add(ind & "\tcase: return " & g.outcome)
    else:
      var ks: seq[string]
      for k in g.keys: ks.add($k)
      lines.add(ind & "\tcase " & ks.join(", ") & ": return " & g.outcome)
  lines.add(ind & "\t}")
  lines.join("\n")

proc decisionRowCondition(ctx: var OdinCodegenCtx, d: Decl, arm: MatchArm): string =
  ## The guard a row fires under — empty when every column is a wildcard,
  ## which makes it the catch-all.
  let pats = if arm.pattern != nil and arm.pattern.kind == pkTuple:
               arm.pattern.elems
             else: @[arm.pattern]
  var conds: seq[string]
  for i, pat in pats:
    let patStr = genPatternStr(pat)
    if patStr != "_" and i < d.fnParams.len:
      conds.add(d.fnParams[i].name & " == " & ctx.patternValue(patStr))
  conds.join(" && ")

proc genChainedDecision(ctx: var OdinCodegenCtx, d: Decl, retTypeStr,
                        ind: string): string =
  ## An open column domain cannot be packed, so the rows become guards in
  ## order, and a table with no catch-all needs a zero value to fall out on.
  var lines: seq[string]
  var hasCatchAll = false
  for s in d.fnBody.stmts:
    let arm = s.arms[0]
    let cond = ctx.decisionRowCondition(d, arm)
    let value = ctx.armValue(arm.body)
    if cond == "":
      lines.add(ind & "\treturn " & value)
      hasCatchAll = true
    else:
      lines.add(ind & "\tif " & cond & " do return " & value)
  if not hasCatchAll and retTypeStr != "void":
    lines.add(ind & "\treturn {}")
  lines.join("\n")

proc genDecisionTable(ctx: var OdinCodegenCtx, d: Decl): string =
  ## Packed when every column is enumerable, chained guards otherwise.
  let ind = "  ".repeat(ctx.indent)
  let header = ctx.decisionHeader(d, ind)
  let retTypeStr = if d.fnReturnType != nil: ctx.odinType(d.fnReturnType)
                   else: "void"
  let (domains, allEnum, comboCount) = columnDomains(ctx.module, d)
  let body = if allEnum and comboCount > 0 and comboCount <= MaxPackedCombos:
               ctx.genPackedDecision(d, domains, comboCount, ind)
             else:
               ctx.genChainedDecision(d, retTypeStr, ind)
  header & "\n" & body & "\n" & ind & "}\n"

proc cCallbackConvention(ctx: var OdinCodegenCtx, d: Decl): string =
  ## A fn handed to a C function pointer needs the C calling convention. Odin
  ## cannot cast between conventions the way Nim can, so it goes on the
  ## DEFINITION, matched by shape against the module's C-callback fnsig.
  ##
  ## ponytail: shape match, not reference tracking. A same-shape fn that never
  ## crosses the boundary gets "c" harmlessly; tighten if that ever matters.
  for mem in ctx.module.externMembers():
    if mem.kind != dkFnSig or not mem.sigIsCCallback or
       mem.sigParams.len != d.fnParams.len: continue
    var same = true
    for i, sp in mem.sigParams:
      if ctx.odinType(sp.typ) != ctx.odinType(d.fnParams[i].typ): same = false
    if same: return "\"c\" "
  ""

proc fnParamList(ctx: var OdinCodegenCtx, d: Decl): string =
  ## Records pass BY VALUE. The checker binds every param isVar:true, but a
  ## Tuck mutator returns the updated record and the caller assigns it back
  ## (`server = withDefaults(server)`), so no pointer is needed — and Odin
  ## proc params aren't addressable, so `&arg` at the call site is illegal.
  ##
  ## Generic fns come first: Odin's parametric polymorphism marks type params
  ## with `$`.
  var params: seq[string]
  for g in d.fnGenerics: params.add("$" & g & ": typeid")
  ctx.fnAsParam = true
  for p in d.fnParams:
    params.add(p.name & ": " & ctx.odinType(p.typ))
  ctx.fnAsParam = false
  params.join(", ")

proc fnHeader(ctx: var OdinCodegenCtx, d: Decl, retTypeStr, ind: string): string =
  ## Names arrive already mangled by the lowering pass (compiler/mangle.nim),
  ## which is also what keeps Tuck's `fn main` from colliding with Odin's entry
  ## point — it is tuck_main by the time it gets here.
  let retStr = if retTypeStr != "void": " -> " & retTypeStr else: ""
  let inlinePrefix = if d.isInline: ind & "@(require_results=false)\n" else: ""
  inlinePrefix & ind & d.name.replace(".", "_") & " :: proc " &
    ctx.cCallbackConvention(d) & "(" & ctx.fnParamList(d) & ")" & retStr & " {"

proc enterReturnContext(ctx: var OdinCodegenCtx, d: Decl) =
  ## What the body needs to know about the return: whether it auto-wraps into
  ## a !T/?T result, and whether the returned value carries invariants to
  ## validate on the way out.
  let (wrapped, innerOdin, innerT) = ctx.odinBangInfo(d.fnReturnType)
  ctx.retWrapped = wrapped
  ctx.retInnerOdin = innerOdin
  ctx.retInnerT = innerT
  ctx.retInvName =
    if not wrapped and d.fnReturnType != nil and
       d.fnReturnType.kind == tkNamed and
       hasInvariants(ctx.module, d.fnReturnType.name): d.fnReturnType.name
    else: ""

proc leaveReturnContext(ctx: var OdinCodegenCtx) =
  ctx.retWrapped = false
  ctx.retInnerOdin = ""
  ctx.retInnerT = nil
  ctx.retInvName = ""

proc genFnBody(ctx: var OdinCodegenCtx, d: Decl, retTypeStr, ind: string): string =
  ## The body, with every return path accounted for: a single-expression body
  ## becomes one `return` line, and a block body gets a trailing return when
  ## the fn owes a value.
  let savedIndent = ctx.indent
  injectTailReturn(d.fnBody, retTypeStr)
  result = ctx.genOdinExpr(d.fnBody)
  if d.fnBody != nil and d.fnBody.kind != exkBlock:
    # single-expression body: `header {` is already open, so just the line
    let kw = if retTypeStr != "void": "return " else: ""
    result = ind & "\t" & kw & result
  elif retTypeStr != "void":
    result = ensureTrailingReturn(result, d.fnBody, savedIndent)
  ctx.indent = savedIndent

proc genOdinFnDecl(ctx: var OdinCodegenCtx, d: Decl): string =
  ## An ordinary fn. A pending fn is a stub and a decision table has its own
  ## lowering; both leave before any of this runs.
  if d.isPending: return ctx.genPendingStub(d)
  ctx.currentParams = @[]
  for p in d.fnParams:
    ctx.currentParams.add(FieldDef(name: p.name, typ: p.typ, span: p.span))
  if d.isDecision or d.isDecisionTable(): return ctx.genDecisionTable(d)
  let ind = "  ".repeat(ctx.indent)
  let retTypeStr = if d.fnReturnType != nil: ctx.odinType(d.fnReturnType)
                   else: "void"
  let header = ctx.fnHeader(d, retTypeStr, ind)
  let savedVars = ctx.definedVars
  for p in d.fnParams: ctx.definedVars.incl(p.name)
  ctx.enterReturnContext(d)
  let bodyStr = ctx.genFnBody(d, retTypeStr, ind)
  ctx.leaveReturnContext()
  ctx.definedVars = savedVars
  header & "\n" & bodyStr & "\n" & ind & "}\n"

# --- dkType sum-type branch helpers ---

proc genTransitionProcs(ctx: var OdinCodegenCtx, d: Decl, kindName: string,
                        hasPayload: bool): string =
  let ind = "  ".repeat(ctx.indent)
  # Names are type-qualified: Odin has no overloading or class scoping, so
  # two sum types in one package would otherwise collide.
  let canName = "canTransition_" & d.name
  var canLines: seq[string]
  canLines.add(ind & canName & " :: proc(frm: " & kindName & ", to: " &
               kindName & ") -> bool {")
  canLines.add(ind & "\tswitch frm {")
  for v in d.typeBody.variants:
    let allowed = allowedTransitions(d.typeBody, v.name)
    if allowed.len > 0:
      var conds: seq[string]
      for a in allowed: conds.add("to == ." & a)
      canLines.add(ind & "\tcase ." & v.name & ": return " & conds.join(" || "))
    else:
      canLines.add(ind & "\tcase ." & v.name & ": return false")
  canLines.add(ind & "\t}")
  canLines.add(ind & "\treturn false")
  canLines.add(ind & "}")
  var res = canLines.join("\n") & "\n"
  # A union-typed value carries its own tag, so the payload case assigns the
  # whole value rather than copying slot by slot the way the Beef class does.
  let subject = if hasPayload: "tag_" & d.name & "(self^)" else: "self^"
  let target = if hasPayload: "tag_" & d.name & "(target)" else: "target"
  res.add(ind & "transitionTo_" & d.name & " :: proc(self: ^" & d.name &
          ", target: " & d.name & ") {\n" &
          ind & "\tassert(" & canName & "(" & subject & ", " & target &
          "), \"Invalid transition\")\n" &
          ind & "\tself^ = target\n" & ind & "}\n")
  return res

proc variantTagList(d: Decl, withValues = false): string =
  ## The variant names, optionally with the explicit ordinals a C enum needs.
  var tags: seq[string]
  for v in d.typeBody.variants:
    tags.add(if withValues and v.value != "": v.name & " = " & v.value
             else: v.name)
  tags.join(", ")

proc genVariantStruct(ctx: var OdinCodegenCtx, d: Decl, v: VariantDef,
                      ind: string): string =
  ## One variant of a payload union, as its own struct.
  let vName = d.name & "_" & v.name
  if v.fields.len == 0: return ind & vName & " :: struct {}\n"
  var fieldLines: seq[string]
  for f in v.fields:
    fieldLines.add(ind & "\t" & f.name & ": " & ctx.odinType(f.typ) & ",")
  ind & vName & " :: struct {\n" & fieldLines.join("\n") & "\n" & ind & "}\n"

proc genTagProjection(d: Decl, kindName, ind: string): string =
  ## Transitions compare states, so a payload union also needs a tag enum and
  ## a projection from value to tag.
  result = ind & kindName & " :: enum { " & variantTagList(d) & " }\n"
  result.add(ind & "tag_" & d.name & " :: proc(v: " & d.name & ") -> " &
             kindName & " {\n" & ind & "\tswitch _ in v {\n")
  for v in d.typeBody.variants:
    result.add(ind & "\tcase " & d.name & "_" & v.name & ": return ." &
               v.name & "\n")
  result.add(ind & "\t}\n" & ind & "\treturn ." &
             d.typeBody.variants[0].name & "\n" & ind & "}\n")

proc genPayloadUnion(ctx: var OdinCodegenCtx, d: Decl, kindName: string,
                     hasTransitions: bool, ind: string): string =
  ## Odin has a real tagged union: each variant becomes its own struct and the
  ## union carries them directly — no hand-rolled kind enum, and
  ## `switch v in value` gets exhaustiveness from the compiler.
  var members: seq[string]
  for v in d.typeBody.variants:
    result.add(ctx.genVariantStruct(d, v, ind))
    members.add(d.name & "_" & v.name)
  result.add(ind & d.name & " :: union {" & members.join(", ") & "}\n")
  if hasTransitions:
    result.add(genTagProjection(d, kindName, ind))

proc genSumType(ctx: var OdinCodegenCtx, d: Decl): string =
  ## A sum type is a plain enum unless it carries payloads or declares
  ## transitions.
  let ind = "  ".repeat(ctx.indent)
  let hasPayload = sumHasPayload(d.typeBody)
  let hasTransitions = d.typeBody.transitions.len > 0
  if not hasPayload and not hasTransitions:
    # plain enum (also what decision tables key over)
    return ind & d.name & " :: enum { " & variantTagList(d, withValues = true) &
           " }\n"
  let kindName = if hasPayload: d.name & "Kind" else: d.name
  result = if hasPayload:
             ctx.genPayloadUnion(d, kindName, hasTransitions, ind)
           else:
             ind & d.name & " :: enum { " & variantTagList(d) & " }\n"
  if hasTransitions:
    # transition matrix: pure predicate + checked assignment
    result.add(ctx.genTransitionProcs(d, kindName, hasPayload))

proc genRecordType(ctx: var OdinCodegenCtx, d: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  var fieldsStr: seq[string]
  for f in d.typeBody.fields:
    fieldsStr.add(ind & "\t" & f.name & ": " & ctx.fieldType(d.name, f) & ",")
  let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: ""
  # Odin's parametric structs take `$T: typeid` params
  var tGenParts: seq[string]
  for g in d.generics: tGenParts.add("$" & g & ": typeid")
  let tGen = if tGenParts.len > 0: "(" & tGenParts.join(", ") & ")" else: ""
  # A fieldless extern type is an opaque C handle (`typedef struct Foo Foo;`
  # with no definition): unknown size, only ever held as a pointer.
  if d.typeExternHeader != "" and d.typeBody.fields.len == 0:
    return ind & d.name & " :: rawptr\n"
  # Tier 1 records are value types (spec §7.1) — struct, not a pointer type
  var res = ind & d.name & " :: struct" & tGen & " {\n" &
            (if fieldsBody != "": fieldsBody & "\n" else: "") & ind & "}\n"
  var invariantChecks: seq[string]
  var checkCtx = OdinCodegenCtx(definedVars: initHashSet[string](),
                                fieldVars: initHashSet[string](),
                                fieldPrefix: "self.", indent: 0,
                                module: ctx.module, realModules: ctx.realModules)
  for f in d.typeBody.fields:
    checkCtx.fieldVars.incl(f.name)
  for member in d.typeMembers:
    if member.kind == dkExpr:
      let condStr = checkCtx.genOdinExpr(member.expr)
      invariantChecks.add(ind & "\tassert(" & condStr & ")")
  if invariantChecks.len > 0:
    # Odin has no overloading, so these are type-qualified rather than
    # relying on the parameter type to disambiguate the way Beef does.
    res.add(ind & "validate_" & d.name & " :: proc(self: " & d.name & ") {\n" &
            invariantChecks.join("\n") & "\n" & ind & "}\n")
    # production sites wrap construction/returns in __validated_T(...)
    res.add(ind & "__validated_" & d.name & " :: proc(v: " & d.name & ") -> " &
            d.name & " {\n" & ind & "\tvalidate_" & d.name & "(v)\n" &
            ind & "\treturn v\n" & ind & "}\n")
  # manager types carry functionality: member fns join the catalog
  for member in d.typeMembers:
    if member.kind == dkFn:
      res.add("\n" & ctx.genOdinDecl(member) & "\n")
  return res

proc genAliasType(ctx: var OdinCodegenCtx, d: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  let typeBodyStr = ctx.odinType(d.typeBody)
  if isDistinctAlias(d.typeBody):
    # Odin has `distinct` natively: same bits, incompatible type, and
    # arithmetic/comparison already work on the distinct type. No wrapper
    # struct or operator overloads needed (the Beef backend hand-rolls both).
    return ind & d.name & " :: distinct " & typeBodyStr & "\n"
  var aGenParts: seq[string]
  for g in d.generics: aGenParts.add("$" & g & ": typeid")
  let aGen = if aGenParts.len > 0: "(" & aGenParts.join(", ") & ")" else: ""
  return ind & d.name & " :: " & (if aGen != "": "struct" & aGen & " { " &
         "using _: " & typeBodyStr & " }" else: typeBodyStr) & "\n"

const DefaultMailboxSize = "8"
  ## Messages an actor's ring holds unless `[queue: N]` says otherwise.

proc msgVariantName(handlerName: string): string =
  ## The message-enum tag a handler receives on.
  "msg" & handlerName.capitalize()

proc mailboxSize(d: Decl): string =
  for attr in d.attrs:
    if attr.name == "queue": return attr.value
  DefaultMailboxSize

proc actorFieldLines(ctx: var OdinCodegenCtx, d: Decl): seq[string] =
  let ind = "  ".repeat(ctx.indent)
  for f in d.actorFields:
    result.add(ind & "\t" & f.name & ": " & ctx.fieldType(d.name, f) & ",")

proc genInertActor(ctx: var OdinCodegenCtx, d: Decl, ind: string): string =
  ## No message handlers: an empty enum is invalid. Emit the state, its
  ## singleton, and a drain that just parks — the entry point starts every
  ## declared actor, so the drain has to exist even with nothing to receive.
  let fields = ctx.actorFieldLines(d)
  let body = if fields.len > 0: fields.join("\n") & "\n" else: ""
  ind & d.name & " :: struct {\n" & body & ind & "}\n\n" &
    ind & actorSingletonName(d.name) & ": " & d.name & "\n\n" &
    ind & "drain_" & d.name & " :: proc() {\n" &
    ind & "\tfor { rt.coroYield() }\n" & ind & "}\n"

proc genMsgEnvelope(ctx: var OdinCodegenCtx, d: Decl, handlers: seq[ActorMsgHandler],
                    variants: seq[string], ind: string): string =
  ## The message enum and the envelope struct. Handler params ride in the
  ## envelope, deduped by name.
  var msgFields: seq[string]
  var seen = initHashSet[string]()
  for h in handlers:
    for p in h.params:
      if p.name in seen: continue
      seen.incl(p.name)
      msgFields.add(ind & "\t" & p.name & ": " & ctx.odinType(p.typ) & ",")
  ind & d.name & "MsgKind :: enum { " & variants.join(", ") & " }\n" &
    ind & d.name & "Msg :: struct {\n" &
    ind & "\tkind: " & d.name & "MsgKind,\n" &
    (if msgFields.len > 0: msgFields.join("\n") & "\n" else: "") &
    ind & "}\n"

proc genActorState(ctx: var OdinCodegenCtx, d: Decl, hasShutdown: bool,
                   ind: string): string =
  ## The actor's state struct: its own fields, its mailbox, and — when it can
  ## be shut down — the flag the drain checks.
  var fields = ctx.actorFieldLines(d)
  fields.add(ind & "\tmailbox: rt.Mailbox(" & d.name & "Msg, " &
             mailboxSize(d) & "),")
  if hasShutdown:
    fields.add(ind & "\tfinished: bool,")
  ind & d.name & " :: struct {\n" & fields.join("\n") & "\n" & ind & "}\n\n"

proc newHandlerCtx(ctx: OdinCodegenCtx, d: Decl): OdinCodegenCtx =
  ## Odin has no methods, so the actor rides as a `self` pointer and field
  ## access inside a handler goes through it.
  result = OdinCodegenCtx(definedVars: initHashSet[string](),
                          fieldVars: initHashSet[string](),
                          fieldPrefix: "self.", indent: ctx.indent + 1,
                          module: ctx.module, realModules: ctx.realModules,
                          errPolicy: ctx.errPolicy)
  for f in d.actorFields:
    result.fieldVars.incl(f.name)

proc adoptHandlerCtx(ctx: var OdinCodegenCtx, hctx: OdinCodegenCtx) =
  ## Anything the handler bodies hoisted belongs to the enclosing file.
  for h in hctx.hoisted:
    if h notin ctx.hoisted: ctx.hoisted.add(h)
  for sig, name in hctx.recShapes:
    if sig notin ctx.recShapes: ctx.recShapes[sig] = name

proc genHandlerCase(hctx: var OdinCodegenCtx, h: ActorMsgHandler, ind: string): string =
  ## One dispatch arm: unpack the envelope's fields, then run the body.
  var unpack = ""
  for p in h.params:
    hctx.definedVars.incl(p.name)
    unpack.add(ind & "\t\t" & p.name & " := msg." & p.name & "\n")
  ind & "\tcase ." & msgVariantName(h.name) & ":\n" & unpack &
    hctx.genOdinExpr(h.body)

proc genDispatch(ctx: var OdinCodegenCtx, d: Decl, handlers: seq[ActorMsgHandler],
                 shutdownBody: Expr, hasShutdown: bool, ind: string): string =
  ## The switch that routes an envelope to its handler.
  var hctx = ctx.newHandlerCtx(d)
  var cases: seq[string]
  for h in handlers:
    cases.add(hctx.genHandlerCase(h, ind))
  if hasShutdown:
    # Stops the actor rather than adding a message: run the arm's body, then
    # set the flag the drain checks.
    let sdBody = if shutdownBody != nil: hctx.genOdinExpr(shutdownBody) & "\n"
                 else: ""
    cases.add(ind & "\tcase .msgShutdown:\n" & sdBody &
              ind & "\t\tself.finished = true")
  ctx.adoptHandlerCtx(hctx)
  ind & "handleMsg_" & d.name & " :: proc(self: ^" & d.name & ", msg: " &
    d.name & "Msg) {\n" & ind & "\tswitch msg.kind {\n" & cases.join("\n") &
    "\n" & ind & "\t}\n" & ind & "}\n"

proc genDrain(d: Decl, hasShutdown: bool, ind: string): string =
  ## The actor's coroutine body. Parks when the mailbox empties;
  ## tuckNotifySend wakes it after a send.
  let singleton = actorSingletonName(d.name)
  let finishedGuard = if hasShutdown:
                        ind & "\t\tif " & singleton & ".finished { return }\n"
                      else: ""
  "\n" & ind & "drain_" & d.name & " :: proc() {\n" &
    ind & "\tfor {\n" & finishedGuard &
    ind & "\t\tmsg: " & d.name & "Msg\n" &
    ind & "\t\tfor rt.dequeue(&" & singleton & ".mailbox, &msg) {\n" &
    ind & "\t\t\thandleMsg_" & d.name & "(&" & singleton & ", msg)\n" &
    ind & "\t\t}\n" & ind & "\t\trt.coroYield()\n" &
    ind & "\t}\n" & ind & "}\n"

proc genSendHelper(ctx: var OdinCodegenCtx, d: Decl, h: ActorMsgHandler,
                   ind: string): string =
  ## Enqueue an envelope; a full ring drops (spec §9.1).
  var params: seq[string]
  var ctorArgs = "kind = ." & msgVariantName(h.name)
  for p in h.params:
    params.add(p.name & ": " & ctx.odinType(p.typ))
    ctorArgs.add(", " & p.name & " = " & p.name)
  let sep = if params.len > 0: ", " else: ""
  "\n" & ind & "send" & h.name.capitalize() & "_" & d.name & " :: proc(self: ^" &
    d.name & sep & params.join(", ") & ") {\n" &
    ind & "\t_ = rt.enqueue(&self.mailbox, " & d.name & "Msg{" & ctorArgs &
    "})\n" & ind & "}\n"

proc genShutdownSender(d: Decl, ind: string): string =
  "\n" & ind & "sendShutdown_" & d.name & " :: proc(self: ^" & d.name &
    ") {\n" & ind & "\t_ = rt.enqueue(&self.mailbox, " & d.name &
    "Msg{kind = .msgShutdown})\n" & ind & "}\n"

proc genActor(ctx: var OdinCodegenCtx, d: Decl): string =
  ## An actor emits its message envelope, state struct, singleton, dispatch,
  ## drain loop and one send helper per handler.
  ##
  ## BOTH forms declare a message: `on add({n: int})` and an
  ## `| add -> {n: int}` select arm. Walking only dkFn made every `on select`
  ## actor take the no-handler path, which emits no enum, no mailbox and no
  ## send procs — while the send SITES still called them, so the package did
  ## not compile.
  let ind = "  ".repeat(ctx.indent)
  let (handlers, shutdownBody, hasShutdown) = collectHandlers(d)
  var variants: seq[string]
  for h in handlers: variants.add(msgVariantName(h.name))
  if hasShutdown:
    variants.add("msgShutdown")   # sent as `Actor send shutdown {}`
  if variants.len == 0:
    return ctx.genInertActor(d, ind)
  result = ctx.genMsgEnvelope(d, handlers, variants, ind)
  result.add(ctx.genActorState(d, hasShutdown, ind))
  # One instance per declared actor (spec §9.1); sends and field reads target
  # it, so `Counter.total` means `counterSingleton.total`.
  result.add(ind & actorSingletonName(d.name) & ": " & d.name & "\n\n")
  result.add(ctx.genDispatch(d, handlers, shutdownBody, hasShutdown, ind))
  result.add(genDrain(d, hasShutdown, ind))
  for h in handlers:
    result.add(ctx.genSendHelper(d, h, ind))
  if hasShutdown:
    result.add(genShutdownSender(d, ind))

proc registryEventStruct(ctx: var OdinCodegenCtx, d: Decl, ind: string): string =
  ## The event enum and the flat struct carrying every variant's fields,
  ## deduped by name.
  var variants: seq[string]
  var fields: seq[string]
  var seen = initHashSet[string]()
  for v in d.variants:
    variants.add(v.name)
    for f in v.fields:
      if f.name in seen: continue
      seen.incl(f.name)
      fields.add(ind & "\t" & f.name & ": " & ctx.odinType(f.typ) & ",")
  let fieldsBody = if fields.len > 0: fields.join("\n") & "\n" else: ""
  ind & d.name & "Kind :: enum { " & variants.join(", ") & " }\n" &
    ind & d.name & " :: struct {\n" &
    ind & "\tkind: " & d.name & "Kind,\n" & fieldsBody & ind & "}\n"

proc registryHandlerCalls(ctx: OdinCodegenCtx, d: Decl, v: VariantDef,
                          ind: string): string =
  ## Every declared handler for this event, called with the event's fields.
  let handlerName = d.name & "." & v.name
  var calls: seq[string]
  for decl in ctx.module.decls:
    if decl.kind != dkFn or decl.name != handlerName: continue
    var argNames: seq[string]
    for f in v.fields: argNames.add(f.name)
    calls.add(ind & "\t" & d.name & "_" & v.name & "(" & argNames.join(", ") & ")")
  if calls.len > 0: calls.join("\n") & "\n" else: ""

proc registryRaiseProc(ctx: var OdinCodegenCtx, d: Decl, v: VariantDef,
                       ind: string): string =
  ## `raise_<Registry>_<Event>` — record the event as latest, then run its
  ## handlers.
  var params: seq[string]
  var assigns: seq[string]
  for f in v.fields:
    params.add(f.name & ": " & ctx.odinType(f.typ))
    assigns.add(f.name & " = " & f.name)
  let assignStr = if assigns.len > 0: ", " & assigns.join(", ") else: ""
  ind & "raise_" & d.name & "_" & v.name & " :: proc(" & params.join(", ") &
    ") {\n" & ind & "\tlatest" & d.name & " = " & d.name & "{kind = ." &
    v.name & assignStr & "}\n" & ctx.registryHandlerCalls(d, v, ind) &
    ind & "}\n\n"

proc genRegistry(ctx: var OdinCodegenCtx, d: Decl): string =
  ## An event registry: the event type, the latest-event global, and one
  ## raise proc per event.
  ##
  ## Odin resolves package-level declaration order lazily, so the raise procs
  ## may call handlers declared after them — no forward decls needed.
  let ind = "  ".repeat(ctx.indent)
  result = ctx.registryEventStruct(d, ind) & "\n"
  result.add(ind & "latest" & d.name & ": " & d.name & "\n\n")
  for v in d.variants:
    result.add(ctx.registryRaiseProc(d, v, ind))

# rt-implemented extern of a library module: forward to the Odin runtime,
# converting the runtime's record shapes to this module's hoisted shapes.
proc forwarderParamType(ctx: var OdinCodegenCtx, p: Param, mem: Decl): string =
  ## A bare `fn` param on an extern (std/scheduler's `waitUntil {pred: fn}`)
  ## is a PREDICATE the runtime calls, so it needs a callable proc type —
  ## `rawptr` would not convert at the rt boundary.
  ##
  ## Odin marks a polymorphic param at the DECLARATION site: `value: $T`, not
  ## `value: T`. Without the sigil T is an undeclared name, so any generic
  ## extern forwarder (std/str's toStr) failed to compile.
  let named = p.typ != nil and p.typ.kind == tkNamed
  if named and p.typ.name == "fn": return "proc() -> bool"
  result = ctx.odinType(p.typ)
  if named and p.typ.name in mem.fnGenerics: result = "$" & result

proc recordFromFields(ctx: var OdinCodegenCtx, fields: seq[FieldDef],
                      source: string): string =
  ## Rebuild a record from `source`'s same-named fields — the runtime's shape
  ## and this module's hoisted shape agree on names, not on identity.
  var args: seq[string]
  for f in fields: args.add(f.name & " = " & source & "." & f.name)
  recStructName(ctx, fields) & "{" & args.join(", ") & "}"

proc forwardWrappedRecord(ctx: var OdinCodegenCtx, innerT: Type,
                          callStr, retTypeStr, ind: string): string =
  ## Convert TuckResult(RuntimeShape) -> TuckResult(ModuleShape) field by field.
  ind & "\tr := " & callStr & "\n" &
    ind & "\tres: " & retTypeStr & "\n" &
    ind & "\tres.status = r.status\n" &
    ind & "\tres.err = r.err\n" &
    ind & "\tif r.status == .Ok {\n" &
    ind & "\t\tres.value = " & ctx.recordFromFields(innerT.fields, "r.value") &
    "\n" & ind & "\t}\n" & ind & "\treturn res\n"

proc forwardRecord(ctx: var OdinCodegenCtx, retT: Type,
                   callStr, ind: string): string =
  ## Plain record return: the runtime returns the single raw value, whose
  ## fields carry the same names as this module's hoisted shape.
  ind & "\traw := " & callStr & "\n" &
    ind & "\treturn " & ctx.recordFromFields(retT.fields, "raw") & "\n"

proc implAlias(module: string): string =
  ## Package alias for an `impl: odin "..."` spec. Odin import paths use both
  ## ':' (collection separator, "core:strings") and '/' (subdirectories), and
  ## the last segment is the package name: "core:strings" -> strings,
  ## "./tuckrt/zlib_shim" -> zlib_shim.
  result = module
  if ':' in result: result = result.rsplit(':', 1)[^1]
  if '/' in result: result = result.rsplit('/', 1)[^1]

proc genRtForwarder(ctx: var OdinCodegenCtx, mem: Decl, alias = "rt"): string =
  ## `alias` is the package the bodies live in: the runtime (`rt`) by default,
  ## or an `impl: odin "..."` package. Only the call prefix differs — the shape
  ## conversions below are the same either way, so they are not duplicated.
  let ind = "  ".repeat(ctx.indent)
  var params: seq[string]
  var argNames: seq[string]
  for p in mem.fnParams:
    params.add(p.name & ": " & ctx.forwarderParamType(p, mem))
    argNames.add(p.name)
  let callStr = alias & "." & mem.name & "(" & argNames.join(", ") & ")"
  let (bw, _, binnerT) = ctx.odinBangInfo(mem.fnReturnType)
  let retTypeStr = if mem.fnReturnType != nil: ctx.odinType(mem.fnReturnType)
                   else: "void"
  let retStr = if retTypeStr != "void": " -> " & retTypeStr else: ""
  let header = ind & mem.name & " :: proc(" & params.join(", ") & ")" &
               retStr & " {\n"
  let body =
    if bw and binnerT != nil and binnerT.kind == tkRecord:
      ctx.forwardWrappedRecord(binnerT, callStr, retTypeStr, ind)
    elif mem.fnReturnType != nil and mem.fnReturnType.kind == tkRecord:
      ctx.forwardRecord(mem.fnReturnType, callStr, ind)
    elif retTypeStr == "void":
      ind & "\t" & callStr & "\n"
    else:
      ind & "\treturn " & callStr & "\n"
  header & body & ind & "}\n"

proc genObjectDecl(ctx: var OdinCodegenCtx, d: Decl, ind: string): string =
  ## A manager object: fields become an Odin struct, members and anything
  ## composed into it come back as package-level procs.
  var fields: seq[string]
  for f in d.objFields:
    fields.add(ind & "\t" & f.name & ": " & ctx.fieldType(d.name, f) & ",")
  var members = ""
  for member in d.objMembers:
    # lowering.composeObject has already merged every RESOLVED `+ X`. What
    # can still reach here is one that named nothing declared — a sketch.
    if isCompositionEntry(member):
      members.add(ind & "// + " & member.expr.operand.name &
                  " (undeclared — sketch)\n")
    elif member.kind == dkFn:
      members.add(ctx.genOdinMemberFn(member, d.name) & "\n")
    else:
      members.add(ctx.genOdinDecl(member) & "\n")
  let body = if fields.len > 0: fields.join("\n") & "\n" else: ""
  # manager objects hold var state but are Tier 1 value types too
  ind & d.name & " :: struct {\n" & body & ind & "}\n\n" & members

proc genTaskDecl(ctx: var OdinCodegenCtx, d: Decl, ind: string): string =
  ## ponytail: a task emits as a plain proc and runs INLINE, so suspension
  ## points do not suspend. The coroutine runtime itself is real and wired
  ## (tuckrt/tuck_coro.odin over minicoro — 28-async-task exits 42 and
  ## 26-actor-run drains its mailbox to 55); what is missing is spawning the
  ## task body ONTO it. Anything relying on a yield behaves synchronously.
  ctx.currentParams = @[]
  var params: seq[string]
  for p in d.taskParams:
    ctx.currentParams.add(FieldDef(name: p.name, typ: p.typ, span: p.span))
    params.add(p.name & ": " & ctx.odinType(p.typ))
  let retTypeStr =
    if d.taskReturnType != nil: ctx.odinType(d.taskReturnType) else: "void"
  let retStr = if retTypeStr != "void": " -> " & retTypeStr else: ""
  let header = ind & d.name & " :: proc(" & params.join(", ") & ")" &
               retStr & " {"
  let oldVars = ctx.definedVars
  for p in d.taskParams: ctx.definedVars.incl(p.name)
  let oldIndent = ctx.indent
  (ctx.retWrapped, ctx.retInnerOdin, ctx.retInnerT) =
    ctx.odinBangInfo(d.taskReturnType)
  injectTailReturn(d.taskBody, retTypeStr)
  var bodyStr = ctx.genOdinExpr(d.taskBody)
  if d.taskBody != nil and d.taskBody.kind != exkBlock:
    let kw = if retTypeStr != "void": "return " else: ""
    bodyStr = ind & "\t" & kw & bodyStr
  elif retTypeStr != "void":
    bodyStr = ensureTrailingReturn(bodyStr, d.taskBody, oldIndent)
  ctx.indent = oldIndent
  ctx.retWrapped = false
  ctx.retInnerOdin = ""
  ctx.retInnerT = nil
  ctx.definedVars = oldVars
  header & "\n" & bodyStr & "\n" & ind & "}\n"

proc isBlank(code: string): bool =
  ## Does this emitted body amount to nothing? A handler whose body generated
  ## only whitespace or an empty block adds no statements.
  for c in code:
    if c notin {' ', '\n', '\t', '{', '}'}: return false
  true

proc genErrHandlerBody(ctx: var OdinCodegenCtx, handler: Decl): string =
  ## The user's handler body, with `code` and `site` in scope as its params.
  let savedVars = ctx.definedVars
  ctx.definedVars.incl("code")
  ctx.definedVars.incl("site")
  result = ctx.genIndented(handler.fnBody)
  ctx.definedVars = savedVars
  if isBlank(result): result = ""

proc genErrHandler(ctx: var OdinCodegenCtx, d: Decl, ind: string): string =
  ## Global handler: rt logger first (errors are always visible), then the
  ## user's handler body.
  result = ind & "tuck_unhandled :: proc(code: u16, site: string) {\n" &
           ind & "\trt.tuckReportUnhandled(code, site)\n"
  if d.errHandler != nil and d.errHandler.fnBody != nil:
    let body = ctx.genErrHandlerBody(d.errHandler)
    if body != "": result.add(body & "\n")
  result.add(ind & "}\n")


proc genCBinding(ctx: var OdinCodegenCtx, m: Decl): string =
  ## One `foreign` entry. `-> ret` is omitted entirely for void; "void" is
  ## Tuck's internal sentinel, not an Odin type. [emit: "c_name"] names the
  ## real C symbol; else the Tuck name — externs are not mangled
  ## (mangle.nim:48), so m.name IS the foreign symbol.
  var params: seq[string]
  for prm in m.fnParams:
    params.add(prm.name & ": " & ctx.odinType(prm.typ))
  let retT = if m.fnReturnType != nil: ctx.odinType(m.fnReturnType) else: "void"
  let retStr = if retT == "void": "" else: " -> " & retT
  let cName = if m.externEmit != "": m.externEmit else: m.name
  "\t" & cName & " :: proc(" & params.join(", ") & ")" & retStr & " ---"

proc genImplForwarders(ctx: var OdinCodegenCtx, m: Decl): string =
  ## `impl: odin "..."` — the bodies live in a named Odin package rather than
  ## the runtime. Odin has no unqualified import, so a bare call to the
  ## extern's name can never resolve; emit a local forwarder into the aliased
  ## package instead, which keeps call sites identical to Nim's.
  ##
  ## An `impl:` naming only `nim` leaves nothing to emit here: that block is
  ## Nim-backend-only and Odin fails at the undeclared call, which is the
  ## honest outcome.
  for (backend, module) in m.externImpl:
    if backend != "odin": continue
    let alias = implAlias(module)
    ctx.implMods[alias] = module
    result.add(ctx.genRtForwarder(m, alias) & "\n")

proc foreignLibAlias(cLib: string): string =
  ## A path (vendored `.a`) cannot double as the Odin alias, so the alias is
  ## derived from the file stem and the path rides along as the import spec.
  ## ".../libpoint.a" -> "point".
  if cLib == "": return "c"
  if '/' notin cLib and '.' notin cLib: return cLib
  var stem = cLib.rsplit('/', 1)[^1]
  if stem.startsWith("lib"): stem = stem[3 .. ^1]
  stem.rsplit('.', 1)[0]

proc genForeignBlock(ctx: var OdinCodegenCtx, bindings: seq[string],
                     cLib: string): string =
  ## `foreign import <alias> "<spec>"` — mirrors tuck_coro.odin's minicoro.a.
  ## The import line itself is hoisted to the file header by emitOdin, since
  ## it is only legal at package top level.
  let libAlias = foreignLibAlias(cLib)
  ctx.foreignLibs[libAlias] = cLib
  "@(default_calling_convention=\"c\")\n" &
    "foreign " & libAlias & " {\n" & bindings.join("\n") & "\n}\n"

proc genMixinMember(ctx: var OdinCodegenCtx, m: Decl, cBindings: var seq[string],
                    cLib: var string): string =
  ## One member of a mixin/extern/pending block. A C binding is collected
  ## rather than emitted, because Odin wants ONE `foreign <lib> { ... }` block
  ## rather than a pragma per proc the way Nim's importc works.
  if m.kind in {dkType, dkFnSig}:
    # a C struct or callback signature declared in the extern block. Odin needs
    # no pragma for the struct: it never sees the C header, it links object
    # code, so a plain struct with matching fields IS the ABI declaration. The
    # callback does need `proc "c"` — see genOdinDecl.
    return ctx.genOdinDecl(m) & "\n"
  if m.kind != dkFn: return ""
  if m.isPending: return ctx.genPendingStub(m) & "\n"
  if not m.isExtern:
    # interface contract (sig only): nothing to emit
    if m.fnBody == nil or takesSelf(m): return ""
    # a mixin is a named bucket of functions (spec 5.1) — emit them
    return ctx.genOdinDecl(m) & "\n"
  if m.externHeader != "":
    cBindings.add(ctx.genCBinding(m))
    if m.externLib != "": cLib = m.externLib
    return ""
  if m.externImpl.len > 0: return ctx.genImplForwarders(m)
  # rt-implemented (no header, no impl): forward to the runtime. Used to be
  # gated on modPrefix != "" — a library module needs the forwarder so a
  # CROSS-module caller has something to qualify (`console.printLine`
  # reaches a real proc); the entry module was assumed never to declare its
  # own rt-implemented extern, since std/* modules normally carry those.
  # Examples 29/30 declare one directly (`openSource`, a demo async source)
  # and broke that assumption: with no forwarder, the entry module's own
  # bare call to it names nothing Odin has ever declared. The forwarder is
  # harmless here too — a plain top-level proc in package main, same as any
  # other top-level fn.
  ctx.genRtForwarder(m) & "\n"

proc genMixinBlock(ctx: var OdinCodegenCtx, d: Decl): string =
  ## Pending blocks parse as a mixin named "pending"; emit stubs for members.
  ## Extern blocks: rt-implemented fns forward to the Odin runtime (library
  ## modules) or emit nothing (entry module); C-imported fns become an Odin
  ## `foreign` block with concrete param types.
  var cBindings: seq[string]
  var cLib = ""
  for m in d.mixinMembers:
    result.add(ctx.genMixinMember(m, cBindings, cLib))
  if cBindings.len > 0:
    result.add(ctx.genForeignBlock(cBindings, cLib))

type
  BitField = object
    ## One `bit N` / `bits LO..HI` field of a memory-mapped register, decoded
    ## from its declared type and attributes.
    prefix: string    # <register>_<field>, the name every emitted symbol shares
    loBit, hiBit: string
    isRange: bool     # a multi-bit field, not a single flag
    canRead, canWrite: bool

proc decodeBitField(regName: string, f: FieldDef): BitField =
  ## `bits 3..7` is a multi-bit FIELD: shift by the low bit and mask the width.
  ## A single `bit N` is the one-bit case of the same shape.
  let bitVal = f.typ.name.replace("bit ", "").replace("bits ", "")
  let dotPos = bitVal.find("..")
  result.loBit = if dotPos >= 0: bitVal[0 ..< dotPos].strip() else: bitVal
  result.hiBit = if dotPos >= 0: bitVal[dotPos + 2 .. ^1].strip() else: bitVal
  result.isRange = dotPos >= 0 and result.loBit != result.hiBit
  result.prefix = regName & "_" & f.name
  var hasRead, hasWrite = false
  for a in f.attrs:
    if a.name == "read": hasRead = true
    elif a.name == "write": hasWrite = true
  # An unmarked field is readable AND writable; marking one direction opts out
  # of the other.
  result.canRead = hasRead or not hasWrite
  result.canWrite = hasWrite or not hasRead

proc bitConsts(bf: BitField, ind: string): seq[string] =
  ## The shift, and for a range the width and mask.
  result.add(ind & bf.prefix & "_SHIFT :: " & bf.loBit)
  if bf.isRange:
    result.add(ind & bf.prefix & "_WIDTH :: " & bf.hiBit & " - " & bf.loBit &
               " + 1")
    result.add(ind & bf.prefix & "_MASK :: u32(1 << u32(" & bf.prefix &
               "_WIDTH)) - 1")

proc bitGetter(bf: BitField, regName, ind: string): string =
  ## A range reads as a masked u32; a single bit reads as a bool.
  let body = if bf.isRange:
               "return (" & regName & "^ >> u32(" & bf.prefix & "_SHIFT)) & " &
                 bf.prefix & "_MASK"
             else:
               "return (" & regName & "^ & (u32(1) << u32(" & bf.prefix &
                 "_SHIFT))) != 0"
  let retT = if bf.isRange: "u32" else: "bool"
  ind & bf.prefix & "_get :: proc() -> " & retT & " {\n" &
    ind & "\t" & body & "\n" & ind & "}\n"

proc bitSetter(bf: BitField, regName, ind: string): string =
  ## A range clears its mask before OR-ing the shifted value in; a single bit
  ## sets or clears one mask.
  if bf.isRange:
    return ind & bf.prefix & "_set :: proc(value: u32) {\n" &
           ind & "\tshifted := (value & " & bf.prefix & "_MASK) << u32(" &
             bf.prefix & "_SHIFT)\n" &
           ind & "\t" & regName & "^ = (" & regName & "^ &~ (" & bf.prefix &
             "_MASK << u32(" & bf.prefix & "_SHIFT))) | shifted\n" &
           ind & "}\n"
  ind & bf.prefix & "_set :: proc(on: bool) {\n" &
    ind & "\tmask := u32(1) << u32(" & bf.prefix & "_SHIFT)\n" &
    ind & "\tif on { " & regName & "^ |= mask } else { " & regName &
      "^ &~= mask }\n" & ind & "}\n"

proc genRegister(ctx: OdinCodegenCtx, d: Decl, ind: string): string =
  ## Memory-mapped register. Nim emits a `registerMMIO` macro call and Beef an
  ## attribute; Odin has neither, so the bits become named masks plus a typed
  ## pointer at the MMIO address — the accessors read/write through it.
  var consts: seq[string]
  var accessors: seq[string]
  for f in d.regFields:
    let bf = decodeBitField(d.name, f)
    consts.add(bitConsts(bf, ind))
    if bf.canRead: accessors.add(bitGetter(bf, d.name, ind))
    if bf.canWrite: accessors.add(bitSetter(bf, d.name, ind))
  ind & d.name & " := cast(^u32)(uintptr(" & d.regAddress & "))\n" &
    consts.join("\n") & "\n" & accessors.join("")

proc genOdinDecl*(ctx: var OdinCodegenCtx, d: Decl): string =
  if d == nil: return ""
  if d.kind == dkType and d.span.file.startsWith(ImportedTypeMarker):
    return ""  # defined in its own module; that module's Odin file has it
  let ind = "  ".repeat(ctx.indent)
  case d.kind
  of dkFn:
    return ctx.genOdinFnDecl(d)
  of dkType:
    if d.typeBody != nil:
      if d.typeBody.kind == tkSum:
        return ctx.genSumType(d)
      elif d.typeBody.kind == tkRecord:
        return ctx.genRecordType(d)
      else:
        return ctx.genAliasType(d)
    return ""
  of dkObject:
    return ctx.genObjectDecl(d, ind)
  of dkActor:
    return ctx.genActor(d)
  of dkTask:
    return ctx.genTaskDecl(d, ind)
  of dkConst:
    # A literal is a true compile-time constant (`::`); structured data
    # becomes a package-level var, still one-time and immutable in intent.
    if d.constVal != nil and d.constVal.kind == exkLit:
      return ind & d.name & " :: " & ctx.genOdinExpr(d.constVal)
    return ind & d.name & " := " & ctx.genOdinExpr(d.constVal)
  of dkExpr:
    return ctx.genOdinExpr(d.expr)
  of dkRegister: ctx.genRegister(d, ind)
  of dkRegistry:
    return ctx.genRegistry(d)
  of dkImport:
    return ""  # emitOdin has no import lines; same project, same namespace
  of dkStaticAssert:
    ctx.staticAsserts.add(ctx.genOdinExpr(d.assertExpr))
    return ""
  of dkErrors: ctx.genErrHandler(d, ind)
  of dkMixin, dkExtern, dkPending: ctx.genMixinBlock(d)
  of dkPool:
    # spec 7.2: one package-level instance; acquire/release are the runtime's
    # generic procs, reached as `Pool.acquire` -> `rt.acquire(&Pool)`.
    # The Beef backend has no arm for this — parity is with codegen.nim.
    return ind & d.name & ": rt.ObjectPool(" & ctx.odinType(d.poolElem) &
           ", " & $d.poolCount & ")\n"
  of dkFnSig:
    # `fnsig NAME = {params} -> ret` → a named Odin proc type, used for
    # callback slots. The Beef backend has no arm for this at all.
    var params: seq[string]
    for prm in d.sigParams:
      params.add(prm.name & ": " & ctx.odinType(prm.typ))
    let retStr =
      if d.sigReturn != nil and not (d.sigReturn.kind == tkNamed and
                                     d.sigReturn.name == "void"):
        " -> " & ctx.odinType(d.sigReturn)
      else: ""
    # A C callback is a bare function pointer using the C calling convention:
    # `proc "c" (...)`. Odin's default convention differs, so passing a plain
    # proc to a C function pointer would be an ABI mismatch.
    let conv = if d.sigIsCCallback: "\"c\" " else: ""
    return ind & d.name & " :: proc " & conv & "(" & params.join(", ") & ")" &
           retStr & "\n"
  of dkInterface:
    # A VARIANT over the satisfying types, copied in — mirrors the Nim backend
    # (spec §5.3). Odin's tagged union does what Nim's case-object does: the
    # payload is the object itself, so the value owns its data and there is no
    # lifetime question.
    let sats = ctx.satisfiersOf(d.name)
    if sats.len == 0:
      return ind & "// interface " & d.name & ": no satisfying types\n"
    var tags: seq[string]
    var fields: seq[string]
    for st in sats:
      tags.add(d.name & "_is_" & st.name)
      fields.add(ind & "\t" & st.name & "Val: " & st.name & ",")
    result = ind & d.name & "Tag :: enum { " & tags.join(", ") & " }\n\n"
    result.add(ind & d.name & " :: struct {\n" &
               ind & "\ttag: " & d.name & "Tag,\n" &
               fields.join("\n") & "\n" & ind & "}\n")
    return result
  else:
    return ""

# Shared emission core: hoisted decls + members inside one Beef type.
proc emitBody(ctx: var OdinCodegenCtx, m: Module): tuple[types, mains: string] =
  var body = ""
  var mainStmts: seq[string]
  for d in m.decls:
    if d != nil and d.kind == dkExpr:
      let oldIndent = ctx.indent
      ctx.indent = 2
      var stmtCode = ctx.genOdinExpr(d.expr)
      ctx.indent = oldIndent
      if stmtCode != "":
        if d.expr != nil and d.expr.kind in {exkIf, exkFor, exkWhile, exkBlock}:
          mainStmts.add(stmtCode)
        else:
          mainStmts.add("        " & stmtCode & ";")
    else:
      let code = ctx.genOdinDecl(d)
      if code != "":
        body.add(code & "\n")
  (body, mainStmts.join("\n"))

# Odin errors on unused imports, so the header is assembled from what the
# body actually referenced rather than emitted wholesale.
const odinPackage = "package main\n\n"

proc newOdinCtx(m: Module, realModules: Table[string, Module],
                moduleName: string, modPrefix = ""): OdinCodegenCtx =
  ## indent 0: Odin declarations are top-level in a package, with no enclosing
  ## class the way Beef/C# needed one.
  result = OdinCodegenCtx(definedVars: initHashSet[string](),
                          fieldVars: initHashSet[string](),
                          fieldPrefix: "self.", indent: 0, module: m,
                          realModules: realModules, moduleName: moduleName,
                          modPrefix: modPrefix)
  for d in m.decls:
    if d != nil and d.kind == dkErrors:
      result.errPolicy = d.policyName

proc mainDecl(m: Module): Decl =
  ## The program's entry fn, if it has one.
  let tuckMain = mangleName("main")
  for d in m.decls:
    if d != nil and d.kind == dkFn and d.name == tuckMain and not d.isPending:
      return d
  nil

proc runtimeUsers(m: Module, actorNames: var seq[string],
                  hasTasks: var bool) =
  ## Which declarations make the program need the scheduler.
  for d in m.decls:
    if d == nil: continue
    if d.kind == dkActor: actorNames.add(d.name)
    elif d.kind == dkTask: hasTasks = true

proc odinImports(ctx: OdinCodegenCtx, m: Module, body, mains: string,
                 realModules: Table[string, Module]): seq[string] =
  ## Only import what the emitted body actually uses — Odin rejects unused
  ## imports, so an unconditional header would fail to compile on any program
  ## that happens not to touch the runtime.
  ##
  ## The runtime boot emits rt.* calls of its own, so the decision reads the
  ## DECLARATIONS too, not just the already-emitted body.
  var actorNames: seq[string]
  var hasTasks = false
  runtimeUsers(m, actorNames, hasTasks)
  let mainFn = mainDecl(m)
  if "fmt." in body or "fmt." in mains:
    result.add("import \"core:fmt\"")
  # a value-returning main exits through os.exit
  if (mainFn != nil and mainFn.returnsValue) or "os." in body:
    result.add("import \"core:os\"")
  if actorNames.len > 0 or hasTasks or "rt." in body or "rt." in mains:
    result.add("import rt \"./tuckrt\"")
  # Imported Tuck modules are sibling packages (mod_<name>/), referenced
  # qualified as `<name>.fn` — import each one the body actually calls. The
  # alias keeps the Tuck name even when it shadows an Odin core package (a
  # module called `io` is fine as long as core:io isn't also imported).
  for modName in realModules.keys:
    let pkg = modName.replace("-", "_")
    if (pkg & ".") in body or (pkg & ".") in mains:
      result.add("import " & pkg & " \"./mod_" & pkg & "\"")
  # C libraries bound by extern blocks — see emitOdinModule for why these are
  # hoisted here rather than emitted beside the `foreign` block.
  for alias, spec in ctx.foreignLibs:
    result.add("foreign import " & alias & " \"" & odinLibSpec(spec) & "\"")
  # `impl: odin "..."` packages — the forwarders emitted call <alias>.<fn>
  for alias, spec in ctx.implMods:
    result.add("import " & alias & " \"" & spec & "\"")

proc genEntryPoint(ctx: OdinCodegenCtx, m: Module, mains: string): string =
  ## Tuck's `fn main` is a plain proc; Odin's entry point calls it. Static
  ## asserts fold into the same entry (Odin has #assert for compile-time, but
  ## these are runtime-checked in the Beef path too).
  ##
  ## Runtime boot mirrors the Nim entry (tuck.nim): init the scheduler and
  ## reactor, start every actor's drain coroutine, run main, then drive the
  ## loop so spawned tasks and actors get to finish.
  result = "main :: proc() {\n"
  for a in ctx.staticAsserts:
    result.add("\tassert(" & a & ")\n")
  var actorNames: seq[string]
  var hasTasks = false
  runtimeUsers(m, actorNames, hasTasks)
  if actorNames.len > 0 or hasTasks:
    result.add("\trt.tuckAsyncInit()\n")
    for a in actorNames:
      result.add("\trt.tuckStartActor(drain_" & a & ")\n")
  if mains != "": result.add(mains & "\n")
  # A value-returning `fn main` IS the process exit code (mirrors tuck.nim).
  let mainFn = mainDecl(m)
  let mainReturns = mainFn != nil and mainFn.returnsValue
  if mainFn != nil:
    let tuckMain = mangleName("main")
    result.add(if mainReturns: "\tmainRc := " & tuckMain & "()\n"
               else: "\t" & tuckMain & "()\n")
  # Drive the loop only when TASKS exist. Actors are daemons whose drain loops
  # never finish, so running the scheduler for them would spin forever —
  # tuck.nim gates on hasTasks for exactly this reason.
  if hasTasks: result.add("\trt.tuckRun()\n")
  if mainReturns: result.add("\tos.exit(mainRc)\n")
  result.add("}\n")

proc emitOdin*(m: Module,
               realModules = initTable[string, Module](),
               moduleName = "main"): string =
  var ctx = newOdinCtx(m, realModules, moduleName)
  let (body, mains) = ctx.emitBody(m)
  result = odinPackage
  let imports = ctx.odinImports(m, body, mains, realModules)
  if imports.len > 0:
    result.add(imports.join("\n") & "\n\n")
  for h in ctx.hoisted:
    result.add(h & "\n\n")
  result.add(body)
  result.add(ctx.genEntryPoint(m, mains))

# A library module (import target). Odin has no static classes: a module is
# a package, and a qualified ref (`fs::readFile`) becomes `fs.readFile` via
# the import alias, so the declarations sit at top level here too.
proc emitOdinModule*(name: string, m: Module,
                     realModules = initTable[string, Module]()): string =
  let pkg = name.replace("-", "_")
  var ctx = newOdinCtx(m, realModules, name, modPrefix = pkg & "_")
  let (body, _) = ctx.emitBody(m)
  # Odin package names are GLOBAL, not scoped to their directory, so a Tuck
  # module called `io` or `os` would collide with core:io / core:os. The
  # emitted package carries a tuck_ prefix; the import alias at the use site
  # keeps the Tuck name, so qualified calls still read as `io.printLine`.
  var res = "package tuck_" & pkg & "\n\n"
  # This file lives in mod_<pkg>/, so siblings are one level up.
  var imports: seq[string]
  if "fmt." in body: imports.add("import \"core:fmt\"")
  if "rt." in body: imports.add("import rt \"../tuckrt\"")
  for modName in realModules.keys:
    let dep = modName.replace("-", "_")
    if dep != pkg and (dep & ".") in body:
      imports.add("import " & dep & " \"../mod_" & dep & "\"")
  # C libraries bound by extern blocks. `foreign import` is only legal at
  # package top level, so the emitter collects the names during emitBody and
  # declares them here — this is what makes the binding link.
  for alias, spec in ctx.foreignLibs:
    imports.add("foreign import " & alias & " \"" & odinLibSpec(spec) & "\"")
  # `impl: odin "..."` packages — the forwarders emitted above call <alias>.<fn>
  for alias, spec in ctx.implMods:
    imports.add("import " & alias & " \"" & spec & "\"")
  if imports.len > 0:
    res.add(imports.join("\n") & "\n\n")
  for h in ctx.hoisted:
    res.add(h & "\n\n")
  res.add(body)
  res