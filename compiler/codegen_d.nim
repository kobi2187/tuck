# compiler/codegen_d.nim
# D (dlang) backend — the third backend beside codegen.nim (Nim) and
# codegen_odin.nim (Odin). ROADMAP "Experimental #1".
#
# Structure mirrors codegen_odin.nim (ctx object, small gen* procs, flat
# exhaustive dispatches). The EMITTED code follows one rule: for each Tuck
# construct use the most identical native D construct, but only where the
# semantics match what codegen.nim (the authority) implements — e.g. Seq[T]
# emits as a native T[] slice, match will emit as `final switch`, but !T/?T
# stays a value-carried TuckResult (D exceptions unwind nonlocally, which is
# a different semantic, so they are out).
#
# A construct this backend cannot emit yet DIES LOUDLY at emission time
# (dUnsupported) — never silent wrong code. Exception: an extern forwarder
# whose signature needs a not-yet-ported type emits a visible TODO comment;
# the D compiler then fails only if a call site actually references it,
# naming the symbol.
import ast, strutils, sets, tables, options
import resolution
import ast_query
import codegen_common
import lowering                # getFieldsForType
# Shared, ctx-free helpers that happen to live in the Odin backend's util
# module: the record-shape hash (so both backends name a shape alike) and the
# enum a bare tag belongs to. Neither is Odin-specific; if a third consumer
# appears they should move to a backend-neutral module.
from codegen_odin_util import odinErrCode, enumTagOwner
from mangle import mangleName
from lowering_d import needsDup

type
  DCodegenCtx = object
    definedVars: HashSet[string]
    indent: int           # statement indent, in 4-space levels
    module: Module
    hoisted: seq[string]  # named decls hoisted out of field positions (records)
    recShapes: Table[string, string]  # record shape signature -> struct name
    modPrefix: string     # library modules prefix hoisted names
    realModules: Table[string, Module]
    moduleName: string
    tmpCounter: int
    currentParams: seq[FieldDef]  # enclosing fn's params — `input` rebuilds them
    retWrapped: bool       # current fn returns !T/?T — returns auto-wrap
    retInnerD: string      # D type of the payload (for terr!T)
    retInnerT: Type        # payload Tuck type (typed struct-literal returns)
    fieldVars: HashSet[string]  # inside an invariant: names that are fields
    fieldPrefix: string         # what those names are reached through

proc dUnsupported(construct: string): string =
  ## The D backend refuses what it cannot yet emit — loudly, at emission
  ## time, naming the construct. Silent wrong code is the one forbidden
  ## outcome (see the actor/task plan: those arrive with the Fiber runtime).
  quit("tuck: D backend does not yet support " & construct, 1)

# ---------------------------------------------------------------- types --

const dPrims = {
  # Tuck int is 64-bit (ROADMAP 2026-08-25 ruling 1); D's `int` is 32-bit,
  # so the bare word maps to `long` — the first hidden Nim-ism this backend
  # exists to flush out.
  "int": "long", "i8": "byte", "i16": "short", "i32": "int", "i64": "long",
  "u8": "ubyte", "u16": "ushort", "u32": "uint", "u64": "ulong",
  "f32": "float", "f64": "double", "float": "double",
  "bool": "bool", "str": "string", "void": "void", "unit": "void",
}.toTable

proc recStructNameD(ctx: var DCodegenCtx, fields: seq[FieldDef],
                    owner = ""): string

proc dAlias*(moduleName: string): string =
  ## A Tuck module's name as a D identifier — the import alias at a use site
  ## and the `mod_<alias>` file it comes from. One spelling rule in one
  ## place: it was written out at nine call sites, which is how a module
  ## named `net-http` ends up half-translated.
  moduleName.replace("-", "_")

proc seqElem*(t: Type): Type =
  ## The element type of a `Seq[T]`, or nil for anything else. One predicate
  ## for the four places that used to re-test `tkApp and base.name == "Seq"`
  ## by hand (type mapping, declaration types, .len, .dup).
  if t != nil and t.kind == tkApp and t.base != nil and
     t.base.kind == tkNamed and t.base.name == "Seq" and t.args.len == 1:
    t.args[0]
  else: nil

proc bangInner*(t: Type): Type =
  ## The payload of a `!T` / `?T` / `!?T`, or nil when the type is plain.
  ## Both spellings are ONE carrier (rt.TuckResult) whose status says which
  ## — see codegen.nim's bangInfo.
  if t != nil and t.kind == tkApp and t.base != nil and
     t.base.kind == tkNamed and t.base.name in ["!", "?", "!?"] and
     t.args.len == 1:
    t.args[0]
  else: nil

proc importedTypeQualifierD(ctx: DCodegenCtx, name: string): string =
  ## A type declared in an IMPORTED module lives in that module's D file, so
  ## it must be referenced through the import alias (`time.tuck_Milliseconds`)
  ## — D, like Odin, never merges module scopes. Port of the Odin helper.
  for d in ctx.module.decls:
    if d == nil or d.kind != dkType or d.name != name: continue
    if not d.span.file.startsWith(ImportedTypeMarker & ":"): break
    let origin = d.span.file[ImportedTypeMarker.len + 1 .. ^1]
    let pkg = dAlias(origin)
    if pkg != dAlias(ctx.moduleName): return pkg & "." & name
    break
  name

type TypeMode = enum
  ## How a type walk answers a type it cannot map.
  tmRequired   ## a position that MUST have a type: die naming the construct
  tmOptional   ## a declaration, which can fall back to `auto`: answer ""

proc dTypeIn(ctx: var DCodegenCtx, t: Type, mode: TypeMode): string

proc dAppType(ctx: var DCodegenCtx, t: Type, mode: TypeMode): string =
  ## The two type applications this backend maps: `Seq[T]` and the `!T`/`?T`
  ## result carrier. Anything else is a gap named at the point of use.
  ##
  ## Seq[T] is a native D dynamic array — same value-semantics contract as
  ## the Nim backend's seq[T] (assignment copies; D slices alias, which the
  ## emitter compensates for at assignment sites — see the T17 audit).
  let payload = bangInner(t)
  if payload != nil:
    # !T / ?T / !?T — ONE value carrier, the status says which. `!void` has
    # no empty type to carry, so it carries the unit struct.
    let inner = ctx.dTypeIn(payload, mode)
    if inner == "": return ""
    if inner == "void": return "rt.TuckResult!(rt.TuckUnit)"
    return "rt.TuckResult!(" & inner & ")"
  let elem = seqElem(t)
  if elem != nil:
    let elemStr = ctx.dTypeIn(elem, mode)
    return if elemStr == "": "" else: elemStr & "[]"
  let baseName = if t.base != nil and t.base.kind == tkNamed: t.base.name
                 else: "?"
  if mode == tmRequired: dUnsupported("type application " & baseName & "[...]")
  else: ""

proc dTypeIn(ctx: var DCodegenCtx, t: Type, mode: TypeMode): string =
  ## The one type walk. It was two near-identical copies — dType (dies) and
  ## dDeclType (returns "") — which is a shape that drifts: a mapping added
  ## to one silently missed the other.
  template giveUp(what: string): string =
    if mode == tmRequired: dUnsupported(what) else: ""
  if t == nil: return (if mode == tmRequired: "void" else: "")
  case t.kind
  of tkNamed:
    if t.name in dPrims: dPrims[t.name]
    elif t.name == UnknownName or t.name == PendingName:
      # a declaration cannot state a sentinel; a signature position must
      if mode == tmRequired: "void" else: ""
    elif t.name.startsWith("<"): giveUp("type sentinel " & t.name)
    else: ctx.importedTypeQualifierD(t.name)
  of tkApp: ctx.dAppType(t, mode)
  of tkTuple: giveUp("tuple type")
  of tkFunc: giveUp("fn-typed value (fnsig)")
  of tkRecord:
    # A record shape is nameable in both modes — it hoists its own struct.
    ctx.recStructNameD(t.fields)
  of tkSum: giveUp("inline sum type")
  of tkUnion: giveUp("union type")
  of tkEffect: ctx.dTypeIn(t.inner, mode)  # [io]: no type-level footprint
  of tkRename: ctx.dTypeIn(t.underlying, mode)

proc dType(ctx: var DCodegenCtx, t: Type): string =
  ## A type in a position that must have one — a param, a return, a field.
  ctx.dTypeIn(t, tmRequired)

proc dDeclType(ctx: var DCodegenCtx, t: Type): string =
  ## A type for a variable declaration, or "" when it cannot be stated and
  ## the caller should fall back to `auto`.
  ctx.dTypeIn(t, tmOptional)

proc recStructNameD(ctx: var DCodegenCtx, fields: seq[FieldDef],
                    owner = ""): string =
  ## An anonymous record shape gets one hoisted named struct per distinct
  ## field-name+type signature — same TRec_<fields>_<hash> naming as the
  ## Odin backend (same FNV fold), so the two outputs read alike.
  ##
  ## `owner`: the module that DECLARED the shape, when that is not this one.
  ## A library module prefixes its hoisted names (modPrefix), so the same
  ## shape is `TRec_fs_content_2C8C` there and `TRec_content_2C8C` here —
  ## two distinct D types for one Tuck record. The caller must name the
  ## declaring module's struct, through its import alias. (Odin never hit
  ## this because `:=` infers the type and never spells it.)
  var sigParts: seq[string]
  var typeStrs: seq[string]
  for f in fields:
    let ts = ctx.dType(f.typ)
    typeStrs.add(ts)
    sigParts.add(f.name & ":" & ts)
  let sig = sigParts.join(",")
  if owner != "" and owner != ctx.moduleName:
    var nameParts: seq[string]
    for f in fields: nameParts.add(f.name)
    let alias = dAlias(owner)
    return alias & ".TRec_" & alias & "_" & nameParts.join("_") & "_" &
           toHex(odinErrCode(sig))
  if sig in ctx.recShapes:
    return ctx.recShapes[sig]
  var nameParts: seq[string]
  for f in fields: nameParts.add(f.name)
  let name = "TRec_" & ctx.modPrefix & nameParts.join("_") & "_" &
             toHex(odinErrCode(sig))
  ctx.recShapes[sig] = name
  var res = "struct " & name & " {\n"
  for i, f in fields:
    res.add("    " & typeStrs[i] & " " & f.name & ";\n")
  res.add("}")
  ctx.hoisted.add(res)
  name

# ---------------------------------------------------------- expressions --

proc genDExpr(ctx: var DCodegenCtx, e: Expr): string

proc declaresFnD(m: Module, name: string): bool =
  ## Same predicate as the Odin backend's declaresFn (private there).
  m.findFn(name) != nil

proc importDeclaring(ctx: DCodegenCtx, name: string): string =
  ## The imported module that declares `name` as a callable, or "" when this
  ## module declares it (local wins) or nobody does. D has no cross-module
  ## scope merge, so every foreign call has to be qualified — three separate
  ## copies of this search had grown before it was named once.
  if name == "" or ctx.module.declaresFnD(name): return ""
  for modName, im in ctx.realModules:
    if im.declaresFnD(name): return modName
  ""

proc genDQualified(ctx: DCodegenCtx, e: Expr): string =
  ## An imported module's fn is always `alias.name`. Local declarations win;
  ## only a name this module does not declare is searched for.
  let modName = if e.modulePath.len > 0: e.modulePath[0] else: ""
  if modName == "":
    let owner = ctx.importDeclaring(e.qualName)
    return if owner == "": e.qualName else: dAlias(owner) & "." & e.qualName
  if modName in ctx.realModules:
    return dAlias(modName) & "." & e.qualName
  # not an imported Tuck module: a foreign namespace, flattened by the
  # mangler into one name
  modName & "_" & e.qualName

proc genDLit(e: Expr): string =
  case e.litKind
  of lkStr: "\"" & e.litValue & "\""
  of lkInt, lkFloat, lkBool: e.litValue
  of lkUnit: ""

const dWideTypes = ["long", "double", "string", "bool", "void"]
  ## Types a narrowing cast must NOT be applied to. No "auto": the emitter
  ## never produces one (see genDAssign).

proc recCtorFromLiteralD(ctx: var DCodegenCtx, declFields: seq[FieldDef],
                         litFields: seq[FieldInit]): string =
  ## Named-argument struct literal — D's native `T(a: 1, b: 2)` (2.103+).
  ## A field the literal omits stays .init, same zero-value story as Odin.
  ## Narrow numeric fields cast explicitly: D's implicit conversions stop at
  ## VRP over literals, and a long variable into a short field is an error.
  let structName = ctx.recStructNameD(declFields)
  var parts: seq[string]
  for fd in declFields:
    for f in litFields:
      if f.name == fd.name:
        let fieldD = ctx.dType(fd.typ)
        let ex = ctx.genDExpr(f.value)
        if fieldD notin dWideTypes and
           (fieldD.startsWith("u") or fieldD.startsWith("i") or
            fieldD in ["byte", "short", "float"]):
          parts.add(fd.name & ": cast(" & fieldD & ")(" & ex & ")")
        else:
          parts.add(fd.name & ": " & ex)
        break
  structName & "(" & parts.join(", ") & ")"

proc genDStructLit(ctx: var DCodegenCtx, e: Expr): string =
  ## A struct literal outside call/return payload positions: land it on the
  ## checker-stamped record shape, or hoist one inferred from the literal.
  var declFields: seq[FieldDef]
  if semLayer.typeFor(e) != nil:
    declFields = getFieldsForType(ctx.module, semLayer.typeFor(e))
  var allKnown = declFields.len > 0
  for f in declFields:
    if hasUnknownType(f.typ): allKnown = false
  if allKnown:
    return ctx.recCtorFromLiteralD(declFields, e.fields)
  var inferred: seq[FieldDef]
  for f in e.fields:
    var ft = inferLitType(f.value)
    if ft == nil:
      return dUnsupported("struct literal with an uninferable field '" &
                          f.name & "'")
    inferred.add(FieldDef(name: f.name, typ: ft, span: e.span))
  ctx.recCtorFromLiteralD(inferred, e.fields)

proc expectedParamNamesD(ctx: var DCodegenCtx, e: Expr,
                         calleeStr: string): seq[string] =
  ## Param order lives with the fn, not the payload literal — mirror of the
  ## Odin backend's expectedParamNames.
  if e.callee != nil and e.callee.kind == exkQualified and
     e.callee.modulePath.len > 0 and e.callee.modulePath[0] in ctx.realModules:
    return lookupFnParams(ctx.realModules[e.callee.modulePath[0]],
                          e.callee.qualName)
  if semLayer.callParamsFor(e).len > 0: return semLayer.callParamsFor(e)
  lookupFnParams(ctx.module, calleeStr)

proc payloadFieldArgD(ctx: var DCodegenCtx, payload: Expr,
                      fieldName: string): string =
  for f in payload.fields:
    if f.name == fieldName: return ctx.genDExpr(f.value)
  # A param the payload does not carry: D default-initializes, but an absent
  # argument cannot be spelled positionally — refuse rather than guess.
  dUnsupported("call omitting parameter '" & fieldName & "'")

proc genDPayloadArgs(ctx: var DCodegenCtx, e: Expr,
                     calleeStr: string): seq[string] =
  ## A payload's fields, ordered to match the callee's params. The checker
  ## already decided which field feeds each param (semLayer.argFieldsFor);
  ## replay that decision, never re-derive it.
  let expected = ctx.expectedParamNamesD(e, calleeStr)
  if expected.len == 0:
    for f in e.args[0].fields: result.add(ctx.genDExpr(f.value))
    return
  let resolved = semLayer.argFieldsFor(e)
  for i, paramName in expected:
    let fieldName = if i < resolved.len and resolved[i].len > 0: resolved[i]
                    else: paramName
    result.add(ctx.payloadFieldArgD(e.args[0], fieldName))

proc genDCallArgs(ctx: var DCodegenCtx, e: Expr,
                  calleeStr: string): seq[string] =
  if e.args.len == 1 and e.args[0].kind == exkStruct:
    return ctx.genDPayloadArgs(e, calleeStr)
  for a in e.args: result.add(ctx.genDExpr(a))

proc explodeRecordArgD(ctx: var DCodegenCtx, e: Expr,
                       calleeStr: string): string =
  ## A record-typed VAR as the whole payload (`p advance`) explodes to the
  ## fn's params by field, replaying the checker's mapping. Mirror of the
  ## Odin backend's explodeRecordArg.
  if e.args.len != 1 or e.args[0].kind != exkVar: return ""
  let params = if semLayer.callParamsFor(e).len > 0: semLayer.callParamsFor(e)
               else: lookupFnParams(ctx.module, calleeStr)
  if params.len == 0: return ""
  let fields = recordFieldNames(ctx.module, semLayer.typeFor(e.args[0]))
  if fields.len == 0: return ""
  let resolved = semLayer.argFieldsFor(e)
  var parts: seq[string]
  for i, paramName in params:
    let fieldName = if i < resolved.len and resolved[i].len > 0: resolved[i]
                    else: paramName
    if fieldName notin fields: return ""
    parts.add(ctx.genDExpr(e.args[0]) & "." & fieldName)
  calleeStr & "(" & parts.join(", ") & ")"

proc isRecordConstructionD(ctx: DCodegenCtx, e: Expr): bool =
  e.args.len == 1 and e.args[0].kind == exkStruct and
    e.callee != nil and e.callee.kind == exkVar and
    isRecordType(ctx.module, e.callee.name)

proc genDRecordCtor(ctx: var DCodegenCtx, e: Expr): string =
  ## `{fields} TypeName` — a named-argument struct literal of the DECLARED
  ## type. A production site: an invariant-carrying value validates before
  ## it flows on (spec 4.7).
  var parts: seq[string]
  for f in e.args[0].fields:
    parts.add(f.name & ": " & ctx.genDExpr(f.value))
  let ctor = e.callee.name & "(" & parts.join(", ") & ")"
  if hasInvariants(ctx.module, e.callee.name):
    return "__validated_" & e.callee.name & "(" & ctor & ")"
  ctor

proc genDBake(ctx: var DCodegenCtx, e: Expr): string =
  ## expr bake {slot: value, ...} — rebuild the record with slots overridden
  ## (adding fields grows the shape). Port of genOdinBake.
  if e.args[0].kind != exkVar: return ""
  let recv = ctx.genDExpr(e.args[0])
  let recvFields = recordFieldNames(ctx.module, semLayer.typeFor(e.args[0]))
  if recvFields.len == 0: return ""
  var declFields: seq[FieldDef]
  for f in getFieldsForType(ctx.module, semLayer.typeFor(e.args[0])):
    declFields.add(f)
  var parts: seq[string]
  for fname in recvFields:
    var overridden = ""
    for (name, valExpr) in e.args[1].fields.items:
      if name == fname: overridden = ctx.genDExpr(valExpr)
    parts.add(fname & ": " & (if overridden != "": overridden
                              else: recv & "." & fname))
  for (name, valExpr) in e.args[1].fields.items:
    if name notin recvFields:
      parts.add(name & ": " & ctx.genDExpr(valExpr))
      var ft = inferLitType(valExpr)
      if ft == nil: ft = Type(kind: tkNamed, name: UnknownName, span: e.span)
      declFields.add(FieldDef(name: name, typ: ft, span: e.span))
  if parts.len == 0: return recv
  ctx.recStructNameD(declFields) & "(" & parts.join(", ") & ")"

proc genDAlias(ctx: var DCodegenCtx, e: Expr): string =
  ## expr alias(old: new, ...) — rebuild as the renamed record shape.
  if e.args[0].kind != exkVar or semLayer.typeFor(e.args[0]) == nil: return ""
  let recvFields = getFieldsForType(ctx.module, semLayer.typeFor(e.args[0]))
  if recvFields.len == 0: return ""
  var newFields: seq[FieldDef]
  var vals: seq[string]
  let recv = ctx.genDExpr(e.args[0])
  for (oldName, newExpr) in e.args[1].fields.items:
    var ft: Type = nil
    for rf in recvFields:
      if rf.name == oldName: ft = rf.typ
    if ft == nil or newExpr == nil or newExpr.kind != exkVar: return ""
    newFields.add(FieldDef(name: newExpr.name, typ: ft, span: e.span))
    vals.add(newExpr.name & ": " & recv & "." & oldName)
  ctx.recStructNameD(newFields) & "(" & vals.join(", ") & ")"

proc genDMerge(ctx: var DCodegenCtx, e: Expr): string =
  ## {a, b} merge — flatten the records into one union shape.
  var newFields: seq[FieldDef]
  var vals: seq[string]
  for (mname, mexpr) in e.args[0].fields.items:
    if mexpr.kind != exkVar or semLayer.typeFor(mexpr) == nil: return ""
    let recv = ctx.genDExpr(mexpr)
    for f in getFieldsForType(ctx.module, semLayer.typeFor(mexpr)):
      newFields.add(f)
      vals.add(f.name & ": " & recv & "." & f.name)
  if newFields.len == 0: return ""
  ctx.recStructNameD(newFields) & "(" & vals.join(", ") & ")"

proc genDSaturatingCtor(ctx: var DCodegenCtx, satT: Type,
                        calleeStr, arg: string): string =
  ## spec 4.1: constructing a `[saturating]` type CLAMPS instead of
  ## wrapping. The guard runs on a wider intermediate, so the value is
  ## tested against the type's real bounds rather than after it has already
  ## wrapped — mirrors both other backends.
  let satBase = ctx.dType(satT)
  let unsigned = satBase.startsWith("u")
  let widen = if unsigned: "ulong" else: "long"
  let satFn = if unsigned: "rt.tuckSat" else: "rt.tuckSatI"
  calleeStr & "(" & satFn & "!(" & satBase & ")(cast(" & widen & ")(" &
    arg & ")))"

proc asCombinatorCallD(ctx: var DCodegenCtx, e: Expr,
                       calleeStr: string): string =
  ## The compile-time combinators; any that declines returns "" and the call
  ## proceeds as a plain one. Same order as the Odin backend.
  if calleeStr == "bake" and e.args.len == 2 and e.args[1].kind == exkStruct:
    return ctx.genDBake(e)
  if ctx.isRecordConstructionD(e): return ctx.genDRecordCtor(e)
  if calleeStr == "alias" and e.args.len == 2 and e.args[1].kind == exkStruct:
    return ctx.genDAlias(e)
  if calleeStr == "merge" and e.args.len == 1 and e.args[0].kind == exkStruct:
    return ctx.genDMerge(e)
  if calleeStr notin ["bake", "alias"]:
    return ctx.explodeRecordArgD(e, calleeStr)
  ""

proc resolveDCallee(ctx: var DCodegenCtx, e: Expr): string =
  ## A bare-name callee (exkVar) resolves like an unqualified exkQualified:
  ## local declarations win, then the imports. (The Nim backend leans on
  ## Nim's own resolution here and needs no such step.)
  if e.callee != nil and e.callee.kind == exkVar:
    let owner = ctx.importDeclaring(e.callee.name)
    if owner != "": return dAlias(owner) & "." & e.callee.name
  ctx.genDExpr(e.callee)

proc memberProcNameD(objName, memberName: string): string =
  ## Object members emit qualified (`Counter_bump`). D could overload the
  ## bare name like Nim does, but the qualified spelling keeps the three
  ## backends' output diffable and is what interface dispatch keys on.
  objName & "_" & memberName

proc memberOwnerD(ctx: DCodegenCtx, recvT: Type): string =
  if recvT == nil or recvT.kind != tkNamed: return ""
  for d in ctx.module.decls:
    if d != nil and d.kind == dkObject and d.name == recvT.name: return d.name
  ""

proc memberRecvType(e: Expr): Type =
  ## The receiver's type: args[0] itself (the checker's rewrite), or the
  ## `self` field of a payload literal (`{self: c} bump`).
  result = semLayer.typeFor(e.args[0])
  if e.args[0].kind == exkStruct:
    for f in e.args[0].fields:
      if f.name == "self": result = semLayer.typeFor(f.value)

proc ownerDeclares(ctx: DCodegenCtx, owner, fnName: string): bool =
  for d in ctx.module.decls:
    if d == nil or d.kind != dkObject or d.name != owner: continue
    for mem in d.objMembers:
      if mem != nil and mem.kind == dkFn and mem.name == fnName:
        return true
  false

proc memberCalleeNameD(ctx: DCodegenCtx, e: Expr): string =
  ## A member call: derive the qualified name from the receiver's type —
  ## port of the Odin backend's memberCalleeName.
  if e.callee == nil or e.callee.kind != exkVar or e.args.len < 1: return ""
  let owner = ctx.memberOwnerD(memberRecvType(e))
  if owner == "" or not ctx.ownerDeclares(owner, e.callee.name): return ""
  memberProcNameD(owner, e.callee.name)

proc genDCall(ctx: var DCodegenCtx, e: Expr): string =
  var calleeStr = ctx.resolveDCallee(e)
  let member = ctx.memberCalleeNameD(e)
  if member != "": calleeStr = member
  let combinator = ctx.asCombinatorCallD(e, calleeStr)
  if combinator != "": return combinator
  let args = ctx.genDCallArgs(e, calleeStr)
  if calleeStr == "echo":
    # `echo` is the builtin debug print; writeln is D's identical construct.
    return "writeln(" & args.join(", ") & ")"
  let satT = ctx.module.saturatingType(calleeStr)
  if satT != nil and args.len == 1:
    return ctx.genDSaturatingCtor(satT, calleeStr, args[0])
  calleeStr & "(" & args.join(", ") & ")"

proc errCodeArg(ctx: DCodegenCtx, name: string): string =
  ## An error code, folded at COMPILE time by the emitter rather than at
  ## runtime — the same FNV value every backend produces for the same name
  ## (verified: "Math.Odd" is 55587 in Nim, Odin and D alike).
  "0x" & toHex(odinErrCode(name)) & " /* " & name & " */"

proc genDRaise(ctx: var DCodegenCtx, e: Expr): string =
  ## `err X` / `return Error.x` — an early return carrying the code. A
  ## RETURNED value, never a thrown one: Tuck's failure is data.
  let rv = e.raiseVal
  let inner = if ctx.retInnerD != "": ctx.retInnerD else: "rt.TuckUnit"
  if isErrEnumRef(ctx.module, rv):
    let name = errNameFor(ctx.module, ctx.moduleName,
                          rv.receiver.writtenName, rv.fieldName)
    return "return rt.terr!(" & inner & ")(" & ctx.errCodeArg(name) & ")"
  "return rt.terr!(" & inner & ")(cast(ushort)(" & ctx.genDExpr(rv) & "))"

proc isErrorDotRef(v: Expr): bool =
  ## `Error.name` — the app-wide error namespace, hashed by the emitter.
  v.kind == exkField and v.receiver != nil and
    v.receiver.kind == exkVar and v.receiver.name == "Error"

proc genDWrappedReturn(ctx: var DCodegenCtx, v: Expr): string =
  ## The return of a fallible fn: every value leaves wrapped in the carrier.
  if v.kind == exkRaise: return ctx.genDRaise(v)
  if isErrorDotRef(v):
    return "return rt.terr!(" & ctx.retInnerD & ")(" &
           ctx.errCodeArg(v.fieldName) & ")"
  if v.kind == exkStruct and ctx.retInnerT != nil and
     ctx.retInnerT.kind == tkRecord:
    # typed literal: land it on the declared payload shape, casts included
    return "return rt.tok(" &
           ctx.recCtorFromLiteralD(ctx.retInnerT.fields, v.fields) & ")"
  "return rt.tok(" & ctx.genDExpr(v) & ")"

proc genDReturn(ctx: var DCodegenCtx, e: Expr): string =
  if e.returnVal == nil:
    if ctx.retWrapped and ctx.retInnerD == "rt.TuckUnit":
      return "return rt.tokVoid()"
    return "return"
  if ctx.retWrapped: return ctx.genDWrappedReturn(e.returnVal)
  let v = ctx.genDExpr(e.returnVal)
  # production site: handing back a value of an invariant-carrying type
  let rt = semLayer.typeFor(e.returnVal)
  if rt != nil and rt.kind == tkNamed and hasInvariants(ctx.module, rt.name):
    return "return __validated_" & rt.name & "(" & v & ")"
  "return " & v

proc indD(ctx: DCodegenCtx): string = repeat(' ', ctx.indent * 4)

proc dBinOp(op: BinOp): string =
  ## D's `/` follows the operand type (integer operands truncate) — same
  ## property as Odin, so both Tuck divisions map to `/` and the Tuck source
  ## carries the distinction. `^` works on bools and ints alike.
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
  of boRangeIncl, boRangeExcl: ""   # only meaningful inside foreach — genDFor

proc isStringConcatD(e: Expr): bool =
  ## `+` over strings — D's identical construct is the native `~`.
  if e.binOp != boAdd or e.left == nil: return false
  let lt = semLayer.typeFor(e.left)
  lt != nil and lt.kind == tkNamed and lt.name in ["str", "string"]

proc genDBinary(ctx: var DCodegenCtx, e: Expr): string =
  if isStringConcatD(e):
    return "(" & ctx.genDExpr(e.left) & " ~ " & ctx.genDExpr(e.right) & ")"
  if e.binOp in {boRangeIncl, boRangeExcl}:
    return dUnsupported("a range outside a for loop")
  "(" & ctx.genDExpr(e.left) & " " & dBinOp(e.binOp) & " " &
    ctx.genDExpr(e.right) & ")"

proc genDUnary(ctx: var DCodegenCtx, e: Expr): string =
  case e.unaryOp
  of uoNeg: "-" & ctx.genDExpr(e.operand)
  of uoNot: "!" & ctx.genDExpr(e.operand)
  of uoComposition: dUnsupported("composition (+Type member)")
  of uoPropagate:
    # `expr?` — forward failure or absence unchanged. Reaches codegen only
    # if the rewrite pass did not desugar it; refuse rather than drop the
    # propagation silently.
    dUnsupported("expr? in this position")

proc isLenOnSized(ctx: var DCodegenCtx, e: Expr): bool =
  ## `.len` on a str or Seq — D spells the identical native property
  ## `.length`. (The Nim backend emits `.len` untranslated because Nim
  ## happens to share Tuck's spelling — a Nim-ism riding through.)
  if e.fieldName != "len" or e.receiver == nil: return false
  let rt = semLayer.typeFor(e.receiver)
  if rt == nil: return false
  if rt.kind == tkNamed and rt.name in ["str", "string"]: return true
  seqElem(rt) != nil

proc isResultStatusTest(e: Expr): bool =
  ## `r.ok` on a !T/?T value is a STATUS TEST, not a field read.
  if e.fieldName != "ok" or e.receiver == nil: return false
  bangInner(semLayer.typeFor(e.receiver)) != nil

proc genDField(ctx: var DCodegenCtx, e: Expr): string =
  ## A `.name` access: a resolved call, a result's status, the len property,
  ## an input param, or a plain read. (Interface dispatch and actor fields
  ## arrive with their milestones.)
  if e.receiver != nil and e.receiver.kind == exkVar and
     e.receiver.name == "input" and ctx.currentParams.len > 0:
    return e.fieldName   # `input.x` IS the param x
  if isResultStatusTest(e):
    # parenthesised: a guard may negate it (`!r.ok`), and the `!` would
    # otherwise bind to the receiver alone
    return "(" & ctx.genDExpr(e.receiver) & ".status == rt.TuckStatus.Ok)"
  if ctx.isLenOnSized(e):
    # cast: D's .length is size_t (unsigned); Tuck's len is a signed int.
    # Unsigned would poison later arithmetic (n - bigger wraps, comparisons
    # promote) — hidden Nim-ism #3, Nim's .len is already signed.
    return "cast(long) " & ctx.genDExpr(e.receiver) & ".length"
  if semLayer.hasCall(e):
    return ctx.genDExpr(semLayer.call(e))
  ctx.genDExpr(e.receiver) & "." & e.fieldName

proc genDInputPayload(ctx: var DCodegenCtx): string =
  ## `input` — the whole incoming payload, rebuilt as its record shape.
  var vals: seq[string]
  for p in ctx.currentParams: vals.add(p.name & ": " & p.name)
  ctx.recStructNameD(ctx.currentParams) & "(" & vals.join(", ") & ")"

proc qualifyEnumTag(ctx: DCodegenCtx, name: string): string =
  ## A bare enum tag is written `Owner.Tag` in D — enum members do not leak
  ## into module scope (same as Odin, unlike Nim). "" when `name` is not a
  ## declared tag.
  if name.len == 0 or name[0] notin {'A' .. 'Z'}: return ""
  let owner = enumTagOwner(ctx.module, name)
  if owner == "": "" else: owner & "." & name

proc isFnRefD(ctx: DCodegenCtx, e: Expr): bool =
  ## A `:fnRef` filling a callback slot — a declared fn named as a VALUE
  ## rather than called. In D a bare function name in value position is a
  ## call with no arguments, so the reference needs `&`; Nim and Odin both
  ## take the bare name.
  ##
  ## Decided by the checker's TYPE, not the node kind: a ref arrives as
  ## exkVar or exkQualified depending on how it was written, but its type is
  ## a function type either way (verified — `{add: :plus}` reaches codegen
  ## as exkQualified).
  if e == nil or semLayer.hasCall(e): return false
  let t = semLayer.typeFor(e)
  t != nil and t.kind == tkFunc

proc genDVarName(ctx: var DCodegenCtx, e: Expr): string =
  ## A bare name: a checker-stamped call, a pending hole, the whole incoming
  ## payload, an enum tag, or a variable.
  if semLayer.hasCall(e): return ctx.genDExpr(semLayer.call(e))
  if e.name == "...": return ""   # pending hole: compiles, does nothing
  if e.name == "input" and ctx.currentParams.len > 0:
    return ctx.genDInputPayload()
  if e.name in ctx.fieldVars: return ctx.fieldPrefix & e.name
  if e.name notin ctx.definedVars:
    let tag = ctx.qualifyEnumTag(e.name)
    if tag != "": return tag
  e.name

proc dupIfSeq(valStr: string, e: Expr): string =
  ## Wrap in `.dup` if THIS BACKEND'S LOWERING marked the node.
  ##
  ## The decision — a D slice aliases where a Tuck Seq copies — is made in
  ## lowering_d, not here; this reads the mark and prints. That split is the
  ## point of the seam: the reasoning is inspectable and testable as a tree
  ## pass, and the emitter stays a printer.
  if needsDup(e): "(" & valStr & ").dup" else: valStr

proc callOwnerModule(ctx: DCodegenCtx, e: Expr): string =
  ## The imported module a call resolves into, or "" for a local one. A
  ## record shape in that call's RESULT is declared over there, so naming
  ## its type here has to go through the module (see recStructNameD).
  if e == nil or e.kind != exkCall or e.callee == nil: return ""
  if e.callee.kind == exkQualified and e.callee.modulePath.len > 0 and
     e.callee.modulePath[0] in ctx.realModules:
    return e.callee.modulePath[0]
  let bare = case e.callee.kind
             of exkVar: e.callee.name
             of exkQualified: e.callee.qualName
             else: ""
  ctx.importDeclaring(bare)

proc declTypeForValue(ctx: var DCodegenCtx, target, val: Expr): string =
  ## The declared D type for `let x = <val>`, naming a foreign record shape
  ## through its owning module when the value came from one.
  ##
  ## The type is read from the VALUE first: the checker stamps the call, and
  ## a `let` target often carries no stamp of its own (verified — the target
  ## read back nil for `let r = {..} fs::readFile`).
  var t = semLayer.typeFor(val)
  if t == nil: t = semLayer.typeFor(target)
  # `.len` is `int` by definition of the language, but the checker types it
  # <unknown> (verified by instrumenting: a STAMPED sentinel, not a missing
  # stamp). The Nim backend never noticed because it emits `var n = s.len`
  # and lets NIM infer — the hidden-inference dependency this backend exists
  # to avoid. Supply the answer the language already guarantees.
  if val != nil and val.kind == exkField and ctx.isLenOnSized(val) and
     (t == nil or (t.kind == tkNamed and t.name == UnknownName)):
    t = Type(kind: tkNamed, name: "int", span: val.span)
  let owner = ctx.callOwnerModule(val)
  if owner != "" and t != nil:
    let payload = bangInner(t)
    if payload != nil and payload.kind == tkRecord:
      return "rt.TuckResult!(" &
             ctx.recStructNameD(payload.fields, owner) & ")"
    if t.kind == tkRecord:
      return ctx.recStructNameD(t.fields, owner)
  ctx.dDeclType(t)

proc genDAssign(ctx: var DCodegenCtx, e: Expr): string =
  ## First assignment to a name declares it, with the CHECKER'S type stated
  ## explicitly. `auto x = 0` would make x a 32-bit D int while Tuck (and
  ## the Nim backend's inference) makes it 64-bit — a value past 2^31 then
  ## wraps in one backend and not the other. Verified with dmd; hidden
  ## Nim-ism #2.
  ##
  ## NEVER `auto`, and never `var`: Tuck HAS a typechecker, so every
  ## declaration's type is a fact the compiler already established, and the
  ## emitted code states it. Asking the target compiler to re-infer would
  ## make the two inference algorithms agree by luck — which is exactly how
  ## the 32-bit `auto x = 0` divergence got in. A type this backend cannot
  ## state is a GAP, reported like any other, not a request for D to guess.
  let valStr = dupIfSeq(ctx.genDExpr(e.assignVal), e.assignVal)
  if e.target.kind == exkVar and e.target.name notin ctx.definedVars:
    ctx.definedVars.incl(e.target.name)
    let declT = ctx.declTypeForValue(e.target, e.assignVal)
    if declT == "":
      return dUnsupported("a declaration of '" & e.target.name &
                          "' whose type the checker did not settle")
    return declT & " " & e.target.name & " = " & valStr
  ctx.genDExpr(e.target) & " = " & valStr

# --- statements & control flow -------------------------------------------

proc ownsLayoutD(s: Expr): bool =
  ## Constructs that emit their own indentation, braces and newlines.
  s.kind in {exkIf, exkFor, exkWhile, exkBlock, exkMatch, exkChain}

proc genDStmt(ctx: var DCodegenCtx, s: Expr): string =
  ## One statement inside a block: indent + expression + `;`, except the
  ## constructs that lay themselves out.
  if s != nil and ownsLayoutD(s):
    let code = ctx.genDExpr(s)
    if code == "": return ""
    return if code.endsWith("\n"): code else: code & "\n"
  let code = ctx.genDExpr(s)
  if code == "": return ""
  ctx.indD & code & ";\n"

proc genDBlock(ctx: var DCodegenCtx, e: Expr): string =
  for s in e.stmts:
    result.add(ctx.genDStmt(s))

proc genDNested(ctx: var DCodegenCtx, body: Expr): string =
  ## A branch/loop body one level deeper, always brace-wrapped by the caller.
  ctx.indent += 1
  result = if body == nil: ""
           elif body.kind == exkBlock: ctx.genDBlock(body)
           else: ctx.genDStmt(body)
  ctx.indent -= 1

proc isValueIfD(e: Expr): bool =
  ## A value-position `if` (both branches are plain expressions and the
  ## checker stamped a type) emits as D's ternary. Mirrors ast_query's
  ## isValueIf used by the Odin backend.
  isValueIf(e)

proc genDIf(ctx: var DCodegenCtx, e: Expr): string =
  if isValueIfD(e):
    return "(" & ctx.genDExpr(e.cond) & " ? " & ctx.genDExpr(e.thenBranch) &
           " : " & ctx.genDExpr(e.elseBranch) & ")"
  let ind = ctx.indD
  result = ind & "if (" & ctx.genDExpr(e.cond) & ") {\n" &
           ctx.genDNested(e.thenBranch)
  if e.elseBranch != nil:
    if e.elseBranch.kind == exkIf:
      # `elif` chain: fold into `} else if (...)` rather than nesting.
      let elseCode = ctx.genDIf(e.elseBranch)
      result.add(ind & "} else " & elseCode.strip(chars = {' '}, trailing = false))
      return
    result.add(ind & "} else {\n" & ctx.genDNested(e.elseBranch))
  result.add(ind & "}")

proc genDWhile(ctx: var DCodegenCtx, e: Expr): string =
  let cond = if e.whileCond == nil: "true" else: ctx.genDExpr(e.whileCond)
  ctx.indD & "while (" & cond & ") {\n" & ctx.genDNested(e.whileBody) &
    ctx.indD & "}"

proc dForVars(e: Expr): string =
  ## `for idx, item in xs:` — D's foreach yields the index natively, in the
  ## same (index, value) order.
  if e.iter != nil and e.iter.kind == pkTuple and e.iter.elems.len == 2:
    genPatternStr(e.iter.elems[0]) & ", " & genPatternStr(e.iter.elems[1])
  else: genPatternStr(e.iter)

proc genDFor(ctx: var DCodegenCtx, e: Expr): string =
  ## foreach over a range or a value. D ranges are exclusive; the inclusive
  ## Tuck range adds one to the upper bound.
  var iterStr: string
  if e.iterable != nil and e.iterable.kind == exkBinary and
     e.iterable.binOp in {boRangeIncl, boRangeExcl}:
    let lo = ctx.genDExpr(e.iterable.left)
    let hi = ctx.genDExpr(e.iterable.right)
    iterStr = lo & " .. " & (if e.iterable.binOp == boRangeIncl: hi & " + 1"
                             else: hi)
  else:
    iterStr = ctx.genDExpr(e.iterable)
  ctx.indD & "foreach (" & dForVars(e) & "; " & iterStr & ") {\n" &
    ctx.genDNested(e.body) & ctx.indD & "}"

proc genDList(ctx: var DCodegenCtx, e: Expr): string =
  var parts: seq[string]
  for item in e.items: parts.add(ctx.genDExpr(item))
  "[" & parts.join(", ") & "]"

proc dPatternStr(ctx: var DCodegenCtx, pat: Pattern): string =
  ## One arm's pattern as a D case label. A bare tag qualifies to its enum;
  ## a literal stands as written.
  let raw = genPatternStr(pat)
  let tag = ctx.qualifyEnumTag(raw)
  if tag != "": tag else: raw

proc genDMatchArm(ctx: var DCodegenCtx, arm: MatchArm): string =
  ## `case LABEL:` plus its body, indented one level in. Every arm breaks:
  ## D switch cases fall through by default where Tuck's arms never do, so
  ## the break is the semantics, not decoration. (A body ending in `return`
  ## makes it unreachable, so it is omitted there.)
  if arm.guard != nil:
    return dUnsupported("a guarded match arm (M4b)")
  let label = ctx.dPatternStr(arm.pattern)
  let head = if arm.pattern != nil and arm.pattern.kind == pkWild:
               ctx.indD & "default:\n"
             else: ctx.indD & "case " & label & ":\n"
  let body = ctx.genDNested(arm.body)
  let ends = body.strip()
  let needsBreak = not (ends.endsWith("return;") or
                        ends.contains("return ") and ends.endsWith(";") and
                        ends.splitLines()[^1].strip().startsWith("return"))
  ctx.indent += 1
  let brk = if needsBreak: ctx.indD & "break;\n" else: ""
  ctx.indent -= 1
  head & body & brk

proc hasWildArm(e: Expr): bool =
  for arm in e.arms:
    if arm.pattern != nil and arm.pattern.kind == pkWild: return true
  false

proc genDMatchStmt(ctx: var DCodegenCtx, e: Expr): string =
  ## `final switch` — D's own exhaustiveness check, which is exactly the
  ## guarantee Tuck's match makes, so the compiler re-verifies the arm set
  ## rather than the emitter trusting it. An arm set WITH a wildcard cannot
  ## be `final` (D rejects a default there), so those emit a plain switch.
  if e.subject == nil: return dUnsupported("decision table (T24)")
  let kw = if hasWildArm(e): "switch" else: "final switch"
  result = ctx.indD & kw & " (" & ctx.genDExpr(e.subject) & ") {\n"
  for arm in e.arms:
    result.add(ctx.genDMatchArm(arm))
  result.add(ctx.indD & "}")

proc genDMatchExpr(ctx: var DCodegenCtx, e: Expr): string =
  ## A match in VALUE position. D has no switch-expression, so the arms go
  ## into an immediately-called lambda — which, unlike Odin's chained
  ## ternary, keeps the exhaustiveness check and reads as the same table the
  ## statement form does.
  if e.subject == nil: return dUnsupported("decision table in value position")
  let kw = if hasWildArm(e): "switch" else: "final switch"
  let saved = ctx.indent
  ctx.indent = 1
  var arms = ""
  for arm in e.arms:
    if arm.guard != nil:
      ctx.indent = saved
      return dUnsupported("a guarded match arm (M4b)")
    let label = ctx.dPatternStr(arm.pattern)
    let head = if arm.pattern != nil and arm.pattern.kind == pkWild:
                 ctx.indD & "default: "
               else: ctx.indD & "case " & label & ": "
    arms.add(head & "return " & ctx.genDExpr(arm.body) & ";\n")
  ctx.indent = saved
  "(() { " & kw & " (" & ctx.genDExpr(e.subject) & ") {\n" & arms &
    ctx.indD & "} })()"

proc genDChainStep(ctx: var DCodegenCtx, step: ChainStep,
                   baseStr: string): string =
  ## One `..` step: a mutator call reassigned into the base var, or a plain
  ## field set. The checker resolved which; replay it.
  if semLayer.stepCall(step) != nil:
    return ctx.indD & baseStr & " = " &
           ctx.genDCall(semLayer.stepCall(step)) & ";\n"
  let valStr = if isSingleFieldPayload(step.arg):
                 ctx.genDExpr(soleFieldValue(step.arg))
               else: ""
  ctx.indD & baseStr & "." & step.target.name & " = " & valStr & ";\n"

proc genDChain(ctx: var DCodegenCtx, e: Expr): string =
  ## `x ..field {v} ..mutate {a}` — one plain statement per step, then a
  ## re-validation: a MUTATION site is a production site too, since the
  ## value that flows on afterwards is a different one.
  let baseStr = ctx.genDExpr(e.base)
  for step in e.steps:
    result.add(ctx.genDChainStep(step, baseStr))
  if e.base != nil:
    let bt = semLayer.typeFor(e.base)
    if bt != nil and bt.kind == tkNamed and hasInvariants(ctx.module, bt.name):
      result.add(ctx.indD & "validate_" & bt.name & "(" & baseStr & ");\n")

proc genDExpr(ctx: var DCodegenCtx, e: Expr): string =
  if e == nil: return ""
  # A fn used as a VALUE needs `&` in D, whichever way it was written —
  # checked here, where exkVar and exkQualified both pass through.
  if e.kind in {exkVar, exkQualified} and ctx.isFnRefD(e):
    let name = if e.kind == exkVar: ctx.genDVarName(e) else: ctx.genDQualified(e)
    return "&" & name
  case e.kind
  of exkLit: genDLit(e)
  of exkVar: ctx.genDVarName(e)
  of exkField: ctx.genDField(e)
  of exkQualified: ctx.genDQualified(e)
  of exkStruct: ctx.genDStructLit(e)
  of exkList: ctx.genDList(e)
  of exkBracket, exkBracketAssign:
    # Indexing resolved to an at()/setAt() call by the checker; a type
    # application never reaches codegen (mirrors both other backends).
    if semLayer.hasCall(e): ctx.genDExpr(semLayer.call(e)) else: ""
  of exkCall: ctx.genDCall(e)
  of exkChain: ctx.genDChain(e)
  of exkBinary: ctx.genDBinary(e)
  of exkUnary: ctx.genDUnary(e)
  of exkBlock: ctx.genDBlock(e)
  of exkIf: ctx.genDIf(e)
  of exkMatch:
    if matchArmsReturn(e): ctx.genDMatchStmt(e) else: ctx.genDMatchExpr(e)
  of exkFor: ctx.genDFor(e)
  of exkWhile: ctx.genDWhile(e)
  of exkBreak: "break"
  of exkContinue: "continue"
  of exkAssign: ctx.genDAssign(e)
  of exkReturn: ctx.genDReturn(e)
  of exkRaise: ctx.genDRaise(e)
  of exkImport: ""   # imports are assembled by dImports from realModules
  of exkSend: dUnsupported("actor send (arrives with the Fiber runtime)")
  of exkSelect: dUnsupported("on select (arrives with the Fiber runtime)")

# --------------------------------------------------------- declarations --

proc genDParams(ctx: var DCodegenCtx, params: seq[Param],
                refSelf = false): string =
  ## `refSelf`: inside an object member, `self` is D's `ref` — the identical
  ## construct to the `self: var T` the Nim backend emits (verified: two
  ## bumps on one var really accumulate there, so the mutation must reach
  ## the caller's value).
  var parts: seq[string]
  for p in params:
    if refSelf and p.name == "self":
      parts.add("ref " & ctx.dType(p.typ) & " " & p.name)
    else:
      parts.add(ctx.dType(p.typ) & " " & p.name)
  parts.join(", ")

proc genDStmtOrBlock(ctx: var DCodegenCtx, body: Expr): string =
  if body == nil: return ""
  if body.kind == exkBlock: ctx.genDBlock(body)
  else: ctx.genDStmt(body)

proc genDFnDecl(ctx: var DCodegenCtx, d: Decl, nameOverride = "",
                refSelf = false): string =
  if d.fnGenerics.len > 0: return dUnsupported("generic fn " & d.name)
  if d.isDecision: return dUnsupported("decision table " & d.name)
  let fnName = if nameOverride != "": nameOverride else: d.name
  let retStr = ctx.dType(d.fnReturnType)
  # A fallible fn wraps every return in the carrier; the arms below need to
  # know the payload type to name terr!(T). Restored after the body, since
  # a nested emission may set its own.
  let payload = bangInner(d.fnReturnType)
  ctx.retWrapped = payload != nil
  ctx.retInnerT = payload
  ctx.retInnerD =
    if payload == nil: ""
    else:
      let inner = ctx.dType(payload)
      if inner == "void": "rt.TuckUnit" else: inner
  # Implicit return: the value flowing at the end of a body is the result.
  # ast_query's shared version, not a private port — the Odin backend kept
  # its own copy and it has since drifted (no matchArmsReturn guard, so a
  # tail match whose arms return gets wrapped in a value-position case).
  injectTailReturn(d.fnBody, retStr)
  result = retStr & " " & fnName & "(" &
           ctx.genDParams(d.fnParams, refSelf) & ") {\n"
  ctx.indent = 1
  ctx.definedVars.clear()
  ctx.currentParams = @[]
  for p in d.fnParams:
    ctx.definedVars.incl(p.name)
    ctx.currentParams.add(FieldDef(name: p.name, typ: p.typ, span: p.span))
  result.add(ctx.genDStmtOrBlock(d.fnBody))
  ctx.indent = 0
  ctx.currentParams = @[]
  ctx.retWrapped = false
  ctx.retInnerD = ""
  ctx.retInnerT = nil
  result.add("}\n")

proc genDObjectDecl(ctx: var DCodegenCtx, d: Decl): string =
  ## `object` — a plain D struct plus its member fns as qualified free
  ## procs. Composition (+Mixin) and satisfies arrive with the interface
  ## work.
  result = "struct " & d.name & " {\n"
  for f in d.objFields:
    result.add("    " & ctx.dType(f.typ) & " " & f.name & ";\n")
  result.add("}\n\n")
  for mem in d.objMembers:
    if mem == nil: continue
    if mem.kind == dkFn:
      result.add(ctx.genDFnDecl(mem, memberProcNameD(d.name, mem.name),
                                refSelf = true) & "\n")
    elif isCompositionEntry(mem):
      return dUnsupported("object composition (+Type) in " & d.name)
    # `satisfies I` entries are conformance metadata, no code of their own

proc dExternTodo(mem: Decl): string =
  ## Why this extern cannot emit a forwarder yet, or "" when it can. A TODO
  ## comment is visible in the output, and the D compiler names the missing
  ## symbol only if a call site actually references it — loud where it
  ## matters, without blocking every program that merely imports the module.
  if mem.externHeader != "" or mem.externLib != "" or mem.externImpl.len > 0:
    return "// D backend TODO: extern " & mem.name &
           " (C-header/lib/impl externs arrive in M5)\n"
  ""

proc externShapeArg(ctx: var DCodegenCtx, ret: Type, retStr: string): string =
  ## A record-returning extern hands the runtime the shape to FILL, as a
  ## template argument: the struct was hoisted by this module, so the
  ## runtime cannot name it (see tuck_rt.d's tuckRec). "" when the return
  ## carries no record and the runtime's own type suffices.
  if ret != nil and ret.kind == tkRecord:
    return "!(" & retStr & ")"
  let payload = bangInner(ret)
  if payload != nil and payload.kind == tkRecord:
    return "!(rt.TuckResult!(" & ctx.dType(payload) & "))"
  ""

proc genDExternFwd(ctx: var DCodegenCtx, mem: Decl): string =
  ## An rt-implemented extern emits a forwarder calling `rt.<name>` — D has
  ## no cross-module scope merge that would make the bare name resolve.
  if mem.kind != dkFn: return ""
  let todo = dExternTodo(mem)
  if todo != "": return todo
  let ret = mem.fnReturnType
  let retStr = ctx.dType(ret)
  let emitName = if mem.externEmit != "": mem.externEmit else: mem.name
  # A generic extern (`fn toStr[T]`) forwards as a D function template —
  # the same construct the runtime's own toStr(T)(T) already is.
  let tmplParams = if mem.fnGenerics.len > 0:
                     "(" & mem.fnGenerics.join(", ") & ")"
                   else: ""
  var args: seq[string]
  for p in mem.fnParams: args.add(p.name)
  let call = "rt." & emitName & ctx.externShapeArg(ret, retStr) &
             "(" & args.join(", ") & ")"
  let body = if retStr == "void": call else: "return " & call
  retStr & " " & mem.name & tmplParams & "(" &
    ctx.genDParams(mem.fnParams) & ") {\n" & "    " & body & ";\n" & "}\n"

proc genDExternBlock(ctx: var DCodegenCtx, d: Decl): string =
  for mem in d.mixinMembers:
    let code = ctx.genDExternFwd(mem)
    if code != "": result.add(code & "\n")

proc genDValidate(ctx: var DCodegenCtx, d: Decl): string =
  ## spec 4.7: an invariant-carrying type validates at every PRODUCTION
  ## site. Emitted behind `version(tuckNoInvariants)` — opt-OUT, so the
  ## checks stay on in a release build by default.
  ##
  ## The Nim backend hardcodes `when not defined(release)`, which makes the
  ## checks impossible to keep in the build where a violated invariant means
  ## corrupt data. ROADMAP's 2026-08-25 ruling 5 reverses that; this backend
  ## is written to the ruling rather than inheriting the bug.
  var checks: seq[string]
  let savedFields = ctx.fieldVars
  let savedPrefix = ctx.fieldPrefix
  ctx.fieldVars.clear()
  for f in d.typeBody.fields: ctx.fieldVars.incl(f.name)
  ctx.fieldPrefix = "self."
  for member in d.typeMembers:
    if member != nil and member.kind == dkExpr:
      let cond = ctx.genDExpr(member.expr)
      # An explicit test + abort, NOT `assert`: dmd's -release strips
      # asserts, which would silently undo the ruling this guard exists to
      # implement (verified — an assert-based version passed in release).
      checks.add("        if (!(" & cond & "))\n" &
                 "            rt.tuckInvariantFailed(\"" &
                 cond.replace("\"", "'") & "\", \"" & d.name & "\");")
  ctx.fieldVars = savedFields
  ctx.fieldPrefix = savedPrefix
  if checks.len == 0: return ""
  "\nvoid validate_" & d.name & "(" & d.name & " self)\n{\n" &
    "    version (tuckNoInvariants) {} else\n    {\n" &
    checks.join("\n") & "\n    }\n}\n\n" &
    d.name & " __validated_" & d.name & "(" & d.name & " v)\n{\n" &
    "    validate_" & d.name & "(v);\n    return v;\n}\n"

proc genDTypeDecl(ctx: var DCodegenCtx, d: Decl): string =
  if d.generics.len > 0: return dUnsupported("generic type " & d.name)
  let body = d.typeBody
  if body == nil: return ""
  if body.kind == tkSum and not sumHasPayload(body):
    # A payload-free sum is exactly a D enum — same construct, same checks.
    var tags: seq[string]
    for v in body.variants: tags.add(v.name)
    return "enum " & d.name & " { " & tags.join(", ") & " }\n"
  if body.kind == tkRecord:
    # A named record is a plain D struct — the value type Tuck means.
    var res = "struct " & d.name & " {\n"
    for f in body.fields:
      res.add("    " & ctx.dType(f.typ) & " " & f.name & ";\n")
    res.add("}\n")
    res.add(ctx.genDValidate(d))
    for member in d.typeMembers:
      if member != nil and member.kind == dkFn:
        res.add("\n" & ctx.genDFnDecl(member) & "\n")
    return res
  if body.kind in {tkNamed, tkApp, tkRename, tkEffect}:
    # `type Ms = int` and friends. The DISTINCTNESS was enforced by the
    # checker; the emitted carrier is the underlying type, as in the Nim
    # backend where the distinct is likewise erased for arithmetic.
    let under = ctx.dDeclType(body)
    if under != "": return "alias " & d.name & " = " & under & ";\n"
    return dUnsupported("type alias " & d.name & " to an unmapped type")
  dUnsupported("type " & d.name & " (sum-with-payload arrives in M4)")

proc genDPendingStub(ctx: var DCodegenCtx, mem: Decl): string =
  ## A pending fn runs as a stub: log to stderr (the Nim backend's stream —
  ## the Odin one prints to stdout, a divergence recorded in the ledger),
  ## return the zero value. The payload rides a template param exactly like
  ## the Nim backend's generic stub, absorbing any record representation.
  if mem.kind != dkFn: return ""
  let retStr = ctx.dType(mem.fnReturnType)
  let params = if mem.fnParams.len > 0: "(T)(T payload)" else: "()"
  result = retStr & " " & mem.name & params & " {\n" &
           "    stderr.writeln(\"TUCK PENDING: " & mem.name &
           " invoked (not implemented)\");\n"
  if retStr != "void":
    result.add("    return typeof(return).init;\n")
  result.add("}\n")

proc genDPendingBlock(ctx: var DCodegenCtx, d: Decl): string =
  for mem in d.mixinMembers:
    let code = ctx.genDPendingStub(mem)
    if code != "": result.add(code & "\n")

proc genDFnSig(ctx: var DCodegenCtx, d: Decl): string =
  ## `fnsig NAME = {params} -> ret` — a named callback shape, filled by a
  ## `:fnRef` and called through.
  ##
  ## D's `function` pointer is the identical construct, and it is the RIGHT
  ## one rather than `delegate`: Tuck has no captured environment (a "closure"
  ## is a baked record whose body reads the record's own fields), so a bare
  ## pointer loses nothing and is what a C callback needs anyway. Nim has to
  ## reach for {.cdecl.} on the C path for exactly this reason.
  var params: seq[string]
  for prm in d.sigParams:
    params.add(ctx.dType(prm.typ) & " " & prm.name)
  let retStr =
    if d.sigReturn != nil and not (d.sigReturn.kind == tkNamed and
                                   d.sigReturn.name == "void"):
      ctx.dType(d.sigReturn)
    else: "void"
  let conv = if d.sigIsCCallback: "extern (C) " else: ""
  "alias " & d.name & " = " & conv & retStr & " function(" &
    params.join(", ") & ");\n"

proc genDDecl(ctx: var DCodegenCtx, d: Decl): string =
  if d == nil: return ""
  # Imported type decls are injected for checking only; the origin module
  # emits them (mirrors codegen.nim:1756 / codegen_odin.nim:2234).
  if d.kind == dkType and d.span.file.startsWith(ImportedTypeMarker):
    return ""
  case d.kind
  of dkType: ctx.genDTypeDecl(d)
  of dkObject: ctx.genDObjectDecl(d)
  of dkRegistry: dUnsupported("registry " & d.name)
  of dkPool: dUnsupported("pool " & d.name)
  of dkFn:
    if d.isPending or d.isExtern: ""   # pending: M3; bare extern fn: via block
    else: ctx.genDFnDecl(d)
  of dkMixin: dUnsupported("mixin " & d.name)
  of dkExtern: ctx.genDExternBlock(d)
  of dkPending: ctx.genDPendingBlock(d)
  of dkActor: dUnsupported("actor " & d.name & " (arrives with the Fiber runtime)")
  of dkTask: dUnsupported("task " & d.name & " (arrives with the Fiber runtime)")
  of dkExpr: ""   # top-level statements are collected by emitBody
  of dkConst:
    # A literal is a true compile-time constant (`enum` is D's word for
    # one); structured data becomes an immutable module-level value.
    if d.constVal != nil and d.constVal.kind == exkLit:
      "enum " & d.name & " = " & ctx.genDExpr(d.constVal) & ";\n"
    else:
      "immutable " & d.name & " = " & ctx.genDExpr(d.constVal) & ";\n"
  of dkRegister: dUnsupported("register " & d.name)
  of dkStaticAssert:
    # D checks this at COMPILE time, natively — the identical construct.
    # (The Odin backend collects these into a runtime `assert` in its entry
    # point, because Odin's #assert does not reach here; Nim has
    # `static: assert`. D needs no such workaround.)
    "static assert(" & ctx.genDExpr(d.assertExpr) & ");\n"
  of dkErrors: dUnsupported("errors policy (M4)")
  of dkImport: ""
  of dkSelect: dUnsupported("top-level on select (arrives with the Fiber runtime)")
  of dkFnSig: ctx.genDFnSig(d)
  of dkSatisfies: dUnsupported("top-level satisfies (M4)")
  of dkInterface: dUnsupported("interface " & d.name & " (M4)")
  of dkWhen: ""   # resolved away by modules.resolveWhenBlocks before codegen

# ------------------------------------------------------------- assembly --

proc emitDBody(ctx: var DCodegenCtx, m: Module): tuple[body, mains: string] =
  var body = ""
  var mainStmts: seq[string]
  for d in m.decls:
    if d != nil and d.kind == dkExpr:
      let oldIndent = ctx.indent
      ctx.indent = 1
      let stmtCode = ctx.genDStmt(d.expr)
      ctx.indent = oldIndent
      if stmtCode != "": mainStmts.add(stmtCode)
    else:
      let code = ctx.genDDecl(d)
      if code != "": body.add(code & "\n")
  (body, mainStmts.join(""))

proc dModuleName*(base: string): string =
  ## A D module name must be a valid identifier; example files are named
  ## like `01-data-flow`. Hyphens become underscores and a leading digit
  ## gets a prefix — the FILE keeps its own name (only imported modules
  ## need name==file, and those are mod_<name> which never start digital).
  result = dAlias(base)
  if result.len > 0 and result[0] in {'0' .. '9'}: result = "_" & result

proc usesSymbol(code, sym: string): bool =
  ## Does the emitted text call or qualify `sym`? Both spellings, because a
  ## symbol may be invoked (`writeln(x)`) or reached through (`stderr.x`).
  (sym & "(") in code or (sym & ".") in code

proc dImports(ctx: DCodegenCtx, body, mains: string,
              inModuleDir = false): seq[string] =
  ## Only import what the emitted code references — same policy as the Odin
  ## backend (and D warns on unused imports under -w).
  let code = body & mains
  # The entry point always calls rt.tuckSetArgs, so an entry module always
  # needs the runtime; a library module only if its own body reached for it.
  if usesSymbol(code, "rt") or not inModuleDir:
    result.add("import rt = tuck_rt;")
  var stdioSyms: seq[string]
  for sym in ["writeln", "stderr"]:
    if usesSymbol(code, sym): stdioSyms.add(sym)
  if stdioSyms.len > 0:
    result.add("import std.stdio : " & stdioSyms.join(", ") & ";")
  for modName in ctx.realModules.keys:
    let alias = dAlias(modName)
    if usesSymbol(code, alias):
      result.add("import " & alias & " = mod_" & alias & ";")

proc mainDeclD(m: Module): Decl =
  let tuckMain = mangleName("main")
  for d in m.decls:
    if d != nil and d.kind == dkFn and d.name == tuckMain and not d.isPending:
      return d
  nil

proc returnsValueD(d: Decl): bool =
  d.fnReturnType != nil and
    not (d.fnReturnType.kind == tkNamed and
         d.fnReturnType.name in ["void", "unit"])

proc genDEntryPoint(ctx: DCodegenCtx, m: Module, mains: string): string =
  ## Tuck's `fn main` is a plain fn; D's entry point calls it. A
  ## value-returning `fn main` IS the process exit code — D's `int main`
  ## says exactly that natively (the Nim backend needs quit(), Odin
  ## os.exit(); this is the identical-construct rule paying off).
  var hasRuntimeUsers = false
  for d in m.decls:
    if d != nil and d.kind in {dkActor, dkTask}: hasRuntimeUsers = true
  if hasRuntimeUsers:
    return dUnsupported("actor/task entry (arrives with the Fiber runtime)")
  let mainFn = mainDeclD(m)
  if mainFn == nil and mains == "": return ""
  let tuckMain = mangleName("main")
  # The command line reaches std/sys through the runtime, which cannot read
  # it for itself in D (no global argv the way Nim's os module has one), so
  # the entry point hands it over. Emitted always: whether a program calls
  # argCount is not knowable from the entry point alone, and the call is
  # one assignment.
  let seedArgs = "    rt.tuckSetArgs(args);\n"
  let head = "(string[] args) {\n" & seedArgs & mains
  if mainFn != nil and mainFn.returnsValueD:
    result = "int main" & head & "    return cast(int) " & tuckMain & "();\n}\n"
  elif mainFn != nil:
    result = "void main" & head & "    " & tuckMain & "();\n}\n"
  else:
    result = "void main" & head & "}\n"

proc newDCtx(m: Module, realModules: Table[string, Module],
             moduleName: string, modPrefix = ""): DCodegenCtx =
  DCodegenCtx(definedVars: initHashSet[string](), indent: 0, module: m,
              realModules: realModules, moduleName: moduleName,
              modPrefix: modPrefix)

proc emitD*(m: Module, realModules = initTable[string, Module](),
            moduleName = "main"): string =
  ## The entry module: declarations, then D's own `main` calling tuck_main.
  var ctx = newDCtx(m, realModules, moduleName)
  let (body, mains) = ctx.emitDBody(m)
  result = "module " & dModuleName(moduleName) & ";\n\n"
  let imports = ctx.dImports(body, mains)
  if imports.len > 0:
    result.add(imports.join("\n") & "\n\n")
  for h in ctx.hoisted:
    result.add(h & "\n\n")
  result.add(body)
  result.add(ctx.genDEntryPoint(m, mains))

proc emitDModule*(name: string, m: Module,
                  realModules = initTable[string, Module]()): string =
  ## A library module (import target): file mod_<name>.d, module mod_<name>.
  ## The import alias at the use site keeps the Tuck name, so calls read
  ## `console.printLine` — and the mod_ prefix keeps a Tuck module called
  ## `std` or `core` from colliding with D's own top-level packages.
  let alias = dAlias(name)
  var ctx = newDCtx(m, realModules, name, modPrefix = alias & "_")
  let (body, _) = ctx.emitDBody(m)
  result = "module mod_" & alias & ";\n\n"
  let imports = ctx.dImports(body, "", inModuleDir = true)
  if imports.len > 0:
    result.add(imports.join("\n") & "\n\n")
  for h in ctx.hoisted:
    result.add(h & "\n\n")
  result.add(body)
