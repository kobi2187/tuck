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
import twin_calls  # which calls take the moved twin — decided in prepare
import codegen_common
import record_shape  # what a combinator PRODUCES, decided once for all backends
import decl_index
import lowering                # getFieldsForType
# Shared, ctx-free helpers that happen to live in the Odin backend's util
# module: the record-shape hash (so both backends name a shape alike) and the
# enum a bare tag belongs to. Neither is Odin-specific; if a third consumer
# appears they should move to a backend-neutral module.
from codegen_odin_util import enumTagOwner
from mangle import mangleName
from lowering_seqcopy import needsDup, recordDupFields
import ./codegen_d_ctx

# Type emission, the ctx type, and dPrims (the D primitive-name table) now
# live in codegen_d_ctx.nim, imported above.

# ---------------------------------------------------------- expressions --

proc genDExpr*(ctx: var DCodegenCtx, e: Expr): string
proc isFnRefD(ctx: DCodegenCtx, e: Expr): bool
proc genDMatchStmt(ctx: var DCodegenCtx, e: Expr): string
proc importDeclaring(ctx: DCodegenCtx, name: string): string =
  ## The imported module that declares `name` as a callable, or "" when this
  ## module declares it (local wins) or nobody does. D has no cross-module
  ## scope merge, so every foreign call has to be qualified — three separate
  ## copies of this search had grown before it was named once.
  if name == "" or ctx.module.declaresFn(name): return ""
  for modName, im in ctx.realModules:
    if im.declaresFn(name): return modName
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
  of lkStr: "\"" & escapeStringLit(e.litValue) & "\""
  of lkInt:
    # `L`, because Tuck's `int` is D's `long` and a bare D integer literal is
    # `int` — 32-bit. Everywhere else there is a declared type to convert to,
    # so this was invisible; the first place D INFERS from a literal is a
    # generic call, where `twice(5)` instantiated `T = int` and then would not
    # assign to the `long[]` the declared return type says it is.
    if '.' in e.litValue or 'e' in e.litValue: e.litValue
    # `UL` past the signed range: `L` alone makes it a signed long and dmd
    # reports "signed integer overflow" on FNV-1a's offset basis.
    elif e.litValue.len > 19 or
         (e.litValue.len == 19 and e.litValue > "9223372036854775807"):
      e.litValue & "UL"
    else: e.litValue & "L"
  of lkFloat, lkBool: e.litValue
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
  if ctx.res.typeFor(e) != nil:
    declFields = getFieldsForType(ctx.res, ctx.module, ctx.res.typeFor(e))
  var allKnown = declFields.len > 0
  for f in declFields:
    if hasMissingType(f.typ): allKnown = false
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

proc genDPayloadArgs(ctx: var DCodegenCtx, e: Expr,
                     calleeStr: string): seq[string] =
  ## codegen_common.payloadArgs, printed. An argument the payload lacks
  ## cannot be spelled positionally in D, so it is refused, not guessed.
  for i, a in payloadArgs(ctx.res, ctx.module, ctx.realModules, e, calleeStr):
    if a == nil:
      let names = calleeParamNames(ctx.res, ctx.module, ctx.realModules, e,
                                   calleeStr)
      discard dUnsupported("call omitting parameter '" & names[i] & "'")
    result.add ctx.genDExpr(a)

proc genDCallArgs(ctx: var DCodegenCtx, e: Expr,
                  calleeStr: string): seq[string] =
  if e.args.len == 1 and e.args[0].kind == exkStruct:
    return ctx.genDPayloadArgs(e, calleeStr)
  for a in e.args: result.add(ctx.genDExpr(a))

proc explodeRecordArgD(ctx: var DCodegenCtx, e: Expr,
                       calleeStr: string): string =
  ## codegen_common.recordArgFields, printed: `f(p.a, p.b)`, or "" when the
  ## call is not a record variable standing for its payload.
  let fields = recordArgFields(ctx.res, ctx.module, e, calleeStr)
  if fields.len == 0: return ""
  let recv = ctx.genDExpr(e.args[0])
  var parts: seq[string]
  for f in fields: parts.add(recv & "." & f)
  calleeStr & "(" & parts.join(", ") & ")"

proc genDRecordCtor(ctx: var DCodegenCtx, e: Expr): string =
  ## `{fields} TypeName` — a named-argument struct literal of the DECLARED
  ## type. A production site: an invariant-carrying value validates before
  ## it flows on (spec 4.7).
  var parts: seq[string]
  for f in e.args[0].fields:
    parts.add(f.name & ": " & ctx.genDExpr(f.value))
  # A GENERIC type is a D template, so the construction names the
  # instantiation: `Pair!(string, long)(...)`. The arguments come from the
  # type the checker stamped on this very call — D cannot infer them from a
  # named-argument literal.
  var name = e.callee.name
  if ctx.declaredGenericD(name):
    let t = ctx.res.typeFor(e)
    if t != nil and t.kind == tkApp:
      let inst = ctx.dDeclType(t)
      if inst != "": name = inst
  let ctor = name & "(" & parts.join(", ") & ")"
  if ctx.index.hasInvariants(e.callee.name):
    return "__validated_" & e.callee.name & "(" & ctor & ")"
  ctor

# The four record combinators share one emitter; what each PRODUCES is
# decided in record_shape.nim. D's part is only its own syntax: a struct
# literal takes `name: value`, and a structural shape lands on a hoisted
# struct rather than an anonymous tuple.
#
# ponytail: exkVar receivers only, matching the Odin backend — a non-var
# receiver declines and the call proceeds as a plain one.
proc renderShape(ctx: var DCodegenCtx, s: RecordShape): string =
  if s.ctor == ckPassThrough: return ""
  for r in s.receivers:
    if r.kind != exkVar or ctx.res.typeFor(r) == nil: return ""
  var parts: seq[string]
  for f in s.fields:
    let value = case f.src
                of vsExpr: ctx.genDExpr(f.value)
                of vsProject: ctx.genDExpr(f.fromExpr) & "." & f.fromField
    parts.add(f.name & ": " & value)
  if parts.len == 0: return ""
  if s.ctor == ckStructural:
    return ctx.recStructNameD(s.declFields) & "(" & parts.join(", ") & ")"
  let ctor = s.typeName & "(" & parts.join(", ") & ")"
  # a rebuilt record is a production site too: its invariants must hold
  if s.invariantsOwed: return "__validated_" & s.typeName & "(" & ctor & ")"
  ctor


proc isRecordConstructionD(ctx: DCodegenCtx, e: Expr): bool =
  ## isRecordConstruction, answered through the index rather than a scan.
  e != nil and e.kind == exkCall and e.args.len == 1 and
    e.args[0].kind == exkStruct and
    e.callee != nil and e.callee.kind == exkVar and
    ctx.index.isRecordType(e.callee.name)

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

proc genDCombinator(ctx: var DCodegenCtx, e: Expr): string =
  ctx.renderShape(shapeOf(ctx.module, ctx.res, e))

proc asCombinatorCallD(ctx: var DCodegenCtx, e: Expr,
                       calleeStr: string): string =
  ## The compile-time combinators; any that declines returns "" and the call
  ## proceeds as a plain one. Same order as the Odin backend.
  let builtin = ctx.asParenBuiltinD(e, calleeStr)
  if builtin != "": return builtin
  if ctx.isRecordConstructionD(e): return ctx.genDRecordCtor(e)
  return ctx.explodeRecordArgD(e, calleeStr)

proc resolveDCallee(ctx: var DCodegenCtx, e: Expr): string =
  ## A bare-name callee (exkVar) resolves like an unqualified exkQualified:
  ## local declarations win, then the imports. (The Nim backend leans on
  ## Nim's own resolution here and needs no such step.)
  if e.callee != nil and e.callee.kind == exkVar:
    let owner = ctx.importDeclaring(e.callee.name)
    if owner != "": return dAlias(owner) & "." & e.callee.name
  # A fn reference in CALLEE position is not a value: `&f` is how D spells
  # taking its address, and `&f(x)` parses as taking the address of the
  # RESULT — "cannot take address of expression because it is not an
  # lvalue". `:twice .invoke {n: 21}` resolves to a call whose callee IS the
  # reference, so the `&` has to come off here.
  if e.callee != nil and e.callee.kind == exkQualified and
     ctx.isFnRefD(e.callee):
    return ctx.genDQualified(e.callee)
  ctx.genDExpr(e.callee)

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
  # A tagged struct is built by NAMING the discriminant and the variant's own
  # union member. Positionally, the second argument binds to the union's FIRST
  # member whatever variant this is, so `Shape.Rect` built a `Shape_Circle`
  # slot and dmd rejected it — every payload variant after the first was
  # unbuildable on this backend. The union is anonymous, so its members are
  # members of the struct and a named literal reaches them.
  typeName & "(kind: " & typeName & "Kind." & variantName & ", " &
    sumPayloadField(variantName) & ": " &
    typeName & "_" & variantName & "(" & parts.join(", ") & "))"

proc asDSumVariantCall(ctx: var DCodegenCtx, e: Expr): string =
  if e.callee == nil or e.callee.kind != exkField or
     e.callee.receiver == nil or e.callee.receiver.kind != exkVar: return ""
  let payload = if e.args.len == 1 and e.args[0].kind == exkStruct: e.args[0]
                else: nil
  ctx.dSumVariantCtor(e.callee.receiver.name, e.callee.fieldName, payload)

const RtByPointer = ["acquire", "release", "alloc", "reset", "enqueue",
                     "dequeue", "hasRoom", "initMailbox", "tuckArraySetAt"]
  ## Runtime intrinsics that MUTATE their receiver, so it goes in by
  ## reference. D takes `ref`, so the call site passes the value as-is —
  ## unlike Odin, which needs an explicit `&`.

const RtByValue = ["at", "setAt", "tuckAt", "tuckSetAt", "tuckArrayAt",
                   "toStr", "tuckConcat", "errCode", "push", "joinStr",
                   "fromBytes", "bitAnd", "bitOr", "bitXor", "bitNot",
                   "shiftLeft", "shiftRight",
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

proc asDPrimConversion(ctx: var DCodegenCtx, e: Expr,
                       calleeStr: string): string =
  ## `{value: n} u64` — a PRIMITIVE conversion. It names a Tuck type, and D's
  ## name for it is a different word: `u64(n)` reached dmd as an undefined
  ## identifier because D spells it `ulong`. The same table dType uses answers
  ## it. Odin needed no equivalent: its own primitive names ARE Tuck's.
  let prim = dPrimName(calleeStr)
  if prim == "" or prim == calleeStr: return ""
  let arg = ctx.genDCallArgs(e, calleeStr).join(", ")
  # NARROWING needs a cast, not a type constructor: `ubyte(x)` where x is a
  # ulong is "cannot implicitly convert expression of type ulong to ubyte" —
  # D's `T(x)` only performs the conversions it would do implicitly. Tuck's
  # conversion call is explicit BY CONSTRUCTION (the author wrote the type
  # name), so `cast` is what it means. Numeric and bool only: `str` is in the
  # same table but converting to it is `toStr`, never a reinterpretation.
  if prim in DCastablePrims:
    return "cast(" & prim & ")(" & arg & ")"
  prim & "(" & arg & ")"

proc genDActorWaitOn(ctx: var DCodegenCtx, e: Expr): string =
  ## `Actor.waitUntil {pred: :p}` -> `rt.tuckWaitOn(<Actor>Slot, &p)`. The
  ## checker rewrote the member call into `waitUntil(<actorRef>, pred)`, so the
  ## actor is still named in arg 0. Twin of the Nim and Odin versions.
  if not isActorWaitOn(e): return ""
  # No `&` here: a `:fnRef` already emits D's address-of, and adding one gave
  # `&&tuck_done`.
  "rt.tuckWaitOn(" & actorSlotName(e.args[0].refName) & ", " &
    ctx.genDExpr(e.args[1]) & ")"

proc genDCall(ctx: var DCodegenCtx, e: Expr): string =
  let waitOn = ctx.genDActorWaitOn(e)
  if waitOn != "": return waitOn
  let variant = ctx.asDSumVariantCall(e)
  if variant != "": return variant
  var calleeStr = ctx.resolveDCallee(e)
  # A PRIMITIVE conversion — `{value: n} u64` — names a Tuck type, and D's
  # name for it is a different word: `u64(n)` reached dmd as an undefined
  # identifier because D spells it `ulong`. The same table dType uses answers
  # it. Odin needed no equivalent: its own primitive names ARE Tuck's.
  let conv = ctx.asDPrimConversion(e, calleeStr)
  if conv != "": return conv
  # Calling a task in STATEMENT position schedules it and moves on —
  # fire-and-forget (spec §9.2). A result-BOUND call is handled in
  # genDAssign, which needs the target to build the slot.
  if ctx.index.isTaskName(calleeStr):
    let args = ctx.genDCallArgs(e, calleeStr)
    return "rt.tuckSpawn({ cast(void) " & calleeStr &
           "(" & args.join(", ") & "); })"
  let member = memberCallee(ctx.res, ctx.module, e)
  if member != "": calleeStr = member
  let combinator = ctx.asCombinatorCallD(e, calleeStr)
  if combinator != "": return combinator
  let args = ctx.genDCallArgs(e, calleeStr)
  if calleeStr == "echo":
    # `echo` is the builtin debug print; writeln is D's identical construct.
    return "writeln(" & args.join(", ") & ")"
  let satT = ctx.index.saturatingType(calleeStr)
  if satT != nil and args.len == 1:
    return ctx.genDSaturatingCtor(satT, calleeStr, args[0])
  let rt = genDRtCall(calleeStr, args)
  if rt != "": return rt
  # A type param mentioned by no parameter cannot be deduced from the call, so
  # D gets the template arguments spelled out: `tuck_firstOf!(Row, long)(r)`.
  # Recorded by the checker only where that is the case — see
  # recordCallTypeArgs — so an ordinary generic call is untouched.
  let targs = ctx.res.callTypeArgsFor(e)
  if targs.len > 0:
    var parts: seq[string]
    for t in targs: parts.add(ctx.dType(t))
    return calleeStr & "!(" & parts.join(", ") & ")(" & args.join(", ") & ")"
  # A call that may take its first argument destructively, in ANY position.
  # See codegen_common.movedCalleeName — the position nothing else reaches is
  # `return f(x, ...)`.
  (if callsTwin(e): movedName(calleeStr) else: calleeStr) & "(" &
    args.join(", ") & ")"

proc errCodeArg(ctx: DCodegenCtx, name: string): string =
  ## An error code, folded at COMPILE time by the emitter rather than at
  ## runtime — the same FNV value every backend produces for the same name
  ## (verified: "Math.Odd" is 55587 in Nim, Odin and D alike).
  "0x" & toHex(errIdCode(name)) & " /* " & name & " */"

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
  # Already a carrier: pass it through rather than wrapping it twice.
  if isResultCarrierType(ctx.res.typeFor(v)):
    return "return " & ctx.genDExpr(v)
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
    if ctx.retWrapped and ctx.retAbsentCapable:
      return "return rt.tnone!(" & ctx.retInnerD & ")()"
    if ctx.retWrapped and ctx.retInnerD == "rt.TuckUnit":
      return "return rt.tokVoid()"
    return "return"
  if ctx.retWrapped: return ctx.genDWrappedReturn(e.returnVal)
  let v = ctx.genDExpr(e.returnVal)
  # production site: handing back a value of an invariant-carrying type
  let rt = ctx.res.typeFor(e.returnVal)
  # `validatesItself` keeps a construction from being wrapped twice — it
  # already validated at the construction site, on this same value.
  if rt != nil and rt.kind == tkNamed and ctx.index.hasInvariants(rt.name) and
     not validatesItself(ctx.module, e.returnVal):
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

proc genDIfaceCall(ctx: var DCodegenCtx, e: Expr): string =
  ## A call through an interface value, lowered (lowering_iface): switch on
  ## the tag and print each arm's member call — no table, no virtual call.
  ## An immediately-called lambda because D has no switch EXPRESSION; its
  ## return type is inferred. A plain `switch` rather than `final switch`:
  ## the satisfier set can be empty and an unreachable default is cheap.
  let recv = ctx.genDExpr(e.dispatchRecv)
  var arms: seq[string]
  for arm in e.dispatchArms:
    arms.add("        case " & e.dispatchIface & "Tag." & e.dispatchIface &
             "_is_" & arm.satisfier & ":\n" &
             "            auto " & arm.bindName & " = v." & arm.satisfier &
             "Val;\n" &
             "            return " & ctx.genDExpr(arm.call) & ";")
  if arms.len == 0: return ""
  "((" & e.dispatchIface & " v) {\n    switch (v.tag) {\n" & arms.join("\n") &
    "\n        default: assert(0, \"unreachable interface tag\");\n" &
    "    }\n})(" & recv & ")"

proc dPayloadSumField(ctx: var DCodegenCtx, e: Expr): string =
  ## A field access on a PAYLOAD sum, or "" when it is not one.
  ##
  ## Two shapes: reading a variant's field (which lives in the union member
  ## named after that variant), and a bare `Type.Variant` construction with
  ## no payload of its own.
  let sumName = payloadSumTypeName(ctx.module, ctx.res.typeFor(e.receiver))
  if sumName != "":
    # Inside a match arm that narrowed this subject to one variant, that
    # variant is the ONLY one this access can mean — never re-derive from
    # field name alone, which picks whichever variant happens to declare it
    # first (see codegen.nim's twin fix).
    let receiverStr = ctx.genDExpr(e.receiver)
    var owner = ""
    if ctx.matchNarrowed.hasKey(receiverStr): owner = ctx.matchNarrowed[receiverStr]
    if owner == "": owner = variantOwningField(ctx.module, sumName, e.fieldName)
    if owner != "":
      return receiverStr & "." & sumPayloadField(owner) & "." & e.fieldName
  if e.receiver != nil and e.receiver.kind == exkVar:
    # The payload, if any, arrives as `.fn {args}`'s dotArg — passing nil
    # here silently dropped every field a `Type.Variant {payload}`
    # construction supplied.
    return ctx.dSumVariantCtor(e.receiver.name, e.fieldName, e.dotArg)
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
  doAssert ctx.res.ifaceCallOf(e).member == "",
    "codegen_d: an interface call reached the emitter unlowered (lowering_iface)"
  if isInputField(e, ctx.currentParams): return e.fieldName
  if isResultStatusTest(e):
    # parenthesised: a guard may negate it (`!r.ok`), and the `!` would
    # otherwise bind to the receiver alone
    return "(" & ctx.genDExpr(e.receiver) & ".status == rt.TuckStatus.Ok)"
  if isLenOnSized(ctx.res, e):
    # cast: D's .length is size_t (unsigned); Tuck's len is a signed int.
    # Unsigned would poison later arithmetic (n - bigger wraps, comparisons
    # promote) — hidden Nim-ism #3, Nim's .len is already signed.
    return "cast(long) " & ctx.genDExpr(e.receiver) & ".length"
  if ctx.res.hasCall(e):
    # A `..` chain feeding this call was already lowered into statements
    # (lowering_chains) — the receiver here can never be exkChain.
    return ctx.genDExpr(ctx.res.call(e))
  # `Order.Before` where `Order` is declared in an IMPORTED module. The type
  # has to be named THROUGH that module, exactly as importDeclaring already
  # does for a foreign call — D has no cross-module scope merge. Without this
  # the variant emitted as a bare `tuck_Order.Before` and dmd reported an
  # undefined identifier, while the call beside it was correctly qualified.
  if e.receiver != nil and e.receiver.kind == exkVar:
    let owner = moduleDeclaringType(ctx.module, e.receiver.name)
    if owner != "":
      return dAlias(owner) & "." & e.receiver.name & "." & e.fieldName
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
  if owner == "": return ""
  # The owner may be an IMPORTED type, in which case the enum lives in that
  # module and has to be reached through it — same rule as the construction
  # site above. `enumTagOwner` answers `TKind` for a payload sum, so the type
  # whose origin to look up is that name minus the suffix.
  let typeName = if owner.endsWith("Kind"): owner[0 ..< owner.len - 4]
                 else: owner
  let origin = moduleDeclaringType(ctx.module, typeName)
  if origin == "": owner & "." & name
  else: dAlias(origin) & "." & owner & "." & name

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
  if e == nil or ctx.res.hasCall(e): return false
  let t = ctx.res.typeFor(e)
  t != nil and t.kind == tkFunc

proc genDVarName(ctx: var DCodegenCtx, e: Expr): string =
  ## A bare name: a checker-stamped call, a pending hole, the whole incoming
  ## payload, an enum tag, or a variable.
  if ctx.res.hasCall(e): return ctx.genDExpr(ctx.res.call(e))
  if isInputRef(e, ctx.currentParams): return ctx.genDInputPayload()
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
  # NO EXCEPTION for a read through a MOVED twin's parameter. There used to
  # be one ("the param belongs to this call, so no defensive copy"), and it
  # was a copy decision made here, invisible to the ownership pass reading
  # the copy marks: `var t = xs; t[0] = 99; return xs` returned 99, and on
  # Odin `t`'s free was a second free of `xs`. What is copied is decided in
  # lowering_seqcopy, once, and printed here.
  if needsDup(ctx.res, e): return "(" & valStr & ").dup"
  let fields = recordDupFields(ctx.res, e)
  if fields.len == 0: return valStr
  # A D struct has no `.dup` of its own (only a slice does), so the record
  # is rebuilt: take the value once into a temp (never re-evaluate `valStr`
  # — it may be a call), then `.dup` just the fields that need it.
  let tmp = ctx.freshName("tuckRecDup")
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

proc ctorDeclType(ctx: var DCodegenCtx, val: Expr): string =
  ## A record CONSTRUCTION is the declared type BY NAME, whatever shape the
  ## checker stamped: constructing with a field left unset stamps a
  ## structural record (the hole rides on the type), which emitted
  ## `TRec_a_b_op_5F99 x = tuck_Ctx(...)` — a mismatch dmd rejects.
  ##
  ## Except a GENERIC one, whose declared type is the instantiation
  ## (`Pair!(string, long)`), not the bare template name. "" when `val` is
  ## not a record construction.
  if not ctx.isRecordConstructionD(val): return ""
  if ctx.declaredGenericD(val.callee.name):
    let inst = ctx.dDeclType(ctx.res.typeFor(val))
    if inst != "": return inst
  val.callee.name

proc declTypeForValue(ctx: var DCodegenCtx, target, val: Expr): string =
  ## The declared D type for `let x = <val>`, naming a foreign record shape
  ## through its owning module when the value came from one.
  ##
  ## The type is read from the VALUE first: the checker stamps the call, and
  ## a `let` target often carries no stamp of its own (verified — the target
  ## read back nil for `let r = {..} fs::readFile`).
  var t = ctx.res.typeFor(val)
  if t == nil: t = ctx.res.typeFor(target)
  # `.len` is `int` by definition of the language, but the checker types it
  # <unknown> (verified by instrumenting: a STAMPED sentinel, not a missing
  # stamp). The Nim backend never noticed because it emits `var n = s.len`
  # and lets NIM infer — the hidden-inference dependency this backend exists
  # to avoid. Supply the answer the language already guarantees.
  if val != nil and val.kind == exkField and isLenOnSized(ctx.res, val) and
     (t == nil):
    t = Type(kind: tkNamed, name: "int", span: val.span)
  let ctorT = ctx.ctorDeclType(val)
  if ctorT != "": return ctorT
  let owner = ctx.callOwnerModule(val)
  if owner != "" and t != nil:
    let payload = bangInner(t)
    if payload != nil and payload.kind == tkRecord:
      return "rt.TuckResult!(" &
             ctx.recStructNameD(payload.fields, owner) & ")"
    if t.kind == tkRecord:
      return ctx.recStructNameD(t.fields, owner)
  ctx.dDeclType(t)

proc movedAssignTarget(ctx: DCodegenCtx, t: Expr): string =
  ## The emitted spelling of an assignment target, for the two FAST PATHS
  ## below: the in-place append and the MOVED twin. Both bypass the field
  ## handling in the normal assign path, so both must qualify the target
  ## themselves.
  ##
  ## They did not, and the asymmetry is what made it hard to see: the
  ## right-hand side is built by the ordinary expression emitter, which DOES
  ## add the `self.`, so an actor handler emitted `st = f(self.st, ...)` —
  ## qualified on the right, bare on the left. Rejected here and by Odin;
  ## Nim was correct only because its backend never takes this path. EV-9.
  if t != nil and t.kind == exkVar and t.name in ctx.fieldVars:
    ctx.fieldPrefix & t.name
  else: t.name

proc genDLocalDecl(ctx: var DCodegenCtx, e: Expr, valStr: string): string

proc genDMovedCall(ctx: var DCodegenCtx, e: Expr): string =
  ## `x = f(x, ...)` on a threaded-container fn: call the MOVED twin, which
  ## may have the container destructively, and skip the defensive copy on the
  ## result — it IS the moved value. "" when this is not that shape.
  let threaded = threadedCall(e)
  if threaded == nil: return ""
  let name = movedName(ctx.resolveDCallee(threaded))
  let call = name & "(" &
             ctx.genDCallArgs(threaded, threaded.callee.name).join(", ") & ")"
  # A DECLARATION needs its type in D. `threadedCall` accepts decls now
  # — that is what lets `let f = sweep(b.ask, ...)` reach the twin at all —
  # and without this the emitted `tuck_f = ...` named something never
  # declared, which dmd answers with "undefined identifier".
  if e.isDecl and e.target.kind == exkVar and
     e.target.name notin ctx.definedVars and
     e.target.name notin ctx.fieldVars:
    ctx.definedVars.incl(e.target.name)
    return ctx.genDLocalDecl(e, call)
  ctx.movedAssignTarget(e.target) & " = " & call

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
  if not ctx.index.isTaskName(v.callee.name): return ""
  let ret = ctx.taskRetTypeD(v.callee.name)
  let args = ctx.genDCallArgs(v, v.callee.name)
  let rawCall = v.callee.name & "(" & args.join(", ") & ")"
  let slot = ctx.freshName("tuckSlot")
  # Three statements, laid out here — the caller strips its own indent and
  # terminator for this shape (see genDStmt's boundTaskCall test).
  var res = "auto " & slot & " = rt.newAsyncResult!(" & ret & ")();\n"
  res.add(ctx.indD & "rt.spawnResult(" & slot & ", { return " & rawCall &
          "; });\n")
  let declT = ctx.dDeclType(ctx.res.typeFor(e.target))
  let targetDecl =
    if e.target.kind == exkVar and e.target.name notin ctx.definedVars:
      ctx.definedVars.incl(e.target.name)
      (if declT != "": declT else: ret) & " " & e.target.name
    else: ctx.genDExpr(e.target)
  res.add(ctx.indD & targetDecl & " = rt.awaitResult(" & slot & ")")
  res

proc genDAssignTarget(ctx: var DCodegenCtx, e: Expr): string =
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
  if not hasBracketBase(e): return ctx.genDExpr(e)
  case e.kind
  of exkBracket:
    ctx.genDExpr(e.brReceiver) & "[" &
      ctx.genDExpr(e.brArgs[0]) & "]"
  of exkField:
    ctx.genDAssignTarget(e.receiver) & "." & e.fieldName
  else: ctx.genDExpr(e)

proc genDLocalDecl(ctx: var DCodegenCtx, e: Expr, valStr: string): string =
  ## A name's FIRST assignment declares it, with its type stated. A STATED
  ## type wins outright — this backend already refuses to let D re-infer, so
  ## an author's annotation is exactly the fact it wants.
  let stated = if e.declType != nil: ctx.dDeclType(e.declType) else: ""
  let declT = if stated != "": stated
              else: ctx.declTypeForValue(e.target, e.assignVal)
  if declT == "":
    return dUnsupported("a declaration of '" & e.target.name &
                        "' whose type the checker did not settle")
  declT & " " & e.target.name & " = " & valStr

proc genDInPlaceAssign(ctx: var DCodegenCtx, e: Expr): string =
  ## An assignment that updates its target IN PLACE rather than rebinding
  ## it, or "" when this is not one.
  # An append assigned back to its own argument is an in-place append.
  let appended = selfAppendValue(ctx.res, e)
  if appended != nil:
    return ctx.movedAssignTarget(e.target) & " ~= " & ctx.genDExpr(appended)
  # `s = s + v` on a str is the same fact one type over. D's `~=` on an array
  # grows through the GC's capacity, so it is amortised where `a ~ b` builds a
  # whole new string each time — an O(n) loop against an O(n^2) one.
  let concatenated = selfConcatValue(ctx.res, e)
  if concatenated != nil:
    return ctx.movedAssignTarget(e.target) & " ~= " & ctx.genDExpr(concatenated)
  # Same fact one level up: a threaded-container call assigned back over its
  # own argument may take it destructively, so it calls the MOVED twin — and
  # the result needs no defensive dup either, since it IS the moved value.
  ctx.genDMovedCall(e)

proc genDRebind(ctx: var DCodegenCtx, e: Expr): string =
  ## The ordinary assignment: a field of the actor, a new local, a register
  ## field's setter, or a plain store — re-validating a field's invariants.
  let valStr = ctx.dupIfSeq(ctx.genDExpr(e.assignVal), e.assignVal)
  # A FIELD is never a new local: inside an actor handler `total += n`
  # assigns the singleton's field, so it must not be declared here.
  if e.target.kind == exkVar and e.target.name in ctx.fieldVars:
    return ctx.fieldPrefix & e.target.name & " = " & valStr
  if e.target.kind == exkVar and e.target.name notin ctx.definedVars:
    ctx.definedVars.incl(e.target.name)
    return ctx.genDLocalDecl(e, valStr)
  if e.target.kind == exkField and e.target.receiver != nil and
     e.target.receiver.kind == exkRegisterRef:
    let prefix = registerAccessorPrefix(ctx.module, e.target.receiver.refName,
                                        e.target.fieldName)
    if prefix != "": return prefix & "_set(" & valStr & ")"
  result = ctx.genDAssignTarget(e.target) & " = " & valStr
  # A field assignment is a mutation site and re-validates, exactly as a `..`
  # chain step does — one shared decision so the three backends cannot drift
  # on which sites check. See codegen_common.assignInvariantOwner.
  let owner = assignInvariantOwner(ctx.res, e)
  if owner != "" and ctx.index.hasInvariants(owner):
    result.add(";\n" & "    ".repeat(ctx.indent) & "validate_" & owner & "(" &
               ctx.genDExpr(e.target.receiver) & ")")

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
  let inPlace = ctx.genDInPlaceAssign(e)
  if inPlace != "": return inPlace
  ctx.genDRebind(e)

# --- statements & control flow -------------------------------------------

proc ownsLayoutD(s: Expr): bool =
  ## Constructs that emit their own indentation, braces and newlines.
  s.kind in {exkIf, exkFor, exkWhile, exkBlock, exkMatch, exkSelect, exkDefer}

proc genDDroppedResult(ctx: var DCodegenCtx, s: Expr,
                       stmtCode: string): string =
  ## A fallible result DROPPED in statement position (spec 4.9). The checker
  ## recorded the site; here it is captured, tested, and handed to the global
  ## handler.
  ##
  ## No value is fabricated — the result is discarded, not replaced with a
  ## zero, which is what `continue` promises. Under `exit` the handler still
  ## runs first: it is the hook for diagnostics, and the program stops after.
  let tn = ctx.freshName("tuckDrop")
  let site = ctx.res.shortcut(s)
  let handler = mangleName("unhandled")
  var onErr = handler & "(" & tn & ".err, \"" & site & "\");"
  if ctx.errPolicy == "exit":
    onErr.add(" rt.exit(1);")
  ctx.indD & "{ auto " & tn & " = " & stmtCode & ";\n" &
    ctx.indD & "  if (" & tn & ".status != rt.TuckStatus.Ok) { " & onErr &
    " } }\n"

proc genDRoutedStmt(ctx: var DCodegenCtx, s: Expr, stmtCode: string): string =
  ## Route an unanswered error to the global handler.
  ##
  ## Two shapes, because a BINDING is not an expression: capturing
  ## `auto r = f();` in a temp would emit `auto tuckDrop1 = auto r = f();`,
  ## and wrapping it in `{ }` would scope the binding away from the rest of
  ## the block. A binding already names its value, so it is tested in place.
  ##
  ## It is also tested for `.Err` and not `!= .Ok`: a binding only reaches
  ## here as the `!?T` case where `if r.ok:` answered ABSENCE and left the
  ## error open, and an absence the author handled must not fire the handler.
  if s == nil or s.kind != exkAssign or s.target == nil or
     s.target.kind != exkVar:
    return ctx.genDDroppedResult(s, stmtCode)
  let site = ctx.res.shortcut(s)
  let name = s.target.name
  let handler = mangleName("unhandled")
  var onErr = handler & "(" & name & ".err, \"" & site & "\");"
  if ctx.errPolicy == "exit":
    onErr.add(" rt.exit(1);")
  ctx.indD & stmtCode & ";\n" &
    ctx.indD & "if (" & name & ".status == rt.TuckStatus.Err) { " & onErr &
    " }\n"

proc genDStmt*(ctx: var DCodegenCtx, s: Expr): string =
  ## One statement inside a block: indent + expression + `;`, except the
  ## constructs that lay themselves out.
  if s != nil and ctx.res.shortcut(s) != "":
    let code = ctx.genDExpr(s)
    if code != "": return ctx.genDRoutedStmt(s, code)
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
  ## A nested body is its own SCOPE, so a name declared inside it is gone
  ## afterwards. `definedVars` decides declaration-vs-assignment and was keyed
  ## by bare name with no scope: a second `let lead` in a SIBLING branch saw
  ## the name present and emitted an assignment to a variable the first branch
  ## had taken out of scope. Restoring the set makes emitted scoping match
  ## Tuck's — the codegen twin of the checker's name-keyed shadow bug.
  let savedVars = ctx.definedVars
  ctx.indent += 1
  result = if body == nil: ""
           elif body.kind == exkBlock: ctx.genDBlock(body)
           else: ctx.genDStmt(body)
  ctx.indent -= 1
  ctx.definedVars = savedVars

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

proc genDDefer(ctx: var DCodegenCtx, e: Expr): string =
  ## `defer:` (spec §7.4). D spells scope exit `scope(exit)` — the same
  ## construct under a different name, and LIFO like the other two. D also has
  ## `scope(success)` and `scope(failure)`; Tuck's defer is the unconditional
  ## one, so `scope(exit)` is the exact match and not an approximation.
  if e.deferBody == nil: return ""
  let ind = ctx.indD
  ind & "scope(exit) {\n" & ctx.genDNested(e.deferBody) & ind & "}"

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
  # `match r.err:` dispatches on the u16 CODE the carrier holds, so an arm
  # naming a variant of an error enum is the folded code, not the enum tag —
  # `case E.Empty:` reached dmd as "undefined identifier `E`" (the type is
  # emitted as `tuck_E`, and the subject is not of it anyway). Same treatment
  # the Odin backend already gives it; nothing caught it because the only
  # error match in the corpus was built on Nim alone.
  if pat != nil and pat.kind == pkVar and "." in pat.name:
    let dot = pat.name.find(".")
    return ctx.errCodeArg(errNameFor(ctx.module, ctx.moduleName,
                                     pat.name[0 ..< dot],
                                     pat.name[dot + 1 .. ^1]))
  let tag = ctx.qualifyEnumTag(raw)
  if tag != "": tag else: raw

proc dMatchSubject(ctx: var DCodegenCtx, e: Expr): string =
  ## A PAYLOAD sum emits as a tagged struct, so a match dispatches on the
  ## discriminant. A payload-free sum is a plain enum and matches directly.
  let base = ctx.genDExpr(e.subject)
  if payloadSumTypeName(ctx.module, ctx.res.typeFor(e.subject)) != "":
    base & ".kind"
  else: base

proc genDMatchArm(ctx: var DCodegenCtx, arm: MatchArm, narrowKey = ""): string =
  ## `case LABEL:` plus its body, indented one level in. Every arm breaks:
  ## D switch cases fall through by default where Tuck's arms never do, so
  ## the break is the semantics, not decoration. (A body ending in `return`
  ## makes it unreachable, so it is omitted there.)
  if arm.guard != nil:
    return dUnsupported("a guarded match arm (M4b)")
  let label = ctx.dPatternStr(arm.pattern)
  let isWild = arm.pattern != nil and arm.pattern.kind == pkWild
  let head = if isWild: ctx.indD & "default:\n"
             else: ctx.indD & "case " & label & ":\n"
  # A variant pattern narrows the subject's storage for the arm body:
  # `v.field` must read the MATCHED variant's union member, not whichever
  # variant happens to declare `field` first (see codegen.nim's twin fix).
  var narrowed = false
  if narrowKey != "" and not isWild and arm.pattern.kind == pkVar and
     "." notin arm.pattern.name:
    ctx.matchNarrowed[narrowKey] = arm.pattern.name
    narrowed = true
  let body = ctx.genDNested(arm.body)
  if narrowed: ctx.matchNarrowed.del(narrowKey)
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

proc isErrMatch(e: Expr): bool =
  ## `match r.err:` — the arms name variants of an error enum, and the
  ## subject is the u16 code the carrier holds, not an enum value.
  for arm in e.arms:
    if arm.pattern != nil and arm.pattern.kind == pkVar and
       "." in arm.pattern.name: return true
  false

proc genDMatchStmt(ctx: var DCodegenCtx, e: Expr): string =
  ## `final switch` — D's own exhaustiveness check, which is exactly the
  ## guarantee Tuck's match makes, so the compiler re-verifies the arm set
  ## rather than the emitter trusting it. An arm set WITH a wildcard cannot
  ## be `final` (D rejects a default there), so those emit a plain switch.
  if e.subject == nil: return dUnsupported("decision table (T24)")
  # An error match dispatches on a u16, and `final switch` is enum-only in D
  # — so it is a plain switch, which then REQUIRES a default arm.
  let errM = isErrMatch(e)
  let kw = if hasWildArm(e) or errM: "switch" else: "final switch"
  let narrowKey = ctx.genDExpr(e.subject)
  result = ctx.indD & kw & " (" & ctx.dMatchSubject(e) & ") {\n"
  for arm in e.arms:
    result.add(ctx.genDMatchArm(arm, narrowKey))
  if errM and not hasWildArm(e):
    ctx.indent += 1
    result.add(ctx.indD & "default: break;  // no arm; the fn falls through\n")
    ctx.indent -= 1
  result.add(ctx.indD & "}")

proc genDMatchExpr(ctx: var DCodegenCtx, e: Expr): string =
  ## A match in VALUE position. D has no switch-expression, so the arms go
  ## into an immediately-called lambda — which, unlike Odin's chained
  ## ternary, keeps the exhaustiveness check and reads as the same table the
  ## statement form does.
  if e.subject == nil: return dUnsupported("decision table in value position")
  let kw = if hasWildArm(e): "switch" else: "final switch"
  let subj = ctx.dMatchSubject(e)
  let narrowKey = ctx.genDExpr(e.subject)
  let saved = ctx.indent
  ctx.indent = 1
  var arms = ""
  for arm in e.arms:
    if arm.guard != nil:
      ctx.indent = saved
      return dUnsupported("a guarded match arm (M4b)")
    let label = ctx.dPatternStr(arm.pattern)
    let isWild = arm.pattern != nil and arm.pattern.kind == pkWild
    let head = if isWild: ctx.indD & "default: "
               else: ctx.indD & "case " & label & ": "
    var narrowed = false
    if not isWild and arm.pattern.kind == pkVar and "." notin arm.pattern.name:
      ctx.matchNarrowed[narrowKey] = arm.pattern.name
      narrowed = true
    let armBody = ctx.genDExpr(arm.body)
    if narrowed: ctx.matchNarrowed.del(narrowKey)
    arms.add(head & "return " & armBody & ";\n")
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
  # One arm is a plain await, not a race — see codegen.nim's genSelect for
  # why this is its own case rather than the marker below (issue #56).
  if readArm != nil and timeoutArm == nil:
    return ctx.indD & "rt.tuckAwaitRead(" & ctx.genDExpr(readArm.arg) &
           ");\n" & ctx.genDNested(readArm.body)
  if timeoutArm != nil and readArm == nil:
    return ctx.indD & "rt.tuckSleep(" & ctx.dSelectTimeoutMs(timeoutArm[]) &
           ");\n" & ctx.genDNested(timeoutArm.body)
  if readArm == nil or timeoutArm == nil:
    return ctx.indD & "// select: no lowerable arm (checker should have refused)\n"
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
  let w = ctx.res.wrapOf(e)
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
    if ctx.res.hasCall(e): ctx.genDExpr(ctx.res.call(e)) else: ""
  of exkCall: ctx.genDCall(e)
  of exkCombinator: ctx.genDCombinator(e)
  of exkChain:
    raiseAssert "codegen_d: a `..` chain reached the emitter; " &
      "lowering_chains rewrites every one into statements"
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
  of exkTripleDot: ""   # `...` outside a fn body: a no-op statement
  of exkImport: ""   # imports are assembled by dImports from realModules
  of exkIfaceCall: ctx.genDIfaceCall(e)
  of exkOrdinal:
    # A cast, for an enum and a bool alike: D converts both to their ordinal.
    "cast(long)(" & ctx.genDExpr(e.ordinalOf) & ")"
  of exkValidate:
    "validate_" & ctx.res.typeFor(e.validated).name & "(" &
      ctx.genDExpr(e.validated) & ")"
  of exkSend: ctx.genDSend(e)
  of exkSelect: ctx.genDSelect(e)
  of exkDefer: ctx.genDDefer(e)
  of exkFinish:
    "rt.finishResource(" & resourceTableName(e.finishKind) & ", " &
      ctx.genDExpr(e.finishHandle) & ")"
  of exkAcquire:
    "rt.acquireResource(" & resourceTableName(e.acquireKind) & ", cast(long)(" &
      ctx.genDExpr(e.acquireRef) & "), " & escape(acquireSite(e, ctx.moduleName)) & ")"

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

