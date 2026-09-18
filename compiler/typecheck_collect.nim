# compiler/typecheck_collect.nim
#
# The pre-pass that fills fnSigs / typeDecls / objDecls before any body is
# checked, so a call can resolve a fn declared later in the file — plus the
# per-declaration validators (pool, arena, actor queue, invariants, registry).
import ast, tables, sets, strutils, options
import resolution
import typecheck_state
import typecheck_util
import ast_query

proc collectSigs*(tc: var TypeChecker, decls: seq[Decl], top = true)
  ## Forward-declared: collectTypeDecl/collectObjectDecl below recurse into
  ## it (nested type/object members) before its own definition.

proc failIfPendingClash*(tc: TypeChecker, d: Decl) =
  ## Stale-pending check, order-independent: implemented + still pending is an
  ## error whichever declaration the checker reaches first.
  fail("Pending Error: '" & d.name &
       "' is implemented — remove it from the pending block", d.span)

proc collectFnSig*(tc: var TypeChecker, d: Decl, top: bool) =
  ## A fn joins the signature catalog, and is indexed so a resolved call can
  ## point at this declaration rather than describe it by name.
  # ADD, not set: two objects may each declare a member of the same name, and
  # evicting the first is what made `b.hash` on a Blob check against Commit's
  # signature.
  tc.addFnSig(d.name, (d.fnParams, d.fnReturnType, d.fnGenerics, d.fnEffects,
                       d.fnResourceKinds))
  for b in d.fnGenericBounds:
    if b.len > 0:
      tc.groupBoundsOf[d.name] = d.fnGenericBounds
      break
  indexDecl(semLayer, d)
  tc.addFnDecl(d.name, d)
  # NOT pending: a pending fn emits a generic one-payload stub
  # (genPendingStub), so its real params are ({payload: T},) — nothing like its
  # DECLARED params, which is what topLevelFns's consumers (lowering,
  # codegen's explodeRecordArg/genCall) would explode against.
  if top and not d.isPending:
    tc.topLevelFns.incl(d.name)
    tc.topLevelFnDecl[d.name] = d
  if "::" in d.name:
    # qualified sketch stub legalizes its module prefix
    tc.knownModules.incl(d.name.split("::")[0])
  if d.isPending:
    if d.name in tc.implementedFns: tc.failIfPendingClash(d)
    tc.pendingFns[d.name] = d.span
  elif d.fnBody != nil:
    if tc.pendingFns.hasKey(d.name): tc.failIfPendingClash(d)
    tc.implementedFns.incl(d.name)

proc collectFnSigType*(tc: var TypeChecker, d: Decl) =
  ## A named function-signature type: register its call shape under NAME and
  ## mark NAME as a fnsig so a call through a NAME-typed slot is validated.
  ## A signature TYPE declares no effects of its own — what gets baked into
  ## the slot carries them.
  tc.setFnSig(d.name, (d.sigParams, d.sigReturn,
                       newSeq[string](), newSeq[EffectMarker](), newSeq[string]()))
  tc.fnSigNames.incl(d.name)
  if d.sigGenerics.len > 0: tc.fnSigGenerics[d.name] = d.sigGenerics

proc collectPoolSigs*(tc: var TypeChecker, d: Decl) =
  ## spec 7.2: a pool exposes two ordinary fns. Registering them as normal
  ## signatures means `Pool.acquire` resolves through the same path as any
  ## other call — no special-case lookup, and the ?T falls out of the declared
  ## return type.
  ## `acquire` yields a HANDLE, not the cell's contents. A value cannot name
  ## the cell it came from, which is why `release` used to search by equality
  ## and free the wrong slot; the handle carries the index and the tenancy.
  ##
  ## The handle type is PER POOL — `FrameBuffersHandle` is not
  ## `SessionsHandle` — so releasing into the wrong pool is a type error here
  ## rather than a runtime check. The emitted type is shared across pools;
  ## only the checker separates them, the way a group's bound is resolved and
  ## discarded before codegen.
  let handle = Type(span: d.span, kind: tkNamed, name: poolHandleName(d.name))
  let optHandle = Type(span: d.span, kind: tkApp, args: @[handle],
                       base: Type(span: d.span, kind: tkNamed, name: "?"))
  tc.setFnSig(d.name & ".acquire", (newSeq[Param](), optHandle,
                                    newSeq[string](), newSeq[EffectMarker](),
                                    newSeq[string]()))
  tc.setFnSig(d.name & ".release",
    (@[Param(name: "slot", typ: handle, span: d.span)],
     Type(span: d.span, kind: tkNamed, name: "void"),
     newSeq[string](), newSeq[EffectMarker](), newSeq[string]()))
  # Opaque: a record with no fields. Nothing to read, nothing to do
  # arithmetic on, and `{} <Pool>Handle` yields a zeroed handle whose tenancy
  # is 0 — which no live slot ever has, so a forged one is refused at release
  # rather than silently accepted.
  tc.typeDecls[poolHandleName(d.name)] =
    Type(span: d.span, kind: tkRecord, fields: @[])
  # Strictly nominal, through the mechanism `distinct` already uses: without
  # it two pools' handles are both empty records and match STRUCTURALLY, so
  # `B.release {aHandle}` type-checked. `distinctNames` is exactly the rule a
  # handle wants — "no widening, no resolving through to the base type".
  tc.distinctNames.incl(poolHandleName(d.name))

proc collectResourceHandles*(tc: var TypeChecker, d: Decl) =
  ## spec §7.4: each declared kind gets its own handle TYPE, registered
  ## exactly as a pool's is — and for the identical reason. A handle is an
  ## opaque record with no fields: nothing to read, nothing to do arithmetic
  ## on, and `{} UdpHandle` yields a zeroed one whose tenancy is 0, which no
  ## live entry ever has, so a forged handle is refused rather than silently
  ## accepted.
  ##
  ## `distinctNames` makes the separation NOMINAL. Without it two kinds'
  ## handles are both empty records, match structurally, and finishing a file
  ## handle into the socket registry type-checks. The emitted type is shared
  ## across kinds; only the checker separates them, the way a group bound is
  ## resolved and discarded before codegen.
  for k in d.resKinds:
    let name = resourceHandleName(k.name)
    tc.typeDecls[name] = Type(span: k.span, kind: tkRecord, fields: @[])
    tc.distinctNames.incl(name)

proc collectTypeDecl*(tc: var TypeChecker, d: Decl) =
  ## A type's body joins the type table; manager types carry functionality, so
  ## their member fns join the catalog too.
  indexDecl(semLayer, d)
  tc.typeDeclsByName[d.name] = d
  if d.typeBody != nil:
    tc.typeDecls[d.name] = d.typeBody
    if d.generics.len > 0:
      tc.typeGenerics[d.name] = d.generics
    for a in d.typeBody.attrs:
      if a.name == "distinct":
        tc.distinctNames.incl(d.name)
  tc.collectSigs(d.typeMembers, top = false)
  for m in d.typeMembers:
    if m != nil and m.kind == dkFn: tc.objectMemberFns.incl(m.name)

proc collectObjectDecl*(tc: var TypeChecker, d: Decl) =
  ## `{fields} Obj` constructs an object, exactly as `{fields} Rec` constructs
  ## a record. Objects were absent from typeDecls, so the construction path in
  ## synthCall fell through and produced Unknown — which made every field
  ## access on the result unchecked (`r.nosuchfield` passed) and let any value
  ## into an interface slot.
  ##
  ## Still NOT registered in typeDecls: `resolve` unwraps any name found there
  ## to its body, and an object is NOMINAL — `loadEpisode({self: PodcastApp})`
  ## must keep seeing PodcastApp, not the record shape behind it. Records are
  ## structural and belong there; objects do not. Field lookup reaches an
  ## object through typeDeclsByName + composedFields instead.
  tc.objDecls[d.name] = d
  tc.typeDeclsByName[d.name] = d
  tc.collectSigs(d.objMembers, top = false)
  for m in d.objMembers:
    if m != nil and m.kind == dkFn: tc.objectMemberFns.incl(m.name)

proc collectErrPolicy*(tc: var TypeChecker, d: Decl) =
  ## The module's error policy, which decides what a dropped fallible result
  ## does.
  tc.errPolicy = d.policyName
  if d.policyName in ["continue", "exit"] and d.errHandler == nil:
    fail("Policy Error: errors [policy: " & d.policyName &
         "] needs an 'on unhandled({code, site})' handler", d.span)

proc collectSigs*(tc: var TypeChecker, decls: seq[Decl], top = true) =
  ## `top` distinguishes a module's own declarations from the members nested
  ## inside a type, object, mixin or actor. Only top-level fns get recorded in
  ## topLevelFns, because they are the only callees lowering explodes payloads
  ## for — a member fn's explosion belongs to the backends, which see the
  ## receiver.
  for d in decls:
    if d == nil: continue
    case d.kind
    of dkImport:
      tc.knownModules.incl(d.name)
    of dkFn: tc.collectFnSig(d, top)
    of dkTask:
      tc.taskNames.incl(d.name)
      tc.setFnSig(d.name, (d.taskParams, d.taskReturnType,
                           newSeq[string](), d.taskEffects,
                           d.taskResourceKinds))
    of dkFnSig: tc.collectFnSigType(d)
    of dkPool: tc.collectPoolSigs(d)
    of dkType: tc.collectTypeDecl(d)
    of dkObject: tc.collectObjectDecl(d)
    of dkInterface:
      # Indexed, NOT collected into fnSigs: an interface's members are
      # requirements, not callable functions. Registering them would put
      # `noise` in the flat table with no body behind it.
      tc.ifaceDecls[d.name] = d
    of dkGroup:
      # Same reasoning as dkInterface, into its own table — see groupDecls'
      # own comment in typecheck_state.nim for why they aren't shared.
      tc.groupDecls[d.name] = d
    of dkMixin, dkExtern, dkPending: tc.collectSigs(d.mixinMembers, top = false)
    of dkActor:
      tc.collectSigs(d.handlers)
      # `<Actor>.waitUntil {pred: :p}` — a static member call, registered the
      # same way `Pool.acquire` is. A plain signature in the flat table, so the
      # call resolves through the ordinary path: the compiler does NOT special-
      # case a library name, and the actor is named by the author rather than
      # inferred from which fields the predicate happens to read.
      #
      # Blocks until `p` holds. The actor evaluates it on its own thread after
      # each message, so the answer is neither racy nor stale (spec §9.1).
      tc.setFnSig(d.name & ".waitUntil",
        # The shape STRUCTURALLY (`{} -> bool`), not the name `Predicate`:
        # that name lives in std/scheduler, and `Actor.waitUntil` is a property
        # of the actor, so it must not require an import to use.
        (@[Param(name: "pred",
                 typ: Type(span: d.span, kind: tkFunc, params: @[],
                           result: Type(span: d.span, kind: tkNamed,
                                        name: "bool"),
                           paramNames: @[]),
                 span: d.span)],
         Type(span: d.span, kind: tkNamed, name: "void"),
         newSeq[string](), @[emIo], newSeq[string]()))
    of dkErrors: tc.collectErrPolicy(d)
    of dkResources: tc.collectResourceHandles(d)
    else: discard

proc resolveTypeRefs*(tc: TypeChecker, t: Type) =
  ## Point every named type reference at the declaration it names, so later
  ## passes follow an edge instead of matching a string. Recursive, because a
  ## reference can be buried in a generic argument or a record field.
  if t == nil: return
  if t.kind == tkNamed and tc.typeDeclsByName.hasKey(t.name):
    resolveTypeTo(semLayer, t, tc.typeDeclsByName[t.name])
  for c in t.children: resolveTypeRefs(tc, c)

proc genericNamesOf(d: Decl): seq[string] =
  ## The type parameters this declaration itself introduces, which are the
  ## only non-evaluable names legal as an `Array` size inside it.
  if d == nil: return
  case d.kind
  of dkType: d.generics
  of dkFn: d.fnGenerics
  of dkFnSig: d.sigGenerics
  of dkGroup: d.groupGenerics
  of dkActor: d.actorGenerics
  else: @[]

proc failIfBadArraySize(tc: TypeChecker, t: Type, generics: seq[string]) =
  ## `Array[N, T]` is N wide, and N must be a number the compiler knows.
  ##
  ## The size is carried as a tkNamed whose NAME is the source text, and
  ## nothing resolved it: `Array[Nonexistent, int]` checked clean and died in
  ## the backend as "undeclared identifier", which is a Tuck mistake reported
  ## against generated code the author never wrote (#59).
  ##
  ## A type PARAMETER is legal and stays unevaluated — inside `fn f[N]` there
  ## is no number yet, and the instantiation is where one appears.
  if t == nil: return
  if t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
     t.base.name == "Array" and t.args.len == 2:
    let size = t.args[0]
    if size != nil and size.kind == tkNamed and size.name notin generics and
       constIntOf(tc.module, size.name).isNone:
      fail("Type Error: `Array[" & size.name & ", _]` — a size must be a " &
           "whole number the compiler knows: a literal, a `const` naming " &
           "one, or a type parameter of the enclosing declaration", size.span)
  for c in t.children: tc.failIfBadArraySize(c, generics)

proc resolveDeclTypeRefs*(tc: TypeChecker, d: Decl) =
  ## Every type a declaration mentions, including its members'.
  ##
  ## `ownTypes` says which types a decl names directly and `childDecls` which
  ## declarations nest inside it — so this is the same two lines as every other
  ## whole-tree pass. It used to spell out all 21 kinds, which is where
  ## dkInterface and dkWhen had gone missing until an `else: discard` removal
  ## surfaced them.
  if d == nil: return
  let gs = genericNamesOf(d)
  for t in d.ownTypes:
    resolveTypeRefs(tc, t)
    tc.failIfBadArraySize(t, gs)
  for m in d.childDecls: resolveDeclTypeRefs(tc, m)

proc resolveTypeNames*(tc: TypeChecker, m: Module) =
  ## Run after collectSigs, when every declaration is known.
  for d in m.decls: resolveDeclTypeRefs(tc, d)

proc resolveInferredTypes*(tc: TypeChecker) =
  ## Point every INFERRED type at its declaration, the way resolveTypeNames
  ## does for declared ones. Run after checking, when the semantic layer holds
  ## a type for every expression.
  ##
  ## Without this the edge exists only for types the user WROTE, so anything
  ## reading a type the checker worked out for itself has to re-derive the
  ## declaration by name — a decl-list scan, once per node. That is a stage
  ## boundary crossing: name resolution happening at emit time.
  for t in semLayer.allTypes():
    resolveTypeRefs(tc, t)

proc checkFallibleNeedsIo*(name: string, ret: Type, effects: seq[EffectMarker], span: Span) =
  if ret != nil and isWrapper(ret) and ret.base.name in ["!", "!?"] and
     emIo notin effects:
    fail("Effect Error: '" & name & "' returns " & typeName(ret) &
         " — fallible functions must be marked [io]; pure functions are total", span)
