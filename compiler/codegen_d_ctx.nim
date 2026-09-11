# compiler/codegen_d_ctx.nim
#
# The D backend's codegen context and type emission. No genDExpr/genDDecl
# calls here — pure state and type translation, safe to split from the
# recursive expression/decl codegen in codegen_d.nim.
import ast, tables, sets, strutils
import ast_query
import resolution
import decl_index
from codegen_odin_util import odinErrCode, enumTagOwner

const dPrims = {
  # Tuck int is 64-bit (ROADMAP 2026-08-25 ruling 1); D's `int` is 32-bit,
  # so the bare word maps to `long` — the first hidden Nim-ism this backend
  # exists to flush out.
  "int": "long", "i8": "byte", "i16": "short", "i32": "int", "i64": "long",
  "u8": "ubyte", "u16": "ushort", "u32": "uint", "u64": "ulong",
  "f32": "float", "f64": "double", "float": "double",
  "bool": "bool", "str": "string", "void": "void", "unit": "void",
}.toTable

const DCastablePrims* = ["long", "byte", "short", "int",
                         "ubyte", "ushort", "uint", "ulong",
                         "float", "double", "bool"]
  ## The D spellings a Tuck conversion call may `cast` to — every numeric
  ## width and bool. `string` and `void` are in dPrims but not here: casting
  ## an int to `string` in D reinterprets the bytes, which is never what
  ## `{value: n} str` would mean.

proc dPrimName*(name: string): string =
  ## D's spelling of a Tuck primitive, or "" when the name is not one. Used
  ## for a CONVERSION call (`{value: n} u64`), where the callee names a type
  ## rather than a fn — a local declaration reaches the same table through
  ## dType, but the call site had nothing.
  if name in dPrims: dPrims[name] else: ""

type
  DCodegenCtx* = object
    res*: Resolution
      ## The semantic layer this emission reads. Handed over by the pipeline
      ## rather than reached for: which is what makes the stage ordering —
      ## typecheck fills it, everything after reads it — visible instead of a
      ## comment on checkOrDie.
    definedVars*: HashSet[string]
    indent*: int           # statement indent, in 4-space levels
    module*: Module
    hoisted*: seq[string]  # named decls hoisted out of field positions (records)
    recShapes*: Table[string, string]  # record shape signature -> struct name
    modPrefix*: string     # library modules prefix hoisted names
    realModules*: Table[string, Module]
    moduleName*: string
    tmpCounter*: int
    currentParams*: seq[FieldDef]  # enclosing fn's params — `input` rebuilds them
    retWrapped*: bool       # current fn returns !T/?T — returns auto-wrap
    retAbsentCapable*: bool   # return type is ?T/!?T — bare return means tnone
    retInnerD*: string      # D type of the payload (for terr!T)
    retInnerT*: Type        # payload Tuck type (typed struct-literal returns)
    inlineTagOwner*: Table[string, string]  # tag -> hoisted enum that owns it.
                            # An INLINE sum has no declaration, so
                            # enumTagOwner (which scans decls) cannot see it.
    inlineSumOwner*: string  # "<Owner><Field>" while typing a field position,
                            # so an INLINE sum can hoist under a stable name
                            # instead of dying. Empty everywhere else.
    fieldVars*: HashSet[string]  # inside an invariant: names that are fields
    fieldPrefix*: string         # what those names are reached through
    matchNarrowed*: Table[string, string]  # subject text -> the variant a
                                            # match arm currently narrows it
                                            # to (see codegen.nim's twin)
    idx*: DeclIndex   # O(1) name lookups; a scan here is quadratic over the
                     # emit hot path (measured — see decl_index.nim)
    cLibs*: HashSet[string]  # `lib:` specs from C-FFI extern blocks; each
                            # becomes a pragma(lib) at module top level
    implMods*: Table[string, string]  # `impl: d "..."` alias -> module path,
                            # mirrors codegen_odin.nim's implMods
    movedParam*: string      # while emitting a fn's MOVED twin: the param
                             # it takes destructively, so a read of it needs
                             # no defensive .dup (the caller proved it dead)
    errPolicy*: string       # from the `errors` declaration; "" = strict.
                            # Only continue/exit reach codegen at all —
                            # strict is a COMPILE ERROR the checker raises,
                            # so a strict program has no drop sites left.

type TypeMode* = enum
  ## How a type walk answers a type it cannot map.
  tmRequired   ## a position that MUST have a type: die naming the construct
  tmOptional   ## a declaration, which can fall back to `auto`: answer ""

proc dUnsupported*(construct: string): string =
  ## The D backend refuses what it cannot yet emit — loudly, at emission
  ## time, naming the construct. Silent wrong code is the one forbidden
  ## outcome (see the actor/task plan: those arrive with the Fiber runtime).
  quit("tuck: D backend does not yet support " & construct, 1)

proc dHandlerFnName*(name: string): string =
  ## A registry handler is declared as `Registry.Event`, which is not a D
  ## identifier — the dot becomes an underscore, matching the name the raise
  ## proc calls.
  name.replace(".", "_")

proc dImplAlias*(module: string): string =
  ## Module alias for an `impl: d "..."` spec — the file's own D module
  ## name, which is just the last path segment. Mirrors codegen_odin.nim's
  ## implAlias, minus the ':' handling: D import paths use only '/'.
  if '/' in module: module.rsplit('/', 1)[^1] else: module

proc dAlias*(moduleName: string): string =
  ## A Tuck module's name as a D identifier — the import alias at a use site
  ## and the `mod_<alias>` file it comes from. One spelling rule in one
  ## place: it was written out at nine call sites, which is how a module
  ## named `net-http` ends up half-translated.
  moduleName.replace("-", "_")

proc bangInner*(t: Type): Type =
  ## The payload of a `!T` / `?T` / `!?T`, or nil when the type is plain.
  ## Both spellings are ONE carrier (rt.TuckResult) whose status says which
  ## — see codegen.nim's bangInfo.
  if t != nil and t.kind == tkApp and t.base != nil and
     t.base.kind == tkNamed and t.base.name in ["!", "?", "!?"] and
     t.args.len == 1:
    t.args[0]
  else: nil

proc importedTypeQualifierD*(ctx: DCodegenCtx, name: string): string =
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

proc declaredGenericD*(ctx: DCodegenCtx, name: string): bool =
  ## Is `name` a type this module declares (or imports) WITH type parameters?
  ## That is what makes `Name[args]` a template instantiation rather than an
  ## unmapped application.
  for d in ctx.module.decls:
    if d != nil and d.kind == dkType and d.name == name:
      return d.generics.len > 0
  false

proc dTypeIn*(ctx: var DCodegenCtx, t: Type, mode: TypeMode): string
  ## Forward-declared: dFixedArray/dAppType below recurse into it before
  ## its own definition.

proc recStructNameD*(ctx: var DCodegenCtx, fields: seq[FieldDef],
                     owner = ""): string
  ## Forward-declared: dTypeIn's tkRecord arm needs it before its own
  ## definition.

proc dFixedArray*(ctx: var DCodegenCtx, t: Type, mode: TypeMode): string =
  ## A fixed-size array, or "" when this type is not one.
  ##
  ## D writes the element first and the size after — `T[N]` — where Odin
  ## puts the size first (`[N]T`) and Nim spells it `array[N, T]`. Two
  ## source spellings reach here: `Array[count, elem]` and the `elem *
  ## count` product form.
  if t.base == nil or t.base.kind != tkNamed or t.args.len != 2: return ""
  let (elemIdx, sizeIdx) = case t.base.name
                           of "Array": (1, 0)
                           of "*": (0, 1)
                           else: return ""
  let inner = ctx.dTypeIn(t.args[elemIdx], mode)
  if inner == "": return ""
  inner & "[" & ctx.dTypeIn(t.args[sizeIdx], mode) & "]"

proc dResultCarrier(ctx: var DCodegenCtx, t: Type,
                    mode: TypeMode): tuple[isCarrier: bool, text: string] =
  ## `!T` / `?T` / `!?T` — ONE value carrier, the status says which. `!void`
  ## has no empty type to carry, so it carries the unit struct. The flag is
  ## separate from the text because a carrier whose PAYLOAD cannot be stated
  ## still answers "" (fall back to `auto`) rather than falling through to
  ## the mappings below.
  let payload = bangInner(t)
  if payload == nil: return (false, "")
  let inner = ctx.dTypeIn(payload, mode)
  if inner == "": return (true, "")
  if inner == "void": return (true, "rt.TuckResult!(rt.TuckUnit)")
  (true, "rt.TuckResult!(" & inner & ")")

proc dGenericApp(ctx: var DCodegenCtx, t: Type, baseName: string,
                 mode: TypeMode): string =
  ## A user GENERIC type applied to arguments — `Pair[str, int]`. D spells a
  ## parameterised struct as a template, so the use site is
  ## `Pair!(string, long)`; genDTypeDecl emits the declaration with the same
  ## parameter list.
  var args: seq[string]
  for a in t.args:
    let one = ctx.dTypeIn(a, mode)
    if one == "":
      if mode == tmRequired:
        return dUnsupported("type application " & baseName & "[...]")
      return ""
    args.add(one)
  ctx.importedTypeQualifierD(baseName) & "!(" & args.join(", ") & ")"

proc dAppType*(ctx: var DCodegenCtx, t: Type, mode: TypeMode): string =
  ## The two type applications this backend maps: `Seq[T]` and the `!T`/`?T`
  ## result carrier. Anything else is a gap named at the point of use.
  ##
  ## Seq[T] is a native D dynamic array — same value-semantics contract as
  ## the Nim backend's seq[T] (assignment copies; D slices alias, which the
  ## emitter compensates for at assignment sites — see the T17 audit).
  # `<uninit>[T]` is the checker's marker for a field the construction did not
  # supply. It is not a type the backend emits — the emitted record keeps its
  # declared field types exactly (see ast.UninitName) — so it erases here, as
  # it already did on the Nim and Odin paths.
  # (spelled out rather than importing typecheck_util's isUninit: codegen
  # sits BELOW the checker, and UninitName is ast's)
  if t.base != nil and t.base.kind == tkNamed and t.base.name == UninitName and
     t.args.len == 1:
    return ctx.dTypeIn(t.args[0], mode)
  let carrier = ctx.dResultCarrier(t, mode)
  if carrier.isCarrier: return carrier.text
  let elem = seqElem(t)
  if elem != nil:
    let elemStr = ctx.dTypeIn(elem, mode)
    return if elemStr == "": "" else: elemStr & "[]"
  let arr = ctx.dFixedArray(t, mode)
  if arr != "": return arr
  let baseName = if t.base != nil and t.base.kind == tkNamed: t.base.name
                 else: "?"
  # A user GENERIC type applied to arguments — `Pair[str, int]`. D spells a
  # parameterised struct as a template, so the use site is `Pair!(string,
  # long)`; the declaration is emitted with the same parameter list by
  # genDTypeDecl. Only a type this module can actually see is spelled this
  # way, so an unmapped application still reports itself.
  # A generic fnsig application is the signature itself, substituted. The
  # declaration emits nothing — see codegen_common.fnSigInstance.
  let sigInst = fnSigInstance(ctx.module, t)
  if sigInst != nil: return ctx.dTypeIn(sigInst, mode)
  if baseName != "?" and ctx.declaredGenericD(baseName):
    return ctx.dGenericApp(t, baseName, mode)
  if mode == tmRequired: dUnsupported("type application " & baseName & "[...]")
  else: ""

proc dFuncType*(ctx: var DCodegenCtx, t: Type): string =
  ## A fn-typed value (`fnsig BinOp = {a: int, b: int} -> int`, or a `:plus`
  ## reference the checker resolved). D spells it `R function(P...)`.
  ##
  ## `function`, NOT `delegate`: the two are distinct types in D, and what
  ## reaches a slot here is a top-level fn with no captured environment.
  ## Nim's `{.closure.}` and Odin's `proc` both accept a plain proc where a
  ## closure type is written, so neither had to make this choice. The call
  ## site takes the address (`&plus`) — isFnRefD already emits that.
  var ps: seq[string]
  for p in t.params: ps.add(ctx.dTypeIn(p, tmRequired))
  let r = if t.result == nil: "void"
          else: ctx.dTypeIn(t.result, tmRequired)
  r & " function(" & ps.join(", ") & ")"

proc dInlineSum*(ctx: var DCodegenCtx, t: Type, mode: TypeMode): string =
  ## A sum written INLINE in a field position (`state: {Red, Yellow, Green}`).
  ## It has no declaration of its own, so it is hoisted to a named enum the
  ## way the Nim and Odin backends name it: `<Owner><Field>Kind`. Only the
  ## payload-free form hoists — a variant carrying fields needs a tagged
  ## union, which has no anonymous spelling here.
  ##
  ## The name comes from ctx.inlineSumOwner, set by whichever field emitter
  ## is walking. Unset means this sum is in a position with no owning field
  ## (a param, a return), where there is nothing to name it after.
  if ctx.inlineSumOwner == "" or t.variants.len == 0:
    return (if mode == tmRequired: dUnsupported("inline sum type") else: "")
  for v in t.variants:
    if v.fields.len > 0:
      return (if mode == tmRequired:
                dUnsupported("inline sum type with a payload")
              else: "")
  let name = ctx.modPrefix & ctx.inlineSumOwner & "Kind"
  if not ctx.recShapes.hasKey("enum:" & name):
    ctx.recShapes["enum:" & name] = name
    var tags: seq[string]
    for v in t.variants:
      tags.add(v.name)
      ctx.inlineTagOwner[v.name] = name
    ctx.hoisted.add("enum " & name & " { " & tags.join(", ") & " }")
  name

proc dTypeIn*(ctx: var DCodegenCtx, t: Type, mode: TypeMode): string =
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
    elif t.name.startsWith(NamedTypeParamPrefix):
      # `<typeparam:K>` — the checker's name for a type param inside its own
      # generic body. In the EMITTED code that is just `K`, which the template
      # parameter list has already introduced. Without this, indexing a
      # `Seq[Entry[K, V]]` inside a generic fn had no statable type.
      t.name[NamedTypeParamPrefix.len .. ^2]
    elif t.name.startsWith("<"): giveUp("type sentinel " & t.name)
    else: ctx.importedTypeQualifierD(t.name)
  of tkApp: ctx.dAppType(t, mode)
  of tkTuple: giveUp("tuple type")
  of tkFunc: ctx.dFuncType(t)
  of tkRecord:
    # A record shape is nameable in both modes — it hoists its own struct.
    ctx.recStructNameD(t.fields)
  of tkSum: ctx.dInlineSum(t, mode)
  of tkUnion: giveUp("union type")
  of tkEffect: ctx.dTypeIn(t.inner, mode)  # [io]: no type-level footprint
  of tkRename: ctx.dTypeIn(t.underlying, mode)

proc dType*(ctx: var DCodegenCtx, t: Type): string =
  ## A type in a position that must have one — a param, a return, a field.
  ctx.dTypeIn(t, tmRequired)

proc dDeclType*(ctx: var DCodegenCtx, t: Type): string =
  ## A type for a variable declaration, or "" when it cannot be stated and
  ## the caller should fall back to `auto`.
  ctx.dTypeIn(t, tmOptional)

proc dFieldType*(ctx: var DCodegenCtx, owner: string, f: FieldDef): string =
  ## The declared type of one field. Identical to dType except that an
  ## INLINE sum here has a place to be named after — `<Owner><Field>Kind`,
  ## the name the Nim and Odin backends give the same hoisted enum.
  let saved = ctx.inlineSumOwner
  ctx.inlineSumOwner = owner & f.name.capitalize()
  result = ctx.dType(f.typ)
  ctx.inlineSumOwner = saved

proc recStructNameD*(ctx: var DCodegenCtx, fields: seq[FieldDef],
                    owner = ""): string =
  ## An anonymous record shape hoists as a TEMPLATE parameterised by its own
  ## field types — `struct TRec_rest_value(T_rest, T_value)` — and every use
  ## site names an instantiation of it.
  ##
  ## It used to be one struct per distinct field-name+TYPE signature, named
  ## with a hash of that signature. That cannot express a shape mentioning a
  ## type param: `fn pop[T]({items: Seq[T]}) -> {rest: Seq[T], value: T}?`
  ## hoisted `struct TRec_rest_value_E4D0 { T[] rest; T value; }` with no `T`
  ## in scope — "undefined identifier `T`". And the two ends disagreed even
  ## in principle: the callee hoisted the shape with `T`, while the caller
  ## hoisted the SUBSTITUTED shape with `long`, so they hashed to two
  ## different structs for one Tuck type.
  ##
  ## Parameterising by field type fixes both at once and needs nothing from
  ## the checker: the generic site writes `TRec_rest_value!(T[], T)`, the
  ## concrete site writes `TRec_rest_value!(long[], long)`, and when `T` is
  ## `long` those ARE the same instantiation. The name is keyed on field
  ## names alone, so no hash is needed and the emitted type says what it
  ## holds instead of hiding it behind four hex digits.
  ##
  ## `owner`: the module that DECLARED the shape, when that is not this one.
  ## A library module prefixes its hoisted names (modPrefix), so the caller
  ## must name the declaring module's template through its import alias.
  ## (Odin never hit this because `:=` infers the type and never spells it.)
  var typeStrs: seq[string]
  var nameParts: seq[string]
  for f in fields:
    typeStrs.add(ctx.dType(f.typ))
    nameParts.add(f.name)
  let args = "!(" & typeStrs.join(", ") & ")"
  if owner != "" and owner != ctx.moduleName:
    let alias = dAlias(owner)
    return alias & ".TRec_" & alias & "_" & nameParts.join("_") & args
  let name = "TRec_" & ctx.modPrefix & nameParts.join("_")
  if name notin ctx.recShapes:
    ctx.recShapes[name] = name
    var params: seq[string]
    for f in fields: params.add("T_" & f.name)
    var res = "struct " & name & "(" & params.join(", ") & ") {\n"
    for i, f in fields:
      res.add("    " & params[i] & " " & f.name & ";\n")
    res.add("}")
    ctx.hoisted.add(res)
  name & args

proc newDCtx*(m: Module, realModules: Table[string, Module],
             moduleName: string, res: Resolution,
             modPrefix = ""): DCodegenCtx =
  result = DCodegenCtx(definedVars: initHashSet[string](), indent: 0,
                       module: m, realModules: realModules,
                       moduleName: moduleName, modPrefix: modPrefix,
                       idx: buildDeclIndex(m), res: res)
  for d in m.decls:
    if d != nil and d.kind == dkErrors: result.errPolicy = d.policyName
