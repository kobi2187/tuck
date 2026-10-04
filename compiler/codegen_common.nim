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
import ast, lowering, ast_query, ast_ops, strutils, sets, tables, options
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
    if h.kind == dkFn and h.isOnHandler:
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

proc isActorWaitOn*(e: Expr): bool =
  ## `Actor.waitUntil {pred: :p}`, as the checker rewrote it:
  ## `waitUntil(<actorRef>, pred)`. Every backend prints it as a wait on the
  ## actor's slot.
  e != nil and e.kind == exkCall and e.callee != nil and
    e.callee.kind == exkVar and e.callee.name == "waitUntil" and
    e.args.len == 2 and e.args[0] != nil and e.args[0].kind == exkActorRef

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
  "tuckSat", "tuckSatI",
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
  ## Does the liveness pass mark some read of `name` inside `e` as its final
  ## use? That stamp is what licenses moving from a parameter.
  if e == nil: return false
  if e.kind == exkVar and e.name == name and res.isLastUse(e): return true
  for c in e.children:
    if hasLastUse(res, c, name): return true
  false

# --- which final reads of a parameter KEEP it ------------------------------
#
# `sink` tells Nim the callee may keep the argument: a caller then MOVES an
# argument that dies at the call and COPIES one that is still live. So a
# parameter the callee only READS must not be `sink` — and marking one anyway
# is not merely wasted. Every call whose argument is still needed pays a full
# copy, and a recursive reader (`eval(ns, n.left) + eval(ns, n.right)`) pays
# one per call: 87 s against 0.037 s on a 2^15-leaf tree held as a node array,
# and 0.25 s against 0.011 s for the boxed tree lowering_recursive emits
# (benches/SCORES.md, "Trees"). Leaving `sink` off is always sound — it only
# gives up a move — so every unrecognised case below answers "kept", which is
# what every final read was taken to mean before.

type ConsumeMemo = object
  known: Table[string, bool]  ## "fn\0param" -> does the fn keep that param
  busy: HashSet[string]       ## being answered: a recursive call reads as not kept

proc fnNamed(m: Module, name: string): Decl =
  ## The one top-level fn called `name`, or nil — none, or several, when the
  ## call cannot say which and the answer has to be the safe one.
  for d in m.decls:
    if d != nil and d.kind == dkFn and d.name == name:
      if result != nil: return nil
      result = d

proc paramKept(res: Resolution, m: Module, fnD: Decl, pname: string,
               memo: var ConsumeMemo): bool

proc calleeKeeps(res: Resolution, m: Module, call: Expr, pname: string,
                 idx: int, memo: var ConsumeMemo): bool =
  ## Does the callee keep the argument bound to its parameter `pname` (by
  ## name, for a record-style call) or at position `idx`? A fn declared in
  ## this module answers from its own body; a construction, an extern or an
  ## import is taken to keep it.
  if call.callee == nil or call.callee.kind != exkVar: return true
  let d = fnNamed(m, call.callee.name)
  if d == nil or d.fnBody == nil: return true
  if pname != "":
    for p in d.fnParams:
      if p.name == pname: return paramKept(res, m, d, pname, memo)
    return true
  if idx < 0 or idx >= d.fnParams.len: return true
  paramKept(res, m, d, d.fnParams[idx].name, memo)

proc keptAt(res: Resolution, m: Module, stack: seq[Expr], k: int,
            memo: var ConsumeMemo): bool

proc fieldKept(res: Resolution, m: Module, stack: seq[Expr], k: int,
               memo: var ConsumeMemo): bool =
  ## stack[k] is a field VALUE of the record literal stack[k-1]. A literal
  ## that is a call's payload hands each field to the parameter of that name;
  ## any other literal holds what it is given.
  let s = stack[k - 1]
  if k >= 2 and stack[k - 2].kind == exkCall and s in stack[k - 2].args:
    for f in s.fields:
      if f.value == stack[k]:
        return calleeKeeps(res, m, stack[k - 2], f.name, -1, memo)
  true

proc keptAt(res: Resolution, m: Module, stack: seq[Expr], k: int,
            memo: var ConsumeMemo): bool =
  ## Is the value stack[k] kept by where it sits — bound, stored, returned,
  ## sent, or handed to a parameter that keeps it? Walks outward while the
  ## value only passes through (a branch, a block's last value, a field read).
  if k == 0: return true   # the body's own value is the fn's result
  let n = stack[k]
  let p = stack[k - 1]
  case p.kind
  of exkReturn, exkList, exkFill, exkSend, exkChain: true
  of exkAssign: n == p.assignVal
  of exkBracketAssign: n == p.brValue
  of exkStruct: fieldKept(res, m, stack, k, memo)
  of exkCall: n != p.callee and calleeKeeps(res, m, p, "", p.args.find(n), memo)
  of exkField:
    p.dotArg != nil or (n == p.receiver and keptAt(res, m, stack, k - 1, memo))
  of exkIf: n != p.cond and keptAt(res, m, stack, k - 1, memo)
  of exkMatch: n != p.subject and keptAt(res, m, stack, k - 1, memo)
  of exkBlock:
    p.stmts.len > 0 and n == p.stmts[^1] and keptAt(res, m, stack, k - 1, memo)
  else: false   # an operand, an index, a condition, a loop's iterable: read

proc keptLastUse(res: Resolution, m: Module, e: Expr, name: string,
                 stack: var seq[Expr], memo: var ConsumeMemo): bool =
  ## Is some read of `name` under `e` both its final use and a keeping one?
  if e == nil: return false
  stack.add e
  if e.kind == exkVar and e.name == name and res.isLastUse(e):
    result = keptAt(res, m, stack, stack.high, memo)
  if not result:
    for c in e.children:
      if keptLastUse(res, m, c, name, stack, memo):
        result = true
        break
  discard stack.pop()

proc paramKept(res: Resolution, m: Module, fnD: Decl, pname: string,
               memo: var ConsumeMemo): bool =
  ## Does `fnD` keep its parameter `pname`? The least fixed point over the
  ## module's fns: a call back into one still being answered reads as "only
  ## read", which is what a recursive reader is.
  let key = fnD.name & "\0" & pname
  if memo.known.hasKey(key): return memo.known[key]
  if key in memo.busy: return false
  memo.busy.incl key
  var stack: seq[Expr]
  result = keptLastUse(res, m, fnD.fnBody, pname, stack, memo)
  memo.busy.excl key
  memo.known[key] = result

proc paramIsMovable*(res: Resolution, m: Module, body: Expr, p: Param): bool =
  ## May this parameter be taken destructively (`sink`)? True when the type
  ## owns storage worth not copying AND the body's final read of it KEEPS it
  ## (keptAt). A parameter the body only reads — indexes, measures, walks,
  ## passes on to another reader — is borrowed instead.
  ##
  ## A parameter the body never reads has no stamped use and stays as it was,
  ## which is the safe answer for anything the analysis did not reach.
  if not ownsHeap(m, p.typ): return false
  var memo: ConsumeMemo
  var stack: seq[Expr]
  keptLastUse(res, m, body, p.name, stack, memo)

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
