# compiler/codegen_ctx.nim
#
# The Nim backend's codegen context: per-emit mutable state (indent, hoisted
# decls, the fn currently being emitted), plus the decl-index fast-lookup
# cache (buildDeclIndex and its O(1) answers) that replaced repeated
# decl-list scans per call expression. No genExpr/genDecl calls here — pure
# state and lookups, safe to split from the recursive expression/decl
# codegen in codegen.nim.
import ast, tables, sets, strutils
import ast_query
import resolution
import codegen_type
import decl_index
export decl_index

type
  CodegenCtx* = object
    res*: Resolution
      ## The semantic layer this emission reads. Handed over by the pipeline
      ## rather than reached for: which is what makes the stage ordering —
      ## typecheck fills it, everything after reads it — visible instead of a
      ## comment on checkOrDie.
    definedVars*: HashSet[string]
    indent*: int
    module*: Module
    hoisted*: seq[string]  # named decls hoisted out of field positions (inline enums)
    typeSection*: seq[string]  # object type headers — emitted with the types,
                              # ahead of every proc (Nim needs decl-before-use)
    retWrapped*: bool      # current fn returns !T/?T → returns auto-wrap
    retAbsentCapable*: bool  # return type is ?T/!?T → bare return means tnone
    retInnerNim*: string   # Nim type of the payload (for terr[T])
    retInnerT*: Type       # payload Tuck type (typed struct-literal emission)
    retInvName*: string    # fn returns an invariant-carrying type: validate at return sites
    tmpCounter*: int
    wrapping*: HashSet[NodeId]
      ## Nodes whose interface wrap is being emitted right now. The wrap has
      ## to render its inner value through genExpr (a construction call is
      ## not a bare name), and genExpr would see the same mark again — this
      ## breaks that cycle without unmarking anything.
    inTask*: bool          # emitting a task body — [io] calls become async yields
    errPolicy*: string     # from the errors declaration; "" = strict
    realModules*: Table[string, Module]  # imported modules emitted as own Nim files
    currentParams*: seq[FieldDef]  # enclosing fn's params — `input` rebuilds them
    moduleName*: string    # error codes hash over "module/Enum.Variant"
    idx: DeclIndex         # decl_index, shared by all three backends; read
                           # through `index`, which builds it on first use.
                           # genConstruction asks it about EVERY call — as
                           # decl scans those questions were 16% of a compile
    importedEmits*: Table[string, string]  # an IMPORTED extern's [emit:] name
    rtExterns*: HashSet[string]      # externs the RUNTIME implements (no
                                     # [c, header:] binding), across the whole
                                     # program — their calls emit qualified as
                                     # `tuck_rt.name` so a std name can never
                                     # be ambiguous against one Nim's own
                                     # system/syncio auto-exports (readFile
                                     # and writeFile collide outright)
    indexBuilt: bool                 # `idx` and the two above are populated?
    matchNarrowed*: Table[string, string]  # var name -> the variant a match
                                            # arm currently narrows it to, so
                                            # `v.field` inside the arm reads
                                            # the MATCHED variant's storage

proc cCallbackSig*(m: Module): string =
  ## The name of a C-callback fnsig declared in an extern block, or "".
  ## ponytail: first one wins — one C callback type per module covers every
  ## real header so far; key by param types when a second one shows up.
  for mem in m.externMembers():
    if mem.kind == dkFnSig and mem.sigIsCCallback: return mem.name
  ""

proc indexRuntimeExterns(ctx: var CodegenCtx) =
  ## Runtime-backed externs from the WHOLE program, not just this module: the
  ## collision this guards against happens at the CALL site, and the call is
  ## in the importer while the `extern:` declaring it sits in the imported
  ## module (`import fs` + a bare `readFile` call is exactly that shape).
  ## An extern with a `[c, header:]` binding is NOT one of these — its name
  ## is the C symbol and must survive verbatim.
  for m in ctx.realModules.values:
    for d in m.decls:
      if d == nil or d.kind != dkExtern: continue
      for mem in d.mixinMembers:
        if mem.kind == dkFn and mem.isExtern and mem.externHeader == "" and
           mem.externEmit == "":
          ctx.rtExterns.incl(mem.name)

proc indexImportedEmits(ctx: var CodegenCtx) =
  ## An IMPORTED module's externs, for their `[emit:]` names only. This
  ## backend calls them UNQUALIFIED — Nim merges module scopes — so the emit
  ## name has to be known here or the call goes out under the Tuck name.
  ## std/seq's `len` is the case: it binds to `getLength`, and without this
  ## the emitted `len(xs)` resolved to Nim's own `system.len` instead. It
  ## worked, which is the problem — a host symbol answering by coincidence is
  ## what an emit name exists to prevent. (Odin and D route through their
  ## module forwarder, which already honoured it, so only the backend that
  ## merges scopes could miss it.)
  for m in ctx.realModules.values:
    for d in m.decls:
      if d == nil or d.kind != dkExtern: continue
      for mem in d.mixinMembers:
        if mem.kind == dkFn and mem.isExtern and mem.externEmit != "":
          ctx.importedEmits[mem.name] = mem.externEmit

proc satisfiersOf*(ctx: CodegenCtx, iface: string): seq[Decl] =
  ## Whole-program satisfier set — see codegen_common.satisfiersOf.
  satisfiersOf(ctx.module, ctx.realModules, iface)

proc taskRetType*(ctx: CodegenCtx, name: string): string =
  ## The Nim return type of a declared task, for its result slot.
  for d in ctx.module.decls:
    if d != nil and d.kind == dkTask and d.name == name:
      return if d.taskReturnType != nil: genType(d.taskReturnType) else: "void"
  "void"

proc fieldType*(ctx: var CodegenCtx, parent: string, f: FieldDef): string =
  ## Field type emission. Nim forbids anonymous enums in field positions, so
  ## an inline sum type is hoisted to a named enum `<Parent><Field>Kind`.
  if f.typ != nil and f.typ.kind == tkSum:
    var allNoFields = true
    for v in f.typ.variants:
      if v.fields.len > 0: allNoFields = false
    if allNoFields and f.typ.variants.len > 0:
      let enumName = parent & f.name.capitalize() & "Kind"
      var tags: seq[string]
      for v in f.typ.variants: tags.add(v.name)
      ctx.hoisted.add("type " & enumName & "* = enum " & tags.join(", "))
      return enumName
  return genType(f.typ)

proc newCodegenCtx*(m: Module, realModules: Table[string, Module],
                   moduleName: string, res: Resolution): CodegenCtx =
  result = CodegenCtx(definedVars: initHashSet[string](), indent: 0, module: m,
                      realModules: realModules, moduleName: moduleName,
                      res: res)
  for d in m.decls:
    if d != nil and d.kind == dkErrors:
      result.errPolicy = d.policyName

proc buildDeclIndex*(ctx: var CodegenCtx) =
  ## Build the module's index (decl_index) and this backend's two
  ## whole-program extras once, so per-node questions are O(1) instead of a
  ## decl scan each call — the emit hot path asks them for every call, and a
  ## linear scan there is O(n²).
  if ctx.indexBuilt: return
  ctx.idx = buildDeclIndex(ctx.module)
  ctx.indexImportedEmits()
  ctx.indexRuntimeExterns()
  ctx.indexBuilt = true

proc index*(ctx: var CodegenCtx): var DeclIndex =
  ## The module's declaration index, built on first use.
  ctx.buildDeclIndex()
  ctx.idx

proc saturatingBase*(ctx: var CodegenCtx, name: string): string =
  ## spec 4.1: `[saturating]` clamps instead of wrapping. The ATTRIBUTE
  ## decides, not the `distinct` keyword — `type X = u16 [saturating]` and
  ## `distinct X = u16 [saturating]` mean the same thing (user ruling).
  ## Returns the underlying Nim integer type, or "" when not saturating.
  let t = ctx.index.saturatingType(name)
  if t == nil: "" else: genType(t)

proc externEmitName*(ctx: var CodegenCtx, fnName: string): string =
  ## The Nim/C proc name to emit for an extern with `[emit: "..."]`, or "" if
  ## it uses its Tuck name (the default). This module's own, else an
  ## imported one's — Nim calls those unqualified too.
  result = ctx.index.externEmitName(fnName)
  if result == "": result = ctx.importedEmits.getOrDefault(fnName, "")

proc isRuntimeExtern*(ctx: var CodegenCtx, fnName: string): bool =
  ## Is this call target an extern the RUNTIME implements? Those emit
  ## qualified (`tuck_rt.name`) — Nim auto-exports `readFile`/`writeFile`
  ## from std/syncio into every module, so a bare call to std/fs's own is
  ## an "ambiguous call" the user never wrote and cannot see. Odin and D
  ## already qualify every runtime call as `rt.name` for the same reason.
  ctx.buildDeclIndex()
  fnName in ctx.rtExterns
