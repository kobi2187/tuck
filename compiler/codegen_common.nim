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
import ast, lowering, ast_query, ast_ops, strutils, sets, tables, options, algorithm
import ./ast_query
import twin_shape
import call_args
export call_args
import name_prefix
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

proc sumPayloadType*(sumName, variantName: string): string =
  ## The object type a payload-carrying variant's fields live in (Nim).
  sumName & "_" & variantName

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
  ## Spelled as a `variant` name (name_prefix.nim), for the reason every other
  ## generated name is: it must not be able to collide with anything in the
  ## target language. Shared by the declaration site and every read site in
  ## both backends that carry one — Odin has no such field, it binds the
  ## union member directly.
  prefixed(variantName.toLowerAscii(), nkVariant)

proc invariantCondLit*(cond: string): string =
  ## A violated invariant's condition, as the string literal every backend's
  ## `tuckInvariantFailed` reports it by: `"` shown as `'` (the message
  ## quotes nothing), anything else escaped for the host.
  "\"" & escapeStringLit(cond.replace("\"", "'")) & "\""

proc poolOpProc*(op: PoolOpKind): string =
  ## The runtime proc a pool operation calls — one name in all three
  ## runtimes, taking the pool first and then the op's args in order. Each
  ## backend prints the call in its own syntax (Odin passes the pool by
  ## pointer, D by `ref`); which proc is not theirs to decide.
  case op
  of poAcquire: "tuckPoolAcquire"
  of poRelease: "tuckPoolRelease"
  of poRead: "tuckPoolRead"
  of poWrite: "tuckPoolWrite"
  of poAddr: "tuckPoolAddr"

proc slabCellValue*(slab, r: string, rt = ""): string =
  ## The value in the cell `r` names, through the runtime's checked
  ## `tuckSlabCell` — a read and a write alike (lowering_slab, `get`, `set`).
  rt & "tuckSlabCell(" & slab & ", " & r & ").value"

proc slabOpCall*(op: SlabOpKind, slab, arg, value: string, rt = "",
                 newProc = "tuckSlabNew"): string =
  ## A slab operation on the runtime's `tuckSlab*` procs, one family in all
  ## three runtimes. `slab` is the storage as the backend passes it (`Nodes`,
  ## `&Nodes`), `rt` the runtime's qualifier, `newProc` the proc that fills
  ## a cell (Odin's fixed slab has its own: its `new` may find no room).
  case op
  of soNew: rt & newProc & "(" & slab & ", " & value & ")"
  of soFree: rt & "tuckSlabFree(" & slab & ", " & arg & ")"
  of soLive: rt & "tuckSlabLive(" & slab & ", " & arg & ")"
  of soReset: rt & "tuckSlabReset(" & slab & ")"
  of soCount: rt & "tuckSlabCount(" & slab & ")"
  of soGet: slabCellValue(slab, arg, rt)
  of soSet: slabCellValue(slab, arg, rt) & " = " & value

const SlabsReleaseProc* = "tuckSlabsRelease"
  ## Odin: each module's proc that hands its slabs back at exit under
  ## TUCK_TRACK (codegen_odin_decl.genOdinSlabsRelease).

const UnhandledHandlerName* = "tuck_unhandled"
  ## The generated proc every dropped fallible result reports through (spec
  ## 4.9), and the one each backend declares. A compiler-made name, so it
  ## lives outside the `tuckˑ` space user names are mangled into and cannot
  ## meet one. Nim and Odin spelled it as a literal while D mangled
  ## "unhandled" to reach the same text; one constant now.

proc absentCapable*(t: Type): bool =
  ## Does this fn's declared return type admit `tsAbsent` — `?T` or `!?T`? A
  ## plain `!T` has no absence, only Ok/Err, so a bare `return` there means
  ## success with a zero value, not "nothing to report".
  t != nil and t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
    t.base.name in ["?", "!?"] and t.args.len == 1

proc collectHandlers*(d: Decl): seq[ActorMsgHandler] =
  ## An actor's message handlers, from both spellings.
  ##
  ## The two forms are the same thing to a backend: `on add({n: int}): ...` and
  ## an `| add -> {n: int}: ...` arm both declare a message named add with that
  ## binding. Walking only dkFn — which the Odin backend did at five separate
  ## sites — made every `on select` actor look like an actor with NO handlers.
  for h in d.handlers:
    if h.kind == dkFn and h.isOnHandler:
      result.add(ActorMsgHandler(name: h.name, params: h.fnParams,
                                 body: h.fnBody))
    elif h.kind == dkSelect:
      for arm in h.selectArms:
        result.add(ActorMsgHandler(name: arm.source, params: arm.binding,
                                   body: arm.body))

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
  ## (`actor X: ...`) has no handlers, so it gets no envelope
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
  collectHandlers(d).len > 0

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

type
  OnFull* = enum
    ## What the send that finds an actor's mailbox full does (R6, ruled
    ## 2026-09-28): the program picks, per actor, `[on_full: ...]`.
    ofWait = "wait"       ## wait for room — the default
    ofDrop = "drop"       ## lose the message, as every send once did
    ofAssert = "assert"   ## stop the program, naming the actor

proc actorOnFull*(d: Decl): OnFull =
  ## The actor's `[on_full: ...]`, or `wait` when it names none. The checker
  ## has refused any other word (TK-AC06), so the fallback is reached only
  ## for an unchecked tree.
  result = ofWait
  if d == nil: return
  for attr in d.attrs:
    if attr.name != "on_full": continue
    for p in OnFull:
      if $p == attr.value: return p

proc actorLabel*(d: Decl, fallback: string): string =
  ## The actor's name as its author wrote it, for a runtime message.
  if d == nil: fallback else: writtenName(d)

proc slabLabel*(d: Decl): string =
  ## A slab's name in the runtime's messages: as written, or for an arena's
  ## slab, the arena's (`TUCK SLAB [Frame]: stale reference ...`).
  if d.slabArena != "": d.slabArena else: actorLabel(d, d.name)

proc arenaOfSlab*(m: Module, real: Table[string, Module], slab: Decl): Decl =
  ## The arena `slab` is the slab of for one element type, or nil.
  if slab == nil or slab.slabArena == "": return nil
  for d in m.decls(dkArena):
    if writtenName(d) == slab.slabArena: return d
  for _, other in real:
    for d in other.decls(dkArena):
      if writtenName(d) == slab.slabArena: return d
  nil

proc slabsOfArena*(m: Module, arena: Decl): seq[Decl] =
  ## An arena's slabs, one per element type its `new`s name — the checker
  ## made them and the driver put them in the arena's module.
  for d in m.decls(dkSlab):
    if d.slabArena == writtenName(arena): result.add d

proc arenaResetProc*(arena: string): string =
  ## Each arena's generated reset: every slab of it, and its budget.
  arena & "_reset"

proc actorDeclNamed*(m: Module, real: Table[string, Module], name: string): Decl =
  ## The actor a send names, declared in this module or one it imports.
  for d in m.decls:
    if d != nil and d.kind == dkActor and (d.name == name or writtenName(d) == name):
      return d
  for other in real.values:
    if other == m: continue
    for d in other.decls:
      if d != nil and d.kind == dkActor and (d.name == name or writtenName(d) == name):
        return d

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


proc runsActor*(d: Decl): bool =
  ## Is `d` an actor DECLARED here that has a drain to start? An importer's
  ## copy of an imported actor (A32) is not: its origin starts it.
  d != nil and d.kind == dkActor and not isImportedCopy(d) and actorHasMessages(d)

proc hasRunningActors*(m: Module): bool =
  ## Does this module declare an actor that actually runs? The same question
  ## the three entry builders ask before emitting the boot and the exit drain,
  ## asked once — a hand-rolled loop in each is how #61 happened.
  for d in m.decls:
    if runsActor(d): return true
  false

const ActorsBootProc* = "tuckActorsBoot"
  ## What an imported module's package exports for the entry point to call: it
  ## sets the module's actors' starting fields and starts their drains, which
  ## the entry cannot do itself — the drain and the slot live in that package
  ## (A18, A32). The slab release (`SlabsReleaseProc`) is the same shape.

proc actorBootModules*(m: Module, real: Table[string, Module]): seq[string] =
  ## The other modules of the program that declare a running actor, sorted.
  for modName, other in real:
    if other != m and hasRunningActors(other): result.add modName
  result.sort()

proc programRunsActors*(m: Module, real: Table[string, Module]): bool =
  ## Does any module of the program, this one included, run an actor?
  hasRunningActors(m) or actorBootModules(m, real).len > 0

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

# The built-in members every actor answers, as the checker registered them
# (`collectSigs` / `collectHeartbeatSigs`) -> the runtime proc each backend
# prints. One table, so the three backends cannot disagree about which member
# calls reach the actor's slot.
const ActorMembers* = {
  "waitUntil": "tuckWaitOn",
  "pingUs": "tuckPingUs",
  "alive": "tuckAlive"}.toTable

proc actorMemberRt*(e: Expr): string =
  ## `Actor.waitUntil {pred: :p}`, `Actor.pingUs {withinMs: n}`, as the
  ## checker rewrote them: `member(<actorRef>, arg)`. The runtime proc that
  ## takes the actor's slot, or "" when `e` is not such a call. Every backend
  ## prints it as `rt(<Actor>Slot, arg)`.
  if e == nil or e.kind != exkCall or e.callee == nil or
     e.callee.kind != exkVar or e.args.len != 2 or e.args[0] == nil or
     e.args[0].kind != exkActorRef: return ""
  ActorMembers.getOrDefault(e.callee.name)

proc msgVariantName*(handlerName: string): string =
  ## The message-enum tag a handler receives on — `msgAdd` for `on add`. The
  ## envelope and the send helpers must agree on it, on every backend.
  "msg" & handlerName.capitalize()

proc mainDecl*(m: Module): Decl =
  ## The module's `fn main`, mangled (`tuck_fn_main`), or nil. A pending one
  ## does not count: there is no body to run.
  let tuckMain = prefixed("main", nkFn)
  for d in m.decls:
    if d != nil and d.kind == dkFn and d.name == tuckMain and not d.isPending:
      return d
  nil

template freshName*(ctx: untyped, tag: string): string =
  ## A fresh emitted name: `tag` and the ctx's next temp number. Every
  ## backend's ctx has a `tmpCounter`; the bump-then-glue pair was written out
  ## at each site that needed a temp.
  (inc ctx.tmpCounter; tag & $ctx.tmpCounter)

proc isInputRef*(e: Expr, params: seq[FieldDef]): bool =
  ## A bare `input` inside a body that has params: the whole incoming
  ## payload, which each backend rebuilds from the params.
  e != nil and e.kind == exkVar and e.name == "input" and params.len > 0

proc isInputField*(e: Expr, params: seq[FieldDef]): bool =
  ## `input.x` — which IS the param `x`.
  e.kind == exkField and isInputRef(e.receiver, params)

proc hasBracketBase*(e: Expr): bool =
  ## Is this a place rooted at an index (`xs[i]`, `xs[i].f.g`)?
  if e == nil: return false
  case e.kind
  of exkBracket: true
  of exkField: hasBracketBase(e.receiver)
  else: false

proc isLenOnSized*(res: Resolution, e: Expr): bool =
  ## `.len` on a value whose length is the target's own (a string, a Seq, a
  ## fixed array) — every backend prints it as its length builtin, not a
  ## field read.
  if e.fieldName != "len" or e.receiver == nil: return false
  let rt = res.typeFor(e.receiver)
  if rt == nil: return false
  if rt.kind == tkNamed and rt.name in ["str", "string"]: return true
  seqElem(rt) != nil or isFixedArray(rt)

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

proc recordArgFields*(res: Resolution, m: Module,
                      real: Table[string, Module], e: Expr): Option[seq[string]] =
  ## A call whose one argument is a VARIABLE standing for its payload (`p fn`
  ## with `p: {a, b}`): the field of it that feeds each param, in param order
  ## (`call_args.fieldFor`). Printed `f(p.a, p.b)`.
  ##
  ## NONE when the call is not that shape, and it is then printed as it
  ## stands: a member call (its one argument is the RECEIVER), a callee
  ## nothing resolved, or a param the record has no field for — the variable
  ## IS that argument.
  ##
  ## `some(@[])` is a callee that takes nothing: `g()`, whatever the variable
  ## holds. All three backends printed `g(p)` while "takes none" and "not
  ## resolved" were one empty list.
  if e.args.len != 1 or e.args[0].kind != exkVar or
     memberCallee(res, m, e) != "":
    return none(seq[string])
  let known = knownParams(res, m, real, e)
  if known.isNone: return none(seq[string])
  if known.get.len == 0: return some(newSeq[string]())
  let fields = recordFieldNames(res, m, res.typeFor(e.args[0]))
  if fields.len == 0: return none(seq[string])
  var picked: seq[string]
  for i, param in known.get:
    let f = fieldFor(res, e, i, param)
    if f notin fields: return none(seq[string])
    picked.add f
  some(picked)

proc nimModuleName*(name: string): string =
  ## What an imported Tuck module is CALLED in the emitted Nim — its own name,
  ## unless that name would shadow a builtin type. The import and every
  ## qualified use go through this one proc so they cannot disagree.
  if name in NimShadowingModuleNames: "tuck_mod_" & name else: name

const RtIntrinsicNames* = [
  "tuckAt", "tuckSetAt", "tuckArrayAt", "tuckArraySetAt", "tuckConcat",
  "tuckSat", "tuckSatI", "tuckArith", "tuckOverflowTrap",
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

proc hasLastUse(res: Resolution, e: Expr, name: string): bool =
  ## Does the liveness pass mark some read of `name` inside `e` as its final
  ## use? That stamp is what licenses moving from a parameter.
  if e == nil: return false
  if e.kind == exkVar and e.name == name and res.isLastUse(e): return true
  for c in e.children:
    if hasLastUse(res, c, name): return true
  false

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

proc registryHandlers*(m: Module, d: Decl, v: VariantDef): seq[Decl] =
  ## Every `on Registry.Event` handler for this event, matched on the names
  ## the user WROTE. Matching the mangled ones (`d.name & "." & v.name`) only
  ## worked while a registry and a fn took the same prefix; since #78 the
  ## handler is `tuck_fn_AppEvents.X` beside the registry's `tuck_AppEvents`,
  ## and every raise silently stopped calling its handler.
  let want = writtenName(d) & "." & v.name
  for decl in m.decls:
    if decl != nil and decl.kind == dkFn and writtenName(decl) == want:
      result.add decl

proc variantsHeader*(m: Module, comment: string): string =
  ## The note at the top of the generated data module (iface_hoist): what it
  ## is, and where each type in it was written. `comment` is the target's line
  ## comment marker.
  result = comment & " " & VariantsModule & " — generated by tuck. The data of types that satisfy an\n" &
           comment & " interface declared in a module that their own module imports, moved here\n" &
           comment & " so both can name them. Their member fns stay where they are written.\n"
  for d in m.decls:
    if d != nil and d.kind in {dkType, dkObject}:
      var file = d.span.file
      let slash = file.rfind('/')
      if slash >= 0: file = file[slash + 1 .. ^1]
      result.add(comment & "   " & writtenName(d) & "  (from " & file & ")\n")
  result.add("\n")

const RegisterProc* = "tuckRegister"
  ## What a module defines, and the entry point calls once before main, when it
  ## hands something to a module that cannot import it: its handlers for
  ## another module's registry (added to the event's list), and its members of
  ## an interface another module declares (assigned to the function references
  ## that module dispatches through). Plain code in the emitted output.

proc handlerListName*(registry, event: string): string =
  ## The list of function references a registry keeps, per event, for the
  ## handlers declared in OTHER modules. The raise proc calls its own module's
  ## handlers directly and then walks this list.
  "tuckHandlers_" & registry & "_" & event

proc isForeignHandler*(m: Module, d: Decl): bool =
  ## Is `d` an `on Registry.Event` handler whose registry another module
  ## declares? The registry's raise proc cannot call into a module that
  ## imports it, so such a handler is handed to the registry as a reference.
  if d == nil or d.kind != dkFn: return false
  let key = writtenName(d)
  let dot = key.find('.')
  if dot < 0: return false
  for r in m.decls(dkRegistry):
    if writtenName(r) == key[0 ..< dot]: return false
  true

proc registryOfHandler*(res: Resolution, d: Decl): Decl =
  ## The registry an `on Registry.Event` handler is for, nil when unknown.
  let key = writtenName(d)
  let dot = key.find('.')
  if dot < 0: return nil
  res.registryNames.getOrDefault(key[0 ..< dot])

proc handlerListOf*(res: Resolution, d: Decl): string =
  ## The list a foreign handler is added to (handlerListName), "" if its
  ## registry is unknown.
  let reg = res.registryOfHandler(d)
  if reg == nil: return ""
  let key = writtenName(d)
  handlerListName(reg.name, key[key.find('.') + 1 .. ^1])

proc foreignHandlers*(m: Module): seq[Decl] =
  ## Every handler this module declares for another module's registry.
  for d in m.decls(dkFn):
    if isForeignHandler(m, d): result.add d

proc movedSatisfiers*(m: Module): seq[tuple[iface: Decl, obj: Decl]] =
  ## The objects this module declares whose data moved to a generated module
  ## (iface_hoist), each with an interface it satisfies, as that interface's
  ## declaration is visible here.
  for o in m.decls(dkObject):
    if o.hoistedTo == "" or isImportedCopy(o): continue
    for name in o.satisfies:
      let i = m.findDecl(dkInterface, name)
      if i != nil: result.add (i, o)

type ProviderNeed* = object
  ## One group requirement a bounded fn calls but its own module does not
  ## declare: the call site must hand the fn its provider (A34). Odin and D
  ## resolve a name where the generic is WRITTEN, so a provider declared by the
  ## caller's module is invisible there unless it is passed in.
  req*: string       # the requirement as the body calls it (mangled)
  member*: Decl      # the group's signature for it
  param*: string     # the bounded type parameter, `T` in `[T: Sized]`
  paramIdx*: int     # a fn parameter whose type is exactly `param`

proc findGroup(m: Module, real: Table[string, Module], name: string): Decl =
  result = m.findDecl(dkGroup, name)
  if result != nil: return
  for _, other in real:
    result = other.findDecl(dkGroup, name)
    if result != nil: return

proc paramNamed(f: Decl, typeParam: string): int =
  ## The index of a parameter of `f` whose type is exactly `typeParam`, or -1.
  for k, p in f.fnParams:
    if p.typ != nil and p.typ.kind == tkNamed and p.typ.name == typeParam: return k
  -1

proc needsOfBound(home: Module, real: Table[string, Module], bound: Type,
                  param: string, idx: int): seq[ProviderNeed] =
  ## What one bound on type parameter `param` asks of the module declaring the
  ## fn: each requirement of a plain group that module does not itself declare.
  if bound == nil or bound.kind != tkNamed: return
  let grp = findGroup(home, real, bound.name)
  if grp == nil or grp.groupGenerics.len > 0: return
  for mem in grp.groupMembers:
    if mem == nil or mem.kind != dkFn: continue
    let req = prefixed(mem.name, nkFn)
    if not home.declaresFn(req):
      result.add ProviderNeed(req: req, member: mem, param: param, paramIdx: idx)

proc providerNeeds*(home: Module, real: Table[string, Module], f: Decl): seq[ProviderNeed] =
  ## The providers `f` (declared in `home`) is passed. Only a plain bound on a
  ## type parameter that a parameter names outright, by a group without type
  ## parameters of its own; anything else keeps resolving by name.
  if f == nil or f.kind != dkFn: return
  for i, g in f.fnGenerics:
    let idx = f.paramNamed(g)
    if i >= f.fnGenericBounds.len or idx < 0: continue
    for b in f.fnGenericBounds[i]:
      result.add needsOfBound(home, real, b, g, idx)

proc fnHome*(m: Module, real: Table[string, Module], name: string): Option[Module] =
  ## The module declaring the fn `name`: this one, else another of the program.
  if m.declaresFn(name): return some(m)
  for _, other in real:
    if other.declaresFn(name): return some(other)

proc providerFor*(m: Module, real: Table[string, Module], need: ProviderNeed,
                  selfType: string): tuple[module, name: string] =
  ## The fn named by the requirement whose first parameter is `selfType`: this
  ## module's, else another's. `module` is "" for this one.
  proc fits(mod2: Module): bool =
    for d in mod2.decls(dkFn):
      if d.name == need.req and d.fnParams.len > 0 and d.fnParams[0].typ != nil and
         d.fnParams[0].typ.kind == tkNamed and d.fnParams[0].typ.name == selfType:
        return true
  if fits(m): return ("", need.req)
  for modName, other in real:
    if other != m and fits(other): return (modName, need.req)

type OverflowPlan* = object
  ## How `+ - *` on a value of one type behaves when the result does not fit
  ## (issue #16, step 3; ROADMAP 2026-08-25 ruling 4). `active` is false for
  ## the types that get plain arithmetic: bare `int` and `i64` (64 bits is
  ## enough), floats, and anything that is not an integer.
  active*: bool
  policy*: string     ## "Trap" (the default), "Wrap" or "Sat"
  base*: string       ## the underlying integer: u8, i32, ...
  named*: string      ## the declared type wrapping it, or "" for the integer itself

const CheckedIntNames = ["i8", "i16", "i32", "u8", "u16", "u32", "u64", "usize"]
  ## The integers whose arithmetic is checked by default. `int` and `i64` are
  ## left alone unless the author attached an overflow attribute to a type.

proc overflowAttr(d: Decl): string =
  ## The policy a type declaration names, or "".
  for a in d.typeBody.attrs:
    case a.name
    of "trapping": return "Trap"
    of "wrapping": return "Wrap"
    of "saturating": return "Sat"
    else: discard

proc typeDeclNamed(m: Module, real: Table[string, Module], name: string): Decl =
  ## The `type`/`distinct` declaration called `name`, here or in an import.
  result = m.findDecl(dkType, name)
  if result != nil: return
  for _, other in real:
    result = other.findDecl(dkType, name)
    if result != nil: return

proc overflowPlan*(m: Module, real: Table[string, Module], t: Type): OverflowPlan =
  ## The overflow plan for arithmetic whose result has type `t`.
  if t == nil or t.kind != tkNamed: return
  if t.name in CheckedIntNames:
    return OverflowPlan(active: true, policy: "Trap", base: t.name)
  let d = typeDeclNamed(m, real, t.name)
  if d == nil or d.typeBody == nil or d.typeBody.kind != tkNamed: return
  let base = d.typeBody.name
  let wide = base in ["int", "i64"]
  if not wide and base notin CheckedIntNames: return
  let attr = d.overflowAttr()
  # `[saturating]` keeps its store-guard design (known_bugs 4b): it clamps where
  # a value is STORED, on a wider intermediate, so `a + b - c` of three 60000s
  # is 60000 and not the 5535 per-operator clamping would give. The helpers can
  # saturate per operator, but which semantics is wanted is an open decision.
  if attr == "Sat": return
  if attr == "" and wide: return
  OverflowPlan(active: true, policy: (if attr == "": "Trap" else: attr),
               base: base, named: t.name)

proc ovOpName*(op: BinOp): string =
  ## The checked-arithmetic helper's operator enum member (OvOp.Add ...).
  case op
  of boAdd: "Add"
  of boSub: "Sub"
  else: "Mul"

type ImplVar* = object
  ## One function reference an interface's module keeps (implVarName): the
  ## contract member `mem` of the moved satisfier `sat`.
  name*: string
  mem*, sat*: Decl
  selfByRef*: bool   # the satisfier's member changes its object

iterator implVars*(res: Resolution, m: Module, iface: Decl,
                   sats: seq[Decl]): ImplVar =
  ## Every function reference `iface` needs in module `m`, in a fixed order.
  for s in sats:
    if not isMovedSatisfier(m, iface, s): continue
    for mem in iface.ifaceMembers:
      if mem == nil or mem.kind != dkFn: continue
      let own = findObjectMember(s, implementingName(s, iface.name, mem.name))
      yield ImplVar(name: implVarName(iface.name, mem.name, s.name), mem: mem,
                    sat: s, selfByRef: writesSelf(res, own))

proc isSelfType*(t: Type): bool =
  t != nil and t.kind == tkNamed and t.name == "Self"

proc registersAnything*(m: Module): bool =
  foreignHandlers(m).len > 0 or movedSatisfiers(m).len > 0

proc registerModules*(m: Module, real: Table[string, Module]): seq[string] =
  ## The other modules of the program that have something to register, sorted.
  for modName, other in real:
    if other != m and registersAnything(other): result.add modName
  result.sort()

proc hasForeignHandlers*(res: Resolution, m: Module, d: Decl,
                         v: VariantDef): bool =
  ## Does some module other than `m` handle this event of `m`'s registry `d`?
  let key = writtenName(d) & "." & v.name
  var local = initHashSet[NodeId]()
  for h in registryHandlers(m, d, v): local.incl(h.id)
  for id in res.handlerSites.getOrDefault(key):
    if id notin local: return true

proc handlerProcName*(handler: Decl): string =
  ## A handler is declared as `Registry.Event`, which is no backend's
  ## identifier — the dot becomes an underscore, as its declaration does.
  handler.name.replace(".", "_")

iterator actorMemberFns*(d: Decl): Decl =
  ## An actor's member `fn`s — the ones spelled `fn`, not `on` (A24). Each is
  ## printed as a proc taking the actor's state as `self`, the way its message
  ## dispatch takes it, and a call to one passes that `self` on.
  for h in d.handlers:
    if h != nil and h.kind == dkFn and not h.isOnHandler: yield h

proc actorMemberCallee*(res: Resolution, e: Expr): string =
  ## The proc a call to an actor's member `fn` prints as (A24) — the name the
  ## member is declared under, `memberProcName` over the mangled actor — or
  ## "" for any other call. The checker only records a call made from the
  ## actor's own code, where `self` is its state.
  let (owner, member) = res.actorMemberOf(e)
  if member == "": "" else: memberProcName(prefixed(owner, nkActor), member)

proc actorSelfParam*(actorType: string, m: Decl): Param =
  ## `self`, the state an actor member `fn` works on, typed as `actorType`
  ## — each backend's spelling of what its message dispatch takes.
  Param(name: "self", typ: Type(span: m.span, kind: tkNamed, name: actorType),
        span: m.span)

proc isZeroFill*(e: Expr): bool =
  ## `[0; N]`, `[0.0; N]`, `[false; N]` — a fill each host can give as its
  ## zero-initialised storage rather than a loop (R8, the owner's note).
  let v = e.fillValue
  v != nil and v.kind == exkLit and v.litValue.len > 0 and
    (v.litValue == "false" or v.litValue.allCharsInSet({'0', '.', '_'}))

proc fillElemType*(res: Resolution, e: Expr): Type =
  ## `[v; N]`'s element type, as the checker settled it (synthFill).
  let t = res.typeFor(e)
  if t != nil and t.kind == tkApp and t.args.len == 2: t.args[1] else: nil


var hostChecks*: bool
  ## Let the host compiler verify what the effect pass was told. ON by default
  ## (`--no-host-checks` opts out): a disagreement is a bug in our analysis or
  ## runtime, and exposing it is the point (proposal §7.3: defence in depth
  ## before reliance).

proc nimFnPragmas*(d: Decl): string =
  ## ` {.inline, noSideEffect.}` for a fn, or "". `noSideEffect` is the host's
  ## own check of `[pure]`.
  var ps: seq[string]
  if d.isInline: ps.add "inline"
  if hostChecks and emPure in d.fnEffects: ps.add "noSideEffect"
  if ps.len > 0: " {." & ps.join(", ") & ".}" else: ""


proc depthVar*(d: Decl): string =
  ## The per-fn recursion counter a `[depth: N]` fn keeps (thread-local, so a
  ## recursion on one thread never counts another's frames).
  result = "tuckDepth_"
  for ch in d.name:
    if ch in IdentChars and ch != '_': result.add ch

proc depthDisplayName*(d: Decl): string =
  ## The name a user wrote: the mangler's prefix (`tuckˑfnˑ`) is not theirs.
  let parts = d.name.split("ˑ")
  parts[^1]
