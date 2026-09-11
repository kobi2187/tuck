# compiler/codegen_common.nim
#
# Small helpers that were copy-pasted byte-for-byte into both codegen.nim
# (Nim backend) and codegen_odin.nim (Odin backend) because each backend's
# context type is different (CodegenCtx vs OdinCodegenCtx) but the logic
# only ever touched the `module`/`moduleName` fields both contexts carry.
# Written out here once, taking those fields directly instead of a ctx
# object, so the two backends can't drift apart on questions that have
# nothing to do with which language is being emitted.
#
# THE TEST FOR BELONGING HERE: is it a QUERY or an EMITTER? A query asks the
# tree a question and returns data — satisfiersOf ("which objects satisfy this
# contract"), recordFieldNames, isCompositionEntry. The answer is the same
# whichever language is being printed, so it belongs here.
#
# An emitter interleaves that traversal with syntax — composeInto and
# genObjectDecl walk the same decls in the same order in both backends, but
# each line they build is target-specific and each calls back into its own
# backend's emitters. Those stay duplicated on purpose; see codegen.nim's
# header: share the logic, never share the syntax.
#
# Sits below both backends in the dependency DAG, alongside ast_query and
# lowering — it imports those and nothing that imports either codegen module.
import resolution
import ast, lowering, ast_query, strutils, sets, tables, algorithm, options
import ./ast_query

proc sumPayloadField*(variantName: string): string =
  ## The struct/object field a payload variant's data sits in.
  ##
  ## It was the variant name lowercased, which is an identifier the AUTHOR did
  ## not write and cannot see — so when it collided with a host keyword the
  ## report named generated code. `| Block({...})` emitted `of Block: block*:`
  ## and Nim answered "identifier expected, but got 'keyword block'". Every
  ## realistic AST or IR type has a variant called Block, If, Case, Var or
  ## Return, so this was waiting for the first tree anyone wrote.
  ##
  ## `tuck_` is the same prefix mangle.nim puts on every other generated name,
  ## for the same reason: a generated identifier must not be able to collide
  ## with anything in the target language. Shared by the declaration site and
  ## every read site in both backends that carry one — Odin has no such field,
  ## it binds the union member directly.
  "tuck_" & variantName.toLowerAscii()

proc absentCapable*(t: Type): bool =
  ## Does this fn's declared return type admit `tsAbsent` — `?T` or `!?T`? A
  ## plain `!T` has no absence, only Ok/Err, so a bare `return` there means
  ## success with a zero value, not "nothing to report".
  t != nil and t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
    t.base.name in ["?", "!?"] and t.args.len == 1

proc findObjectMember*(obj: Decl, name: string): Decl =
  ## The member fn named `name` declared inside object `obj`, or nil — the
  ## satisfier-specific counterpart to `findFn`, which resolves by name alone
  ## and cannot tell two same-named methods on different objects apart.
  for mem in obj.members():
    if mem != nil and mem.kind == dkFn and mem.name == name: return mem

proc moduleDeclaringType*(module: Module, name: string): string =
  ## The imported module a TYPE came from, or "" when this module declares it.
  ##
  ## `injectImportedTypes` makes an imported type visible unqualified by
  ## inserting a COPY into the importer's own decl list, stamped with
  ## `ImportedTypeMarker & ":" & origin` in its span. So the importer holds
  ## both kinds and the marker is the only thing telling them apart — asking
  ## `findDecl` whether the type is local answers "yes" for both.
  ##
  ## The D backend already qualified foreign CALLABLES (importDeclaring —
  ## "D has no cross-module scope merge, so every foreign call has to be
  ## qualified") and Odin already qualified foreign TYPES in type position
  ## (importedTypeQualifier). Neither qualified a type used as a VALUE
  ## receiver, so `Order.Before` on a sum from another module emitted bare and
  ## both backends reported an undeclared name — beside a correctly qualified
  ## `cmp.tuck_flipped` on the same line.
  ##
  ## Nim never showed it: `import cmp` merges names, so the bare form
  ## resolves. That is why a two-module program compiled on one backend of
  ## three, and why the stdlib design's "modules rely on each other" had never
  ## been exercised.
  for d in module.decls:
    if d == nil or d.kind != dkType or d.name != name: continue
    if not d.span.file.startsWith(ImportedTypeMarker & ":"): return ""
    return d.span.file[ImportedTypeMarker.len + 1 .. ^1]
  ""

proc satisfiersOf*(module: Module, realModules: Table[string, Module],
                   iface: string): seq[Decl] =
  ## Every object declaring `satisfies iface`, across the WHOLE PROGRAM.
  ##
  ## An interface value is a variant over its satisfying types, so the set has
  ## to be complete before the type can be emitted — an object in another
  ## module adds a branch. Ordered by name so the emitted tag enum is stable
  ## between runs rather than depending on table iteration order.
  ##
  ## Takes the two fields directly rather than a ctx: the question is "which
  ## objects satisfy this contract", which has no target syntax in it.
  var seen = initHashSet[string]()
  for d in module.decls:
    if d != nil and d.kind == dkObject and iface in d.satisfies and
       d.name notin seen:
      seen.incl(d.name)
      result.add(d)
  for _, m in realModules:
    for d in m.decls:
      if d != nil and d.kind == dkObject and iface in d.satisfies and
         d.name notin seen:
        seen.incl(d.name)
        result.add(d)
  result.sort(proc (a, b: Decl): int = cmp(a.name, b.name))

# An actor's receive branch, gathered from BOTH `on <name>` blocks AND `on
# select` message arms (spec §9.3): a message kind + typed binding + body.
type ActorMsgHandler* = object
  name*: string
  params*: seq[Param]
  body*: Expr

proc collectHandlers*(d: Decl):
    tuple[handlers: seq[ActorMsgHandler], shutdownBody: Expr, hasShutdown: bool] =
  ## Split an actor's declarations into message handlers plus the reserved
  ## `shutdown` control arm (which stops the actor rather than adding a message).
  ##
  ## The two forms are the same thing to a backend: `on add({n: int}): ...` and
  ## an `| add -> {n: int}: ...` arm both declare a message named add with that
  ## binding. Walking only dkFn — which the Odin backend did at five separate
  ## sites — made every `on select` actor look like an actor with NO handlers.
  for h in d.handlers:
    if h.kind == dkFn:
      result.handlers.add(ActorMsgHandler(name: h.name, params: h.fnParams,
                                          body: h.fnBody))
    elif h.kind == dkSelect:
      for arm in h.selectArms:
        if arm.source == "shutdown":
          result.shutdownBody = arm.body
          result.hasShutdown = true
        else:
          result.handlers.add(ActorMsgHandler(name: arm.source,
                                              params: arm.binding, body: arm.body))

proc actorQueueSize*(d: Decl): string =
  ## The `[queue: N]` attribute, or the default mailbox size.
  result = "8"
  for attr in d.attrs:
    if attr.name == "queue": return attr.value

proc isDistinctAlias*(body: Type): bool =
  ## Does this alias declare a type the compiler must keep SEPARATE from its
  ## base? `distinct` says so outright; an overflow mode implies it, because
  ## the ATTRIBUTE is what changes behaviour (user ruling) and it is
  ## meaningless on a bare alias — an alias IS its base type and cannot carry
  ## different arithmetic.
  ##
  ## Shared because the two backends had already drifted: codegen.nim matched
  ## all four names, codegen_odin.nim only "distinct", so `u16 [saturating]`
  ## emitted `distinct uint16` on Nim and a plain `:: u16` alias on Odin —
  ## freely mixable with any other u16. Same question, one answer.
  if body == nil: return false
  for a in body.attrs:
    if a.name in ["distinct", "saturating", "wrapping", "trapping"]:
      return true
  false


proc payloadSumVariant*(m: Module, typeName, variantName: string): Option[VariantDef] =
  ## The named variant of a PAYLOAD-carrying sum type. None when there is no
  ## such type, it carries no payload anywhere, or it has no such variant —
  ## all three mean "not a variant construction", and the caller falls through
  ## to plain emission.
  ##
  ## Both backends' sumVariantCtor opened with this same scan-and-precondition
  ## before diverging on how a variant is spelled. VariantDef is a value
  ## object, so this is an Option rather than a nillable ref.
  for d in m.decls:
    if d != nil and d.kind == dkType and d.name == typeName and
       d.typeBody != nil and d.typeBody.kind == tkSum:
      if not sumHasPayload(d.typeBody): return none(VariantDef)
      for v in d.typeBody.variants:
        if v.name == variantName: return some(v)
  none(VariantDef)

proc allowedTransitions*(body: Type, fromVariant: string): seq[string] =
  ## Which variants `fromVariant` may transition to, per the declared table.
  ## Data only — Nim spells the result `to in {a, b}` and Odin
  ## `to == .a || to == .b`.
  if body == nil: return @[]
  for tr in body.transitions:
    if tr.`from` == fromVariant: result.add(tr.to)

proc resolveWrapNames*(m: Module, iface, objName: string): tuple[iface, obj: string] =
  ## Map an (interface, object) pair from the names the CHECKER recorded to the
  ## names being EMITTED. Mangling renames decls but the wrap was recorded
  ## before that, so both backends re-resolved through sourceName here — the
  ## only two places either backend reads sourceName, which is exactly how they
  ## would drift apart if mangling changed.
  result = (iface: iface, obj: objName)
  for d in m.decls:
    if d == nil: continue
    let src = if d.sourceName.isSome: d.sourceName.get else: d.name
    if d.kind == dkInterface and src == iface: result.iface = d.name
    if d.kind == dkObject and src == objName: result.obj = d.name


proc actorSingletonName*(actorType: string): string =
  ## An actor is a global singleton (spec §9): one instance per declared
  ## type, named <type>Singleton. genActor emits it; sends target it.
  if actorType.len == 0: return "actorSingleton"
  actorType[0].toLowerAscii() & actorType[1..^1] & "Singleton"

proc namesType(d: Decl, typeName: string): bool =
  ## Does this decl name that type? Matches either spelling: callers may hold
  ## the emitted name or the one the user wrote, and after mangling those
  ## differ.
  d != nil and d.kind == dkType and
    (d.name == typeName or d.writtenName == typeName)

proc declOf(module: Module, typeName: string): Decl =
  ## The type decl named `typeName` in this module, or nil if there isn't one.
  for d in module.decls:
    if namesType(d, typeName): return d
  nil

proc importOrigin(d: Decl): string =
  ## The module an IMPORTED type decl came from, or "" if it's not
  ## imported (declared locally, or `d` is nil).
  if d == nil or not d.span.file.startsWith(ImportedTypeMarker & ":"): return ""
  d.span.file[ImportedTypeMarker.len + 1 .. ^1]

proc originModuleOf(module: Module, moduleName, enumName: string): string =
  ## Which module "owns" this enum, for namespacing its error ids —
  ## the enum's origin module if imported, else the current module.
  let origin = importOrigin(declOf(module, enumName))
  if origin != "": origin else: moduleName

proc formatErrId(origin, enumName, variant: string): string =
  ## Error ids hash over "module/Enum.Variant" (spec: namespaced so two
  ## modules' same-named enum variants don't collide).
  origin & "/" & enumName & "." & variant

proc errNameFor*(module: Module, moduleName, enumName, variant: string): string =
  ## The namespaced error id for one variant of a (possibly imported) enum.
  formatErrId(originModuleOf(module, moduleName, enumName), enumName, variant)

proc lookupFnParams*(m: Module, name: string): seq[string] =
  ## Member fns (mixin buckets, manager types, externs) have concrete
  ## exploded params. Pending fns stay excluded: their stub takes one
  ## generic payload.
  m.findFn(name).paramNames()

proc hasKnownFields(t: Type): bool =
  ## Is `t` a type whose fields we could possibly look up? False for nil
  ## and for the sketch-mode "unknown" placeholder type.
  t != nil and not (t.kind == tkNamed and t.name == UnknownName)

proc fieldNames(fields: seq[FieldDef]): seq[string] =
  ## Just the names, in order, off a field list.
  for f in fields: result.add(f.name)

proc recordFieldNames*(res: Resolution, module: Module,
                       t: Type): seq[string] =
  ## Field names of a record type, in declaration order — the shared
  ## question behind bake's slot rebuild and postfix field explosion in
  ## both backends.
  if not hasKnownFields(t): return @[]
  fieldNames(getFieldsForType(res, module, t))

const NimShadowingModuleNames* = [
  "seq", "string", "int", "float", "bool", "byte", "char", "set", "array",
  "range", "ref", "ptr", "cstring", "openArray", "varargs", "pointer",
]
  ## Tuck module names that would shadow a Nim TYPE if imported under their
  ## own name. `import seq` binds the module symbol to `seq`, and the next
  ## `seq[tuck_Entry[K, V]]` in that file is "cannot instantiate the 'seq'
  ## module". Only these are aliased: Nim merges module scopes, so an
  ## unnecessary alias would break every `module::fn` call site, which is
  ## exactly what a blanket aliasing pass did.

proc nimModuleName*(name: string): string =
  ## What an imported Tuck module is CALLED in the emitted Nim — its own name,
  ## unless that name would shadow a builtin type. The import and every
  ## qualified use go through this one proc so they cannot disagree.
  if name in NimShadowingModuleNames: "tuck_mod_" & name else: name

const RtIntrinsicNames* = [
  "tuckAt", "tuckSetAt", "tuckConcat", "tuckSat", "tuckSatI",
  "tuckSeqBounds", "tuckSeqCopy", "tuckSpawn", "tuckSetArgs",
]
  ## Runtime helpers the compiler INTRODUCES — a `xs[i]` lowers to `tuckAt`,
  ## a `[saturating]` construction to `tuckSat`. They carry the reserved
  ## `tuck` prefix so a user fn cannot collide with them... which is true of
  ## every backend except the one that matters most.
  ##
  ## Nim identifiers ignore underscores and case after the first character,
  ## so the user fn `at` — emitted `tuck_at` — IS `tuckAt` to Nim. A stdlib
  ## module defining `fn at` silently rebound every `xs[i]` in the program to
  ## itself, and the failure surfaced as a type error about double-wrapping
  ## somewhere else entirely. Qualifying the runtime side closes the whole
  ## class rather than renaming one helper out of the way.

proc nimRtCallee*(name: string): string =
  ## A runtime intrinsic, spelled so Nim cannot fold a user fn into it.
  if name in RtIntrinsicNames: "tuck_rt." & name else: name

proc isResultCarrierType*(t: Type): bool =
  ## Is this type ALREADY a `!T`/`?T`/`!?T` — the carrier itself, rather than
  ## a payload that needs wrapping into one?
  ##
  ## Every backend's wrapped-return emitter needs it: `return {..} at` inside
  ## a fn that itself returns `?T` is a PASS-THROUGH, not a value to wrap.
  ## Wrapping built TuckResult[TuckResult[T]], which typechecks clean here and
  ## fails in the host compile. The Nim backend learned this when `!void`
  ## pass-through bit it; Odin and D never got the twin, and alloc.vec's
  ## `first`/`last` — one-liners delegating to `at` — found both.
  t != nil and t.kind == tkApp and t.base != nil and
    t.base.kind == tkNamed and t.base.name in ["!", "?", "!?"]

proc plainVarAssign(e: Expr): bool =
  ## `x = <value>` where x is a bare name and this is not its declaration.
  e != nil and e.kind == exkAssign and not e.isDecl and
    e.target != nil and e.target.kind == exkVar

proc isRtPushCall(call: Expr): bool =
  ## A runtime `push` with its payload still a struct literal. Matched on the
  ## UNMANGLED name: mangling runs before codegen, so a user's own `fn push`
  ## is `tuck_push` here and only the runtime's is `push`.
  call != nil and call.kind == exkCall and call.args.len == 1 and
    call.callee != nil and call.callee.kind == exkVar and
    call.callee.name == "push" and
    call.args[0] != nil and call.args[0].kind == exkStruct

proc pushCallOf(res: Resolution, e: Expr): Expr =
  ## The runtime `push` call this plain assignment's value is, or nil.
  if not plainVarAssign(e): return nil
  var call = e.assignVal
  if call != nil and res.hasCall(call): call = res.call(call)
  if not isRtPushCall(call): return nil
  call

proc selfAppendValue*(res: Resolution, e: Expr): Expr =
  ## `xs = {items: xs, value: v} push` — an append whose result is assigned
  ## back to its own argument. Returns `v`, or nil when the statement is not
  ## that shape.
  ##
  ## WHY THIS IS A SPECIAL CASE AND NOT AN OPTIMISATION PASS. The runtime's
  ## `push` returns a NEW seq, because value semantics forbid writing through
  ## a parameter — so every append copies the whole sequence and a build loop
  ## is O(n^2). Measured: 50k/100k appends took 1.29s/5.24s in release, a
  ## ratio of 4.06 on a doubled input.
  ##
  ## But `xs = push(xs, v)` is provably a MOVE: the old value of `xs` is dead
  ## the instant the new one is assigned, so nothing can observe the
  ## difference between copying it and appending in place. Every backend's
  ## host already has an amortised append (`add` / `append` / `~=`), so this
  ## needs no new runtime — only for the emitters to recognise the shape.
  ##
  let call = pushCallOf(res, e)
  if call == nil: return nil
  # The payload is still a STRUCT at this point — the positional explosion
  # happens in the emitters — so the two arguments are read by the names
  # std/seq declares them with.
  var items, value: Expr
  for f in call.args[0].fields:
    if f.name == "items": items = f.value
    elif f.name == "value": value = f.value
  if items == nil or value == nil: return nil
  if items.kind != exkVar or items.name != e.target.name: return nil
  value
