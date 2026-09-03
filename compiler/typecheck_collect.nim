# compiler/typecheck_collect.nim
#
# The pre-pass that fills fnSigs / typeDecls / objDecls before any body is
# checked, so a call can resolve a fn declared later in the file — plus the
# per-declaration validators (pool, arena, actor queue, invariants, registry).
import ast, tables, sets, strutils
import resolution
import typecheck_state
import typecheck_util

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
  tc.fnSigs[d.name] = (d.fnParams, d.fnReturnType, d.fnGenerics, d.fnEffects)
  indexDecl(semLayer, d)
  tc.fnDecls[d.name] = d
  # NOT pending: a pending fn emits a generic one-payload stub
  # (genPendingStub), so its real params are ({payload: T},) — nothing like its
  # DECLARED params, which is what topLevelFns's consumers (lowering,
  # codegen's explodeRecordArg/genCall) would explode against.
  if top and not d.isPending: tc.topLevelFns.incl(d.name)
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
  tc.fnSigs[d.name] = (d.sigParams, d.sigReturn,
                       newSeq[string](), newSeq[EffectMarker]())
  tc.fnSigNames.incl(d.name)
  if d.sigGenerics.len > 0: tc.fnSigGenerics[d.name] = d.sigGenerics

proc collectPoolSigs*(tc: var TypeChecker, d: Decl) =
  ## spec 7.2: a pool exposes two ordinary fns. Registering them as normal
  ## signatures means `Pool.acquire` resolves through the same path as any
  ## other call — no special-case lookup, and the ?T falls out of the declared
  ## return type.
  let optElem = Type(span: d.span, kind: tkApp, args: @[d.poolElem],
                     base: Type(span: d.span, kind: tkNamed, name: "?"))
  tc.fnSigs[d.name & ".acquire"] = (newSeq[Param](), optElem,
                                    newSeq[string](), newSeq[EffectMarker]())
  tc.fnSigs[d.name & ".release"] =
    (@[Param(name: "slot", typ: d.poolElem, span: d.span)],
     Type(span: d.span, kind: tkNamed, name: "void"),
     newSeq[string](), newSeq[EffectMarker]())

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
      tc.fnSigs[d.name] = (d.taskParams, d.taskReturnType,
                           newSeq[string](), d.taskEffects)
    of dkFnSig: tc.collectFnSigType(d)
    of dkPool: tc.collectPoolSigs(d)
    of dkType: tc.collectTypeDecl(d)
    of dkObject: tc.collectObjectDecl(d)
    of dkInterface:
      # Indexed, NOT collected into fnSigs: an interface's members are
      # requirements, not callable functions. Registering them would put
      # `noise` in the flat table with no body behind it.
      tc.ifaceDecls[d.name] = d
    of dkMixin, dkExtern, dkPending: tc.collectSigs(d.mixinMembers, top = false)
    of dkActor: tc.collectSigs(d.handlers)
    of dkErrors: tc.collectErrPolicy(d)
    else: discard

proc resolveTypeRefs*(tc: TypeChecker, t: Type) =
  ## Point every named type reference at the declaration it names, so later
  ## passes follow an edge instead of matching a string. Recursive, because a
  ## reference can be buried in a generic argument or a record field.
  if t == nil: return
  if t.kind == tkNamed and tc.typeDeclsByName.hasKey(t.name):
    resolveTypeTo(semLayer, t, tc.typeDeclsByName[t.name])
  for c in t.children: resolveTypeRefs(tc, c)

proc resolveDeclTypeRefs*(tc: TypeChecker, d: Decl) =
  ## Every type a declaration mentions, including its members'.
  ##
  ## `ownTypes` says which types a decl names directly and `childDecls` which
  ## declarations nest inside it — so this is the same two lines as every other
  ## whole-tree pass. It used to spell out all 21 kinds, which is where
  ## dkInterface and dkWhen had gone missing until an `else: discard` removal
  ## surfaced them.
  if d == nil: return
  for t in d.ownTypes: resolveTypeRefs(tc, t)
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
