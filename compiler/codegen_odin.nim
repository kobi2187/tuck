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
    else:
      # Odd bit widths from decision tables (u2, u12, ...) round up to a real int
      if t.name.len >= 2 and t.name[0] in {'u', 'i'} and t.name[1..^1].allCharsInSet({'0'..'9'}):
        let bits = parseInt(t.name[1..^1])
        let base = if t.name[0] == 'u': "u" else: "i"
        if bits <= 8: base & "8"
        elif bits <= 16: base & "16"
        elif bits <= 32: base & "32"
        else: base & "64"
      elif t.name == UnknownName: "any"  # sketch mode: no type information
      else:
        # A type declared in an IMPORTED module lives in that module's Odin
        # package, so it must be referenced qualified (`time.Milliseconds`).
        # Beef needs no such qualification — its modules are static classes
        # in one namespace.
        var qualified = t.name
        for d in ctx.module.decls:
          if d != nil and d.kind == dkType and d.name == t.name and
             d.span.file.startsWith(ImportedTypeMarker & ":"):
            let origin = d.span.file[ImportedTypeMarker.len + 1 .. ^1]
            let pkg = origin.replace("-", "_")
            if pkg != ctx.moduleName.replace("-", "_"):
              qualified = pkg & "." & t.name
            break
        qualified
  of tkTuple:
    if t.elems.len == 1: return ctx.odinType(t.elems[0])
    var parts: seq[string]
    for e in t.elems: parts.add(ctx.odinType(e))
    "(" & parts.join(", ") & ")"
  of tkApp:
    # Odin puts the size BEFORE the element type: [N]T, not T[N].
    if t.base.kind == tkNamed and t.base.name == "*":
      # elem * count — sized array
      return "[" & ctx.odinType(t.args[1]) & "]" & ctx.odinType(t.args[0])
    if t.base.kind == tkNamed and t.base.name == "Array":
      # Array[count, elem]
      return "[" & ctx.odinType(t.args[0]) & "]" & ctx.odinType(t.args[1])
    # !T / ?T / !?T lower to rt.TuckResult(T) — errors are first-class values
    if t.base.kind == tkNamed and t.base.name in ["!", "?", "!?"] and t.args.len == 1:
      let inner = ctx.odinType(t.args[0])
      return "rt.TuckResult(" & (if inner == "void": "rt.TuckUnit" else: inner) & ")"
    if t.base.kind == tkNamed and t.base.name == "Seq":
      var parts: seq[string]
      for a in t.args: parts.add(ctx.odinType(a))
      return "[dynamic]" & parts.join(", ")
    var parts: seq[string]
    for a in t.args: parts.add(ctx.odinType(a))
    return ctx.odinType(t.base) & "(" & parts.join(", ") & ")"
  of tkFunc:
    # A resolved function reference (`:plus`) carries its real signature, so
    # it emits a callable proc type rather than an opaque pointer.
    var ps: seq[string]
    for p in t.params: ps.add(ctx.odinType(p))
    let r = if t.result != nil and not (t.result.kind == tkNamed and
                                        t.result.name == "void"):
              " -> " & ctx.odinType(t.result)
            else: ""
    "proc(" & ps.join(", ") & ")" & r
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

proc memberOwner(ctx: OdinCodegenCtx, recvT: Type): string =
  ## The object type a member call dispatches on, or "" when the receiver is
  ## not an object (a record's `.fn` is a free fn and keeps its bare name).
  if recvT == nil or recvT.kind != tkNamed: return ""
  for d in ctx.module.decls:
    if d != nil and d.kind == dkObject and d.name == recvT.name: return d.name
  ""


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
                        litFields: seq[(string, Expr)]): string =
  let structName = recStructName(ctx, declFields)
  # Odin struct literals are named — `T{a = 1, b = 2}` — so a field the
  # literal omits simply stays zero-valued and needs no placeholder.
  var parts: seq[string]
  for fd in declFields:
    for f in litFields:
      if f[0] == fd.name:
        let fieldOdin = ctx.odinType(fd.typ)
        let ex = ctx.genOdinExpr(f[1])
        # narrow numeric literals to the declared field width
        if fieldOdin notin ["int", "f64", "f32", "string", "bool"] and
           (fieldOdin.startsWith("u") or fieldOdin.startsWith("i") or
            fieldOdin.startsWith("f")):
          parts.add(fd.name & " = " & fieldOdin & "(" & ex & ")")
        else:
          parts.add(fd.name & " = " & ex)
        break
  return structName & "{" & parts.join(", ") & "}"

proc hasUnknownType(t: Type): bool =
  if t == nil: return true
  case t.kind
  of tkNamed: t.name == UnknownName
  of tkApp:
    if hasUnknownType(t.base): return true
    for a in t.args:
      if hasUnknownType(a): return true
    false
  of tkRecord:
    for f in t.fields:
      if hasUnknownType(f.typ): return true
    false
  of tkTuple:
    for el in t.elems:
      if hasUnknownType(el): return true
    false
  else: false

proc inferLitType(e: Expr): Type =
  # best-effort inference for sketch-mode literals
  if e != nil and semLayer.typeFor(e) != nil and not hasUnknownType(semLayer.typeFor(e)): return semLayer.typeFor(e)
  if e != nil and e.kind == exkLit:
    case e.litKind
    of lkStr: return Type(kind: tkNamed, name: "str")
    of lkBool: return Type(kind: tkNamed, name: "bool")
    of lkFloat: return Type(kind: tkNamed, name: "float")
    else: return Type(kind: tkNamed, name: "int")
  return nil

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
    let ft = inferLitType(e.fields[0][1])
    if ft != nil:
      return ctx.recCtorFromLiteral(@[FieldDef(name: e.fields[0][0], typ: ft)],
                                    e.fields)
    # no type information at all: sketch mode, emit the bare value
    return ctx.genOdinExpr(e.fields[0][1])
  # Multi-field sketch literal: infer each field's type and hoist a shape.
  # Odin has no anonymous struct type, so a bare `{a = 1}` is a hard error
  # ("missing type in compound literal") — every literal MUST land on a named
  # shape. A field whose type can't be inferred falls back to the runtime's
  # `any`, which keeps sketch code compiling the way the Nim backend does.
  var inferred: seq[FieldDef]
  for f in e.fields:
    var ft = inferLitType(f[1])
    if ft == nil: ft = Type(kind: tkNamed, name: UnknownName, span: e.span)
    inferred.add(FieldDef(name: f[0], typ: ft, span: e.span))
  return ctx.recCtorFromLiteral(inferred, e.fields)

# exkCall: record construction (with invariant validation and generic
# instantiation), payload explosion, named-param reordering, or a plain call.
# {payload} Type.Variant — construction of a payload-carrying sum type
# (kind + per-variant TRec struct field). Fieldless-only sums are plain Beef
# enums, where Type.Variant is already valid — returns "" to fall through.
proc sumVariantCtor(ctx: var OdinCodegenCtx, typeName, variantName: string,
                    payload: Expr): string =
  for d in ctx.module.decls:
    if d != nil and d.kind == dkType and d.name == typeName and
       d.typeBody != nil and d.typeBody.kind == tkSum:
      var hasPayload = false
      for v in d.typeBody.variants:
        if v.fields.len > 0: hasPayload = true
      if not hasPayload: return ""
      for v in d.typeBody.variants:
        if v.name == variantName:
          # Odin union: constructing a variant IS constructing its struct;
          # the union carries the tag itself, so there is no kind field to
          # set and no per-variant payload slot to name.
          let vName = typeName & "_" & v.name
          if v.fields.len == 0 or payload == nil:
            return vName & "{}"
          var vals: seq[string]
          for f in v.fields:
            for pf in payload.fields:
              if pf[0] == f.name:
                vals.add(f.name & " = " & ctx.genOdinExpr(pf[1]))
                break
          return vName & "{" & vals.join(", ") & "}"
  ""

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

proc genOdinCall(ctx: var OdinCodegenCtx, e: Expr): string =
  var args: seq[string]
  if e.callee != nil and e.callee.kind == exkField and
     e.callee.receiver != nil and e.callee.receiver.kind == exkVar:
    let payload = if e.args.len == 1 and e.args[0].kind == exkStruct: e.args[0]
                  else: nil
    let ctor = ctx.sumVariantCtor(e.callee.receiver.name, e.callee.fieldName,
                                   payload)
    if ctor != "": return ctor
  var calleeStr = ctx.genOdinExpr(e.callee)
  # A member call arrives as a bare-name callee with the receiver as args[0]
  # (the checker's asFnByName rewrite). The DECLARATION emitted qualified, so
  # the call has to match — derive the same name from the receiver's type.
  if e.callee != nil and e.callee.kind == exkVar and e.args.len >= 1:
    let owner = ctx.memberOwner(semLayer.typeFor(e.args[0]))
    if owner != "":
      for d in ctx.module.decls:
        if d == nil or d.kind != dkObject or d.name != owner: continue
        for mem in d.objMembers:
          if mem != nil and mem.kind == dkFn and mem.name == e.callee.name:
            calleeStr = memberProcName(owner, e.callee.name)
  if calleeStr == "bake" and e.args.len == 2 and e.args[1].kind == exkStruct:
    let baked = ctx.genOdinBake(e)
    if baked != "": return baked
  if e.args.len == 1 and e.args[0].kind == exkStruct and
     e.callee != nil and e.callee.kind == exkVar and
     isRecordType(ctx.module, e.callee.name):
    # record construction: named fields, not positional
    var parts: seq[string]
    for field in e.args[0].fields:
      parts.add(field[0] & " = " & ctx.genOdinExpr(field[1]))
    # generic type: the checker's ty stamp carries the inferred instantiation
    var ctorName = e.callee.name
    if semLayer.typeFor(e) != nil and semLayer.typeFor(e).kind == tkApp and semLayer.typeFor(e).base != nil and
       semLayer.typeFor(e).base.kind == tkNamed and semLayer.typeFor(e).base.name == e.callee.name:
      var gparts: seq[string]
      for a in semLayer.typeFor(e).args: gparts.add(ctx.odinType(a))
      ctorName &= "(" & gparts.join(", ") & ")"
    # Odin struct literal: `Type{field = value, ...}`, a value not a pointer
    let ctor = ctorName & "{" & parts.join(", ") & "}"
    if hasInvariants(ctx.module, e.callee.name):
      # production site: construction — validate before the value flows on
      return "__validated_" & e.callee.name & "(" & ctor & ")"
    return ctor
  if calleeStr == "alias" and e.args.len == 2 and e.args[1].kind == exkStruct:
    let aliased = ctx.genOdinAlias(e)
    if aliased != "": return aliased
  if calleeStr == "merge" and e.args.len == 1 and e.args[0].kind == exkStruct:
    let merged = ctx.genOdinMerge(e)
    if merged != "": return merged
  if calleeStr notin ["bake", "alias"]:
    let exploded = ctx.explodeRecordArg(e, calleeStr)
    if exploded != "": return exploded
  if e.args.len == 1 and e.args[0].kind == exkStruct:
    # param order lives with the fn, not the literal — match by name.
    # A qualified callee into a real module resolves in THAT module.
    let expectedParams =
      if e.callee != nil and e.callee.kind == exkQualified and
         e.callee.modulePath.len > 0 and e.callee.modulePath[0] in ctx.realModules:
        lookupFnParams(ctx.realModules[e.callee.modulePath[0]], e.callee.qualName)
      elif semLayer.callParamsFor(e).len > 0:
        semLayer.callParamsFor(e)
      else:
        lookupFnParams(ctx.module, calleeStr)
    if expectedParams.len > 0:
      # The checker's mapping wins: a field matched by TYPE carries its own
      # name, not the param's (see checkCallArgs / semLayer.argFieldsFor).
      let resolved = semLayer.argFieldsFor(e)
      for i, paramName in expectedParams:
        let fieldName = if i < resolved.len and resolved[i].len > 0: resolved[i]
                        else: paramName
        var found = false
        for field in e.args[0].fields:
          if field[0] == fieldName:
            args.add(ctx.genOdinExpr(field[1]))
            found = true
            break
        if not found:
          args.add("{}")
    else:
      for field in e.args[0].fields:
        args.add(ctx.genOdinExpr(field[1]))
  else:
    # bare positional args (incl. the receiver a chain mutator call
    # synthesizes, e.g. `c ..bump`) — a mutable-record param takes a pointer,
    # so the call site passes `&x`; only a bare var has an address to take
    # ponytail: pass records BY VALUE. A mutating callee would need `^T` and
    # `&x` here, but Odin proc params aren't addressable, so `&param` is a
    # hard error — and Tuck's mutators already return the updated value,
    # which the chain emitter assigns back. Revisit if a real in-place
    # mutator shows up that the return-and-assign shape can't express.
    for a in e.args:
      args.add(ctx.genOdinExpr(a))
  if calleeStr == "bake":
    return args[0] & "(" & args[1..^1].join(", ") & ")"
  elif calleeStr == "alias":
    return args[0]
  let satT = ctx.module.saturatingType(calleeStr)
  if satT != nil and args.len == 1:
    # spec 4.1: constructing a [saturating] type CLAMPS instead of wrapping.
    # Mirrors codegen.nim — the guard runs on a wider intermediate so the
    # value is checked against the real bounds, not after it has wrapped.
    let satBase = ctx.odinType(satT)
    let unsigned = satBase.startsWith("u")
    let widen = if unsigned: "u64" else: "i64"
    let satFn = if unsigned: "rt.tuckSat" else: "rt.tuckSatI"
    return calleeStr & "(" & satFn & "(" & satBase & ", " & widen & "(" &
           args[0] & ")))"
  if externInvRet(ctx.module, calleeStr) != "":
    # extern boundary: the returned value validates on entry
    return "__validated_" & externInvRet(ctx.module, calleeStr) & "(" &
           calleeStr & "(" & args.join(", ") & "))"
  elif calleeStr == "echo":
    return "fmt.println(" & args.join(", ") & ")"
  # Runtime intrinsics: Beef reaches these through `using static Rt`, but
  # Odin has no such import, so they qualify explicitly. The container ones
  # mutate their receiver, so it goes in by pointer.
  elif calleeStr in ["acquire", "release", "alloc", "reset", "enqueue",
                     "dequeue", "hasRoom", "initMailbox"] and args.len > 0:
    return "rt." & calleeStr & "(&" & args[0] &
           (if args.len > 1: ", " & args[1..^1].join(", ") else: "") & ")"
  elif calleeStr in ["at", "setAt", "toStr", "tuckConcat", "errCode",
                     "tuckSat", "tuckSatI", "tuckReportUnhandled"]:
    return "rt." & calleeStr & "(" & args.join(", ") & ")"
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
proc genMatchStmt(ctx: var OdinCodegenCtx, e: Expr): string =
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

proc genOdinExpr*(ctx: var OdinCodegenCtx, e: Expr): string =
  if e == nil: return ""
  let ind = "  ".repeat(ctx.indent)
  # A concrete object entering an interface slot is COPIED into the variant
  # (spec §5.3). Mirrors the Nim backend: the value owns its data, so it can be
  # returned or stored with no lifetime question — nothing borrows.
  let w = semLayer.wrapOf(e)
  if w.objName != "" and e.kind == exkVar:
    var ifaceName = w.iface
    var objName = w.objName
    for d in ctx.module.decls:
      if d == nil: continue
      let src = if d.sourceName.isSome: d.sourceName.get else: d.name
      if d.kind == dkInterface and src == w.iface: ifaceName = d.name
      if d.kind == dkObject and src == w.objName: objName = d.name
    return ifaceName & "{tag = ." & ifaceName & "_is_" & objName & ", " &
           objName & "Val = " & e.name & "}"
  case e.kind
  of exkLit:
    return case e.litKind
           of lkStr: "\"" & e.litValue & "\""
           else: e.litValue
  of exkVar:
    # nullary call stamped by the checker (spec 2.3: a bare name IS a call)
    if semLayer.hasCall(e): return ctx.genOdinExpr(semLayer.call(e))
    if e.name == "...": return ""  # pending hole: compiles, does nothing
    if e.name == "input" and ctx.currentParams.len > 0:
      # the whole incoming payload, rebuilt as its TRec shape
      var vals: seq[string]
      for p in ctx.currentParams: vals.add(p.name & " = " & p.name)
      return ctx.recStructName(ctx.currentParams) & "{" & vals.join(", ") & "}"
    # inside a member fn `self` is a pointer: read through it
    if e.name == "self" and ctx.ptrSelf: return "self^"
    if e.name in ctx.fieldVars: return ctx.fieldPrefix & e.name
    if e.name notin ctx.definedVars:
      # bare enum tag: qualify with its declared owner (Beef has no
      # module-global enum members the way Nim does)
      let owner = enumTagOwner(ctx.module, e.name)
      if owner != "": return owner & "." & e.name
      # unqualified cross-module call (`0 exit` for `sys::exit`). Nim resolves
      # this itself through the emitted `import`; Odin never merges package
      # scopes, so the owning package has to be found and spelled out here.
      if not ctx.module.declaresFn(e.name):
        for modName, im in ctx.realModules:
          if im.declaresFn(e.name):
            return modName.replace("-", "_") & "." & e.name
    return e.name
  of exkField:
    # A call through an interface value: switch on the tag the value carries
    # and call the concrete member fn. Mirrors the Nim backend.
    let ic = semLayer.ifaceCallOf(e)
    if ic.member != "":
      # Dispatch is a switch on the tag calling the concrete member fn — no
      # table, no thunk. Emitted as an immediately-called closure because Odin
      # has no switch EXPRESSION, and a call site needs a value.
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
      return "(proc(v: " & ic.iface & ") -> int {\n\tswitch v.tag {\n" &
             arms.join("\n") & "\n\t}\n\treturn 0\n})(" & recv & ")"
    # `Counter.total` reads the actor SINGLETON's field, not a type's.
    if e.receiver != nil and e.receiver.kind == exkVar and
       ctx.isActorType(e.receiver.name):
      return actorSingletonName(e.receiver.name) & "." & e.fieldName
    # `r.ok` on a !T/?T value is a STATUS TEST, not a field — the runtime
    # models status as an enum, so emit the comparison the guard means.
    if e.fieldName == "ok" and e.receiver != nil:
      let rt = semLayer.typeFor(e.receiver)
      if rt != nil and rt.kind == tkApp and rt.base != nil and
         rt.base.kind == tkNamed and rt.base.name in ["!", "?", "!?"]:
        # parenthesised: a guard may negate it (`!r.ok`), and `!x == y`
        # would otherwise bind the `!` to the receiver alone
        return "(" & ctx.genOdinExpr(e.receiver) & ".status == .Ok)"
    # `input.x` — the incoming payload's field is just the param
    if e.receiver != nil and e.receiver.kind == exkVar and
       e.receiver.name == "input" and ctx.currentParams.len > 0:
      return e.fieldName
    if semLayer.hasCall(e):
      # fieldName resolved to a fn call, not a field (checker-resolved)
      return ctx.genOdinCall(semLayer.call(e))
    if e.receiver != nil and e.receiver.kind == exkVar:
      # bare Type.Variant of a payload sum: kind-tagged construction
      let ctor = ctx.sumVariantCtor(e.receiver.name, e.fieldName, nil)
      if ctor != "": return ctor
    if e.receiver != nil and e.receiver.kind == exkLit and
       e.receiver.litKind in {lkInt, lkFloat}:
      # `5.ms` the checker could not resolve — see the Nim backend's twin of
      # this branch. A declared helper never reaches here; `hasCall` above
      # catches it.
      return ctx.genOdinExpr(e.receiver)
    return ctx.genOdinExpr(e.receiver) & "." & e.fieldName
  of exkQualified:
    return genQualified(ctx, e)
  of exkCall:
    return ctx.genOdinCall(e)
  of exkStruct:
    return ctx.genStructLit(e)
  of exkList:
    var parts: seq[string]
    for item in e.items:
      parts.add(ctx.genOdinExpr(item))
    # Odin infers the element type from context: `{a, b}` as a compound literal
    return "{" & parts.join(", ") & "}"
  of exkBracket:
    # indexing resolved to an at() call; a type application never reaches codegen
    if semLayer.hasCall(e): return ctx.genOdinExpr(semLayer.call(e))
    return ""
  of exkBracketAssign:
    if semLayer.hasCall(e): return ctx.genOdinExpr(semLayer.call(e))
    return ""
  of exkFor:
    let iterStr = ctx.genOdinExpr(e.iterable)
    if e.iter != nil and e.iter.kind == pkTuple and e.iter.elems.len == 2:
      # `for idx, item in xs:` — Beef foreach has no index form; lower to a
      # counter initialized to -1 and incremented FIRST in the body, so
      # `continue` inside the body cannot skip the increment.
      let idxN = genPatternStr(e.iter.elems[0])
      let itemN = genPatternStr(e.iter.elems[1])
      let oldIndent = ctx.indent
      ctx.indent += 1
      let bodyStr = ctx.genOdinExpr(e.body)
      ctx.indent = oldIndent
      # Odin's range-for yields the index natively — no counter to maintain.
      return ind & "for " & itemN & ", " & idxN & " in " & iterStr & " {\n" &
             bodyStr & "\n" & ind & "}"
    let oldIndent = ctx.indent
    ctx.indent += 1
    let bodyStr = ctx.genOdinExpr(e.body)
    ctx.indent = oldIndent
    return ind & "for " & genPatternStr(e.iter) & " in " & iterStr & " {\n" &
           bodyStr & "\n" & ind & "}"
  of exkWhile:
    let condStr = if e.whileCond == nil: "true" else: ctx.genOdinExpr(e.whileCond)
    let oldIndent = ctx.indent
    ctx.indent += 1
    let bodyStr = ctx.genOdinExpr(e.whileBody)
    ctx.indent = oldIndent
    return ind & "while (" & condStr & ")\n" & bodyStr
  of exkBreak:
    return "break"
  of exkContinue:
    return "continue"
  of exkBinary:
    let opStr = case e.binOp
                of boAdd: "+"
                of boSub: "-"
                of boMul: "*"
                # Odin's `/` follows the operand type (integer operands give
                # integer division), so both map to `/` here — the DIFFERENCE
                # from Nim, which needs `div`, is exactly why the Tuck source
                # has to say which one it means.
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
    if e.binOp == boAdd and e.left != nil and semLayer.typeFor(e.left) != nil and
       semLayer.typeFor(e.left).kind == tkNamed and semLayer.typeFor(e.left).name in ["str", "string"]:
      # rt.tuckConcat — `concat` was the Beef runtime's name and never
      # existed in the Odin one (tuckrt/tuck_rt.odin:87), so any string `+`
      # emitted an undeclared call.
      return "rt.tuckConcat(" & ctx.genOdinExpr(e.left) & ", " &
             ctx.genOdinExpr(e.right) & ")"
    return "(" & ctx.genOdinExpr(e.left) & " " & opStr & " " & ctx.genOdinExpr(e.right) & ")"
  of exkUnary:
    let opStr = case e.unaryOp
                of uoNeg: "-"
                of uoNot: "!"
                else: ""
    return opStr & ctx.genOdinExpr(e.operand)
  of exkBlock:
    var lines: seq[string]
    let oldIndent = ctx.indent
    ctx.indent += 1
    for s in e.stmts:
      var stmtCode: string
      var ownsLayout = false  # statement carries its own indentation/terminator
      if s.kind == exkMatch and s.subject != nil:
        stmtCode = ctx.genMatchStmt(s)
        ownsLayout = true
      else:
        stmtCode = ctx.genOdinExpr(s)
      if stmtCode != "" and semLayer.shortcut(s) != "":
        # continue/exit policy: dropped result routes to the global handler
        ctx.tmpCounter.inc
        let tn = "tuckDrop" & $ctx.tmpCounter
        let onErr = if ctx.errPolicy == "exit":
                      "tuck_unhandled(" & tn & ".err, \"" & semLayer.shortcut(s) &
                      "\"); panic(\"unhandled error\")"
                    else:
                      "tuck_unhandled(" & tn & ".err, \"" & semLayer.shortcut(s) & "\")"
        stmtCode = ind & "\t" & tn & " := " & stmtCode & "\n" &
                   ind & "\tif " & tn & ".status != .Ok { " & onErr & " }"
        ownsLayout = true
      if stmtCode != "":
        if s.kind in {exkIf, exkFor, exkWhile, exkBlock, exkChain} or ownsLayout:
          lines.add(stmtCode)  # these carry their own indentation
        else:
          lines.add(ind & "  " & stmtCode)  # Odin has no statement terminator
    ctx.indent = oldIndent
    # No braces here: Odin's block-owning constructs (proc, if, for) emit
    # their own `{`, and a bare nested block is rare enough not to need one.
    if lines.len == 0:
      return ""
    return lines.join("\n")
  of exkIf:
    # Odin: no parens around the condition, braces mandatory.
    let condStr = ctx.genOdinExpr(e.cond)
    # R2: a value-position if becomes Odin's ternary. Odin has no
    # if-expression, so the statement form below cannot stand in — it is not
    # legal where a value is expected.
    if isValueIf(e):
      let saved = ctx.indent
      ctx.indent = 0
      let t = ctx.genOdinExpr(e.thenBranch)
      let f = ctx.genOdinExpr(e.elseBranch)
      ctx.indent = saved
      return "(" & condStr & " ? " & t & " : " & f & ")"
    let oldIndent = ctx.indent
    ctx.indent += 1
    var thenStr = ctx.genOdinExpr(e.thenBranch)
    if e.thenBranch != nil and e.thenBranch.kind != exkBlock:
      thenStr = ind & "  " & thenStr
    var elseStr = ""
    if e.elseBranch != nil:
      var elseBodyStr = ctx.genOdinExpr(e.elseBranch)
      if e.elseBranch.kind != exkBlock:
        elseBodyStr = ind & "  " & elseBodyStr
      elseStr = "\n" & ind & "} else {\n" & elseBodyStr
    ctx.indent = oldIndent
    return ind & "if " & condStr & " {\n" & thenStr & elseStr & "\n" & ind & "}"
  of exkAssign:
    let targetStr = ctx.genOdinExpr(e.target)
    let valStr = ctx.genOdinExpr(e.assignVal)
    if e.target.kind == exkVar:
      let name = e.target.name
      if name notin ctx.definedVars and name notin ctx.fieldVars:
        ctx.definedVars.incl(name)
        return name & " := " & valStr
    return targetStr & " = " & valStr
  of exkMatch:
    if e.subject != nil:
      return ctx.genMatchExpr(e)
    return ""
  of exkReturn:
    if e.returnVal != nil and e.returnVal.kind == exkRaise:
      return ctx.genOdinExpr(e.returnVal)
    return ctx.genOdinReturn(e)
  of exkRaise:
    return ctx.genRaise(e)
  of exkChain:
    # `x ..field {v} ..mutate {a}` — one plain statement per step:
    # field set, or mutator call reassigned into the base var
    let baseStr = ctx.genOdinExpr(e.base)
    var lines: seq[string]
    for step in e.steps:
      if semLayer.stepCall(step) != nil:
        lines.add(ind & baseStr & " = " & ctx.genOdinCall(semLayer.stepCall(step)))
      else:
        var valStr = ""
        if step.arg != nil and step.arg.kind == exkStruct and
           step.arg.fields.len == 1:
          valStr = ctx.genOdinExpr(step.arg.fields[0][1])
        lines.add(ind & baseStr & "." & step.target.name & " = " & valStr)
    # mutation site: an invariant-carrying var re-validates after the chain
    if e.base != nil and semLayer.typeFor(e.base) != nil and semLayer.typeFor(e.base).kind == tkNamed and
       hasInvariants(ctx.module, semLayer.typeFor(e.base).name):
      lines.add(ind & "validate_" & semLayer.typeFor(e.base).name & "(" &
                baseStr & ")")
    return lines.join("\n")
  of exkSend:
    # `Actor send handler {payload}` — enqueue an envelope on the singleton's
    # mailbox, then wake the actor. A full ring drops (spec §9.1).
    # The send helper genActor emitted takes the payload fields positionally
    # after the actor pointer, in handler-param order.
    var sendArgs: seq[string]
    if e.sendPayload != nil and e.sendPayload.kind == exkStruct:
      for (_, fexpr) in e.sendPayload.fields.items:
        sendArgs.add(ctx.genOdinExpr(fexpr))
    let sep = if sendArgs.len > 0: ", " else: ""
    return "send" & e.sendHandler.capitalize() & "_" & e.sendActor & "(&" &
           actorSingletonName(e.sendActor) & sep & sendArgs.join(", ") & ")"
  of exkSelect:
    # ponytail: `on select` needs the reactor to race a read against a
    # timeout per branch (rt.tuckAwaitReadOrTimeout is there for it). The
    # branch lowering isn't wired yet; 27-actor-select / 29-task-timeout
    # are the cases. Emits nothing rather than pretending to work.
    return "/* on select: not yet lowered for Odin */"
  of exkImport:
    # imports are declarations; they never reach expression position
    return ""

proc genOdinDecl*(ctx: var OdinCodegenCtx, d: Decl): string

# Object member fn (or a mixin fn materialized by `+ mixin`): the object
# rides as a `ref self` first parameter (reassignment must reach the
# caller); `Self` resolves to the object. Shallow copy — the shared AST
# stays untouched for the other backend.
# ponytail: call sites don't take the address yet — nothing in the
# examples calls a member fn; wire it when one does.
proc genOdinMemberFn(ctx: var OdinCodegenCtx, m: Decl, objName: string): string =
  let selfType = Type(span: m.span, kind: tkNamed, name: "^" & objName)
  let plainSelf = Type(span: m.span, kind: tkNamed, name: objName)
  var params: seq[Param]
  var hasSelf = false
  for p in m.fnParams:
    var pt = p.typ
    if pt != nil and pt.kind == tkNamed and pt.name == "Self": pt = plainSelf
    if p.name == "self":
      hasSelf = true
      params.add(Param(name: "self", typ: selfType, span: p.span))
    else:
      params.add(Param(name: p.name, typ: pt, span: p.span))
  if not hasSelf:
    params = @[Param(name: "self", typ: selfType, span: m.span)] & params
  var ret = m.fnReturnType
  if ret != nil and ret.kind == tkNamed and ret.name == "Self": ret = plainSelf
  let copy = Decl(span: m.span, kind: dkFn, name: memberProcName(objName, m.name),
                  fnParams: params,
                  fnReturnType: ret, fnBody: m.fnBody, fnEffects: m.fnEffects,
                  fnGenerics: m.fnGenerics)
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
proc injectTailReturn(body: Expr, retTypeStr: string) =
  if body != nil and body.kind == exkBlock and body.stmts.len > 0 and
     retTypeStr != "void":
    let lastS = body.stmts[^1]
    if lastS.kind == exkChain:
      # a chain's value is its base var: keep the mutation statements,
      # return the base afterwards (idempotent across backends — the shared
      # AST may already carry the appended return)
      if lastS.base != nil:
        body.stmts.add(Expr(span: lastS.span, kind: exkReturn,
                            returnVal: lastS.base))
    elif lastS.kind == exkMatch and lastS.subject != nil:
      # `match subject:` with value arms is an EXPRESSION — the tail match is
      # the fn's result (decision tables, subject == nil, keep row returns).
      # Idempotent: the other backend may have wrapped it already.
      body.stmts[^1] = Expr(span: lastS.span, kind: exkReturn, returnVal: lastS)
    elif lastS.kind notin {exkReturn, exkRaise, exkIf, exkMatch, exkFor, exkWhile, exkBreak, exkContinue,
                           exkAssign, exkBlock} and
       not (lastS.kind == exkVar and lastS.name == "..."):
      body.stmts[^1] = Expr(span: lastS.span, kind: exkReturn, returnVal: lastS)

# Decision tables: packed single-switch when every column is enumerable,
# otherwise a first-match if/else chain (mirrors codegen.nim).
proc genDecisionTable(ctx: var OdinCodegenCtx, d: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  let fnNameSanitized = d.name.replace(".", "_")
  var params: seq[string]
  for p in d.fnParams:
    params.add(p.name & ": " & ctx.odinType(p.typ))
  let retTypeStr = if d.fnReturnType != nil: ctx.odinType(d.fnReturnType) else: "void"
  let retStr = if retTypeStr != "void": " -> " & retTypeStr else: ""
  let header = ind & fnNameSanitized & " :: proc(" & params.join(", ") & ")" &
               retStr & " {"

  # Bitmask/packed path: when every column domain is enumerable the whole
  # table collapses to one switch over a packed integer key (spec 6.1).
  var domains: seq[seq[string]]
  var allEnum = true
  var comboCount = 1
  for p in d.fnParams:
    let dom = enumDomain(ctx.module, p.typ)
    if dom.len == 0: allEnum = false
    domains.add(dom)
    comboCount *= max(dom.len, 1)
  if allEnum and comboCount > 0 and comboCount <= 4096:
    var rowPats: seq[seq[string]]
    var rowBodies: seq[string]
    for s in d.fnBody.stmts:
      if s.kind != exkMatch or s.arms.len == 0: continue
      let pat = s.arms[0].pattern
      var pats: seq[string]
      for el in (if pat != nil and pat.kind == pkTuple: pat.elems else: @[pat]):
        pats.add(genPatternStr(el))
      rowPats.add(pats)
      rowBodies.add(ctx.armValue(s.arms[0].body))
    # first-match outcome for every combination, grouped by outcome
    var groups: seq[tuple[outcome: string, keys: seq[int]]]
    for combo in 0 ..< comboCount:
      var rem = combo
      var vals = newSeq[string](domains.len)
      for c in countdown(domains.high, 0):
        vals[c] = domains[c][rem mod domains[c].len]
        rem = rem div domains[c].len
      var outcome = ""
      for i in 0 ..< rowPats.len:
        var matches = true
        for c in 0 ..< rowPats[i].len:
          if rowPats[i][c] != "_" and rowPats[i][c] != vals[c]:
            matches = false
            break
        if matches:
          outcome = rowBodies[i]
          break
      var found = false
      for g in groups.mitems:
        if g.outcome == outcome:
          g.keys.add(combo)
          found = true
          break
      if not found:
        groups.add((outcome, @[combo]))
    # packed key: mixed radix over the ordinal of each column
    var keyParts: seq[string]
    var stride = comboCount
    for c in 0 ..< domains.len:
      stride = stride div domains[c].len
      let ordExpr = if domains[c] == @["false", "true"]:
                      "(" & d.fnParams[c].name & " ? 1 : 0)"
                    else:
                      "int(" & d.fnParams[c].name & ")"
      if stride > 1:
        keyParts.add(ordExpr & " * " & $stride)
      else:
        keyParts.add(ordExpr)
    var caseLines: seq[string]
    caseLines.add(ind & "\tswitch " & keyParts.join(" + ") & " {   // packed decision key")
    for gi, g in groups:
      if gi == groups.len - 1:
        caseLines.add(ind & "\tcase: return " & g.outcome)
      else:
        var ks: seq[string]
        for k in g.keys: ks.add($k)
        caseLines.add(ind & "\tcase " & ks.join(", ") & ": return " & g.outcome)
    caseLines.add(ind & "\t}")
    return header & "\n" & caseLines.join("\n") & "\n" & ind & "}\n"

  var bodyLines: seq[string]
  var hasCatchAll = false
  for idx, s in d.fnBody.stmts:
    let arm = s.arms[0]
    let pats = if arm.pattern != nil and arm.pattern.kind == pkTuple:
                 arm.pattern.elems
               else:
                 @[arm.pattern]
    var conds: seq[string]
    for i, pat in pats:
      let patStr = genPatternStr(pat)
      if patStr != "_" and i < d.fnParams.len:
        conds.add(d.fnParams[i].name & " == " & ctx.patternValue(patStr))
    let condStr = if conds.len > 0: conds.join(" && ") else: ""
    let resultExprStr = ctx.armValue(arm.body)
    if condStr == "":
      bodyLines.add(ind & "\treturn " & resultExprStr)
      hasCatchAll = true
    else:
      bodyLines.add(ind & "\tif " & condStr & " do return " & resultExprStr)
  if not hasCatchAll and retTypeStr != "void":
    bodyLines.add(ind & "\treturn {}")
  return header & "\n" & bodyLines.join("\n") & "\n" & ind & "}\n"

proc genOdinFnDecl(ctx: var OdinCodegenCtx, d: Decl): string =
  if d.isPending:
    return ctx.genPendingStub(d)
  ctx.currentParams = @[]
  for p in d.fnParams:
    ctx.currentParams.add(FieldDef(name: p.name, typ: p.typ, span: p.span))
  if d.isDecision or d.isDecisionTable():
    return ctx.genDecisionTable(d)
  let ind = "  ".repeat(ctx.indent)
  # Names arrive already mangled by the lowering pass (compiler/mangle.nim),
  # which is also what keeps Tuck's `fn main` from colliding with Odin's
  # entry point — it is tuck_main by the time it gets here.
  let fnNameSanitized = d.name.replace(".", "_")
  var params: seq[string]
  ctx.fnAsParam = true
  for p in d.fnParams:
    # Records pass BY VALUE. The checker binds every param isVar:true, but a
    # Tuck mutator returns the updated record and the caller assigns it back
    # (`server = withDefaults(server)`), so no pointer is needed — and Odin
    # proc params aren't addressable, so `&arg` at the call site is illegal.
    params.add(p.name & ": " & ctx.odinType(p.typ))
  ctx.fnAsParam = false
  let retTypeStr = if d.fnReturnType != nil: ctx.odinType(d.fnReturnType) else: "void"
  # Generic fns: Odin's parametric polymorphism marks type params with `$`
  var genericParams: seq[string]
  for g in d.fnGenerics: genericParams.add("$" & g & ": typeid")
  let allParams = genericParams & params
  let retStr = if retTypeStr != "void": " -> " & retTypeStr else: ""
  let inlinePrefix = if d.isInline: ind & "@(require_results=false)\n" else: ""
  # A fn handed to a C function pointer needs the C calling convention. Odin
  # cannot cast between conventions the way Nim can, so it goes on the
  # DEFINITION, matched by shape against the module's C-callback fnsig.
  # ponytail: shape match, not reference tracking. A same-shape fn that never
  # crosses the boundary gets "c" harmlessly; tighten if that ever matters.
  var conv = ""
  for mem in ctx.module.externMembers():
    if mem.kind == dkFnSig and mem.sigIsCCallback and
       mem.sigParams.len == d.fnParams.len:
      var same = true
      for i, sp in mem.sigParams:
        if ctx.odinType(sp.typ) != ctx.odinType(d.fnParams[i].typ): same = false
      if same: conv = "\"c\" "
  let header = inlinePrefix & ind & fnNameSanitized & " :: proc " & conv & "(" &
               allParams.join(", ") & ")" & retStr & " {"
  let oldVars = ctx.definedVars
  for p in d.fnParams:
    ctx.definedVars.incl(p.name)
  let oldIndent = ctx.indent
  let (bw, binner, binnerT) = ctx.odinBangInfo(d.fnReturnType)
  ctx.retWrapped = bw
  ctx.retInnerOdin = binner
  ctx.retInnerT = binnerT
  ctx.retInvName =
    if not bw and d.fnReturnType != nil and d.fnReturnType.kind == tkNamed and
       hasInvariants(ctx.module, d.fnReturnType.name): d.fnReturnType.name
    else: ""
  injectTailReturn(d.fnBody, retTypeStr)
  var bodyStr = ctx.genOdinExpr(d.fnBody)
  if d.fnBody != nil and d.fnBody.kind != exkBlock:
    # single-expression body: `header {` is already open, so just the line
    let kw = if retTypeStr != "void": "return " else: ""
    bodyStr = ind & "\t" & kw & bodyStr
  elif retTypeStr != "void":
    bodyStr = ensureTrailingReturn(bodyStr, d.fnBody, oldIndent)
  ctx.indent = oldIndent
  ctx.retWrapped = false
  ctx.retInnerOdin = ""
  ctx.retInnerT = nil
  ctx.retInvName = ""
  ctx.definedVars = oldVars
  return header & "\n" & bodyStr & "\n" & ind & "}\n"

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
    var allowed: seq[string]
    for tr in d.typeBody.transitions:
      if tr.`from` == v.name: allowed.add(tr.to)
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

proc genSumType(ctx: var OdinCodegenCtx, d: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  var hasPayload = false
  for v in d.typeBody.variants:
    if v.fields.len > 0: hasPayload = true
  let hasTransitions = d.typeBody.transitions.len > 0
  if not hasPayload and not hasTransitions:
    # plain enum (also what decision tables key over)
    var tags: seq[string]
    for v in d.typeBody.variants:
      tags.add(if v.value != "": v.name & " = " & v.value else: v.name)
    return ind & d.name & " :: enum { " & tags.join(", ") & " }\n"

  var res = ""
  var kindName = d.name
  if hasPayload:
    # Odin has a real tagged union: each variant becomes its own struct and
    # the union carries them directly — no hand-rolled kind enum, and
    # `switch v in value` gets exhaustiveness from the compiler.
    kindName = d.name & "Kind"
    var members: seq[string]
    for v in d.typeBody.variants:
      let vName = d.name & "_" & v.name
      if v.fields.len > 0:
        var fieldLines: seq[string]
        for f in v.fields:
          fieldLines.add(ind & "\t" & f.name & ": " & ctx.odinType(f.typ) & ",")
        res.add(ind & vName & " :: struct {\n" & fieldLines.join("\n") &
                "\n" & ind & "}\n")
      else:
        res.add(ind & vName & " :: struct {}\n")
      members.add(vName)
    res.add(ind & d.name & " :: union {" & members.join(", ") & "}\n")
    if hasTransitions:
      # Transitions compare states, so a payload union also needs a tag enum
      # and a projection from value to tag.
      var tags: seq[string]
      for v in d.typeBody.variants: tags.add(v.name)
      res.add(ind & kindName & " :: enum { " & tags.join(", ") & " }\n")
      res.add(ind & "tag_" & d.name & " :: proc(v: " & d.name & ") -> " &
              kindName & " {\n" & ind & "\tswitch _ in v {\n")
      for v in d.typeBody.variants:
        res.add(ind & "\tcase " & d.name & "_" & v.name & ": return ." &
                v.name & "\n")
      res.add(ind & "\t}\n" & ind & "\treturn ." & d.typeBody.variants[0].name &
              "\n" & ind & "}\n")
  else:
    var tags: seq[string]
    for v in d.typeBody.variants: tags.add(v.name)
    res.add(ind & d.name & " :: enum { " & tags.join(", ") & " }\n")

  if hasTransitions:
    # transition matrix: pure predicate + checked assignment
    res.add(ctx.genTransitionProcs(d, kindName, hasPayload))
  return res

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
  var isDistinctT = false
  for a in d.typeBody.attrs:
    if a.name == "distinct": isDistinctT = true
  let typeBodyStr = ctx.odinType(d.typeBody)
  if isDistinctT:
    # Odin has `distinct` natively: same bits, incompatible type, and
    # arithmetic/comparison already work on the distinct type. No wrapper
    # struct or operator overloads needed (the Beef backend hand-rolls both).
    return ind & d.name & " :: distinct " & typeBodyStr & "\n"
  var aGenParts: seq[string]
  for g in d.generics: aGenParts.add("$" & g & ": typeid")
  let aGen = if aGenParts.len > 0: "(" & aGenParts.join(", ") & ")" else: ""
  return ind & d.name & " :: " & (if aGen != "": "struct" & aGen & " { " &
         "using _: " & typeBodyStr & " }" else: typeBodyStr) & "\n"

proc genActor(ctx: var OdinCodegenCtx, d: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  var queueSize = "8"
  for attr in d.attrs:
    if attr.name == "queue":
      queueSize = attr.value
      break

  let msgEnumName = d.name & "MsgKind"
  let msgTypeName = d.name & "Msg"
  var enumVariants: seq[string]
  for h in d.handlers:
    if h.kind == dkFn:
      enumVariants.add("msg" & h.name.capitalize())

  if enumVariants.len == 0:
    # No message handlers: an empty enum is invalid. Emit the state, its
    # singleton, and a drain that just parks — the entry point starts every
    # declared actor, so the drain has to exist even with nothing to receive.
    var bareFields: seq[string]
    for f in d.actorFields:
      bareFields.add(ind & "\t" & f.name & ": " & ctx.fieldType(d.name, f) & ",")
    let bareBody = if bareFields.len > 0: bareFields.join("\n") & "\n" else: ""
    return ind & d.name & " :: struct {\n" & bareBody & ind & "}\n\n" &
           ind & actorSingletonName(d.name) & ": " & d.name & "\n\n" &
           ind & "drain_" & d.name & " :: proc() {\n" &
           ind & "\tfor { rt.coroYield() }\n" & ind & "}\n"

  # Handler params ride in the message envelope (deduped by name)
  var msgFields: seq[string]
  var seenMsgFields = initHashSet[string]()
  for h in d.handlers:
    if h.kind == dkFn:
      for p in h.fnParams:
        if p.name notin seenMsgFields:
          seenMsgFields.incl(p.name)
          msgFields.add(ind & "\t" & p.name & ": " & ctx.odinType(p.typ) & ",")

  var res = ind & msgEnumName & " :: enum { " & enumVariants.join(", ") & " }\n"
  res.add(ind & msgTypeName & " :: struct {\n" &
          ind & "\tkind: " & msgEnumName & ",\n" &
          (if msgFields.len > 0: msgFields.join("\n") & "\n" else: "") &
          ind & "}\n")

  # Actor state struct
  var fieldsStr: seq[string]
  for f in d.actorFields:
    fieldsStr.add(ind & "\t" & f.name & ": " & ctx.fieldType(d.name, f) & ",")
  fieldsStr.add(ind & "\tmailbox: rt.Mailbox(" & msgTypeName & ", " &
                queueSize & "),")

  # Dispatch. Odin has no methods, so the actor rides as a `self` pointer and
  # field access inside a handler goes through it.
  var handlerCases: seq[string]
  var hctx = OdinCodegenCtx(definedVars: initHashSet[string](),
                            fieldVars: initHashSet[string](),
                            fieldPrefix: "self.", indent: ctx.indent + 1,
                            module: ctx.module, realModules: ctx.realModules,
                            errPolicy: ctx.errPolicy)
  for f in d.actorFields:
    hctx.fieldVars.incl(f.name)
  for h in d.handlers:
    if h.kind == dkFn:
      let variantName = "msg" & h.name.capitalize()
      var caseBody = ""
      for p in h.fnParams:
        hctx.definedVars.incl(p.name)
        caseBody.add(ind & "\t\t" & p.name & " := msg." & p.name & "\n")
      let bodyStr = hctx.genOdinExpr(h.fnBody)
      handlerCases.add(ind & "\tcase ." & variantName & ":\n" & caseBody & bodyStr)
  for hstr in hctx.hoisted:
    if hstr notin ctx.hoisted: ctx.hoisted.add(hstr)
  for sig, name in hctx.recShapes:
    if sig notin ctx.recShapes: ctx.recShapes[sig] = name

  res.add(ind & d.name & " :: struct {\n" & fieldsStr.join("\n") & "\n" &
          ind & "}\n\n")
  # One instance per declared actor (spec §9.1); sends and field reads
  # target it, so `Counter.total` means `counterSingleton.total`.
  res.add(ind & actorSingletonName(d.name) & ": " & d.name & "\n\n")
  res.add(ind & "handleMsg_" & d.name & " :: proc(self: ^" & d.name &
          ", msg: " & msgTypeName & ") {\n" &
          ind & "\tswitch msg.kind {\n" & handlerCases.join("\n") & "\n" &
          ind & "\t}\n" & ind & "}\n")
  # Drain loop: the actor's coroutine body. Parks when the mailbox empties;
  # tuckNotifySend wakes it after a send.
  res.add("\n" & ind & "drain_" & d.name & " :: proc() {\n" &
          ind & "\tfor {\n" &
          ind & "\t\tmsg: " & msgTypeName & "\n" &
          ind & "\t\tfor rt.dequeue(&" & actorSingletonName(d.name) &
          ".mailbox, &msg) {\n" &
          ind & "\t\t\thandleMsg_" & d.name & "(&" &
          actorSingletonName(d.name) & ", msg)\n" &
          ind & "\t\t}\n" &
          ind & "\t\trt.coroYield()\n" &
          ind & "\t}\n" & ind & "}\n")

  # Send helpers: enqueue an envelope; a full ring drops (spec §9.1)
  for h in d.handlers:
    if h.kind == dkFn:
      let helperName = "send" & h.name.capitalize() & "_" & d.name
      let variantName = "msg" & h.name.capitalize()
      var helperParams: seq[string]
      var ctorArgs = "kind = ." & variantName
      for p in h.fnParams:
        helperParams.add(p.name & ": " & ctx.odinType(p.typ))
        ctorArgs.add(", " & p.name & " = " & p.name)
      let sep = if helperParams.len > 0: ", " else: ""
      res.add("\n" & ind & helperName & " :: proc(self: ^" & d.name & sep &
              helperParams.join(", ") & ") {\n" &
              ind & "\t_ = rt.enqueue(&self.mailbox, " & msgTypeName &
              "{" & ctorArgs & "})\n" & ind & "}\n")
  return res

proc genRegistry(ctx: var OdinCodegenCtx, d: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  let msgEnumName = d.name & "Kind"
  var enumVariants: seq[string]
  var fieldsStr: seq[string]
  var seenFields = initHashSet[string]()
  for v in d.variants:
    enumVariants.add(v.name)
    for f in v.fields:
      if f.name notin seenFields:
        seenFields.incl(f.name)
        fieldsStr.add(ind & "\t" & f.name & ": " & ctx.odinType(f.typ) & ",")

  let enumStr = ind & msgEnumName & " :: enum { " & enumVariants.join(", ") & " }\n"
  let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") & "\n" else: ""
  let typeStr = ind & d.name & " :: struct {\n" &
                ind & "\tkind: " & msgEnumName & ",\n" & fieldsBody & ind & "}\n"
  let globalVarStr = ind & "latest" & d.name & ": " & d.name & "\n\n"

  # Odin resolves package-level declaration order lazily: no forward decls
  var raiseProcsStr = ""
  for v in d.variants:
    var params: seq[string]
    var assignParts: seq[string]
    for f in v.fields:
      params.add(f.name & ": " & ctx.odinType(f.typ))
      assignParts.add(f.name & " = " & f.name)
    let paramStr = params.join(", ")
    let assignStr = if assignParts.len > 0: ", " & assignParts.join(", ") else: ""

    let handlerName = d.name & "." & v.name
    let handlerNameSanitized = d.name & "_" & v.name
    var handlerCalls: seq[string]
    for decl in ctx.module.decls:
      if decl.kind == dkFn and decl.name == handlerName:
        var argNames: seq[string]
        for f in v.fields: argNames.add(f.name)
        handlerCalls.add(ind & "\t" & handlerNameSanitized & "(" &
                         argNames.join(", ") & ")")

    let handlerInvokes = if handlerCalls.len > 0: handlerCalls.join("\n") & "\n" else: ""
    raiseProcsStr.add(ind & "raise_" & d.name & "_" & v.name &
                      " :: proc(" & paramStr & ") {\n" &
                      ind & "\tlatest" & d.name & " = " & d.name &
                      "{kind = ." & v.name & assignStr & "}\n" &
                      handlerInvokes & ind & "}\n\n")

  return enumStr & typeStr & "\n" & globalVarStr & raiseProcsStr

# rt-implemented extern of a library module: forward to the Odin runtime,
# converting the runtime's record shapes to this module's hoisted shapes.
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
    # A bare `fn` param on an extern (std/scheduler's `waitUntil {pred: fn}`)
    # is a PREDICATE the runtime calls, so it needs a callable proc type —
    # `rawptr` would not convert at the rt boundary.
    var pt = if p.typ != nil and p.typ.kind == tkNamed and p.typ.name == "fn":
               "proc() -> bool"
             else: ctx.odinType(p.typ)
    # Odin marks a polymorphic param at the DECLARATION site: `value: $T`, not
    # `value: T`. Without the sigil T is an undeclared name, so any generic
    # extern forwarder (std/str's toStr) failed to compile.
    if p.typ != nil and p.typ.kind == tkNamed and p.typ.name in mem.fnGenerics:
      pt = "$" & pt
    params.add(p.name & ": " & pt)
    argNames.add(p.name)
  let callStr = alias & "." & mem.name & "(" & argNames.join(", ") & ")"
  let (bw, _, binnerT) = ctx.odinBangInfo(mem.fnReturnType)
  let retTypeStr = if mem.fnReturnType != nil: ctx.odinType(mem.fnReturnType) else: "void"
  let retStr = if retTypeStr != "void": " -> " & retTypeStr else: ""
  let header = ind & mem.name & " :: proc(" & params.join(", ") & ")" &
               retStr & " {\n"
  if bw and binnerT != nil and binnerT.kind == tkRecord:
    # convert TuckResult(RuntimeShape) -> TuckResult(ModuleShape) field by field
    let recName = recStructName(ctx, binnerT.fields)
    var fieldArgs: seq[string]
    for f in binnerT.fields: fieldArgs.add(f.name & " = r.value." & f.name)
    return header &
      ind & "\tr := " & callStr & "\n" &
      ind & "\tres: " & retTypeStr & "\n" &
      ind & "\tres.status = r.status\n" &
      ind & "\tres.err = r.err\n" &
      ind & "\tif r.status == .Ok {\n" &
      ind & "\t\tres.value = " & recName & "{" & fieldArgs.join(", ") & "}\n" &
      ind & "\t}\n" &
      ind & "\treturn res\n" & ind & "}\n"
  elif mem.fnReturnType != nil and mem.fnReturnType.kind == tkRecord:
    # plain record return: the runtime returns the single raw value, whose
    # fields carry the same names as this module's hoisted shape
    let recName = recStructName(ctx, mem.fnReturnType.fields)
    var fieldArgs: seq[string]
    for f in mem.fnReturnType.fields:
      fieldArgs.add(f.name & " = raw." & f.name)
    return header & ind & "\traw := " & callStr & "\n" &
           ind & "\treturn " & recName & "{" & fieldArgs.join(", ") & "}\n" &
           ind & "}\n"
  elif retTypeStr == "void":
    return header & ind & "\t" & callStr & "\n" & ind & "}\n"
  else:
    return header & ind & "\treturn " & callStr & "\n" & ind & "}\n"

proc composeInto(ctx: var OdinCodegenCtx, compName, objName, ind: string,
                 fields: var seq[string], members: var string): bool =
  ## Materialise `+ compName` onto this object: a mixin's fns become member
  ## fns, a record type's FIELDS MERGE IN (set union, spec §4.5). Mirrors the
  ## Nim backend; only the emitted syntax differs. False if nothing by that
  ## name is declared.
  for cd in ctx.module.decls:
    if cd == nil or cd.name != compName: continue
    if cd.kind == dkMixin:   # composition names a real mixin, never a
                             # pending/extern block
      for mm in cd.mixinMembers:
        if mm.kind == dkFn and mm.fnBody != nil:
          members.add(ctx.genOdinMemberFn(mm, objName) & "\n")
      return true
    if cd.kind == dkType and cd.typeBody != nil and cd.typeBody.kind == tkRecord:
      for f in cd.typeBody.fields:
        fields.add(ind & "\t" & f.name & ": " & ctx.fieldType(objName, f) & ",")
      return true
  false

proc genObjectDecl(ctx: var OdinCodegenCtx, d: Decl, ind: string): string =
  ## A manager object: fields become an Odin struct, members and anything
  ## composed into it come back as package-level procs.
  var fields: seq[string]
  for f in d.objFields:
    fields.add(ind & "\t" & f.name & ": " & ctx.fieldType(d.name, f) & ",")
  var members = ""
  for member in d.objMembers:
    if isCompositionEntry(member):
      let compName = member.expr.operand.name
      if not ctx.composeInto(compName, d.name, ind, fields, members):
        members.add(ind & "// + " & compName & " (undeclared — sketch)\n")
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

proc genOdinDecl*(ctx: var OdinCodegenCtx, d: Decl): string =
  if d == nil: return ""
  if d.kind == dkType and d.span.file.startsWith(ImportedTypeMarker):
    return ""  # defined in its own module; that module's Beef file has it
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
  of dkRegister:
    # Memory-mapped register. Nim emits a `registerMMIO` macro call and Beef
    # an attribute; Odin has neither, so the bits become named masks plus a
    # typed pointer at the MMIO address — the accessors read/write through it.
    var bitConsts: seq[string]
    var accessors: seq[string]
    for f in d.regFields:
      let bitVal = f.typ.name.replace("bit ", "").replace("bits ", "")
      var hasRead = false
      var hasWrite = false
      for a in f.attrs:
        if a.name == "read": hasRead = true
        elif a.name == "write": hasWrite = true
      let canRead = hasRead or not hasWrite
      let canWrite = hasWrite or not hasRead
      # `bits 3..7` is a multi-bit FIELD: shift by the low bit and mask the
      # width. A single `bit N` is the one-bit case of the same shape.
      let dotPos = bitVal.find("..")
      let loBit = if dotPos >= 0: bitVal[0 ..< dotPos].strip() else: bitVal
      let hiBit = if dotPos >= 0: bitVal[dotPos + 2 .. ^1].strip() else: bitVal
      let isRange = dotPos >= 0 and loBit != hiBit
      let pfx = d.name & "_" & f.name
      bitConsts.add(ind & pfx & "_SHIFT :: " & loBit)
      if isRange:
        bitConsts.add(ind & pfx & "_WIDTH :: " & hiBit & " - " & loBit & " + 1")
        bitConsts.add(ind & pfx & "_MASK :: u32(1 << u32(" & pfx &
                      "_WIDTH)) - 1")
      if canRead:
        let body = if isRange:
                     "return (" & d.name & "^ >> u32(" & pfx & "_SHIFT)) & " &
                       pfx & "_MASK"
                   else:
                     "return (" & d.name & "^ & (u32(1) << u32(" & pfx &
                       "_SHIFT))) != 0"
        let retT = if isRange: "u32" else: "bool"
        accessors.add(ind & pfx & "_get :: proc() -> " & retT & " {\n" &
                      ind & "\t" & body & "\n" & ind & "}\n")
      if canWrite:
        if isRange:
          accessors.add(ind & pfx & "_set :: proc(value: u32) {\n" &
                        ind & "\tshifted := (value & " & pfx & "_MASK) << u32(" &
                        pfx & "_SHIFT)\n" &
                        ind & "\t" & d.name & "^ = (" & d.name & "^ &~ (" & pfx &
                        "_MASK << u32(" & pfx & "_SHIFT))) | shifted\n" &
                        ind & "}\n")
        else:
          accessors.add(ind & pfx & "_set :: proc(on: bool) {\n" &
                        ind & "\tmask := u32(1) << u32(" & pfx & "_SHIFT)\n" &
                        ind & "\tif on { " & d.name & "^ |= mask } else { " &
                        d.name & "^ &~= mask }\n" & ind & "}\n")
    return ind & d.name & " := cast(^u32)(uintptr(" & d.regAddress & "))\n" &
           bitConsts.join("\n") & "\n" & accessors.join("")
  of dkRegistry:
    return ctx.genRegistry(d)
  of dkImport:
    return ""  # emitOdin has no import lines; same project, same namespace
  of dkStaticAssert:
    ctx.staticAsserts.add(ctx.genOdinExpr(d.assertExpr))
    return ""
  of dkErrors:
    # Global handler: rt logger first (errors are always visible), then the
    # user's handler body.
    var res = ind & "tuck_unhandled :: proc(code: u16, site: string) {\n" &
              ind & "\trt.tuckReportUnhandled(code, site)\n"
    if d.errHandler != nil and d.errHandler.fnBody != nil:
      let oldVars = ctx.definedVars
      ctx.definedVars.incl("code")
      ctx.definedVars.incl("site")
      let oldIndent = ctx.indent
      ctx.indent += 1
      let bodyStr = ctx.genOdinExpr(d.errHandler.fnBody)
      ctx.indent = oldIndent
      ctx.definedVars = oldVars
      var squeezed = ""
      for c in bodyStr:
        if c notin {' ', '\n', '\t'}: squeezed.add(c)
      if squeezed != "" and squeezed != "{}":
        res.add(bodyStr & "\n")
    res.add(ind & "}\n")
    return res
  of dkMixin, dkExtern, dkPending:
    # Pending blocks parse as a mixin named "pending"; emit stubs for members.
    # Extern blocks: rt-implemented fns forward to the Odin runtime (library
    # modules) or emit nothing (entry module); C-imported fns become an Odin
    # `foreign` block with concrete param types.
    var res = ""
    # C bindings group per library: Odin wants ONE `foreign <lib> { ... }`
    # block, not a pragma per proc the way Nim's importc works. The matching
    # `foreign import` line is hoisted to the file header by emitOdin, since
    # it is only legal at package top level.
    var cBindings: seq[string]
    var cLib = ""
    for m in d.mixinMembers:
      if m.kind in {dkType, dkFnSig}:
        # a C struct or callback signature declared in the extern block. Odin
        # needs no pragma for the struct: it never sees the C header, it links
        # object code, so a plain struct with matching fields IS the ABI
        # declaration. The callback does need `proc "c"` — see genOdinDecl.
        res.add(ctx.genOdinDecl(m) & "\n")
      elif m.kind == dkFn and m.isPending:
        res.add(ctx.genPendingStub(m) & "\n")
      elif m.kind == dkFn and not m.isExtern:
        # interface contract (sig only): nothing to emit; a fn with a `self`
        # param materializes at `+ mixin` composition, not standalone
        if m.fnBody == nil: continue
        var hasSelf = false
        for p in m.fnParams:
          if p.name == "self": hasSelf = true
        if hasSelf: continue
        # a mixin is a named bucket of functions (spec 5.1) — emit them
        res.add(ctx.genOdinDecl(m) & "\n")
      elif m.kind == dkFn and m.isExtern and m.externHeader != "":
        var params: seq[string]
        for prm in m.fnParams:
          params.add(prm.name & ": " & ctx.odinType(prm.typ))
        # `-> ret` is omitted entirely for void; "void" is Tuck's internal
        # sentinel, not an Odin type.
        let retT = if m.fnReturnType != nil: ctx.odinType(m.fnReturnType) else: "void"
        let retStr = if retT == "void": "" else: " -> " & retT
        # [emit: "c_name"] names the real C symbol; else the Tuck name. Externs
        # are not mangled (mangle.nim:48), so m.name IS the foreign symbol.
        let cName = if m.externEmit != "": m.externEmit else: m.name
        cBindings.add("\t" & cName & " :: proc(" & params.join(", ") &
                      ")" & retStr & " ---")
        if m.externLib != "": cLib = m.externLib
      elif m.kind == dkFn and m.isExtern and m.externImpl.len > 0:
        # `impl: odin "..."` — the bodies live in a named Odin package rather
        # than the runtime. Odin has no unqualified import, so a bare call to
        # the extern's name can never resolve; emit a local forwarder into the
        # aliased package instead, which keeps call sites identical to Nim's.
        # An `impl:` naming only `nim` leaves nothing to emit here: that block
        # is Nim-backend-only and Odin fails at the undeclared call, which is
        # the honest outcome.
        for (backend, module) in m.externImpl:
          if backend != "odin": continue
          let alias = implAlias(module)
          ctx.implMods[alias] = module
          res.add(ctx.genRtForwarder(m, alias) & "\n")
      elif m.kind == dkFn and m.isExtern and ctx.modPrefix != "":
        res.add(ctx.genRtForwarder(m) & "\n")
    if cBindings.len > 0:
      # A path (vendored `.a`) cannot double as the Odin alias, so the alias is
      # derived from the file stem and the path rides along as the import spec.
      # `foreign import <alias> "<spec>"` — mirrors tuck_coro.odin's minicoro.a.
      let libAlias = if cLib == "": "c"
                     elif '/' in cLib or '.' in cLib:
                       # ".../libpoint.a" -> "point"
                       var stem = cLib.rsplit('/', 1)[^1]
                       if stem.startsWith("lib"): stem = stem[3 .. ^1]
                       stem.rsplit('.', 1)[0]
                     else: cLib
      ctx.foreignLibs[libAlias] = cLib
      res.add("@(default_calling_convention=\"c\")\n")
      res.add("foreign " & libAlias & " {\n" & cBindings.join("\n") & "\n}\n")
    return res
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

proc emitOdin*(m: Module,
               realModules = initTable[string, Module](),
               moduleName = "main"): string =
  # indent 0: Odin declarations are top-level in a package, with no
  # enclosing class the way Beef/C# needs one.
  var ctx = OdinCodegenCtx(definedVars: initHashSet[string](),
                           fieldVars: initHashSet[string](),
                           fieldPrefix: "self.", indent: 0, module: m,
                           realModules: realModules, moduleName: moduleName)
  for d in m.decls:
    if d != nil and d.kind == dkErrors:
      ctx.errPolicy = d.policyName
  let (body, mains) = ctx.emitBody(m)
  var res = odinPackage
  # Only import what the emitted body actually uses — Odin rejects unused
  # imports, so an unconditional header would fail to compile on any program
  # that happens not to touch the runtime.
  # The runtime boot below emits rt.* calls of its own, so decide on the
  # import from the DECLARATIONS, not just the already-emitted body.
  var bootUsesRt = false
  var bootMainReturns = false
  for d in m.decls:
    if d == nil: continue
    if d.kind in {dkActor, dkTask}: bootUsesRt = true
    elif d.kind == dkFn and d.name == mangleName("main") and not d.isPending:
      bootMainReturns = d.fnReturnType != nil and
                        not (d.fnReturnType.kind == tkNamed and
                             d.fnReturnType.name == "void")
  var imports: seq[string]
  if "fmt." in body or "fmt." in mains:
    imports.add("import \"core:fmt\"")
  # a value-returning main exits through os.exit
  if bootMainReturns or "os." in body:
    imports.add("import \"core:os\"")
  if bootUsesRt or "rt." in body or "rt." in mains:
    imports.add("import rt \"./tuckrt\"")
  # Imported Tuck modules are sibling packages (mod_<name>/), referenced
  # qualified as `<name>.fn` — import each one the body actually calls.
  # The alias keeps the Tuck name even when it shadows an Odin core package
  # (a module called `io` is fine as long as core:io isn't also imported).
  for modName in realModules.keys:
    let pkg = modName.replace("-", "_")
    if (pkg & ".") in body or (pkg & ".") in mains:
      imports.add("import " & pkg & " \"./mod_" & pkg & "\"")
  # C libraries bound by extern blocks — see emitOdinModule for why these are
  # hoisted here rather than emitted beside the `foreign` block.
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
  # Tuck's `fn main` is a plain proc; Odin's entry point calls it. Static
  # asserts fold into the same entry (Odin has #assert for compile-time,
  # but these are runtime-checked in the Beef path too).
  res.add("main :: proc() {\n")
  for a in ctx.staticAsserts:
    res.add("\tassert(" & a & ")\n")
  # Runtime boot mirrors the Nim entry (tuck.nim): init the scheduler and
  # reactor, start every actor's drain coroutine, run main, then drive the
  # loop so spawned tasks and actors get to finish.
  var actorNames: seq[string]
  var hasTasks = false
  for d in m.decls:
    if d == nil: continue
    if d.kind == dkActor: actorNames.add(d.name)
    elif d.kind == dkTask: hasTasks = true
  let usesRuntime = actorNames.len > 0 or hasTasks
  if usesRuntime:
    res.add("\trt.tuckAsyncInit()\n")
    for a in actorNames:
      res.add("\trt.tuckStartActor(drain_" & a & ")\n")
  if mains != "":
    res.add(mains & "\n")
  # A value-returning `fn main` IS the process exit code (mirrors tuck.nim).
  var mainReturns = false
  let tuckMain = mangleName("main")
  for d in m.decls:
    if d != nil and d.kind == dkFn and d.name == tuckMain and not d.isPending:
      mainReturns = d.fnReturnType != nil and
                    not (d.fnReturnType.kind == tkNamed and
                         d.fnReturnType.name == "void")
      res.add(if mainReturns: "\tmainRc := " & tuckMain & "()\n"
              else: "\t" & tuckMain & "()\n")
      break
  # Drive the loop only when TASKS exist. Actors are daemons whose drain
  # loops never finish, so running the scheduler for them would spin
  # forever — tuck.nim gates on hasTasks for exactly this reason.
  if hasTasks:
    res.add("\trt.tuckRun()\n")
  if mainReturns:
    res.add("\tos.exit(mainRc)\n")
  res.add("}\n")
  res

# A library module (import target). Odin has no static classes: a module is
# a package, and a qualified ref (`fs::readFile`) becomes `fs.readFile` via
# the import alias, so the declarations sit at top level here too.
proc emitOdinModule*(name: string, m: Module,
                     realModules = initTable[string, Module]()): string =
  let pkg = name.replace("-", "_")
  var ctx = OdinCodegenCtx(definedVars: initHashSet[string](),
                           fieldVars: initHashSet[string](),
                           fieldPrefix: "self.", indent: 0, module: m,
                           realModules: realModules, moduleName: name,
                           modPrefix: pkg & "_")
  for d in m.decls:
    if d != nil and d.kind == dkErrors:
      ctx.errPolicy = d.policyName
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
