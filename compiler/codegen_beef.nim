# compiler/codegen_beef.nim
# Beef backend. Mirrors codegen.nim (the Nim backend) construct for
# construct: !T/?T result auto-wrap, record construction with invariant
# validation, decision tables (packed and chained), payload sum types,
# actors with message envelopes, registries, mixins/extern bindings,
# pending stubs, and qualified module references. Generated code links
# against compiler/tuck_rt.bf (namespace TuckRt) the way Nim output
# imports compiler/tuck_rt.nim.
import ast, lowering, strutils, sets, tables

type
  BeefCodegenCtx = object
    definedVars: HashSet[string]
    fieldVars: HashSet[string]
    fieldPrefix: string   # "this." in methods, "self." in static validate procs
    indent: int
    module: Module
    hoisted: seq[string]  # named decls hoisted out of field positions
    recShapes: Table[string, string]  # record shape signature -> struct name
    modPrefix: string     # library modules prefix hoisted names (dedupe per project)
    retWrapped: bool      # current fn returns !T/?T -> returns auto-wrap
    retInnerBeef: string  # Beef type of the payload (for terr<T>)
    retInnerT: Type       # payload Tuck type (typed struct-literal emission)
    retInvName: string    # fn returns an invariant-carrying type: validate at return
    tmpCounter: int
    errPolicy: string     # from the errors declaration; "" = strict
    realModules: Table[string, Module]  # imported modules emitted as own Beef files
    staticAsserts: seq[string]  # collected into one `static this()` block
    moduleName: string    # error codes hash over "module/Enum.Variant"
    currentParams: seq[FieldDef]  # enclosing fn's params — `input` rebuilds them

proc repeat(s: string, n: int): string =
  var res = ""
  for i in 0..<n: res.add(s)
  res

proc capitalize(s: string): string =
  if s.len == 0: return ""
  return s[0].toUpperAscii() & s[1..^1]

# Same FNV-1a fold as tuck_rt.nim's errCode: the emitter precomputes error
# codes so the Beef runtime needs no compile-time hashing.
proc beefErrCode*(name: string): uint16 =
  var h = 2166136261'u32
  for c in name:
    h = (h xor uint32(c)) * 16777619'u32
  uint16((h xor (h shr 16)) and 0xFFFF'u32)

proc errCodeLit(name: string): string =
  "0x" & toHex(beefErrCode(name)) & " /* " & name & " */"

# --- Type emission --------------------------------------------------------

proc beefType*(ctx: var BeefCodegenCtx, t: Type): string

# Record shapes become hoisted structs with a positional constructor:
# Beef has no single-element tuples, and structs give every shape a stable
# nominal type for construction and field access.
proc recStructName(ctx: var BeefCodegenCtx, fields: seq[FieldDef]): string =
  var sigParts: seq[string]
  var typeStrs: seq[string]
  for f in fields:
    let ts = ctx.beefType(f.typ)
    typeStrs.add(ts)
    sigParts.add(f.name & ":" & ts)
  let sig = sigParts.join(",")
  if sig in ctx.recShapes:
    return ctx.recShapes[sig]
  var nameParts: seq[string]
  for f in fields: nameParts.add(f.name)
  let name = "TRec_" & ctx.modPrefix & nameParts.join("_") & "_" &
             toHex(beefErrCode(sig))
  ctx.recShapes[sig] = name
  var res = "public struct " & name & "\n{\n"
  var ctorParams: seq[string]
  var ctorAssigns: seq[string]
  for i, f in fields:
    res.add("    public " & typeStrs[i] & " " & f.name & ";\n")
    ctorParams.add(typeStrs[i] & " " & f.name)
    ctorAssigns.add("this." & f.name & " = " & f.name & ";")
  res.add("    public this(" & ctorParams.join(", ") & ") { " &
          ctorAssigns.join(" ") & " }\n")
  res.add("}")
  ctx.hoisted.add(res)
  return name

proc beefType*(ctx: var BeefCodegenCtx, t: Type): string =
  if t == nil: return "void"
  case t.kind
  of tkNamed:
    case t.name
    of "void": "void"
    of "u8": "uint8"
    of "u16": "uint16"
    of "u32": "uint32"
    of "u64": "uint64"
    of "i8": "int8"
    of "i16": "int16"
    of "i32": "int32"
    of "i64": "int64"
    of "int": "int"
    of "string", "str": "String"
    of "bool": "bool"
    of "float": "float"
    of "f32": "float"
    of "f64": "double"
    of "usize": "uint"
    of "Seq": "List"
    of "Array": "Array"
    of "fn": "void*"  # ponytail: fn-ref fields become delegate types once bake lands
    else:
      # Odd bit widths from decision tables (u2, u12, ...) round up to a real int
      if t.name.len >= 2 and t.name[0] in {'u', 'i'} and t.name[1..^1].allCharsInSet({'0'..'9'}):
        let bits = parseInt(t.name[1..^1])
        let base = if t.name[0] == 'u': "uint" else: "int"
        if bits <= 8: base & "8"
        elif bits <= 16: base & "16"
        elif bits <= 32: base & "32"
        else: base & "64"
      elif t.name == UnknownName: "Object"  # sketch mode: no type information
      else: t.name
  of tkTuple:
    if t.elems.len == 1: return ctx.beefType(t.elems[0])
    var parts: seq[string]
    for e in t.elems: parts.add(ctx.beefType(e))
    "(" & parts.join(", ") & ")"
  of tkApp:
    if t.base.kind == tkNamed and t.base.name == "*":
      # elem * count — sized array
      return ctx.beefType(t.args[0]) & "[" & ctx.beefType(t.args[1]) & "]"
    if t.base.kind == tkNamed and t.base.name == "Array":
      # Array[count, elem]
      return ctx.beefType(t.args[1]) & "[" & ctx.beefType(t.args[0]) & "]"
    # !T / ?T / !?T lower to TuckResult<T> — errors are first-class values
    if t.base.kind == tkNamed and t.base.name in ["!", "?", "!?"] and t.args.len == 1:
      let inner = ctx.beefType(t.args[0])
      return "TuckResult<" & (if inner == "void": "TuckUnit" else: inner) & ">"
    if t.base.kind == tkNamed and t.base.name == "Seq":
      var parts: seq[string]
      for a in t.args: parts.add(ctx.beefType(a))
      return "List<" & parts.join(", ") & ">"
    var parts: seq[string]
    for a in t.args: parts.add(ctx.beefType(a))
    return ctx.beefType(t.base) & "<" & parts.join(", ") & ">"
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
      let name = "TEnum_" & ctx.modPrefix & toHex(beefErrCode(tags.join(",")))
      let decl = "public enum " & name & " { " & tags.join(", ") & " }"
      if decl notin ctx.hoisted: ctx.hoisted.add(decl)
      name
    else:
      "Object"
  else:
    "void*"

# Field type emission. Beef forbids anonymous enums in field positions, so an
# inline sum type is hoisted to a named enum `<Parent><Field>Kind` (the same
# name the Nim backend uses).
proc fieldType(ctx: var BeefCodegenCtx, parent: string, f: FieldDef): string =
  if f.typ != nil and f.typ.kind == tkSum:
    var allNoFields = true
    for v in f.typ.variants:
      if v.fields.len > 0: allNoFields = false
    if allNoFields and f.typ.variants.len > 0:
      let enumName = parent & f.name.capitalize() & "Kind"
      var tags: seq[string]
      for v in f.typ.variants: tags.add(v.name)
      ctx.hoisted.add("public enum " & enumName & " { " & tags.join(", ") & " }")
      return enumName
  return ctx.beefType(f.typ)

# --- Shared declaration lookups (mirror codegen.nim) -----------------------

proc hasInvariants(m: Module, name: string): bool =
  for d in m.decls:
    if d != nil and d.kind == dkType and d.name == name:
      for member in d.typeMembers:
        if member.kind == dkExpr: return true
  false

# An extern fn returning an invariant-carrying named type validates at the
# call site (mirrors codegen.nim externInvRet).
proc externInvRet(m: Module, fnName: string): string =
  for d in m.decls:
    if d != nil and d.kind == dkMixin:
      for mem in d.mixinMembers:
        if mem.kind == dkFn and mem.isExtern and mem.name == fnName and
           mem.fnReturnType != nil and mem.fnReturnType.kind == tkNamed and
           hasInvariants(m, mem.fnReturnType.name):
          return mem.fnReturnType.name
  ""

proc isRecordType(m: Module, name: string): bool =
  for d in m.decls:
    if d != nil and d.kind == dkType and d.name == name and
       d.typeBody != nil and d.typeBody.kind == tkRecord:
      return true
  false

proc isErrEnumRef(m: Module, e: Expr): bool =
  if e == nil or e.kind != exkField or e.receiver == nil or
     e.receiver.kind != exkVar: return false
  for d in m.decls:
    if d != nil and d.kind == dkType and d.name == e.receiver.name and
       d.typeBody != nil and d.typeBody.kind == tkSum:
      return true
  false

proc lookupFnParams(m: Module, name: string): seq[string] =
  for d in m.decls:
    if d.kind == dkFn and d.name == name:
      var res: seq[string]
      for p in d.fnParams:
        res.add(p.name)
      return res
    if d.kind == dkMixin or d.kind == dkType:
      let members = if d.kind == dkMixin: d.mixinMembers else: d.typeMembers
      for mem in members:
        if mem.kind == dkFn and not mem.isPending and mem.name == name:
          var res: seq[string]
          for p in mem.fnParams:
            res.add(p.name)
          return res
  return @[]

# fn param TYPES by position, for call sites deciding whether an arg needs
# the `ref` marker (mutable record param) — mirrors lookupFnParams but
# keeps the type instead of just the name.
proc lookupFnParamTypes(m: Module, name: string): seq[Type] =
  for d in m.decls:
    if d.kind == dkFn and d.name == name:
      for p in d.fnParams: result.add(p.typ)
      return result

proc genQualified(ctx: BeefCodegenCtx, e: Expr): string =
  let modName = if e.modulePath.len > 0: e.modulePath[0] else: ""
  if modName in ctx.realModules: modName & "." & e.qualName
  else: modName & "_" & e.qualName

proc genBeefExpr*(ctx: var BeefCodegenCtx, e: Expr): string

proc recordFieldNames(ctx: var BeefCodegenCtx, t: Type): seq[string] =
  if t == nil: return @[]
  if t.kind == tkNamed and t.name == UnknownName: return @[]
  for f in getFieldsForType(ctx.module, t):
    result.add(f.name)

# Type-directed explosion: a record-typed VAR as the whole payload
# (`p advance`) explodes to the fn's params by field name, in param order.
proc explodeRecordArg(ctx: var BeefCodegenCtx, e: Expr, calleeStr: string): string =
  if e.args.len != 1 or e.args[0].kind != exkVar: return ""
  let params = lookupFnParams(ctx.module, calleeStr)
  if params.len == 0: return ""
  let fields = ctx.recordFieldNames(e.args[0].ty)
  if fields.len == 0: return ""
  var parts: seq[string]
  for paramName in params:
    if paramName notin fields: return ""
    parts.add(ctx.genBeefExpr(e.args[0]) & "." & paramName)
  return calleeStr & "(" & parts.join(", ") & ")"

# Positional construction of a hoisted record struct from a struct literal,
# in declared-field order, casting numeric fields to the declared type.
proc recCtorFromLiteral(ctx: var BeefCodegenCtx, declFields: seq[FieldDef],
                        litFields: seq[(string, Expr)]): string =
  let structName = recStructName(ctx, declFields)
  var parts: seq[string]
  for fd in declFields:
    var found = false
    for f in litFields:
      if f[0] == fd.name:
        let fieldBeef = ctx.beefType(fd.typ)
        let ex = ctx.genBeefExpr(f[1])
        if fieldBeef notin ["int", "float", "double", "String", "bool"] and
           (fieldBeef.startsWith("uint") or fieldBeef.startsWith("int") or
            fieldBeef.startsWith("float")):
          parts.add("(" & fieldBeef & ")(" & ex & ")")
        else:
          parts.add(ex)
        found = true
        break
    if not found:
      parts.add("default")
  return structName & "(" & parts.join(", ") & ")"

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
  if e != nil and e.ty != nil and not hasUnknownType(e.ty): return e.ty
  if e != nil and e.kind == exkLit:
    case e.litKind
    of lkStr: return Type(kind: tkNamed, name: "str")
    of lkBool: return Type(kind: tkNamed, name: "bool")
    of lkFloat: return Type(kind: tkNamed, name: "float")
    else: return Type(kind: tkNamed, name: "int")
  return nil

# Struct literal outside call/return contexts: use the checker's ty stamp to
# pick the record shape; fall back to a named tuple (types inferred by Beef)
# when the shape can't be fully resolved.
proc genStructLit(ctx: var BeefCodegenCtx, e: Expr): string =
  var declFields: seq[FieldDef]
  if e.ty != nil:
    declFields = getFieldsForType(ctx.module, e.ty)
  var allKnown = declFields.len > 0
  for f in declFields:
    if hasUnknownType(f.typ): allKnown = false
  if allKnown:
    return ctx.recCtorFromLiteral(declFields, e.fields)
  if e.fields.len == 1:
    # Beef has no single-element tuples: hoist a struct, inferring the type
    let ft = inferLitType(e.fields[0][1])
    if ft != nil:
      return ctx.recCtorFromLiteral(@[FieldDef(name: e.fields[0][0], typ: ft)],
                                    e.fields)
    # no type information at all: sketch mode, emit the bare value
    return ctx.genBeefExpr(e.fields[0][1])
  var parts: seq[string]
  for f in e.fields:
    parts.add(f[0] & ": " & ctx.genBeefExpr(f[1]))
  return "(" & parts.join(", ") & ")"

# exkCall: record construction (with invariant validation and generic
# instantiation), payload explosion, named-param reordering, or a plain call.
# {payload} Type.Variant — construction of a payload-carrying sum type
# (kind + per-variant TRec struct field). Fieldless-only sums are plain Beef
# enums, where Type.Variant is already valid — returns "" to fall through.
proc sumVariantCtor(ctx: var BeefCodegenCtx, typeName, variantName: string,
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
          if v.fields.len == 0 or payload == nil:
            return "new " & typeName & "() { kind = ." & variantName & " }"
          let recName = ctx.recStructName(v.fields)
          # positional ctor in DECLARED field order
          var vals: seq[string]
          for f in v.fields:
            var valStr = "default"
            for pf in payload.fields:
              if pf[0] == f.name: valStr = ctx.genBeefExpr(pf[1])
            vals.add(valStr)
          return "new " & typeName & "() { kind = ." & variantName & ", " &
                 v.name.toLowerAscii() & " = " & recName & "(" &
                 vals.join(", ") & ") }"
  ""

# expr alias(old: new, ...) — rebuild as the renamed TRec shape.
# ponytail: exkVar receivers only (no expr-position temp in Beef);
# falls back to pass-through otherwise.
proc genBeefAlias(ctx: var BeefCodegenCtx, e: Expr): string =
  if e.args[0].kind != exkVar or e.args[0].ty == nil: return ""
  let recvFields = getFieldsForType(ctx.module, e.args[0].ty)
  if recvFields.len == 0: return ""
  var newFields: seq[FieldDef]
  var vals: seq[string]
  let recv = ctx.genBeefExpr(e.args[0])
  for (oldName, newExpr) in e.args[1].fields.items:
    var ft: Type = nil
    for rf in recvFields:
      if rf.name == oldName: ft = rf.typ
    if ft == nil or newExpr == nil or newExpr.kind != exkVar: return ""
    newFields.add(FieldDef(name: newExpr.name, typ: ft, span: e.span))
    vals.add(recv & "." & oldName)
  let recName = ctx.recStructName(newFields)
  return recName & "(" & vals.join(", ") & ")"

# {a, b} merge — flatten into the union TRec shape (mirrors codegen.nim)
proc genBeefMerge(ctx: var BeefCodegenCtx, e: Expr): string =
  var newFields: seq[FieldDef]
  var vals: seq[string]
  for (mname, mexpr) in e.args[0].fields.items:
    if mexpr.kind != exkVar or mexpr.ty == nil: return ""
    let recv = ctx.genBeefExpr(mexpr)
    for f in getFieldsForType(ctx.module, mexpr.ty):
      newFields.add(f)
      vals.add(recv & "." & f.name)
  if newFields.len == 0: return ""
  return ctx.recStructName(newFields) & "(" & vals.join(", ") & ")"

proc genBeefCall(ctx: var BeefCodegenCtx, e: Expr): string =
  var args: seq[string]
  if e.callee != nil and e.callee.kind == exkField and
     e.callee.receiver != nil and e.callee.receiver.kind == exkVar:
    let payload = if e.args.len == 1 and e.args[0].kind == exkStruct: e.args[0]
                  else: nil
    let ctor = ctx.sumVariantCtor(e.callee.receiver.name, e.callee.fieldName,
                                   payload)
    if ctor != "": return ctor
  let calleeStr = ctx.genBeefExpr(e.callee)
  if e.args.len == 1 and e.args[0].kind == exkStruct and
     e.callee != nil and e.callee.kind == exkVar and
     isRecordType(ctx.module, e.callee.name):
    # record construction: named fields, not positional
    var parts: seq[string]
    for field in e.args[0].fields:
      parts.add(field[0] & " = " & ctx.genBeefExpr(field[1]))
    # generic type: the checker's ty stamp carries the inferred instantiation
    var ctorName = e.callee.name
    if e.ty != nil and e.ty.kind == tkApp and e.ty.base != nil and
       e.ty.base.kind == tkNamed and e.ty.base.name == e.callee.name:
      var gparts: seq[string]
      for a in e.ty.args: gparts.add(ctx.beefType(a))
      ctorName &= "<" & gparts.join(", ") & ">"
    # value-type struct: `new` would heap-allocate and yield a pointer
    # (Type*), not the value — Beef's struct object-initializer is `.()`
    let ctor = ctorName & "() { " & parts.join(", ") & " }"
    if hasInvariants(ctx.module, e.callee.name):
      # production site: construction — validate before the value flows on
      return "__validated(" & ctor & ")"
    return ctor
  if calleeStr == "alias" and e.args.len == 2 and e.args[1].kind == exkStruct:
    let aliased = ctx.genBeefAlias(e)
    if aliased != "": return aliased
  if calleeStr == "merge" and e.args.len == 1 and e.args[0].kind == exkStruct:
    let merged = ctx.genBeefMerge(e)
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
      else:
        lookupFnParams(ctx.module, calleeStr)
    if expectedParams.len > 0:
      for paramName in expectedParams:
        var found = false
        for field in e.args[0].fields:
          if field[0] == paramName:
            args.add(ctx.genBeefExpr(field[1]))
            found = true
            break
        if not found:
          args.add("default")
    else:
      for field in e.args[0].fields:
        args.add(ctx.genBeefExpr(field[1]))
  else:
    # bare positional args (incl. the receiver a chain mutator call
    # synthesizes, e.g. `c ..bump`) — a mutable-record param needs `ref`
    # at the call site too; only a bare var can be passed by ref in Beef
    let paramTypes = lookupFnParamTypes(ctx.module, calleeStr)
    for i, a in e.args:
      let argStr = ctx.genBeefExpr(a)
      let needsRef = a.kind == exkVar and i < paramTypes.len and
                     paramTypes[i] != nil and paramTypes[i].kind == tkNamed and
                     isRecordType(ctx.module, paramTypes[i].name)
      args.add((if needsRef: "ref " else: "") & argStr)
  if calleeStr == "bake":
    return args[0] & "(" & args[1..^1].join(", ") & ")"
  elif calleeStr == "alias":
    return args[0]
  elif externInvRet(ctx.module, calleeStr) != "":
    # extern boundary: the returned value validates on entry
    return "__validated(" & calleeStr & "(" & args.join(", ") & "))"
  elif calleeStr == "echo":
    return "Console.WriteLine(" & args.join(", ") & ")"
  return calleeStr & "(" & args.join(", ") & ")"

proc beefBangInfo(ctx: var BeefCodegenCtx, t: Type):
    tuple[wrapped: bool, inner: string, innerT: Type] =
  if t != nil and t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
     t.base.name in ["!", "?", "!?"] and t.args.len == 1:
    let inner = ctx.beefType(t.args[0])
    return (true, (if inner == "void": "TuckUnit" else: inner), t.args[0])
  return (false, "", nil)

proc isDecisionTable(d: Decl): bool =
  if d.kind != dkFn or d.fnBody == nil or d.fnBody.kind != exkBlock: return false
  if d.fnBody.stmts.len == 0: return false
  for s in d.fnBody.stmts:
    if s.kind != exkMatch or s.subject != nil: return false
  return true

proc genPatternStr(p: Pattern): string =
  if p == nil: return "_"
  case p.kind
  of pkWild: "_"
  of pkVar: p.name
  of pkLit: p.litValue
  else: "_"

# The declared enum (or its Kind enum) that owns a variant tag, if any.
proc enumTagOwner(m: Module, tag: string): string =
  for d in m.decls:
    if d != nil and d.kind == dkType and d.typeBody != nil and
       d.typeBody.kind == tkSum:
      for v in d.typeBody.variants:
        if v.name == tag:
          var hasPayload = false
          for vv in d.typeBody.variants:
            if vv.fields.len > 0: hasPayload = true
          return (if hasPayload: d.name & "Kind" else: d.name)
  return ""

# Comparison operand for a pattern value: enum tags need qualification (or
# Beef's `.Tag` inference prefix for hoisted inline enums); literals pass.
proc patternValue(ctx: BeefCodegenCtx, patStr: string): string =
  if patStr.len == 0: return patStr
  let owner = enumTagOwner(ctx.module, patStr)
  if owner != "": return owner & "." & patStr
  if patStr[0] in {'A'..'Z'}: return "." & patStr
  patStr

# A match-arm result that is a bare enum tag needs the same treatment; the
# assignment/return target supplies the type for `.Tag` inference.
proc armValue(ctx: var BeefCodegenCtx, e: Expr): string =
  if e != nil and e.kind == exkVar and e.name notin ctx.definedVars and
     e.name notin ctx.fieldVars and e.name.len > 0 and e.name[0] in {'A'..'Z'}:
    return ctx.patternValue(e.name)
  return ctx.genBeefExpr(e)

# exkRaise: err X — early-return an error result
# Error ids hash over "module/Enum.Variant" — module = the enum's origin
proc errNameFor(ctx: BeefCodegenCtx, enumName, variant: string): string =
  var origin = ctx.moduleName
  for d in ctx.module.decls:
    if d != nil and d.kind == dkType and d.name == enumName:
      if d.span.file.startsWith(ImportedTypeMarker & ":"):
        origin = d.span.file[ImportedTypeMarker.len + 1 .. ^1]
      break
  origin & "/" & enumName & "." & variant

proc genRaise(ctx: var BeefCodegenCtx, e: Expr): string =
  let rv = e.raiseVal
  let inner = if ctx.retInnerBeef != "": ctx.retInnerBeef else: "TuckUnit"
  if isErrEnumRef(ctx.module, rv):
    "return terr<" & inner & ">(" &
      errCodeLit(ctx.errNameFor(rv.receiver.name, rv.fieldName)) & ")"
  else:
    "return terr<" & inner & ">((uint16)(" & ctx.genBeefExpr(rv) & "))"

# exkReturn emission: auto-wrapped tok()/terr() results, typed struct
# literals, invariant-carrying returns, or a plain return.
proc genBeefReturn(ctx: var BeefCodegenCtx, e: Expr): string =
  if e.returnVal == nil:
    if ctx.retWrapped and ctx.retInnerBeef == "TuckUnit": return "return tokVoid()"
    else: return "return"
  elif ctx.retWrapped:
    let v = e.returnVal
    if v.kind == exkRaise:
      return ctx.genRaise(v)  # err X already emits the full error return
    elif v.kind == exkField and v.receiver != nil and v.receiver.kind == exkVar and
       v.receiver.name == "Error":
      # Error.name → app-wide 16-bit code, hashed by the emitter
      return "return terr<" & ctx.retInnerBeef & ">(" & errCodeLit(v.fieldName) & ")"
    elif v.kind == exkStruct and ctx.retInnerT != nil and ctx.retInnerT.kind == tkRecord:
      # Typed literal: cast numeric fields to the declared payload field type
      return "return tok(" & ctx.recCtorFromLiteral(ctx.retInnerT.fields, v.fields) & ")"
    else:
      return "return tok(" & ctx.genBeefExpr(v) & ")"
  elif ctx.retInvName != "":
    # production site: return value of an invariant-carrying type
    return "return __validated(" & ctx.genBeefExpr(e.returnVal) & ")"
  else: return "return " & ctx.genBeefExpr(e.returnVal)

# exkMatch in statement position: a real switch statement.
proc genMatchStmt(ctx: var BeefCodegenCtx, e: Expr): string =
  let ind = "  ".repeat(ctx.indent)
  let subjectStr = ctx.genBeefExpr(e.subject)
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
    let bodyStr = ctx.genBeefExpr(arm.body)
    var caseVal = ""
    if arm.pattern != nil and arm.pattern.kind == pkVar and
       "." in arm.pattern.name:
      let dot = arm.pattern.name.find(".")
      caseVal = errCodeLit(ctx.errNameFor(arm.pattern.name[0 ..< dot],
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
proc genMatchExpr(ctx: var BeefCodegenCtx, e: Expr): string =
  let subjectStr = ctx.genBeefExpr(e.subject)
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
      cmpVal = errCodeLit(ctx.errNameFor(arm.pattern.name[0 ..< dot],
                                         arm.pattern.name[dot+1 .. ^1]))
    res.add("((" & subjectStr & " == " & cmpVal & ") ? " &
            bodyStr & " : ")
    closing.inc
  res.add(")".repeat(closing))
  return res

proc genBeefExpr*(ctx: var BeefCodegenCtx, e: Expr): string =
  if e == nil: return ""
  let ind = "  ".repeat(ctx.indent)
  case e.kind
  of exkLit:
    return case e.litKind
           of lkStr: "\"" & e.litValue & "\""
           else: e.litValue
  of exkVar:
    # nullary call stamped by the checker (spec 2.3: a bare name IS a call)
    if e.varCallNode != nil: return ctx.genBeefExpr(e.varCallNode)
    if e.name == "...": return ""  # pending hole: compiles, does nothing
    if e.name == "input" and ctx.currentParams.len > 0:
      # the whole incoming payload, rebuilt as its TRec shape
      var vals: seq[string]
      for p in ctx.currentParams: vals.add(p.name)
      return ctx.recStructName(ctx.currentParams) & "(" & vals.join(", ") & ")"
    if e.name in ctx.fieldVars: return ctx.fieldPrefix & e.name
    if e.name notin ctx.definedVars:
      # bare enum tag: qualify with its declared owner (Beef has no
      # module-global enum members the way Nim does)
      let owner = enumTagOwner(ctx.module, e.name)
      if owner != "": return owner & "." & e.name
    return e.name
  of exkField:
    # `input.x` — the incoming payload's field is just the param
    if e.receiver != nil and e.receiver.kind == exkVar and
       e.receiver.name == "input" and ctx.currentParams.len > 0:
      return e.fieldName
    # Unit sugar: 5.ms is a postfix call to the ordinary function ms
    if e.receiver != nil and e.receiver.kind == exkLit and
       e.receiver.litKind in {lkInt, lkFloat}:
      if lookupFnParams(ctx.module, e.fieldName).len > 0:
        return e.fieldName & "(" & ctx.genBeefExpr(e.receiver) & ")"
      else:
        return ctx.genBeefExpr(e.receiver)
    if e.callNode != nil:
      # fieldName resolved to a fn call, not a field (checker-stamped)
      return ctx.genBeefCall(e.callNode)
    if e.receiver != nil and e.receiver.kind == exkVar:
      # bare Type.Variant of a payload sum: kind-tagged construction
      let ctor = ctx.sumVariantCtor(e.receiver.name, e.fieldName, nil)
      if ctor != "": return ctor
    return ctx.genBeefExpr(e.receiver) & "." & e.fieldName
  of exkQualified:
    return genQualified(ctx, e)
  of exkCall:
    return ctx.genBeefCall(e)
  of exkStruct:
    return ctx.genStructLit(e)
  of exkList:
    var parts: seq[string]
    for item in e.items:
      parts.add(ctx.genBeefExpr(item))
    return ".(" & parts.join(", ") & ")"
  of exkFor:
    let iterStr = ctx.genBeefExpr(e.iterable)
    if e.iter != nil and e.iter.kind == pkTuple and e.iter.elems.len == 2:
      # `for idx, item in xs:` — Beef foreach has no index form; lower to a
      # counter initialized to -1 and incremented FIRST in the body, so
      # `continue` inside the body cannot skip the increment.
      let idxN = genPatternStr(e.iter.elems[0])
      let itemN = genPatternStr(e.iter.elems[1])
      let oldIndent = ctx.indent
      ctx.indent += 1
      let bodyStr = ctx.genBeefExpr(e.body)
      ctx.indent = oldIndent
      var res = ind & "{\n"
      res.add(ind & "\tint " & idxN & " = -1;\n")
      res.add(ind & "\tfor (var " & itemN & " in " & iterStr & ")\n")
      res.add(ind & "\t{\n")
      res.add(ind & "\t\t" & idxN & "++;\n")
      # inner body statements re-emitted one level deeper inside our braces
      var innerLines: seq[string]
      for line in bodyStr.splitLines():
        if line.len > 0: innerLines.add("\t" & line)
      res.add(innerLines.join("\n") & "\n")
      res.add(ind & "\t}\n")
      res.add(ind & "}")
      return res
    let oldIndent = ctx.indent
    ctx.indent += 1
    let bodyStr = ctx.genBeefExpr(e.body)
    ctx.indent = oldIndent
    return ind & "for (var " & genPatternStr(e.iter) & " in " & iterStr & ")\n" & bodyStr
  of exkWhile:
    let condStr = if e.whileCond == nil: "true" else: ctx.genBeefExpr(e.whileCond)
    let oldIndent = ctx.indent
    ctx.indent += 1
    let bodyStr = ctx.genBeefExpr(e.whileBody)
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
                of boDiv: "/"
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
                of boRangeIncl: "..."
                of boRangeExcl: "..<"
    if e.binOp == boAdd and e.left != nil and e.left.ty != nil and
       e.left.ty.kind == tkNamed and e.left.ty.name in ["str", "string"]:
      return "concat(" & ctx.genBeefExpr(e.left) & ", " & ctx.genBeefExpr(e.right) & ")"
    return "(" & ctx.genBeefExpr(e.left) & " " & opStr & " " & ctx.genBeefExpr(e.right) & ")"
  of exkUnary:
    let opStr = case e.unaryOp
                of uoNeg: "-"
                of uoNot: "!"
                else: ""
    return opStr & ctx.genBeefExpr(e.operand)
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
      elif s.kind == exkBinary and s.binOp == boOr and s.right != nil and
           s.right.kind == exkReturn:
        # x or return E — shortcut: bail out when the condition is false
        stmtCode = "if (!(" & ctx.genBeefExpr(s.left) & ")) { " &
                   ctx.genBeefReturn(s.right) & "; }"
        ownsLayout = true
        stmtCode = ind & "  " & stmtCode
      else:
        stmtCode = ctx.genBeefExpr(s)
      if stmtCode != "" and s.shortcutSite != "":
        # continue/exit policy: dropped result routes to the global handler
        ctx.tmpCounter.inc
        let tn = "tuckDrop" & $ctx.tmpCounter
        let onErr = if ctx.errPolicy == "exit":
                      "{ tuck_unhandled(" & tn & ".err, \"" & s.shortcutSite &
                      "\"); Runtime.FatalError(\"unhandled error\"); }"
                    else:
                      "tuck_unhandled(" & tn & ".err, \"" & s.shortcutSite & "\");"
        stmtCode = "{ let " & tn & " = " & stmtCode & "; if (!" & tn &
                   ".ok) " & onErr & " }"
        ownsLayout = true
        stmtCode = ind & "  " & stmtCode
      if stmtCode != "":
        if s.kind in {exkIf, exkFor, exkWhile, exkBlock, exkChain} or ownsLayout:
          lines.add(stmtCode)  # these carry their own indentation
        else:
          lines.add(ind & "  " & stmtCode & ";")
    ctx.indent = oldIndent
    if lines.len == 0:
      return ind & "{\n" & ind & "}"
    return ind & "{\n" & lines.join("\n") & "\n" & ind & "}"
  of exkIf:
    let condStr = ctx.genBeefExpr(e.cond)
    let oldIndent = ctx.indent
    ctx.indent += 1
    var thenStr = ctx.genBeefExpr(e.thenBranch)
    if e.thenBranch != nil and e.thenBranch.kind != exkBlock:
      thenStr = ind & "  " & thenStr & ";"
    var elseStr = ""
    if e.elseBranch != nil:
      var elseBodyStr = ctx.genBeefExpr(e.elseBranch)
      if e.elseBranch.kind != exkBlock:
        elseBodyStr = ind & "  " & elseBodyStr & ";"
      elseStr = "\n" & ind & "else\n" & elseBodyStr
    ctx.indent = oldIndent
    return ind & "if (" & condStr & ")\n" & thenStr & elseStr
  of exkAssign:
    let targetStr = ctx.genBeefExpr(e.target)
    let valStr = ctx.genBeefExpr(e.assignVal)
    if e.target.kind == exkVar:
      let name = e.target.name
      if name notin ctx.definedVars and name notin ctx.fieldVars:
        ctx.definedVars.incl(name)
        return "var " & name & " = " & valStr
    return targetStr & " = " & valStr
  of exkMatch:
    if e.subject != nil:
      return ctx.genMatchExpr(e)
    return ""
  of exkReturn:
    if e.returnVal != nil and e.returnVal.kind == exkRaise:
      return ctx.genBeefExpr(e.returnVal)
    return ctx.genBeefReturn(e)
  of exkRaise:
    return ctx.genRaise(e)
  of exkChain:
    # `x ..field {v} ..mutate {a}` — one plain Beef statement per step:
    # field set, or mutator call reassigned into the base var
    let baseStr = ctx.genBeefExpr(e.base)
    var lines: seq[string]
    for step in e.steps:
      if step.callNode != nil:
        lines.add(ind & baseStr & " = " & ctx.genBeefCall(step.callNode) & ";")
      else:
        var valStr = ""
        if step.arg != nil and step.arg.kind == exkStruct and
           step.arg.fields.len == 1:
          valStr = ctx.genBeefExpr(step.arg.fields[0][1])
        lines.add(ind & baseStr & "." & step.target.name & " = " & valStr & ";")
    # mutation site: an invariant-carrying var re-validates after the chain
    if e.base != nil and e.base.ty != nil and e.base.ty.kind == tkNamed and
       hasInvariants(ctx.module, e.base.ty.name):
      lines.add(ind & "validate(" & baseStr & ");")
    return lines.join("\n")
  else:
    return ""

proc genBeefDecl*(ctx: var BeefCodegenCtx, d: Decl): string

# Object member fn (or a mixin fn materialized by `+ mixin`): the object
# rides as a `ref self` first parameter (reassignment must reach the
# caller); `Self` resolves to the object. Shallow copy — the shared AST
# stays untouched for the other backend.
# ponytail: call sites don't add the `ref` marker yet — nothing in the
# examples calls a member fn; wire it when one does.
proc genBeefMemberFn(ctx: var BeefCodegenCtx, m: Decl, objName: string): string =
  let selfType = Type(span: m.span, kind: tkNamed, name: "ref " & objName)
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
  let copy = Decl(span: m.span, kind: dkFn, name: m.name, fnParams: params,
                  fnReturnType: ret, fnBody: m.fnBody, fnEffects: m.fnEffects,
                  fnGenerics: m.fnGenerics)
  ctx.genBeefDecl(copy)

# Pending stub: logs on invocation, returns the zero value.
proc genPendingStub(ctx: var BeefCodegenCtx, d: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  let fnNameSanitized = d.name.replace(".", "_").replace("::", "_")
  let retTypeStr = if d.fnReturnType != nil: ctx.beefType(d.fnReturnType) else: "void"
  let paramStr = if d.fnParams.len > 0: "<T>(T payload)" else: "()"
  var res = ind & "public static " & retTypeStr & " " & fnNameSanitized &
            paramStr & "\n" & ind & "{\n" &
            ind & "    Console.WriteLine(\"TUCK PENDING: " & d.name &
            " invoked (not implemented)\");\n"
  if retTypeStr != "void":
    res.add(ind & "    return default;\n")
  res.add(ind & "}\n")
  return res

# Beef's flow analysis rejects non-void fns that can fall off the end;
# append `return default;` inside the closing brace when the last statement
# doesn't guarantee a return (checker enforces the real branch agreement).
proc ensureTrailingReturn(bodyStr: string, body: Expr, blockIndent: int): string =
  if body == nil or body.kind != exkBlock: return bodyStr
  if body.stmts.len > 0 and body.stmts[^1].kind in {exkReturn, exkRaise}:
    return bodyStr
  let idx = bodyStr.rfind('\n')
  if idx < 0: return bodyStr
  let lastLine = bodyStr[idx + 1 .. ^1]
  if not lastLine.strip().startsWith("}"): return bodyStr
  return bodyStr[0 ..< idx] & "\n" & "  ".repeat(blockIndent) & "  return default;\n" &
         lastLine

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
    elif lastS.kind notin {exkReturn, exkRaise, exkIf, exkMatch, exkFor, exkWhile, exkBreak, exkContinue,
                           exkAssign, exkBlock} and
       not (lastS.kind == exkVar and lastS.name == "..."):
      body.stmts[^1] = Expr(span: lastS.span, kind: exkReturn, returnVal: lastS)

# Decision tables: packed single-switch when every column is enumerable,
# otherwise a first-match if/else chain (mirrors codegen.nim).
proc genDecisionTable(ctx: var BeefCodegenCtx, d: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  let fnNameSanitized = d.name.replace(".", "_")
  var params: seq[string]
  for p in d.fnParams:
    params.add(ctx.beefType(p.typ) & " " & p.name)
  let retTypeStr = if d.fnReturnType != nil: ctx.beefType(d.fnReturnType) else: "void"
  let header = ind & "public static " & retTypeStr & " " & fnNameSanitized &
               "(" & params.join(", ") & ")"

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
                      "(int)" & d.fnParams[c].name
      if stride > 1:
        keyParts.add(ordExpr & " * " & $stride)
      else:
        keyParts.add(ordExpr)
    var caseLines: seq[string]
    caseLines.add(ind & "{")
    caseLines.add(ind & "    switch (" & keyParts.join(" + ") & ")   // packed decision key")
    caseLines.add(ind & "    {")
    for gi, g in groups:
      if gi == groups.len - 1:
        caseLines.add(ind & "    default: return " & g.outcome & ";")
      else:
        var ks: seq[string]
        for k in g.keys: ks.add($k)
        caseLines.add(ind & "    case " & ks.join(", ") & ": return " & g.outcome & ";")
    caseLines.add(ind & "    }")
    caseLines.add(ind & "}")
    return header & "\n" & caseLines.join("\n") & "\n"

  var bodyLines: seq[string]
  bodyLines.add(ind & "{")
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
    let condStr = if conds.len > 0: conds.join(" && ") else: "true"
    let resultExprStr = ctx.armValue(arm.body)
    if condStr == "true":
      bodyLines.add(ind & "    return " & resultExprStr & ";")
      hasCatchAll = true
    else:
      bodyLines.add(ind & "    if (" & condStr & ") return " & resultExprStr & ";")
  if not hasCatchAll and retTypeStr != "void":
    bodyLines.add(ind & "    return default;")
  bodyLines.add(ind & "}")
  return header & "\n" & bodyLines.join("\n") & "\n"

proc genBeefFnDecl(ctx: var BeefCodegenCtx, d: Decl): string =
  if d.isPending:
    return ctx.genPendingStub(d)
  ctx.currentParams = @[]
  for p in d.fnParams:
    ctx.currentParams.add(FieldDef(name: p.name, typ: p.typ, span: p.span))
  if d.isDecision or d.isDecisionTable():
    return ctx.genDecisionTable(d)
  let ind = "  ".repeat(ctx.indent)
  let fnNameSanitized = d.name.replace(".", "_")
  var params: seq[string]
  for p in d.fnParams:
    # the checker binds every param isVar:true (`self ..mutate` is fn-
    # uniform) — value-type (struct) records need `ref` to allow that
    # mutation in Beef, mirroring the self-param treatment below
    let isMutParam = p.typ != nil and p.typ.kind == tkNamed and
                      isRecordType(ctx.module, p.typ.name)
    let typeStr = ctx.beefType(p.typ)
    params.add((if isMutParam: "ref " & typeStr else: typeStr) & " " & p.name)
  let retTypeStr = if d.fnReturnType != nil: ctx.beefType(d.fnReturnType) else: "void"
  # Generic fns pass their type params straight through — Beef monomorphizes
  let genericStr = if d.fnGenerics.len > 0: "<" & d.fnGenerics.join(", ") & ">" else: ""
  let inlinePrefix = if d.isInline: ind & "[Inline]\n" else: ""
  let header = inlinePrefix & ind & "public static " & retTypeStr & " " & fnNameSanitized &
               genericStr & "(" & params.join(", ") & ")"
  let oldVars = ctx.definedVars
  for p in d.fnParams:
    ctx.definedVars.incl(p.name)
  let oldIndent = ctx.indent
  let (bw, binner, binnerT) = ctx.beefBangInfo(d.fnReturnType)
  ctx.retWrapped = bw
  ctx.retInnerBeef = binner
  ctx.retInnerT = binnerT
  ctx.retInvName =
    if not bw and d.fnReturnType != nil and d.fnReturnType.kind == tkNamed and
       hasInvariants(ctx.module, d.fnReturnType.name): d.fnReturnType.name
    else: ""
  injectTailReturn(d.fnBody, retTypeStr)
  var bodyStr = ctx.genBeefExpr(d.fnBody)
  if d.fnBody != nil and d.fnBody.kind != exkBlock:
    let kw = if retTypeStr != "void": "return " else: ""
    bodyStr = ind & "{\n" & ind & "  " & kw & bodyStr & ";\n" & ind & "}"
  elif retTypeStr != "void":
    bodyStr = ensureTrailingReturn(bodyStr, d.fnBody, oldIndent)
  ctx.indent = oldIndent
  ctx.retWrapped = false
  ctx.retInnerBeef = ""
  ctx.retInnerT = nil
  ctx.retInvName = ""
  ctx.definedVars = oldVars
  return header & "\n" & bodyStr & "\n"

# --- dkType sum-type branch helpers ---

proc genTransitionProcs(ctx: var BeefCodegenCtx, d: Decl, kindName: string,
                        hasPayload: bool): string =
  let ind = "  ".repeat(ctx.indent)
  var canLines: seq[string]
  canLines.add(ind & "public static bool canTransition(" & kindName & " frm, " &
               kindName & " to)")
  canLines.add(ind & "{")
  canLines.add(ind & "    switch (frm)")
  canLines.add(ind & "    {")
  for v in d.typeBody.variants:
    var allowed: seq[string]
    for tr in d.typeBody.transitions:
      if tr.`from` == v.name: allowed.add(tr.to)
    if allowed.len > 0:
      var conds: seq[string]
      for a in allowed: conds.add("to == ." & a)
      canLines.add(ind & "    case ." & v.name & ": return " & conds.join(" || ") & ";")
    else:
      canLines.add(ind & "    case ." & v.name & ": return false;")
  canLines.add(ind & "    }")
  canLines.add(ind & "}")
  var res = canLines.join("\n") & "\n"
  if hasPayload:
    # payload carrier is a class: mutate in place (kind + every payload slot)
    var copyLines: seq[string]
    for v in d.typeBody.variants:
      if v.fields.len > 0:
        let fld = v.name.toLowerAscii()
        copyLines.add(ind & "    self." & fld & " = target." & fld & ";")
    res.add(ind & "public static void transitionTo(" & d.name & " self, " &
            d.name & " target)\n" & ind & "{\n" &
            ind & "    if (!canTransition(self.kind, target.kind))\n" &
            ind & "        Runtime.FatalError(\"Invalid transition\");\n" &
            ind & "    self.kind = target.kind;\n" &
            copyLines.join("\n") & (if copyLines.len > 0: "\n" else: "") &
            ind & "}\n")
  else:
    res.add(ind & "public static void transitionTo(ref " & d.name & " self, " &
            d.name & " target)\n" & ind & "{\n" &
            ind & "    if (!canTransition(self, target))\n" &
            ind & "        Runtime.FatalError(\"Invalid transition\");\n" &
            ind & "    self = target;\n" & ind & "}\n")
  return res

proc genSumType(ctx: var BeefCodegenCtx, d: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  var hasPayload = false
  for v in d.typeBody.variants:
    if v.fields.len > 0: hasPayload = true
  let hasTransitions = d.typeBody.transitions.len > 0
  if not hasPayload and not hasTransitions:
    # plain enum (also what decision tables key over)
    var tags: seq[string]
    for v in d.typeBody.variants: tags.add(v.name)
    return ind & "public enum " & d.name & " { " & tags.join(", ") & " }\n"

  var res = ""
  var kindName = d.name
  if hasPayload:
    # tagged union: kind enum + carrier class; each variant's payload is a
    # struct field named after the variant (no cross-branch name clashes)
    kindName = d.name & "Kind"
    var tags: seq[string]
    for v in d.typeBody.variants: tags.add(v.name)
    res.add(ind & "public enum " & kindName & " { " & tags.join(", ") & " }\n")
    res.add(ind & "public class " & d.name & "\n" & ind & "{\n")
    res.add(ind & "    public " & kindName & " kind;\n")
    for v in d.typeBody.variants:
      if v.fields.len > 0:
        let payloadType = recStructName(ctx, v.fields)
        res.add(ind & "    public " & payloadType & " " & v.name.toLowerAscii() & ";\n")
    res.add(ind & "}\n")
  else:
    var tags: seq[string]
    for v in d.typeBody.variants: tags.add(v.name)
    res.add(ind & "public enum " & d.name & " { " & tags.join(", ") & " }\n")

  if hasTransitions:
    # transition matrix: pure predicate + checked assignment
    res.add(ctx.genTransitionProcs(d, kindName, hasPayload))
  return res

proc genRecordType(ctx: var BeefCodegenCtx, d: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  var fieldsStr: seq[string]
  for f in d.typeBody.fields:
    fieldsStr.add(ind & "    public " & ctx.fieldType(d.name, f) & " " & f.name & ";")
  let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: ind & "    // empty"
  let tGen = if d.generics.len > 0: "<" & d.generics.join(", ") & ">" else: ""
  # Tier 1 records are value types (spec §7.1) — struct, not class
  var res = ind & "public struct " & d.name & tGen & "\n" & ind & "{\n" &
            fieldsBody & "\n" & ind & "}\n"
  var invariantChecks: seq[string]
  var checkCtx = BeefCodegenCtx(definedVars: initHashSet[string](),
                                fieldVars: initHashSet[string](),
                                fieldPrefix: "self.", indent: 0,
                                module: ctx.module, realModules: ctx.realModules)
  for f in d.typeBody.fields:
    checkCtx.fieldVars.incl(f.name)
  for member in d.typeMembers:
    if member.kind == dkExpr:
      let condStr = checkCtx.genBeefExpr(member.expr)
      invariantChecks.add(ind & "    Runtime.Assert(" & condStr & ");")
  if invariantChecks.len > 0:
    res.add(ind & "public static void validate(" & d.name & " self)\n" &
            ind & "{\n" & invariantChecks.join("\n") & "\n" & ind & "}\n")
    # production sites wrap construction/returns in __validated(...)
    res.add(ind & "public static " & d.name & " __validated(" & d.name & " v)\n" &
            ind & "{\n" & ind & "    validate(v);\n" & ind & "    return v;\n" &
            ind & "}\n")
  # manager types carry functionality: member fns join the catalog
  for member in d.typeMembers:
    if member.kind == dkFn:
      res.add("\n" & ctx.genBeefDecl(member) & "\n")
  return res

proc genAliasType(ctx: var BeefCodegenCtx, d: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  var isDistinctT = false
  for a in d.typeBody.attrs:
    if a.name == "distinct": isDistinctT = true
  let typeBodyStr = ctx.beefType(d.typeBody)
  if isDistinctT:
    # wrapper struct + operators: same bits, incompatible type
    var res = ind & "public struct " & d.name & "\n" & ind & "{\n"
    res.add(ind & "    public " & typeBodyStr & " val;\n")
    res.add(ind & "    public this(" & typeBodyStr & " v) { val = v; }\n")
    for op in ["+", "-", "*", "/", "%"]:
      # Beef promotes small-int arithmetic; cast back to the base type
      res.add(ind & "    public static " & d.name & " operator" & op & "(" &
              d.name & " a, " & d.name & " b) { return " & d.name &
              "((" & typeBodyStr & ")(a.val " & op & " b.val)); }\n")
    res.add(ind & "    public static bool operator==(" & d.name & " a, " &
            d.name & " b) { return a.val == b.val; }\n")
    res.add(ind & "    public static int operator<=>(" & d.name & " a, " &
            d.name & " b) { return a.val <=> b.val; }\n")
    res.add(ind & "    public override void ToString(String strBuffer) " &
            "{ val.ToString(strBuffer); }\n")
    res.add(ind & "}\n")
    return res
  let aGen = if d.generics.len > 0: "<" & d.generics.join(", ") & ">" else: ""
  return ind & "public typealias " & d.name & aGen & " = " & typeBodyStr & ";\n"

proc genActor(ctx: var BeefCodegenCtx, d: Decl): string =
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
    # No message handlers: an empty enum is invalid Beef. Emit just the state.
    var bareFields: seq[string]
    for f in d.actorFields:
      bareFields.add(ind & "    public " & ctx.fieldType(d.name, f) & " " & f.name & ";")
    let bareBody = if bareFields.len > 0: bareFields.join("\n") else: ind & "    // empty"
    return ind & "public class " & d.name & "\n" & ind & "{\n" & bareBody &
           "\n" & ind & "}\n"

  # Handler params ride in the message envelope (deduped by name)
  var msgFields: seq[string]
  var seenMsgFields = initHashSet[string]()
  for h in d.handlers:
    if h.kind == dkFn:
      for p in h.fnParams:
        if p.name notin seenMsgFields:
          seenMsgFields.incl(p.name)
          msgFields.add(ind & "    public " & ctx.beefType(p.typ) & " " & p.name & ";")

  var res = ind & "public enum " & msgEnumName & " { " & enumVariants.join(", ") & " }\n"
  res.add(ind & "public class " & msgTypeName & "\n" & ind & "{\n" &
          ind & "    public " & msgEnumName & " kind;\n" &
          (if msgFields.len > 0: msgFields.join("\n") & "\n" else: "") &
          ind & "}\n")

  # Actor state object
  var fieldsStr: seq[string]
  for f in d.actorFields:
    fieldsStr.add(ind & "    public " & ctx.fieldType(d.name, f) & " " & f.name & ";")
  fieldsStr.add(ind & "    public Mailbox<" & msgTypeName & ", const " &
                queueSize & "> mailbox;")

  # Dispatch handler
  var handlerCases: seq[string]
  var hctx = BeefCodegenCtx(definedVars: initHashSet[string](),
                            fieldVars: initHashSet[string](),
                            fieldPrefix: "this.", indent: ctx.indent + 3,
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
        caseBody.add(ind & "        let " & p.name & " = msg." & p.name & ";\n")
      let bodyStr = hctx.genBeefExpr(h.fnBody)
      handlerCases.add(ind & "        case ." & variantName & ":\n" & caseBody & bodyStr)
  for hstr in hctx.hoisted:
    if hstr notin ctx.hoisted: ctx.hoisted.add(hstr)
  for sig, name in hctx.recShapes:
    if sig notin ctx.recShapes: ctx.recShapes[sig] = name

  res.add(ind & "public class " & d.name & "\n" & ind & "{\n" &
          fieldsStr.join("\n") & "\n\n")
  res.add(ind & "    public void handleMsg(" & msgTypeName & " msg)\n" &
          ind & "    {\n" & ind & "        switch (msg.kind)\n" &
          ind & "        {\n" & handlerCases.join("\n") & "\n" &
          ind & "        }\n" & ind & "    }\n")

  # Send helpers
  for h in d.handlers:
    if h.kind == dkFn:
      let helperName = "send" & h.name.capitalize()
      let variantName = "msg" & h.name.capitalize()
      var helperParams: seq[string]
      var ctorArgs = "kind = ." & variantName
      for p in h.fnParams:
        helperParams.add(ctx.beefType(p.typ) & " " & p.name)
        ctorArgs.add(", " & p.name & " = " & p.name)
      res.add("\n" & ind & "    public void " & helperName & "(" &
              helperParams.join(", ") & ")\n" & ind & "    {\n" &
              ind & "        this.mailbox.enqueue(new " & msgTypeName &
              "() { " & ctorArgs & " });\n" & ind & "    }\n")
  res.add(ind & "}\n")
  return res

proc genRegistry(ctx: var BeefCodegenCtx, d: Decl): string =
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
        fieldsStr.add(ind & "    public " & ctx.beefType(f.typ) & " " & f.name & ";")

  let enumStr = ind & "public enum " & msgEnumName & " { " & enumVariants.join(", ") & " }\n"
  let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") & "\n" else: ""
  let typeStr = ind & "public class " & d.name & "\n" & ind & "{\n" &
                ind & "    public " & msgEnumName & " kind;\n" & fieldsBody & ind & "}\n"
  let globalVarStr = ind & "public static " & d.name & " latest" & d.name & ";\n\n"

  # Beef resolves declaration order lazily: no forward decls needed
  var raiseProcsStr = ""
  for v in d.variants:
    var params: seq[string]
    var assignParts: seq[string]
    for f in v.fields:
      params.add(ctx.beefType(f.typ) & " " & f.name)
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
        handlerCalls.add(ind & "    " & handlerNameSanitized & "(" &
                         argNames.join(", ") & ");")

    let handlerInvokes = if handlerCalls.len > 0: handlerCalls.join("\n") & "\n" else: ""
    raiseProcsStr.add(ind & "public static void raise_" & d.name & "_" & v.name &
                      "(" & paramStr & ")\n" & ind & "{\n" &
                      ind & "    latest" & d.name & " = new " & d.name &
                      "() { kind = ." & v.name & assignStr & " };\n" &
                      handlerInvokes & ind & "}\n\n")

  return enumStr & typeStr & "\n" & globalVarStr & raiseProcsStr

# rt-implemented extern of a library module: forward to the Beef runtime,
# converting the runtime's record shapes to this module's hoisted shapes.
proc genRtForwarder(ctx: var BeefCodegenCtx, mem: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  var params: seq[string]
  var argNames: seq[string]
  for p in mem.fnParams:
    params.add(ctx.beefType(p.typ) & " " & p.name)
    argNames.add(p.name)
  let callStr = "Rt." & mem.name & "(" & argNames.join(", ") & ")"
  let (bw, _, binnerT) = ctx.beefBangInfo(mem.fnReturnType)
  let retTypeStr = if mem.fnReturnType != nil: ctx.beefType(mem.fnReturnType) else: "void"
  let header = ind & "public static " & retTypeStr & " " & mem.name & "(" &
               params.join(", ") & ")\n" & ind & "{\n"
  if bw and binnerT != nil and binnerT.kind == tkRecord:
    # convert TuckResult<RuntimeShape> -> TuckResult<ModuleShape> field by field
    let recName = recStructName(ctx, binnerT.fields)
    var fieldArgs: seq[string]
    for f in binnerT.fields: fieldArgs.add("r.value." & f.name)
    return header &
      ind & "    let r = " & callStr & ";\n" &
      ind & "    " & retTypeStr & " res = default;\n" &
      ind & "    res.status = r.status;\n" &
      ind & "    res.err = r.err;\n" &
      ind & "    if (r.status == .tsOk)\n" &
      ind & "        res.value = " & recName & "(" & fieldArgs.join(", ") & ");\n" &
      ind & "    return res;\n" & ind & "}\n"
  elif mem.fnReturnType != nil and mem.fnReturnType.kind == tkRecord:
    # plain record return: the runtime returns the single raw value
    let recName = recStructName(ctx, mem.fnReturnType.fields)
    return header & ind & "    return " & recName & "(" & callStr & ");\n" & ind & "}\n"
  elif retTypeStr == "void":
    return header & ind & "    " & callStr & ";\n" & ind & "}\n"
  else:
    return header & ind & "    return " & callStr & ";\n" & ind & "}\n"

proc genBeefDecl*(ctx: var BeefCodegenCtx, d: Decl): string =
  if d == nil: return ""
  if d.kind == dkType and d.span.file.startsWith(ImportedTypeMarker):
    return ""  # defined in its own module; that module's Beef file has it
  let ind = "  ".repeat(ctx.indent)
  case d.kind
  of dkFn:
    return ctx.genBeefFnDecl(d)
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
    var fieldsStr: seq[string]
    for f in d.objFields:
      fieldsStr.add(ind & "    public " & ctx.fieldType(d.name, f) & " " & f.name & ";")
    var membersStr = ""
    for member in d.objMembers:
      if member.kind == dkExpr and member.expr != nil and
         member.expr.kind == exkUnary and member.expr.unaryOp == uoComposition and
         member.expr.operand != nil and member.expr.operand.kind == exkVar:
        # `+ Name`: declared mixin materializes its fns on this object;
        # a declared record type embeds as a field (mirrors codegen.nim)
        let compName = member.expr.operand.name
        var composed = false
        for cd in ctx.module.decls:
          if cd == nil or cd.name != compName: continue
          if cd.kind == dkMixin:
            for mm in cd.mixinMembers:
              if mm.kind == dkFn and mm.fnBody != nil:
                membersStr.add(ctx.genBeefMemberFn(mm, d.name) & "\n")
            composed = true
          elif cd.kind == dkType and cd.typeBody != nil and
               cd.typeBody.kind == tkRecord:
            let fname = compName[0].toLowerAscii() & compName[1..^1]
            fieldsStr.add(ind & "    public " & compName & " " & fname & ";")
            composed = true
        if not composed:
          membersStr.add(ind & "// + " & compName & " (undeclared — sketch)\n")
      elif member.kind == dkFn:
        membersStr.add(ctx.genBeefMemberFn(member, d.name) & "\n")
      else:
        membersStr.add(ctx.genBeefDecl(member) & "\n")
    let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: ind & "    // empty"
    # manager objects hold var state but are Tier 1 value types too
    return ind & "public struct " & d.name & "\n" & ind & "{\n" & fieldsBody &
           "\n" & ind & "}\n\n" & membersStr
  of dkActor:
    return ctx.genActor(d)
  of dkTask:
    ctx.currentParams = @[]
    for p in d.taskParams:
      ctx.currentParams.add(FieldDef(name: p.name, typ: p.typ, span: p.span))
    var params: seq[string]
    for p in d.taskParams:
      params.add(ctx.beefType(p.typ) & " " & p.name)
    let retTypeStr = if d.taskReturnType != nil: ctx.beefType(d.taskReturnType) else: "void"
    let header = ind & "public static " & retTypeStr & " " & d.name & "(" &
                 params.join(", ") & ")"
    let oldVars = ctx.definedVars
    for p in d.taskParams:
      ctx.definedVars.incl(p.name)
    let oldIndent = ctx.indent
    let (bw, binner, binnerT) = ctx.beefBangInfo(d.taskReturnType)
    ctx.retWrapped = bw
    ctx.retInnerBeef = binner
    ctx.retInnerT = binnerT
    injectTailReturn(d.taskBody, retTypeStr)
    var bodyStr = ctx.genBeefExpr(d.taskBody)
    if d.taskBody != nil and d.taskBody.kind != exkBlock:
      let kw = if retTypeStr != "void": "return " else: ""
      bodyStr = ind & "{\n" & ind & "  " & kw & bodyStr & ";\n" & ind & "}"
    elif retTypeStr != "void":
      bodyStr = ensureTrailingReturn(bodyStr, d.taskBody, oldIndent)
    ctx.indent = oldIndent
    ctx.retWrapped = false
    ctx.retInnerBeef = ""
    ctx.retInnerT = nil
    ctx.definedVars = oldVars
    return header & "\n" & bodyStr & "\n"
  of dkConst:
    # literals become Beef consts; structured data a static field
    # (initialized at static ctor — still one-time, still immutable intent)
    if d.constVal != nil and d.constVal.kind == exkLit:
      let ty = case d.constVal.litKind
               of lkInt: "int"
               of lkFloat: "float"
               of lkStr: "String"
               of lkBool: "bool"
               else: "int"
      return ind & "public const " & ty & " " & d.name & " = " &
             ctx.genBeefExpr(d.constVal) & ";"
    return ind & "public static var " & d.name & " = " &
           ctx.genBeefExpr(d.constVal) & ";"
  of dkExpr:
    return ctx.genBeefExpr(d.expr)
  of dkRegister:
    var fieldsStr: seq[string]
    for f in d.regFields:
      let bitVal = f.typ.name.replace("bit ", "").replace("bits ", "")
      var accessMode = "ReadWrite"
      var hasRead = false
      var hasWrite = false
      for a in f.attrs:
        if a.name == "read": hasRead = true
        elif a.name == "write": hasWrite = true
      if hasRead and not hasWrite: accessMode = "ReadOnly"
      elif hasWrite and not hasRead: accessMode = "WriteOnly"
      fieldsStr.add(ind & "    [Bit(" & bitVal & ", AccessMode." & accessMode &
                    ")] public bool " & f.name & ";")
    return ind & "[RegisterMMIO(" & d.regAddress & ")]\n" & ind &
           "public class " & d.name & "\n" & ind & "{\n" &
           fieldsStr.join("\n") & "\n" & ind & "}\n"
  of dkRegistry:
    return ctx.genRegistry(d)
  of dkImport:
    return ""  # emitBeef has no import lines; same project, same namespace
  of dkStaticAssert:
    ctx.staticAsserts.add(ctx.genBeefExpr(d.assertExpr))
    return ""
  of dkErrors:
    # Global handler: rt logger first (errors are always visible), then the
    # user's handler body.
    var res = ind & "public static void tuck_unhandled(uint16 code, String site)\n" &
              ind & "{\n" & ind & "    tuckReportUnhandled(code, site);\n"
    if d.errHandler != nil and d.errHandler.fnBody != nil:
      let oldVars = ctx.definedVars
      ctx.definedVars.incl("code")
      ctx.definedVars.incl("site")
      let oldIndent = ctx.indent
      ctx.indent += 1
      let bodyStr = ctx.genBeefExpr(d.errHandler.fnBody)
      ctx.indent = oldIndent
      ctx.definedVars = oldVars
      var squeezed = ""
      for c in bodyStr:
        if c notin {' ', '\n', '\t'}: squeezed.add(c)
      if squeezed != "" and squeezed != "{}":
        res.add(bodyStr & "\n")
    res.add(ind & "}\n")
    return res
  of dkMixin:
    # Pending blocks parse as a mixin named "pending"; emit stubs for members.
    # Extern blocks: rt-implemented fns forward to the Beef runtime (library
    # modules) or emit nothing (entry module — `using static Rt` covers them);
    # C-imported fns emit [CLink] extern bindings with concrete param types.
    var res = ""
    for m in d.mixinMembers:
      if m.kind == dkFn and m.isPending:
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
        res.add(ctx.genBeefDecl(m) & "\n")
      elif m.kind == dkFn and m.isExtern and m.externHeader != "":
        var params: seq[string]
        for prm in m.fnParams:
          params.add(ctx.beefType(prm.typ) & " " & prm.name)
        let retStr = if m.fnReturnType != nil: ctx.beefType(m.fnReturnType) else: "void"
        res.add(ind & "[CLink] public static extern " & retStr & " " & m.name &
                "(" & params.join(", ") & ");\n")
      elif m.kind == dkFn and m.isExtern and ctx.modPrefix != "":
        res.add(ctx.genRtForwarder(m) & "\n")
    return res
  else:
    return ""

# Shared emission core: hoisted decls + members inside one Beef type.
proc emitBody(ctx: var BeefCodegenCtx, m: Module): tuple[types, mains: string] =
  var body = ""
  var mainStmts: seq[string]
  for d in m.decls:
    if d != nil and d.kind == dkExpr:
      let oldIndent = ctx.indent
      ctx.indent = 2
      var stmtCode = ctx.genBeefExpr(d.expr)
      ctx.indent = oldIndent
      if stmtCode != "":
        if d.expr != nil and d.expr.kind in {exkIf, exkFor, exkWhile, exkBlock}:
          mainStmts.add(stmtCode)
        else:
          mainStmts.add("        " & stmtCode & ";")
    else:
      let code = ctx.genBeefDecl(d)
      if code != "":
        body.add(code & "\n")
  (body, mainStmts.join("\n"))

const beefHeader = """using System;
using System.Collections;
using TuckRt;
using static TuckRt.Rt;

"""

proc emitBeef*(m: Module,
               realModules = initTable[string, Module](),
               moduleName = "main"): string =
  var ctx = BeefCodegenCtx(definedVars: initHashSet[string](),
                           fieldVars: initHashSet[string](),
                           fieldPrefix: "this.", indent: 1, module: m,
                           realModules: realModules, moduleName: moduleName)
  for d in m.decls:
    if d != nil and d.kind == dkErrors:
      ctx.errPolicy = d.policyName
  let (body, mains) = ctx.emitBody(m)
  var res = "namespace TuckApp;\n\n" & beefHeader
  res.add("static class Program\n{\n")
  for h in ctx.hoisted:
    res.add(h.indent(2) & "\n")
  if ctx.hoisted.len > 0:
    res.add("\n")
  res.add(body)
  if ctx.staticAsserts.len > 0:
    res.add("  static this()\n  {\n")
    for a in ctx.staticAsserts:
      res.add("    Runtime.Assert(" & a & ");\n")
    res.add("  }\n\n")
  res.add("  public static void Main()\n  {\n")
  if mains != "":
    res.add(mains & "\n")
  # fn main is the program entry point (the Nim path injects this in the CLI)
  for d in m.decls:
    if d != nil and d.kind == dkFn and d.name == "main" and not d.isPending:
      res.add("    main();\n")
      break
  res.add("  }\n}\n")
  res

# A library module (import target): a static class named after the module,
# so qualified refs (`fs::readFile`) emit as `fs.readFile`.
proc emitBeefModule*(name: string, m: Module,
                     realModules = initTable[string, Module]()): string =
  var ctx = BeefCodegenCtx(definedVars: initHashSet[string](),
                           fieldVars: initHashSet[string](),
                           fieldPrefix: "this.", indent: 1, module: m,
                           realModules: realModules, moduleName: name,
                           modPrefix: name.replace("-", "_") & "_")
  for d in m.decls:
    if d != nil and d.kind == dkErrors:
      ctx.errPolicy = d.policyName
  let (body, _) = ctx.emitBody(m)
  var res = "namespace TuckApp;\n\n" & beefHeader
  res.add("public static class " & name.replace("-", "_") & "\n{\n")
  for h in ctx.hoisted:
    res.add(h.indent(2) & "\n")
  if ctx.hoisted.len > 0:
    res.add("\n")
  res.add(body)
  res.add("}\n")
  res
