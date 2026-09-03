# compiler/codegen_d_ctx.nim
#
# The D backend's codegen context and type emission. No genDExpr/genDDecl
# calls here — pure state and type translation, safe to split from the
# recursive expression/decl codegen in codegen_d.nim.
import ast, tables, sets, strutils
import ast_query
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

type
  DCodegenCtx* = object
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
    idx*: DeclIndex   # O(1) name lookups; a scan here is quadratic over the
                     # emit hot path (measured — see decl_index.nim)
    cLibs*: HashSet[string]  # `lib:` specs from C-FFI extern blocks; each
                            # becomes a pragma(lib) at module top level
    implMods*: Table[string, string]  # `impl: d "..."` alias -> module path,
                            # mirrors codegen_odin.nim's implMods
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

proc dAppType*(ctx: var DCodegenCtx, t: Type, mode: TypeMode): string =
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
  let arr = ctx.dFixedArray(t, mode)
  if arr != "": return arr
  let baseName = if t.base != nil and t.base.kind == tkNamed: t.base.name
                 else: "?"
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

proc newDCtx*(m: Module, realModules: Table[string, Module],
             moduleName: string, modPrefix = ""): DCodegenCtx =
  result = DCodegenCtx(definedVars: initHashSet[string](), indent: 0,
                       module: m, realModules: realModules,
                       moduleName: moduleName, modPrefix: modPrefix,
                       idx: buildDeclIndex(m))
  for d in m.decls:
    if d != nil and d.kind == dkErrors: result.errPolicy = d.policyName
