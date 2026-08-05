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
import ast, lowering, ast_query, strutils, sets, tables, algorithm, options

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

proc sumHasPayload*(body: Type): bool =
  ## Does any variant of this sum carry fields? The branch key for four
  ## emitters: a fieldless sum is a plain enum in both targets, a
  ## payload-carrying one needs a tagged representation.
  if body == nil: return false
  for v in body.variants:
    if v.fields.len > 0: return true
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

proc isCompositionEntry*(member: Decl): bool =
  ## `+ Name` inside an object body — the entry that pulls another
  ## declaration's members or data into this one.
  member.kind == dkExpr and member.expr != nil and
    member.expr.kind == exkUnary and member.expr.unaryOp == uoComposition and
    member.expr.operand != nil and member.expr.operand.kind == exkVar

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

proc recordFieldNames*(module: Module, t: Type): seq[string] =
  ## Field names of a record type, in declaration order — the shared
  ## question behind bake's slot rebuild and postfix field explosion in
  ## both backends.
  if not hasKnownFields(t): return @[]
  fieldNames(getFieldsForType(module, t))
