# compiler/codegen_odin_ctx.nim
#
# The Odin backend's codegen context, type emission, and decl-shape fast
# lookups. No genOdinExpr/genOdinDecl calls here — pure state and type
# translation, safe to split from the recursive expression/decl codegen
# in codegen_odin.nim.
import ast, tables, sets, strutils
import ast_query
import resolution
import analysis_ownership
import decl_index
export decl_index

type
  OdinCodegenCtx* = object
    res*: Resolution
      ## The semantic layer this emission reads. Handed over by the pipeline
      ## rather than reached for: which is what makes the stage ordering —
      ## typecheck fills it, everything after reads it — visible instead of a
      ## comment on checkOrDie.
    definedVars*: HashSet[string]
    fieldVars*: HashSet[string]
    fieldPrefix*: string   # "this." in methods, "self." in static validate procs
    indent*: int
    module*: Module
    hoisted*: seq[string]  # named decls hoisted out of field positions
    recShapes*: Table[string, string]  # record shape signature -> struct name
    modPrefix*: string     # library modules prefix hoisted names (dedupe per project)
    retWrapped*: bool      # current fn returns !T/?T -> returns auto-wrap
    retAbsentCapable*: bool  # return type is ?T/!?T -> bare return means tnone
    retInnerOdin*: string  # Odin type of the payload (for terr<T>)
    retInnerT*: Type       # payload Tuck type (typed struct-literal emission)
    retInvName*: string    # fn returns an invariant-carrying type: validate at return
    tmpCounter*: int
    owned*: Ownership
      ## What analysis_ownership decided for the fn being emitted: which
      ## locals die at scope exit, which die at an overwrite, and what the
      ## MOVED twin frees. The emitter prints it; it decides nothing.
    movedParam*: string    # while emitting a fn's MOVED twin: the param it
                           # takes destructively. NOT a reason to skip a
                           # copy — what is copied is the copy pass's call
                           # (lowering_seqcopy, movedTransfer)
    errPolicy*: string     # from the errors declaration; "" = strict
    realModules*: Table[string, Module]  # imported modules emitted as own Odin files
    staticAsserts*: seq[string]  # collected into one `static this()` block
    actorInits*: seq[string]     # `singleton.field = v`, run by the entry
                                 # point before any actor starts (#87)
    moduleName*: string    # error codes hash over "module/Enum.Variant"
    currentParams*: seq[FieldDef]  # enclosing fn's params — `input` rebuilds them
    ptrSelf*: bool         # inside a member fn: `self` is ^T and needs a deref
    fnAsParam*: bool       # emitting a param list: a bare `fn` is `$T` there
    foreignLibs*: Table[string, string]  # C libs bound by extern blocks:
                                        # alias -> import spec. Each needs a
                                        # `foreign import` at package top level
    implMods*: Table[string, string]     # `impl: odin "..."` modules: alias ->
                                        # import spec. Odin has no unqualified
                                        # re-export, so each extern fn also gets
                                        # a local forwarder calling <alias>.<fn>
                                        # — call sites stay unqualified, as on
                                        # the Nim side
    unionBind*: string   # inside `switch v in value`: the name bound to the
                        # matched variant. A payload field is read through
                        # IT, not off the subject — Odin's union has no
                        # discriminant field to reach past.
    idx: DeclIndex       # decl_index, shared by all three backends; read
    idxBuilt: bool       # through `index`, which builds it on first use
    taskArgsHoisted*: HashSet[string]   # task names whose Env_/wrap_ pair is
                                       # already hoisted — one signature per
                                       # task, unlike anonymous records,
                                       # so the task's own name IS the key

proc odinType*(ctx: var OdinCodegenCtx, t: Type): string
  ## Forward-declared: recStructName/odinTupleType/odinAppType/odinFuncType
  ## below recurse into it before its own definition.

proc index*(ctx: var OdinCodegenCtx): var DeclIndex =
  ## The module's declaration index (decl_index), built on first use — a
  ## throwaway ctx (an invariant's check proc) builds its own when it asks.
  if not ctx.idxBuilt:
    ctx.idx = buildDeclIndex(ctx.module)
    ctx.idxBuilt = true
  ctx.idx

proc recStructName*(ctx: var OdinCodegenCtx, fields: seq[FieldDef]): string =
  ## Record shapes become hoisted structs, giving every shape a stable
  ## nominal type for construction and field access. Odin needs no
  ## constructor: struct literals take named fields (`Name{a = 1, b = 2}`).
  ##
  ## PARAMETERISED by its own field types, for the reason spelled out on the
  ## D backend's twin: a shape mentioning a type param (`{rest: Seq[T],
  ## value: T}`) hoisted a struct with no `T` in scope — "Undeclared name: T"
  ## — and the generic and substituted ends named two different structs for
  ## one Tuck type. `TRec_rest_value([dynamic]T, T)` and
  ## `TRec_rest_value([dynamic]int, int)` are the same template, so they
  ## agree by construction when T is int.
  var typeStrs: seq[string]
  var nameParts: seq[string]
  for f in fields:
    typeStrs.add(ctx.odinType(f.typ))
    nameParts.add(f.name)
  let args = "(" & typeStrs.join(", ") & ")"
  let name = "TRec_" & ctx.modPrefix & nameParts.join("_")
  if name notin ctx.recShapes:
    ctx.recShapes[name] = name
    var params: seq[string]
    for f in fields: params.add("$T_" & f.name)
    var decl: seq[string]
    for p in params: decl.add(p & ": typeid")
    var res = name & " :: struct " & "(" & decl.join(", ") & ") {\n"
    for i, f in fields:
      res.add("\t" & f.name & ": T_" & f.name & ",\n")
    res.add("}")
    ctx.hoisted.add(res)
  return name & args

proc isOddBitWidth*(name: string): bool =
  ## `u2`, `u12` — a width a decision table produced that no machine type has.
  name.len >= 2 and name[0] in {'u', 'i'} and
    name[1..^1].allCharsInSet({'0'..'9'})

proc roundedIntType*(name: string): string =
  ## Odd bit widths round UP to the next real machine int.
  let bits = parseInt(name[1..^1])
  let base = if name[0] == 'u': "u" else: "i"
  if bits <= 8: base & "8"
  elif bits <= 16: base & "16"
  elif bits <= 32: base & "32"
  else: base & "64"

proc importedTypeQualifier*(ctx: OdinCodegenCtx, name: string): string =
  ## `pkg.Name` for a type another module declares, else `Name`.
  let origin = moduleDeclaringType(ctx.module, name)
  let pkg = origin.replace("-", "_")
  if origin != "" and pkg != ctx.moduleName.replace("-", "_"): pkg & "." & name
  else: name

proc qualifyEnumOwner*(ctx: OdinCodegenCtx, owner: string): string =
  ## An enum owner reached through its module when the TYPE it belongs to was
  ## imported. `importedTypeQualifier` above already does this for a type in
  ## TYPE position; a bare tag and a match-arm label are the two places the
  ## same name appears in VALUE position, and neither was qualified — so a sum
  ## declared in another module produced `tuck_Order.Before` and "Undeclared
  ## name" beside a correctly qualified `cmp.tuck_flipped`.
  ##
  ## `enumTagOwner` answers `TKind` for a payload sum, so the decl whose
  ## origin to look up is that name minus the suffix.
  let typeName = if owner.endsWith("Kind"): owner[0 ..< owner.len - 4]
                 else: owner
  let origin = moduleDeclaringType(ctx.module, typeName)
  if origin.len == 0: return owner
  let pkg = origin.replace("-", "_")
  if pkg == ctx.moduleName.replace("-", "_"): owner else: pkg & "." & owner

proc odinNamedFallback*(ctx: OdinCodegenCtx, t: Type): string =
  ## A name the primitive table did not cover.
  if isOddBitWidth(t.name): roundedIntType(t.name)

  else: ctx.importedTypeQualifier(t.name)

proc odinTupleType*(ctx: var OdinCodegenCtx, t: Type): string =
  if t.elems.len == 1: return ctx.odinType(t.elems[0])
  var parts: seq[string]
  for e in t.elems: parts.add(ctx.odinType(e))
  "(" & parts.join(", ") & ")"

proc odinAppType*(ctx: var OdinCodegenCtx, t: Type): string =
  ## Odin puts the size BEFORE the element type: [N]T, not T[N].
  if t.base.kind == tkNamed:
    # `<uninit>[T]` marks a field the construction did not supply. It is not
    # a type any backend emits — the emitted record keeps its declared field
    # types exactly (ast.UninitName) — so it erases here. It leaked as
    # `op: <uninit>(tuck_BinOp)` the first time an example constructed a
    # record with a hole; the D backend had the identical gap.
    if t.base.name == UninitName and t.args.len == 1:
      return ctx.odinType(t.args[0])
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

proc odinFuncType*(ctx: var OdinCodegenCtx, t: Type): string =
  ## A resolved function reference (`:plus`) carries its real signature, so it
  ## emits a callable proc type rather than an opaque pointer.
  var ps: seq[string]
  for p in t.params: ps.add(ctx.odinType(p))
  let r = if t.result != nil and
             not (t.result.kind == tkNamed and t.result.name == "void"):
            " -> " & ctx.odinType(t.result)
          else: ""
  "proc(" & ps.join(", ") & ")" & r

proc odinNamedBuiltin(ctx: var OdinCodegenCtx, name: string): string =
  ## Map Tuck builtin type names to Odin equivalents.
  case name
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
  of "cstring": "cstring"
  of "Buf": "[^]u8"
  of "bool": "bool"
  of "float": "f64"
  of "f32": "f32"
  of "f64": "f64"
  of "usize": "uint"
  of "Seq": "[dynamic]"
  of "Array": "[]"
  of "fn": (if ctx.fnAsParam: "$T" else: "proc()")
  else: ""

proc odinSumTypeName(ctx: var OdinCodegenCtx, t: Type): string =
  ## Hoists anonymous enum variants as a named type, or returns "any" for tagged unions.
  var allNoFields = true
  for v in t.variants:
    if v.fields.len > 0: allNoFields = false
  if allNoFields and t.variants.len > 0:
    var tags: seq[string]
    for v in t.variants: tags.add(v.name)
    let name = "TEnum_" & ctx.modPrefix & toHex(errIdCode(tags.join(",")))
    let decl = name & " :: enum { " & tags.join(", ") & " }"
    if decl notin ctx.hoisted: ctx.hoisted.add(decl)
    return name
  return "any"

proc odinType*(ctx: var OdinCodegenCtx, t: Type): string =
  if t == nil: return "void"
  case t.kind
  of tkNamed:
    # `<typeparam:K>` is the checker's name for a type param inside its own
    # generic body; emitted, it is just `K`.
    if t.name.startsWith(NamedTypeParamPrefix):
      return t.name[NamedTypeParamPrefix.len .. ^2]
    let builtin = odinNamedBuiltin(ctx, t.name)
    if builtin != "": return builtin
    ctx.odinNamedFallback(t)
  of tkTuple: ctx.odinTupleType(t)
  of tkApp:
    # A generic fnsig application is the SIGNATURE, substituted — the
    # declaration emits nothing, because Odin's proc types are not
    # parametric. See codegen_common.fnSigInstance.
    let sigInst = fnSigInstance(ctx.module, t)
    if sigInst != nil: ctx.odinFuncType(sigInst)
    else: ctx.odinAppType(t)
  of tkFunc: ctx.odinFuncType(t)
  of tkRecord:
    recStructName(ctx, t.fields)
  of tkSum:
    odinSumTypeName(ctx, t)
  else:
    "rawptr"

proc fieldType*(ctx: var OdinCodegenCtx, parent: string, f: FieldDef): string =
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
#
# hasInvariants / externInvRet / isRecordType / isErrEnumRef used to be
# copy-pasted here from codegen.nim (this backend began as a fork). They are
# backend-neutral questions about the AST, so they live in ast_query.

proc genQualified*(ctx: OdinCodegenCtx, e: Expr): string =
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

proc satisfiersOf*(ctx: OdinCodegenCtx, iface: string): seq[Decl] =
  ## Whole-program satisfier set — see codegen_common.satisfiersOf.
  satisfiersOf(ctx.module, ctx.realModules, iface)

proc newOdinCtx*(m: Module, realModules: Table[string, Module],
                moduleName: string, res: Resolution,
                modPrefix = ""): OdinCodegenCtx =
  ## indent 0: Odin declarations are top-level in a package, with no enclosing
  ## class the way Beef/C# needed one.
  result = OdinCodegenCtx(definedVars: initHashSet[string](),
                          fieldVars: initHashSet[string](),
                          fieldPrefix: "self.", indent: 0, module: m,
                          realModules: realModules, moduleName: moduleName,
                          modPrefix: modPrefix, res: res)
  for d in m.decls:
    if d != nil and d.kind == dkErrors:
      result.errPolicy = d.policyName
