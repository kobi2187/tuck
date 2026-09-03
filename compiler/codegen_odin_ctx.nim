# compiler/codegen_odin_ctx.nim
#
# The Odin backend's codegen context, type emission, and decl-shape fast
# lookups. No genOdinExpr/genOdinDecl calls here — pure state and type
# translation, safe to split from the recursive expression/decl codegen
# in codegen_odin.nim.
import ast, tables, sets, strutils
import ast_query
import codegen_common
import codegen_odin_util

type
  OdinCodegenCtx* = object
    definedVars*: HashSet[string]
    fieldVars*: HashSet[string]
    fieldPrefix*: string   # "this." in methods, "self." in static validate procs
    indent*: int
    module*: Module
    hoisted*: seq[string]  # named decls hoisted out of field positions
    recShapes*: Table[string, string]  # record shape signature -> struct name
    modPrefix*: string     # library modules prefix hoisted names (dedupe per project)
    retWrapped*: bool      # current fn returns !T/?T -> returns auto-wrap
    retInnerOdin*: string  # Odin type of the payload (for terr<T>)
    retInnerT*: Type       # payload Tuck type (typed struct-literal emission)
    retInvName*: string    # fn returns an invariant-carrying type: validate at return
    tmpCounter*: int
    errPolicy*: string     # from the errors declaration; "" = strict
    realModules*: Table[string, Module]  # imported modules emitted as own Odin files
    staticAsserts*: seq[string]  # collected into one `static this()` block
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
    taskNames*: HashSet[string]   # dkTask decl names, same one-shot index
    taskNamesBuilt*: bool
    taskArgsHoisted*: HashSet[string]   # task names whose Env_/wrap_ pair is
                                       # already hoisted — one signature per
                                       # task, unlike anonymous records,
                                       # so the task's own name IS the key

proc odinType*(ctx: var OdinCodegenCtx, t: Type): string
  ## Forward-declared: recStructName/odinTupleType/odinAppType/odinFuncType
  ## below recurse into it before its own definition.

proc odinUnsupported*(construct: string): string =
  ## The Odin backend refuses what it cannot yet emit — loudly, at emission
  ## time, naming the construct. Silent wrong code is the one forbidden
  ## outcome (mirrors the D backend's dUnsupported).
  quit("tuck: Odin backend does not yet support " & construct, 1)

proc isTaskName*(ctx: var OdinCodegenCtx, name: string): bool =
  ## Mirrors the Nim backend. Calling a task SCHEDULES it as a coroutine
  ## (spec §9.2); emitting a direct call instead runs its body on the main
  ## context, where the first tuckAwaitRead hits parkCurrent's
  ## "cannot await outside a coroutine" panic.
  if not ctx.taskNamesBuilt:
    for d in ctx.module.decls:
      if d != nil and d.kind == dkTask: ctx.taskNames.incl(d.name)
    ctx.taskNamesBuilt = true
  name in ctx.taskNames

proc recStructName*(ctx: var OdinCodegenCtx, fields: seq[FieldDef]): string =
  ## Record shapes become hoisted structs, giving every shape a stable
  ## nominal type for construction and field access. Odin needs no
  ## constructor: struct literals take named fields (`Name{a = 1, b = 2}`).
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

proc odinNamedFallback*(ctx: OdinCodegenCtx, t: Type): string =
  ## A name the primitive table did not cover.
  if isOddBitWidth(t.name): roundedIntType(t.name)
  elif t.name == UnknownName: "any"  # sketch mode: no type information
  else: ctx.importedTypeQualifier(t.name)

proc odinTupleType*(ctx: var OdinCodegenCtx, t: Type): string =
  if t.elems.len == 1: return ctx.odinType(t.elems[0])
  var parts: seq[string]
  for e in t.elems: parts.add(ctx.odinType(e))
  "(" & parts.join(", ") & ")"

proc odinAppType*(ctx: var OdinCodegenCtx, t: Type): string =
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

# fn param TYPES by position, for call sites deciding whether an arg needs
# the `ref` marker (mutable record param).
proc lookupFnParamTypes*(m: Module, name: string): seq[Type] =
  m.findFn(name).paramTypes()

proc declaresFn*(m: Module, name: string): bool =
  ## Does this module declare `name` as a callable? A bool, because a fn with
  ## no params is indistinguishable from "not found" in a param list.
  m.findFn(name) != nil

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

proc newOdinCtx*(m: Module, realModules: Table[string, Module],
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
