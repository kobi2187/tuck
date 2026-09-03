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
import decl_index
import codegen_table  # decision-table combinatorics, shared with both backends
import lowering                # getFieldsForType
# Shared, ctx-free helpers that happen to live in the Odin backend's util
# module: the record-shape hash (so both backends name a shape alike) and the
# enum a bare tag belongs to. Neither is Odin-specific; if a third consumer
# appears they should move to a backend-neutral module.
from codegen_odin_util import odinErrCode, enumTagOwner
from mangle import mangleName
from lowering_d import needsDup, recordDupFields
import ./codegen_d_ctx

# Type emission, the ctx type, and dPrims (the D primitive-name table) now
# live in codegen_d_ctx.nim, imported above.

# ---------------------------------------------------------- expressions --

proc genDExpr*(ctx: var DCodegenCtx, e: Expr): string
proc genDMatchStmt(ctx: var DCodegenCtx, e: Expr): string
proc genDChainStep(ctx: var DCodegenCtx, step: ChainStep, into: string,
                   base: Expr = nil, baseStr = ""): string

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

proc genDRecordCtor(ctx: var DCodegenCtx, e: Expr): string =
  ## `{fields} TypeName` — a named-argument struct literal of the DECLARED
  ## type. A production site: an invariant-carrying value validates before
  ## it flows on (spec 4.7).
  var parts: seq[string]
  for f in e.args[0].fields:
    parts.add(f.name & ": " & ctx.genDExpr(f.value))
  let ctor = e.callee.name & "(" & parts.join(", ") & ")"
  if ctx.idx.hasInvariantsIdx(e.callee.name):
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

proc isRecordConstructionIdx(ctx: DCodegenCtx, e: Expr): bool =
  ## isRecordConstruction, answered through the index rather than a scan.
  e != nil and e.kind == exkCall and e.args.len == 1 and
    e.args[0].kind == exkStruct and
    e.callee != nil and e.callee.kind == exkVar and
    ctx.idx.isRecordTypeIdx(e.callee.name)

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

proc asParenBuiltinD(ctx: var DCodegenCtx, e: Expr, calleeStr: string): string =
  ## `sizeof`/`alignof`/`offsetof` parse as ordinary calls
  ## (parser_expr.ParenBuiltins), the identical call syntax as C and as
  ## Tuck's own source — which is also valid Nim, so that backend's
  ## emission is right by coincidence. D spells the first two as a POSTFIX
  ## property (`T.sizeof`), not a call; Odin's own real spelling
  ## (`size_of(T)`) differs too, unfixed there for the same reason — no
  ## example has reached the line yet. `offsetof` has no example to verify
  ## against and no clean 1:1 postfix form for an arbitrary field, so it
  ## stays unsupported rather than guessed. "" when `calleeStr` names none
  ## of these, so the caller falls through to a plain call.
  if calleeStr in ["sizeof", "alignof"] and e.args.len == 1:
    return ctx.genDExpr(e.args[0]) & "." & calleeStr
  if calleeStr == "offsetof":
    return dUnsupported("offsetof (no D translation verified yet)")
  ""

proc asCombinatorCallD(ctx: var DCodegenCtx, e: Expr,
                       calleeStr: string): string =
  ## The compile-time combinators; any that declines returns "" and the call
  ## proceeds as a plain one. Same order as the Odin backend.
  let builtin = ctx.asParenBuiltinD(e, calleeStr)
  if builtin != "": return builtin
  if calleeStr == "bake" and e.args.len == 2 and e.args[1].kind == exkStruct:
    return ctx.genDBake(e)
  if ctx.isRecordConstructionIdx(e): return ctx.genDRecordCtor(e)
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

proc memberProcNameD*(objName, memberName: string): string =
  ## Object members emit qualified (`Counter_bump`). D could overload the
  ## bare name like Nim does, but the qualified spelling keeps the three
  ## backends' output diffable and is what interface dispatch keys on.
  objName & "_" & memberName

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
  let owner = memberOwner(ctx.module, memberRecvType(e))
  if owner == "" or not ctx.ownerDeclares(owner, e.callee.name): return ""
  memberProcNameD(owner, e.callee.name)

proc dSumVariantCtor(ctx: var DCodegenCtx, typeName, variantName: string,
                     payload: Expr): string =
  ## `{payload} Type.Variant` — a tagged construction, not a call. A
  ## payload-FREE sum is a plain D enum, where `Type.Variant` is already
  ## valid, so this returns "" and the caller falls through.
  let found = payloadSumVariant(ctx.module, typeName, variantName)
  if found.isNone: return ""
  let v = found.get
  if v.fields.len == 0 or payload == nil:
    return typeName & "(" & typeName & "Kind." & variantName & ")"
  var parts: seq[string]
  for f in v.fields:
    for pf in payload.fields:
      if pf[0] == f.name:
        parts.add(f.name & ": " & ctx.genDExpr(pf[1]))
        break
  # A tagged struct is built by naming the discriminant and the variant's
  # own union member — D's named struct literal reaches both.
  typeName & "(" & typeName & "Kind." & variantName & ", " &
    typeName & "_" & variantName & "(" & parts.join(", ") & "))"

proc asDSumVariantCall(ctx: var DCodegenCtx, e: Expr): string =
  if e.callee == nil or e.callee.kind != exkField or
     e.callee.receiver == nil or e.callee.receiver.kind != exkVar: return ""
  let payload = if e.args.len == 1 and e.args[0].kind == exkStruct: e.args[0]
                else: nil
  ctx.dSumVariantCtor(e.callee.receiver.name, e.callee.fieldName, payload)

const RtByPointer = ["acquire", "release", "alloc", "reset", "enqueue",
                     "dequeue", "hasRoom", "initMailbox"]
  ## Runtime intrinsics that MUTATE their receiver, so it goes in by
  ## reference. D takes `ref`, so the call site passes the value as-is —
  ## unlike Odin, which needs an explicit `&`.

const RtByValue = ["at", "setAt", "toStr", "tuckConcat", "errCode",
                   "tuckSat", "tuckSatI", "tuckReportUnhandled"]
  ## Runtime intrinsics taking their arguments as-is. Both lists qualify
  ## explicitly: D has no cross-module scope merge, so `rt.` is required.

proc genDRtCall(calleeStr: string, args: seq[string]): string =
  ## A runtime intrinsic, or "" when the name is not one.
  if calleeStr in RtByPointer or calleeStr in RtByValue:
    return "rt." & calleeStr & "(" & args.join(", ") & ")"
  ""

proc taskRetTypeD(ctx: var DCodegenCtx, name: string): string =
  ## The D type a task hands back, for the result slot.
  for d in ctx.module.decls:
    if d != nil and d.kind == dkTask and d.name == name:
      return ctx.dType(d.taskReturnType)
  "void"

proc genDCall(ctx: var DCodegenCtx, e: Expr): string =
  let variant = ctx.asDSumVariantCall(e)
  if variant != "": return variant
  var calleeStr = ctx.resolveDCallee(e)
  # Calling a task in STATEMENT position schedules it and moves on —
  # fire-and-forget (spec §9.2). A result-BOUND call is handled in
  # genDAssign, which needs the target to build the slot.
  if ctx.idx.isTaskNameIdx(calleeStr):
    let args = ctx.genDCallArgs(e, calleeStr)
    return "rt.tuckSpawn({ cast(void) " & calleeStr &
           "(" & args.join(", ") & "); })"
  let member = ctx.memberCalleeNameD(e)
  if member != "": calleeStr = member
  let combinator = ctx.asCombinatorCallD(e, calleeStr)
  if combinator != "": return combinator
  let args = ctx.genDCallArgs(e, calleeStr)
  if calleeStr == "echo":
    # `echo` is the builtin debug print; writeln is D's identical construct.
    return "writeln(" & args.join(", ") & ")"
  let satT = ctx.idx.saturatingTypeIdx(calleeStr)
  if satT != nil and args.len == 1:
    return ctx.genDSaturatingCtor(satT, calleeStr, args[0])
  let rt = genDRtCall(calleeStr, args)
  if rt != "": return rt
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
  if rt != nil and rt.kind == tkNamed and ctx.idx.hasInvariantsIdx(rt.name):
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

proc genDBinary(ctx: var DCodegenCtx, e: Expr): string =
  if isStringConcat(e):
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

proc satisfiersOfD*(ctx: DCodegenCtx, iface: string): seq[Decl] =
  ## Whole-program satisfier set — see codegen_common.satisfiersOf.
  satisfiersOf(ctx.module, ctx.realModules, iface)

proc genDInterfaceWrap(ctx: var DCodegenCtx, e: Expr,
                       w: tuple[objName, iface: string]): string =
  ## A concrete object entering an interface slot is COPIED into the variant
  ## (spec 5.3) — verified: mutating the original afterwards leaves the
  ## wrapped value alone.
  let (ifaceName, objName) = resolveWrapNames(ctx.module, w.iface, w.objName)
  ifaceName & "(" & ifaceName & "Tag." & ifaceName & "_is_" & objName &
    ", " & objName & "Val: " & e.name & ")"

proc genDIfaceDispatch(ctx: var DCodegenCtx, e: Expr,
                       ic: tuple[iface, member: string]): string =
  ## A call through an interface value: switch on the tag it carries and call
  ## the concrete member directly — no table, no thunk, no virtual call.
  ##
  ## An immediately-called lambda because D has no switch EXPRESSION and a
  ## call site needs a value. A plain `switch` rather than `final switch`:
  ## the satisfier set can be empty and an unreachable default is cheap.
  let recv = ctx.genDExpr(e.receiver)
  var extra = ""
  if e.dotArg != nil: extra = ", " & ctx.genDExpr(e.dotArg)
  var arms: seq[string]
  for st in ctx.satisfiersOfD(ic.iface):
    arms.add("        case " & ic.iface & "Tag." & ic.iface & "_is_" &
             st.name & ":\n" &
             "            auto tmp = v." & st.name & "Val;\n" &
             "            return " & memberProcNameD(st.name, ic.member) &
             "(tmp" & extra & ");")
  if arms.len == 0: return ""
  "((" & ic.iface & " v) {\n    switch (v.tag) {\n" & arms.join("\n") &
    "\n        default: assert(0, \"unreachable interface tag\");\n" &
    "    }\n})(" & recv & ")"

proc dPayloadSumField(ctx: var DCodegenCtx, e: Expr): string =
  ## A field access on a PAYLOAD sum, or "" when it is not one.
  ##
  ## Two shapes: reading a variant's field (which lives in the union member
  ## named after that variant), and a bare `Type.Variant` construction with
  ## no payload of its own.
  let sumName = payloadSumTypeName(ctx.module, semLayer.typeFor(e.receiver))
  if sumName != "":
    let owner = variantOwningField(ctx.module, sumName, e.fieldName)
    if owner != "":
      return ctx.genDExpr(e.receiver) & "." & owner.toLowerAscii() & "." &
             e.fieldName
  if e.receiver != nil and e.receiver.kind == exkVar:
    return ctx.dSumVariantCtor(e.receiver.name, e.fieldName, nil)
  ""



proc genDFieldRead(ctx: var DCodegenCtx, e: Expr): string =
  ## A `.name` that is a READ, not a call — the tail of genDField once every
  ## call-shaped interpretation has declined.
  # A PAYLOAD sum keeps each variant's fields in a union member named after
  # the variant, so `s.length` on `Line({length: int})` is `s.line.length`.
  let sumField = ctx.dPayloadSumField(e)
  if sumField != "": return sumField
  # `Counter.total` reads the actor SINGLETON's field — an actor is one
  # instance per declared type, so the type name IS the instance.
  if e.receiver != nil and e.receiver.kind == exkActorRef:
    return actorSingletonName(e.receiver.refName) & "." & e.fieldName
  # A register field is a raw pointer with no real field — reading it means
  # calling the getter genDRegister already emitted for it.
  if e.receiver != nil and e.receiver.kind == exkRegisterRef:
    let prefix = registerAccessorPrefix(ctx.module, e.receiver.refName, e.fieldName)
    if prefix != "": return prefix & "_get()"
  ctx.genDExpr(e.receiver) & "." & e.fieldName

proc genDField(ctx: var DCodegenCtx, e: Expr): string =
  ## A `.name` access: a resolved call, a result's status, the len property,
  ## an input param, or a plain read. (Interface dispatch and actor fields
  ## arrive with their milestones.)
  # A call through an interface value: which implementations are POSSIBLE
  # was fixed at the wrap site; which one runs is the tag, read here.
  let ic = semLayer.ifaceCallOf(e)
  if ic.member != "":
    let disp = ctx.genDIfaceDispatch(e, ic)
    if disp != "": return disp
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
    # A `..` chain feeding this call was already hoisted into a temp by
    # lowering.hoistChainCalls — the receiver here can never be exkChain.
    return ctx.genDExpr(semLayer.call(e))
  ctx.genDFieldRead(e)

proc genDInputPayload(ctx: var DCodegenCtx): string =
  ## `input` — the whole incoming payload, rebuilt as its record shape.
  var vals: seq[string]
  for p in ctx.currentParams: vals.add(p.name & ": " & p.name)
  ctx.recStructNameD(ctx.currentParams) & "(" & vals.join(", ") & ")"

proc qualifyEnumTag*(ctx: DCodegenCtx, name: string): string =
  ## A bare enum tag is written `Owner.Tag` in D — enum members do not leak
  ## into module scope (same as Odin, unlike Nim). "" when `name` is not a
  ## declared tag.
  ##
  ## NO case filter. Odin's patternValue keys off an uppercase initial, and
  ## copying that here dropped every lowercase tag — which is the common
  ## Tuck spelling (`| low`, `| high` in examples/09). The lookup already
  ## answers "is this a declared tag"; a naming convention must not stand in
  ## for it.
  if name.len == 0: return ""
  # A hoisted INLINE sum has no declaration for enumTagOwner to find, so its
  # tags are answered from the hoist table instead.
  if ctx.inlineTagOwner.hasKey(name):
    return ctx.inlineTagOwner[name] & "." & name
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

proc dupIfSeq(ctx: var DCodegenCtx, valStr: string, e: Expr): string =
  ## Wrap in `.dup` (a bare Seq), or reconstruct with per-field `.dup`s (a
  ## record holding one or more Seq fields), if THIS BACKEND'S LOWERING
  ## marked the node.
  ##
  ## The decision — a D slice aliases where a Tuck Seq copies, and a D
  ## struct's bitwise field-for-field copy carries that aliasing one level
  ## down into any Seq-typed FIELD — is made in lowering_d, not here; this
  ## reads the mark and prints. That split is the point of the seam: the
  ## reasoning is inspectable and testable as a tree pass, and the emitter
  ## stays a printer.
  if needsDup(e): return "(" & valStr & ").dup"
  let fields = recordDupFields(e)
  if fields.len == 0: return valStr
  # A D struct has no `.dup` of its own (only a slice does), so the record
  # is rebuilt: take the value once into a temp (never re-evaluate `valStr`
  # — it may be a call), then `.dup` just the fields that need it.
  ctx.tmpCounter.inc
  let tmp = "tuckRecDup" & $ctx.tmpCounter
  var fixups = ""
  for f in fields: fixups.add(tmp & "." & f & " = " & tmp & "." & f & ".dup; ")
  "(() { auto " & tmp & " = " & valStr & "; " & fixups & "return " & tmp &
    "; })()"

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

proc genDBoundTaskCall(ctx: var DCodegenCtx, e: Expr): string =
  ## `let r = {args} someTask` — spawn the task into a result slot and wait
  ## for it. "" when this assignment is not a task call.
  ##
  ## Await, not block: inside a coroutine awaitResult yields so everything
  ## else keeps running; in `main` (a plain fn, never a coroutine) it drives
  ## the scheduler instead. Mirrors the Nim backend's newAsyncResult /
  ## spawnResult / awaitResult triple.
  let v = e.assignVal
  if v == nil or v.kind != exkCall or v.callee == nil or
     v.callee.kind != exkVar: return ""
  if not ctx.idx.isTaskNameIdx(v.callee.name): return ""
  let ret = ctx.taskRetTypeD(v.callee.name)
  let args = ctx.genDCallArgs(v, v.callee.name)
  let rawCall = v.callee.name & "(" & args.join(", ") & ")"
  ctx.tmpCounter.inc
  let slot = "tuckSlot" & $ctx.tmpCounter
  # Three statements, laid out here — the caller strips its own indent and
  # terminator for this shape (see genDStmt's boundTaskCall test).
  var res = "auto " & slot & " = rt.newAsyncResult!(" & ret & ")();\n"
  res.add(ctx.indD & "rt.spawnResult(" & slot & ", { return " & rawCall &
          "; });\n")
  let declT = ctx.dDeclType(semLayer.typeFor(e.target))
  let targetDecl =
    if e.target.kind == exkVar and e.target.name notin ctx.definedVars:
      ctx.definedVars.incl(e.target.name)
      (if declT != "": declT else: ret) & " " & e.target.name
    else: ctx.genDExpr(e.target)
  res.add(ctx.indD & targetDecl & " = rt.awaitResult(" & slot & ")")
  res

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
  # `let r = {args} someTask` — schedule the task AND await its result. It
  # reads as an ordinary call at the source level, which is the point
  # (spec §9.2): the effect marker is the async annotation, there is no
  # await keyword.
  let bound = ctx.genDBoundTaskCall(e)
  if bound != "": return bound
  let valStr = ctx.dupIfSeq(ctx.genDExpr(e.assignVal), e.assignVal)
  # A FIELD is never a new local: inside an actor handler `total += n`
  # assigns the singleton's field, so it must not be declared here.
  if e.target.kind == exkVar and e.target.name in ctx.fieldVars:
    return ctx.fieldPrefix & e.target.name & " = " & valStr
  if e.target.kind == exkVar and e.target.name notin ctx.definedVars:
    ctx.definedVars.incl(e.target.name)
    let declT = ctx.declTypeForValue(e.target, e.assignVal)
    if declT == "":
      return dUnsupported("a declaration of '" & e.target.name &
                          "' whose type the checker did not settle")
    return declT & " " & e.target.name & " = " & valStr
  if e.target.kind == exkField and e.target.receiver != nil and
     e.target.receiver.kind == exkRegisterRef:
    let prefix = registerAccessorPrefix(ctx.module, e.target.receiver.refName,
                                        e.target.fieldName)
    if prefix != "": return prefix & "_set(" & valStr & ")"
  ctx.genDExpr(e.target) & " = " & valStr

# --- statements & control flow -------------------------------------------

proc ownsLayoutD(s: Expr): bool =
  ## Constructs that emit their own indentation, braces and newlines.
  s.kind in {exkIf, exkFor, exkWhile, exkBlock, exkMatch, exkChain, exkSelect}

proc genDDroppedResult(ctx: var DCodegenCtx, s: Expr,
                       stmtCode: string): string =
  ## A fallible result DROPPED in statement position (spec 4.9). The checker
  ## recorded the site; here it is captured, tested, and handed to the global
  ## handler.
  ##
  ## No value is fabricated — the result is discarded, not replaced with a
  ## zero, which is what `continue` promises. Under `exit` the handler still
  ## runs first: it is the hook for diagnostics, and the program stops after.
  ctx.tmpCounter.inc
  let tn = "tuckDrop" & $ctx.tmpCounter
  let site = semLayer.shortcut(s)
  let handler = mangleName("unhandled")
  var onErr = handler & "(" & tn & ".err, \"" & site & "\");"
  if ctx.errPolicy == "exit":
    onErr.add(" rt.exit(1);")
  ctx.indD & "{ auto " & tn & " = " & stmtCode & ";\n" &
    ctx.indD & "  if (" & tn & ".status != rt.TuckStatus.Ok) { " & onErr &
    " } }\n"

proc genDStmt*(ctx: var DCodegenCtx, s: Expr): string =
  ## One statement inside a block: indent + expression + `;`, except the
  ## constructs that lay themselves out.
  if s != nil and semLayer.shortcut(s) != "":
    let code = ctx.genDExpr(s)
    if code != "": return ctx.genDDroppedResult(s, code)
  # A match reached HERE is a statement by construction — genDStmt only
  # ever runs on a block's own top-level statements, never on a nested
  # expression — so it goes straight to genDMatchStmt, bypassing
  # genDExpr's matchArmsReturn check entirely. That check answers a
  # different question ("do this VALUE match's arms already return,
  # so no further wrapping is needed") and answered it wrong here: arms
  # with no explicit return, in a fn returning void, read as `false` and
  # fell into the value/IIFE form — which then only had room for the
  # arm's FIRST statement, stranding the rest as bare statements outside
  # the switch. Mirrors Odin's genStmt, which has the identical direct
  # dispatch for the identical reason.
  if s != nil and s.kind == exkMatch and s.subject != nil:
    let code = ctx.genDMatchStmt(s)
    if code == "": return ""
    return if code.endsWith("\n"): code else: code & "\n"
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

proc dMatchSubject(ctx: var DCodegenCtx, e: Expr): string =
  ## A PAYLOAD sum emits as a tagged struct, so a match dispatches on the
  ## discriminant. A payload-free sum is a plain enum and matches directly.
  let base = ctx.genDExpr(e.subject)
  if payloadSumTypeName(ctx.module, semLayer.typeFor(e.subject)) != "":
    base & ".kind"
  else: base

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
  result = ctx.indD & kw & " (" & ctx.dMatchSubject(e) & ") {\n"
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
  let subj = ctx.dMatchSubject(e)
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
  "(() { " & kw & " (" & subj & ") {\n" & arms &
    ctx.indD & "} })()"

proc genDSend(ctx: var DCodegenCtx, e: Expr): string =
  ## `Actor send handler {payload}` — enqueue on the singleton's mailbox and
  ## wake it. Fire-and-forget with no reply channel (spec 9.1): a caller that
  ## wants a value polls a public field through waitUntil.
  var sendArgs: seq[string]
  if e.sendPayload != nil and e.sendPayload.kind == exkStruct:
    for f in e.sendPayload.fields:
      sendArgs.add(ctx.genDExpr(f.value))
  let sep = if sendArgs.len > 0: ", " else: ""
  "send" & e.sendHandler.capitalize() & "_" & e.sendActor & "(" &
    actorSingletonName(e.sendActor) & sep & sendArgs.join(", ") & ")"

proc genDChainStep(ctx: var DCodegenCtx, step: ChainStep, into: string,
                   base: Expr = nil, baseStr = ""): string =
  ## One `..` step, assigning through `into`. That is the base var when
  ## nothing consumes the chain (the builder form updates it), or a temp
  ## when something does and the base must be left alone.
  ##
  ## Each step's resolved call names the chain's BASE as its receiver, so
  ## when `into` is a temp the receiver has to be threaded through — else
  ## `a ..setN {5} ..setN {7}` emits two calls both reading `a` and the
  ## first result is dropped. threadReceiver is shared with the Nim backend.
  if semLayer.stepCall(step) != nil:
    let call = threadReceiver(semLayer.stepCall(step), base, into, baseStr)
    return ctx.indD & into & " = " & ctx.genDCall(call) & ";\n"
  let valStr = if isSingleFieldPayload(step.arg):
                 ctx.genDExpr(soleFieldValue(step.arg))
               else: ""
  # A register field is a raw pointer with no real field — writing it means
  # calling the setter genDRegister already emitted for it.
  let prefix = registerAccessorPrefix(ctx.module, into, step.target.name)
  if prefix != "": return ctx.indD & prefix & "_set(" & valStr & ");\n"
  ctx.indD & into & "." & step.target.name & " = " & valStr & ";\n"

proc genDChain(ctx: var DCodegenCtx, e: Expr): string =
  ## `x ..field {v} ..mutate {a}` — one plain statement per step, then a
  ## re-validation: a MUTATION site is a production site too, since the
  ## value that flows on afterwards is a different one.
  let baseStr = ctx.genDExpr(e.base)
  for step in e.steps:
    result.add(ctx.genDChainStep(step, baseStr, e.base, baseStr))
  if e.base != nil:
    let bt = semLayer.typeFor(e.base)
    if bt != nil and bt.kind == tkNamed and ctx.idx.hasInvariantsIdx(bt.name):
      result.add(ctx.indD & "validate_" & bt.name & "(" & baseStr & ");\n")

proc dSelectTimeoutMs(ctx: var DCodegenCtx, arm: SelectArm): string =
  ## The `timeout` arm's deadline as a plain int-of-milliseconds expression.
  ## Mirrors the Nim/Odin backends' selectTimeoutMs exactly: `timeout {5.ms}`
  ## unwraps its single-field payload; a bare `timeout 30` is already a
  ## literal and passes through untouched.
  ctx.genDExpr(soleFieldValue(arm.arg))

proc genDSelect(ctx: var DCodegenCtx, e: Expr): string =
  ## Task `on select` (spec §9.3): a `read <fd>` arm racing a `timeout <ms>`
  ## arm via rt.tuckAwaitReadOrTimeout — true means the fd won (run the read
  ## body), false means the deadline won. Mirrors codegen_odin.nim's
  ## genOdinSelect. rt.tuckAwaitReadOrTimeout takes Tuck `int` (D `long`)
  ## for both fd and timeoutMs, so no narrowing cast is needed here — the
  ## narrowing to a real C `int` happens inside tuck_coro.d, once, at the
  ## syscall boundary.
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
    return ctx.indD & "// select: only read+timeout arms supported (first cut)\n"
  let fd = ctx.genDExpr(readArm.arg)
  let ms = ctx.dSelectTimeoutMs(timeoutArm[])
  let readBody = ctx.genDNested(readArm.body)
  let toBody = ctx.genDNested(timeoutArm.body)
  ctx.indD & "if (rt.tuckAwaitReadOrTimeout(" & fd & ", " & ms & ")) {\n" &
    readBody & ctx.indD & "} else {\n" & toBody & ctx.indD & "}\n"

proc genDExpr*(ctx: var DCodegenCtx, e: Expr): string =
  if e == nil: return ""
  # A concrete value entering an interface slot is copied into the variant
  # at THIS site — the checker marked it (spec 5.3).
  let w = semLayer.wrapOf(e)
  if w.objName != "" and e.kind == exkVar:
    return ctx.genDInterfaceWrap(e, w)
  # A fn used as a VALUE needs `&` in D, whichever way it was written —
  # checked here, where exkVar and exkQualified both pass through.
  if e.kind in {exkVar, exkQualified} and ctx.isFnRefD(e):
    let name = if e.kind == exkVar: ctx.genDVarName(e) else: ctx.genDQualified(e)
    return "&" & name
  case e.kind
  of exkLit: genDLit(e)
  of exkVar: ctx.genDVarName(e)
  of exkActorRef, exkRegisterRef, exkRegistryRef, exkPoolRef, exkMixinRef:
    e.refName
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
  of exkDiscard:
    # D already allows an expression statement's value to go unused, no
    # keyword needed — the identical construct to Tuck's `discard <expr>`.
    # A bare `discard` has nothing to drop, so it emits nothing.
    if e.discardVal != nil: ctx.genDExpr(e.discardVal) else: ""
  of exkImport: ""   # imports are assembled by dImports from realModules
  of exkSend: ctx.genDSend(e)
  of exkSelect: ctx.genDSelect(e)

# --------------------------------------------------------- declarations --

proc genDParams*(ctx: var DCodegenCtx, params: seq[Param],
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

proc genDStmtOrBlock*(ctx: var DCodegenCtx, body: Expr): string =
  if body == nil: return ""
  if body.kind == exkBlock: ctx.genDBlock(body)
  else: ctx.genDStmt(body)

