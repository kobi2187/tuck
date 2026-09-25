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
import ast, lowering, ast_query, ast_ops, strutils, sets, tables, algorithm, options
import ./ast_query
import twin_shape
export twin_shape

const TagField* = "tuckTag"
  ## The discriminator an actor's message envelope and a registry's event type
  ## carry. NOT `kind`: those two are the only generated types that flatten
  ## user payload fields in beside a field of codegen's own, so a handler
  ## taking `{kind: NalKind}` — the ordinary name for tagged data — emitted
  ## `kind` twice and every backend refused it while `tuck ch` said OK.
  ##
  ## Moving Tuck's own name is the fix rather than reserving the user's:
  ## nothing in Tuck source ever reads this field, so it is internal, and the
  ## author keeps the name they wrote. A sum type is unaffected and keeps
  ## `kind` — its payloads are namespaced per variant, so they never sit
  ## beside the tag.
  ##
  ## `tuckTag` is not collision-PROOF (an author may still write a field of
  ## that name), so `failIfHostKeyword` refuses it at the declaration, the
  ## same way it refuses a host keyword.

proc assignInvariantOwner*(res: Resolution, e: Expr): string =
  ## The TYPE NAME whose invariants an assignment must re-check, or "" when
  ## there are none to check. Shared by the three backends so a mutation site
  ## cannot validate on one and stay silent on another — which is exactly how
  ## the assignment form came to differ from the `..` chain form.
  ##
  ## Only a FIELD assignment mutates a value someone else can still see;
  ## rebinding a whole var (`t = ...`) is a construction and validates where
  ## it is built.
  if e == nil or e.target == nil or e.target.kind != exkField: return ""
  if e.target.receiver == nil: return ""
  # A `..` chain's step: the chain validates once, when it ends (exkValidate).
  if e.inChain: return ""
  let t = res.typeFor(e.target.receiver)
  if t == nil or t.kind != tkNamed: return ""
  t.name

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

proc isActorTemplate*(d: Decl): bool =
  ## An exported generic actor — `public: Box[T]`. It survives generic_actors
  ## (an importer must be able to instantiate it) and the checker exempts it
  ## from TK-TY28 for the same reason, so it is the ONE actor that reaches
  ## codegen still carrying a type parameter.
  ##
  ## It must not be emitted. A template is not a declaration: its fields name a
  ## parameter, so emitting one produces `last*: T` with T declared nowhere —
  ## the exact bug #18 was about, arriving by the export path instead. The
  ## importer's own expansion emits the concrete actors.
  d != nil and d.kind == dkActor and d.actorGenerics.len > 0

proc actorHasMessages*(d: Decl): bool =
  ## Whether this actor has anything to receive. A specimen actor
  ## (`actor X: ...`) has no handlers and no shutdown, so it gets no envelope
  ## type, no mailbox and no drain — and the entry point must not try to start
  ## one.
  ##
  ## Here rather than in one backend because ALL FOUR sites must ask the same
  ## question: the three entry-point builders (tuck.nim's Nim prologue,
  ## runtimeUsers for Odin, genDDaemons for D) and the three genActor bodies.
  ## Only D asked it; Nim and Odin re-derived "every dkActor" and so emitted a
  ## call to a registerActor/drain proc their own genActor had declined to
  ## define (issue #61).
  if isActorTemplate(d): return false   # nothing to start: it is not emitted
  let (handlers, _, hasShutdown) = collectHandlers(d)
  handlers.len > 0 or hasShutdown

proc actorQueueSize*(m: Module, d: Decl): string =
  ## The `[queue: N]` attribute, or the default mailbox size.
  ##
  ## Emits the NUMBER, not the source text. `[queue: Fan]` used to emit the
  ## bare name `Fan` while the const itself emitted as `tuck_Fan`, so every
  ## backend failed with "undeclared identifier" — and a name here would raise
  ## a mangling question that a resolved integer simply does not have. The
  ## checker has already refused anything constIntOf cannot answer
  ## (typecheck.checkActorQueue), so the fallback is unreachable for a checked
  ## program.
  result = "8"
  for attr in d.attrs:
    if attr.name != "queue": continue
    let n = constIntOf(m, attr.value)
    return if n.isSome: $n.get else: attr.value

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


proc hasRunningActors*(m: Module): bool =
  ## Does this module declare an actor that actually runs? The same question
  ## the three entry builders ask before emitting the boot and the exit drain,
  ## asked once — a hand-rolled loop in each is how #61 happened.
  for d in m.decls:
    if d != nil and d.kind == dkActor and actorHasMessages(d): return true
  false

proc actorSlotName*(actorType: string): string =
  ## The runtime handle for an actor's thread, named <type>Slot. `Actor.waitUntil`
  ## names the actor at the call site and the emitted call hands the predicate
  ## to THIS, so the handle has to be reachable by name from anywhere the actor
  ## is visible — same reason, and same shape, as the singleton below.
  if actorType.len == 0: return "actorSlot"
  actorType[0].toLowerAscii() & actorType[1..^1] & "Slot"

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
  t != nil

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


proc mentionsName(e: Expr, name: string): bool =
  if e == nil: return false
  if e.kind == exkVar and e.name == name: return true
  for c in e.children:
    if mentionsName(c, name): return true
  false

proc selfConcatValue*(res: Resolution, e: Expr): Expr =
  ## `s = s + <expr>` on a `str` — a concatenation assigned back over its own
  ## LEFT operand. Returns `<expr>`, or nil when the statement is not that
  ## shape.
  ##
  ## The twin of selfAppendValue above, and the same argument: the old `s` is
  ## dead the instant the new one lands, so growing it in place is
  ## unobservable. Syntactic, so there is no liveness to get wrong.
  ##
  ## IT IS WORTH MORE THAN IT LOOKS. `s = s + t` in a loop is O(n^2) on every
  ## backend, because each concatenation copies the whole string — measured at
  ## 100k/200k/400k iterations, Nim took 117/461/1859 ms, a clean 4x per
  ## doubling. Emitting the host's amortised append instead took the 200k case
  ## from 460 ms to 2 ms and turned the loop linear.
  ##
  ## LEFT OPERAND ONLY, and the right must not name the target:
  ##   `s = t + s`  is a PREPEND, and appending would silently reverse it
  ##   `s = s + s`  would grow a string while reading it
  if not plainVarAssign(e): return nil
  let v = e.assignVal
  if v == nil or v.kind != exkBinary or not isStringConcat(v): return nil
  if v.left == nil or v.left.kind != exkVar or v.left.name != e.target.name:
    return nil
  if mentionsName(v.right, e.target.name): return nil
  v.right

proc hasLastUse(res: Resolution, e: Expr, name: string): bool =
  if e == nil: return false
  if e.kind == exkVar and e.name == name and res.isLastUse(e): return true
  for c in e.children:
    if hasLastUse(res, c, name): return true
  false

proc ownsHeap(m: Module, t: Type, depth = 0): bool

proc anyOwnsHeap(m: Module, ts: seq[Type], depth: int): bool =
  for t in ts:
    if ownsHeap(m, t, depth): return true
  false

proc fieldsOwnHeap(m: Module, fields: seq[FieldDef], depth: int): bool =
  var ts: seq[Type]
  for f in fields: ts.add(f.typ)
  anyOwnsHeap(m, ts, depth)

proc namedOwnsHeap(m: Module, name: string, depth: int): bool =
  if name == "str": return true
  for d in m.decls:
    if d != nil and d.kind == dkType and d.name == name:
      return ownsHeap(m, d.typeBody, depth)
  false

proc sumOwnsHeap(m: Module, t: Type, depth: int): bool =
  for v in t.variants:
    if fieldsOwnHeap(m, v.fields, depth): return true
  false

proc ownsHeap(m: Module, t: Type, depth = 0): bool =
  ## Does a value of this type own storage that copying would duplicate?
  ##
  ## Only these are worth moving. A record of two ints copies in a register
  ## pair, so marking it movable buys nothing and only adds noise to the
  ## emitted output — every golden in the corpus moved for it before this
  ## guard went in.
  if t == nil or depth > 4: return false
  case t.kind
  of tkNamed: namedOwnsHeap(m, t.name, depth + 1)
  of tkApp:
    # Seq[T] owns a buffer outright; a `!T`/`?T` carrier, or an Array, owns
    # whatever its arguments do. A GENERIC USER TYPE — `Box[T]`, `Set[T]`,
    # `Table[K, V]` — owns whatever its DECLARED BODY does: without this the
    # whole alloc tier read as owning nothing, and the container-threading
    # benchmark was linear on Odin and D (which look through the twin's own
    # predicate) and quadratic on Nim, which consults this one.
    if t.base != nil and t.base.kind == tkNamed and t.base.name == "Seq": true
    elif ownsHeap(m, genericBaseBody(m, t), depth + 1): true
    else: anyOwnsHeap(m, t.args, depth + 1)
  of tkRecord: fieldsOwnHeap(m, t.fields, depth + 1)
  of tkSum: sumOwnsHeap(m, t, depth + 1)
  else: false

proc paramIsMovable*(res: Resolution, m: Module, body: Expr, p: Param): bool =
  ## May this parameter be taken destructively? True when the analysis proved
  ## the body's final read of it — so the caller's copy is unobservable from
  ## that point — AND the type owns storage worth not copying.
  ##
  ## A parameter the body never reads has no stamped use and stays as it was,
  ## which is the safe answer for anything the analysis did not reach.
  if not ownsHeap(m, p.typ): return false
  hasLastUse(res, body, p.name)

# --- the MOVED twin ---------------------------------------------------------
#
# A fn that threads a container through — `f(c, ...) -> c`, which is the shape
# value semantics forces on every container verb — is emitted twice on the
# backends that have no move analysis of their own: the real body as `f_moved`,
# free to read its container param without a defensive copy, and a one-line `f`
# that copies and delegates.
#
# Soundness is SYNTACTIC, not analytical. `x = f(x, ...)` overwrites its own
# argument, so the old value is dead the instant the new one lands and value
# semantics guarantees nothing else was looking at it. No liveness to get
# wrong, and an unrecognised call site merely misses the speedup.
#
# Both copies have to go together or neither pays: measured on a 50k loop in D,
# dropping the caller's alone gave 1.26s -> 0.69s and dropping the callee's
# alone 0.76s — both still quadratic. Dropping both gave 0.00s.

proc ownsHeapType*(m: Module, t: Type): bool = ownsHeap(m, t)


proc rootBindingName*(e: Expr): string =
  ## The name a field path is rooted at: `b` for `b`, `b.items`, `b.a.b`.
  ## "" when the path is not rooted at a plain name.
  var cur = e
  while cur != nil and cur.kind == exkField and cur.receiver != nil:
    cur = cur.receiver
  if cur != nil and cur.kind == exkVar: cur.name else: ""

proc otherArgLives(res: Resolution, m: Module, call: Expr): bool =
  ## Does any argument BESIDES the first still hold a container the caller
  ## will read again? Then the callee's result may BE that container, and
  ## the copy that separates them cannot be dropped.
  for i in 1 ..< call.args.len:
    let a = call.args[i]
    if a == nil: continue
    if not ownsHeap(m, res.typeFor(a)): continue
    if res.isLastUse(a): continue   # dead too, so nothing observes the share
    return true
  false

proc movedCallInto*(res: Resolution, m: Module, call: Expr,
                    targetName: string): bool =
  ## Is `call` a threaded-container call whose FIRST argument is the very
  ## variable its result is being written back into? Then the old value is
  ## dead and the MOVED twin may have it.
  ##
  ## Shared by the two spellings that reach it: a plain `x = f(x, ...)`, and
  ## the BUILDER chain `x ..f {...}`, which the chain emitter writes as an
  ## assignment of its own rather than routing through genAssign. The chain
  ## form is the one TUCK-TRANSLATION.md recommends, and it was the shape
  ## still measuring quadratic on Odin (3.5x) and D (3.3x) when only the
  ## plain form was recognised.
  if call == nil or call.kind != exkCall: return false
  if call.callee == nil or call.callee.kind != exkVar: return false
  if movedFnParam(res, m, m.findFn(call.callee.name)) == "": return false
  # A resolved user call is already exploded positionally by the time it
  # reaches here (a payload call like std/seq's `push` is not, and is handled
  # by selfAppendValue).
  if call.args.len < 1 or call.args[0] == nil: return false
  let a = call.args[0]
  # THE SYNTACTIC CASE: `x = f(x, ...)` overwrites its own argument, so the
  # old value is dead the instant the new one lands. No liveness involved.
  if a.kind == exkVar and a.name == targetName: return true
  # THE ANALYSED CASE, for everything else: a value this body OWNS and will
  # not read again. Both halves are needed and `analysis_provenance` joins
  # them into one stamp — being a last use says nobody HERE reads it again,
  # which on D and Odin says nothing about the caller whose buffer a
  # container parameter aliases. See `markMovableArgs`.
  #
  # It covers two shapes. `sweep(b.ask, ...)` needs liveness at PATH
  # granularity, because `b` being live is not the question when `b.bestAsk`
  # is read two lines later. And `pass(a, ...)` — a plain local, dead after
  # the call — is the shape a CHAIN of threading calls takes, which is the
  # whole of EV-15.
  #
  # ...AND NO OTHER ARGUMENT MAY STILL BE LIVE, which is what this predicate
  # answers over and above `movedCalleeName`. Reaching the twin is one
  # decision; SKIPPING THE RESULT'S FIX-UP COPY, which the emitters do on
  # this path, is a second one, and it rests on the result being unable to
  # alias anything the caller still reads. That holds when the result can
  # only be the moved argument or a fresh allocation. It does not hold here:
  #
  #     fn pick({p: Seq[int], q: Seq[int], which: int}) -> Seq[int]:
  #       if which == 0: return p
  #       return q
  #
  # `pick` is twinnable on `p` and returns `q`. Moving `src` in is fine and
  # still worth doing; dropping the copy of the RESULT is not, because the
  # result is `other`'s buffer and `other` is read on the next line. It came
  # back 65 instead of 17 on D and Odin alike, caught by value_semantics'
  # "a record returned from a call does not alias its argument".
  if a.kind in {exkVar, exkField}:
    return res.isMovedArg(a) and not otherArgLives(res, m, call)
  false

proc movedCalleeName*(res: Resolution, m: Module, e: Expr,
                      calleeStr, member: string): string =
  ## `f_moved` when this call may take its first argument destructively at
  ## ANY position, or "".
  ##
  ## `movedCallInto` answers the same question for the two positions that
  ## have a write target — `x = f(x, ...)` and the builder chain — and it is
  ## reached from the assignment emitters. Nothing reached the others, and
  ## the one that matters is RETURN:
  ##
  ##     return {sl: up, c: c, cols: cols} relight
  ##
  ## `up` is dead there and owned, and `analysis_provenance` stamps it, but
  ## no assignment emitter ever sees the call so nothing asked. That left
  ## `relight`'s wrapper copying three arrays per edit and abandoning them.
  ## `member` is the resolved member-fn name when this is a member call, and
  ## excludes it: no twin is emitted for a member, and `findFn` would answer
  ## with a top-level fn that merely shares the name. Taken as an argument
  ## rather than tested at each call site, so neither emitter gains a branch.
  if member.len > 0: return ""
  if e == nil or e.kind != exkCall: return ""
  if e.callee == nil or e.callee.kind != exkVar: return ""
  if movedFnParam(res, m, m.findFn(e.callee.name)) == "": return ""
  if e.args.len < 1 or e.args[0] == nil: return ""
  if not res.isMovedArg(e.args[0]): return ""
  movedName(calleeStr)

proc selfThreadedCall*(res: Resolution, m: Module, e: Expr): Expr =
  ## `x = f(x, ...)` on a threaded-container fn, or `let y = f(b.ask, ...)`
  ## where `b.ask` is never read again. Returns the CALL, or nil.
  ##
  ## DECLARATIONS ARE ACCEPTED, which they were not before. The syntactic
  ## rule could not match one anyway — a decl's target is a fresh name, so it
  ## is never its own argument — so excluding them cost nothing until the
  ## field case arrived. It costs a great deal now: `let f = sweep(b.ask,
  ## ...)` is exactly the shape the matching engine threads its ladders
  ## through, and refusing it left `sweep` copying a container its caller was
  ## finished with.
  if e == nil or e.kind != exkAssign or e.target == nil or
     e.target.kind != exkVar: return nil
  var call = e.assignVal
  if call != nil and res.hasCall(call): call = res.call(call)
  if call == nil or call.kind != exkCall: return nil
  if call.callee == nil or call.callee.kind != exkVar: return nil
  if movedCallInto(res, m, call, e.target.name): return call
  nil



proc isExportedDecl*(m: Module, d: Decl): bool =
  ## Does this declaration leave its module (spec 2.3c)?
  ##
  ## A module with NO `public:` block exports everything, which is what every
  ## module written before the block existed relies on — and what keeps every
  ## emitted golden unchanged. A module WITH one exports the listed names and
  ## nothing else.
  ##
  ## The list holds what the AUTHOR WROTE, so the comparison is against
  ## writtenName, never the mangled identifier the backends emit.
  if d == nil: return true
  let (restricted, allowed) = exportedNames(m)
  (not restricted) or writtenName(d) in allowed
