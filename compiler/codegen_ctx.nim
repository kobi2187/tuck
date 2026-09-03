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
import codegen_common
import codegen_type

type
  CodegenCtx* = object
    definedVars*: HashSet[string]
    fieldVars*: HashSet[string]
    indent*: int
    module*: Module
    hoisted*: seq[string]  # named decls hoisted out of field positions (inline enums)
    typeSection*: seq[string]  # object type headers — emitted with the types,
                              # ahead of every proc (Nim needs decl-before-use)
    retWrapped*: bool      # current fn returns !T/?T → returns auto-wrap
    retInnerNim*: string   # Nim type of the payload (for terr[T])
    retInnerT*: Type       # payload Tuck type (typed struct-literal emission)
    retInvName*: string    # fn returns an invariant-carrying type: validate at return sites
    tmpCounter*: int
    inTask*: bool          # emitting a task body — [io] calls become async yields
    errPolicy*: string     # from the errors declaration; "" = strict
    realModules*: Table[string, Module]  # imported modules emitted as own Nim files
    currentParams*: seq[FieldDef]  # enclosing fn's params — `input` rebuilds them
    moduleName*: string    # error codes hash over "module/Enum.Variant"
    recordNames*: HashSet[string]     # names of record types in `module` (O(1) lookup)
    invariantNames*: HashSet[string]  # names of invariant-carrying types in `module`
    taskNames*: HashSet[string]       # names of dkTask decls in `module`
    # Answers for the three questions genConstruction asks about EVERY call:
    # is the callee a [saturating] type, an extern with an invariant-carrying
    # return, an extern with an [emit: "..."] name. Each used to be a full
    # decl scan per call expression — together 16% of a whole compile.
    saturatingTypes*: Table[string, Type]  # name -> underlying type
    externInvRets*: Table[string, string]  # extern fn -> invariant ret type
    externEmits*: Table[string, string]    # extern fn -> [emit: "..."] name
    indexBuilt: bool                 # the sets above are populated?

proc cCallbackSig*(m: Module): string =
  ## The name of a C-callback fnsig declared in an extern block, or "".
  ## ponytail: first one wins — one C callback type per module covers every
  ## real header so far; key by param types when a second one shows up.
  for mem in m.externMembers():
    if mem.kind == dkFnSig and mem.sigIsCCallback: return mem.name
  ""

proc indexTypeDecl*(ctx: var CodegenCtx, d: Decl) =
  ## The three things a `type` contributes to the index.
  if d.typeBody == nil: return
  if d.typeBody.kind == tkRecord:
    ctx.recordNames.incl(d.name)
  for member in d.typeMembers:
    if member.kind == dkExpr:
      ctx.invariantNames.incl(d.name)
      break
  # `[saturating]` is the ATTRIBUTE, not the `distinct` keyword — see
  # ast_query.saturatingType, whose answer this caches.
  if d.typeBody.kind == tkNamed:
    for a in d.typeBody.attrs:
      if a.name == "saturating":
        ctx.saturatingTypes[d.name] = d.typeBody
        break

proc indexExterns*(ctx: var CodegenCtx) =
  ## Externs are a SECOND pass: an extern's invariant-carrying return type is
  ## looked up in invariantNames, which the first pass has to finish filling
  ## (a type may be declared after the extern that returns it).
  for d in ctx.module.decls:
    if d == nil or d.kind != dkExtern: continue
    for mem in d.mixinMembers:
      if mem.kind != dkFn or not mem.isExtern: continue
      if mem.externEmit != "":
        ctx.externEmits[mem.name] = mem.externEmit
      if mem.fnReturnType != nil and mem.fnReturnType.kind == tkNamed and
         mem.fnReturnType.name in ctx.invariantNames:
        ctx.externInvRets[mem.name] = mem.fnReturnType.name

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
                   moduleName: string): CodegenCtx =
  result = CodegenCtx(definedVars: initHashSet[string](), indent: 0, module: m,
                      realModules: realModules, moduleName: moduleName)
  for d in m.decls:
    if d != nil and d.kind == dkErrors:
      result.errPolicy = d.policyName

proc buildDeclIndex*(ctx: var CodegenCtx) =
  ## Populate the name sets for `module` once, so per-node type queries are O(1)
  ## instead of a full decl scan each call (the emit hot path is O(n) fns each
  ## checking their param/return type names — a linear scan there is O(n²)).
  if ctx.indexBuilt: return
  for d in ctx.module.decls:
    if d == nil: continue
    case d.kind
    # An object constructs exactly like a record — `{name: "rex"} Dog` is named
    # fields, not positional — so it belongs in the same set. Without this,
    # construction emitted `tuck_Dog("rex")` and Nim rejected it.
    of dkObject: ctx.recordNames.incl(d.name)
    of dkType: ctx.indexTypeDecl(d)
    of dkTask: ctx.taskNames.incl(d.name)
    # Everything else contributes no NAME to this index. Listed rather than
    # left to `else`, so a new DeclKind that should be indexed is a compile
    # error here instead of a lookup that quietly returns false. dkActor is
    # here, not its own arm: exkActorRef (resolve_refs.nim) now resolves
    # actor references before this index would ever be asked about one.
    of dkFn, dkActor, dkMixin, dkExtern, dkPending, dkPool, dkFnSig,
       dkRegistry, dkRegister, dkExpr, dkConst, dkStaticAssert, dkErrors,
       dkImport, dkSelect, dkSatisfies, dkInterface, dkWhen: discard
  ctx.indexExterns()
  ctx.indexBuilt = true

proc isRecordTypeFast*(ctx: var CodegenCtx, name: string): bool =
  ctx.buildDeclIndex()
  name in ctx.recordNames

proc hasInvariantsFast*(ctx: var CodegenCtx, name: string): bool =
  ## Does this declared type carry invariant predicates? (block members are
  ## dkExpr decls; production sites append a validate() call — spec 4.7)
  ctx.buildDeclIndex()
  name in ctx.invariantNames

proc saturatingTypeFast*(ctx: var CodegenCtx, name: string): Type =
  ## ast_query.saturatingType's answer, from the index. genConstruction asks
  ## this for EVERY call; the scanning version was 10% of a whole compile.
  ctx.buildDeclIndex()
  ctx.saturatingTypes.getOrDefault(name, nil)

proc externInvRetFast*(ctx: var CodegenCtx, fnName: string): string =
  ## ast_query.externInvRet's answer, from the index.
  ctx.buildDeclIndex()
  ctx.externInvRets.getOrDefault(fnName, "")

proc externEmitNameFast*(ctx: var CodegenCtx, fnName: string): string =
  ## externEmitName's answer, from the index.
  ctx.buildDeclIndex()
  ctx.externEmits.getOrDefault(fnName, "")

proc isTaskName*(ctx: var CodegenCtx, name: string): bool =
  ## Reads the index built once in buildDeclIndex, not a per-call scan of
  ## ctx.module.decls — this is called from genConstruction, once per call
  ## and a scan there is the same O(fns x calls) mistake fixed for lowering and
  ## the effect checker's task-spawn check.
  ctx.buildDeclIndex()
  name in ctx.taskNames

proc saturatingBase*(ctx: var CodegenCtx, name: string): string =
  ## spec 4.1: `[saturating]` clamps instead of wrapping. The ATTRIBUTE
  ## decides, not the `distinct` keyword — `type X = u16 [saturating]` and
  ## `distinct X = u16 [saturating]` mean the same thing (user ruling).
  ## Returns the underlying Nim integer type, or "" when not saturating.
  let t = ctx.saturatingTypeFast(name)
  if t == nil: "" else: genType(t)

proc externEmitName*(ctx: var CodegenCtx, fnName: string): string =
  ## The Nim/C proc name to emit for an extern with `[emit: "..."]`, or "" if
  ## it uses its Tuck name (the default).
  ctx.externEmitNameFast(fnName)
