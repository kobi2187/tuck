# compiler/typecheck_state.nim
#
# The type checker's shared state: the TypeChecker object plus the scope stack
# and the small operations that read/resolve it (bind/lookup, alias resolution,
# field lists). The synthesis, flow, and validation modules all operate on a
# `var TypeChecker` threaded through their signatures, so this type and its core
# operations live here for them to import.
import resolution
import ast, lowering, tables, sets
import ast_query
import typecheck_util

type
  Binding* = tuple[typ: Type, isVar: bool, isParam: bool, narrowed: bool,
                   used: bool, errSeen: bool, span: Span, site: Expr]
    ## `isVar` is write permission; `isParam` says the name is a FUNCTION
    ## PARAMETER, which is a third thing rather than a flavour of the first.
    ##
    ## `narrowed` is "this result has been guarded, so `.value` is readable"
    ## (spec §4.8). It lives on the BINDING, not in a name-keyed set beside
    ## the scope stack, because an inner `let r` is a different result that
    ## nothing has guarded — keyed by name alone it inherited the outer `r`'s
    ## narrowing and read `.value` off an unhandled wrapper.
    ##
    ## A parameter is an immutable binding of a VALUE (spec §7.1): the callee
    ## may read it and may copy it, but may never write through it to the
    ## caller's record. That is not the same rejection as `..` on a `let`, and
    ## it does not have the same fix, so failIfMutatingLet needs to tell them
    ## apart to say anything useful.
    ##
    ## `self` in an object member and an actor's own fields stay `isVar: true`
    ## and `isParam: false` — they mutate state the callee OWNS, which is the
    ## stated exception (§5.1), not a caller's value.
  # The in-memory twin of ast.nim's SigInfo: what the checker needs to know
  # about a fn it is calling, whether that fn was read from source or restored
  # from the cached index. Keep the two in step — a field here that SigInfo
  # lacks cannot survive to disk, and the check quietly weakens for imports.
  FnSig* = tuple[params: seq[Param], ret: Type, generics: seq[string],
                 effects: seq[EffectMarker], resources: seq[string]]
    ## `resources` rides beside `effects` for the reason SigInfo's own comment
    ## gives: anything a CALLER must know to check a call correctly belongs in
    ## the signature, and a resource kind is exactly that (§7.4 — a fn calling
    ## an acquirer declares the kind itself). Left out, an imported acquirer
    ## would look non-acquiring across a module boundary, which is the bug
    ## effects themselves had before they were carried here.
  TypeChecker* = object
    module*: Module
    fnSigs*: Table[string, seq[FnSig]]
      ## Name -> every signature declared under it, not one. Two objects may
      ## each declare a `hash` member, and a flat name->sig table let the
      ## second overwrite the first, so `b.hash` on a Blob was checked
      ## against Commit's signature and rejected — the receiver's own type
      ## never got a say. The list keeps them all; `sigOf` picks when the
      ## receiver is known and otherwise answers exactly as the flat table
      ## did (the last one registered), which is what keeps every call site
      ## that cannot know a receiver behaving as before.
    typeDecls*: Table[string, Type]
    typeGenerics*: Table[string, seq[string]]  # generic type decls: Box -> @["T"]
    fnSigGenerics*: Table[string, seq[string]] # generic fnsig decls: Mapper -> @["T", "U"]
      ## Kept SEPARATE from `fnSigs[name].generics` (always left empty for a
      ## fnsig entry) rather than reusing it: that field feeds the ordinary
      ## payload-inference machinery (checkPayloadCall/substituteParams) any
      ## direct call by name would go through, and a fnsig's generics are
      ## resolved a different way — directly from a SLOT's own declared type
      ## args (`Mapper[int, str]`), never inferred from a call's arguments.
    currentGenerics*: HashSet[string]          # type params of the fn body being checked
    currentBounds*: Table[string, seq[Type]]
                           ## while checking a generic body: type param -> the
                           ## groups bounding it. A call to a requirement's
                           ## name on a value of that param is typed from the
                           ## GROUP, so the body is checked once against the
                           ## contract instead of resolving to whichever
                           ## concrete fn happens to share the name.
    scopes*: seq[Table[string, Binding]]
    currentRet*: Type
    currentFn*: string
    pendingFns*: Table[string, Span]
    implementedFns*: HashSet[string]
    errPolicy*: string            # strict (default) | continue | exit
    wrapperFieldRead*: bool
    ownerFieldScope*: int
      ## 1 + the index in `scopes` where the enclosing owner bound its fields
      ## bare (an object's members, an actor's handlers, a type's invariants);
      ## 0 outside one. A name found THERE, and not in a scope inside it, is
      ## the owner's field (`resolvesToOwnerField`).
      ## Set while synthesizing the RECEIVER of `.ok`/`.value`, so a bare read
      ## of a binding can be told from one — see markErrSeen.
    unhandledSites*: seq[string]  # strict: error list; continue/exit: SHORTCUTS
    bodyBlock*: Expr              # current fn's outermost block: its last stmt
                                  # is the implicit return, not a discard
    transitionCtx*: bool          # constructing THROUGH transitionTo: sealed
                                  # non-initial variants are legal there
    expectedType*: Type       # the type context expects the expression
                                  # currently being synthesized to have (nil
                                  # otherwise) — the checker's one expected-
                                  # type channel, fed from a match arm's
                                  # subject, an assignment's target, a `check`
                                  # call's own `expected`, or (via
                                  # fieldTypeHints below) a construction/call
                                  # payload's declared field type. Consulted
                                  # only by synthBareVariant: an inline sum
                                  # type (`state: {Red, Yellow, Green}`) has
                                  # no name to look up in typeDecls, so a
                                  # bare variant used as a VALUE (not a
                                  # pattern) has nowhere else to learn its
                                  # type from.
    fieldTypeHints*: Table[string, Type]  # field name -> declared type, for
                                  # the struct literal synthStruct is
                                  # CURRENTLY walking, set by asNamedCallee
                                  # from the constructed type's own fields
                                  # before descending (empty otherwise).
                                  # `{state: Green} Light` needs this the
                                  # same way `state = Green` needs
                                  # expectedType — Green has no name
                                  # to look up unless something ambient
                                  # says which field it is filling.
    distinctNames*: HashSet[string]   # distinct types: nominal, never widened
    fnSigNames*: HashSet[string]      # `fnsig NAME` — named function-signature types
    fnDecls*: Table[string, seq[Decl]]
      ## The DECLARATIONS behind each fnSigs entry, so a resolved call can be
      ## recorded as an edge to one (resolution.resolveTo). A LIST for the
      ## same reason fnSigs is: an object member and a top-level fn may share
      ## a name, and keeping one evicted the other — the uninit-field analysis
      ## then scanned the WRONG body and rejected correct code ("'peek' reads
      ## field 'b'" when the top-level `peek` reads only `a`).
    typeDeclsByName*: Table[string, Decl]  # same, for type declarations: lets a
                                      # tkNamed reference be resolved to the
                                      # decl it names instead of carrying only
                                      # the name into later passes
    ifaceDecls*: Table[string, Decl]  # `interface NAME` (spec §5.2). Kept apart
                                      # from typeDeclsByName because an
                                      # interface is NOT a type: it has no size
                                      # and nothing is ever an instance of one.
    bareOwnerOf*: Table[string, string]
                                      ## imported name -> the module it came
                                      ## from, so a bound can be resolved in
                                      ## the namespace of the module that
                                      ## declares the bounded fn
    ambiguousImports*: Table[string, seq[string]]
                                      ## A name exported by more than one
                                      ## import. It is reachable only as
                                      ## `mod::name`; writing it bare is the
                                      ## error, and it is reported where it is
                                      ## written rather than at the import.
    groupBoundsOf*: Table[string, seq[seq[Type]]]
                                      ## fn name -> its generic params' group
                                      ## bounds, parallel to the signature's
                                      ## `generics`. Kept beside fnSigs rather
                                      ## than read off the declaration because
                                      ## a call to a generic fn in ANOTHER
                                      ## module has no declaration here — and
                                      ## that is the call a stdlib is made of.
    groupDecls*: Table[string, Decl]  # `group NAME` (spec §5.5). Separate
                                      # from ifaceDecls even though both hold
                                      # a body-less requirement list: a group
                                      # is looked up when a generic type
                                      # parameter is bound (`[T: Sortable]`),
                                      # never when an object declares
                                      # `satisfies` — different callers, at a
                                      # different pipeline stage, and mixing
                                      # the two tables would let a `satisfies
                                      # SomeGroup` or a `[T: SomeInterface]`
                                      # silently resolve instead of failing
                                      # with a message naming the mistake.
    objDecls*: Table[string, Decl]    # `object NAME` — to answer "does this
                                      # object declare `satisfies I`" at a call
                                      # site without rescanning the decl list
    taskNames*: HashSet[string]       # `task` decls. A bare task call is a
                                      # fire-and-forget SPAWN (spec §9.2) —
                                      # binding it is what awaits a result —
                                      # so dropping its value is the point,
                                      # not an oversight to report.
    topLevelFns*: HashSet[string]     # plain top-level `fn` decls: the only
                                      # callees lowering explodes payloads for
                                      # (tasks and member fns are the backends')
    objectMemberFns*: HashSet[string]
      ## Fn names declared INSIDE a `type` or `object` body. Distinct from
      ## "not top-level": a mixin/extern/pending member is collected with
      ## top = false too, but it becomes a free fn in every backend, so it is
      ## not one of these. Used to tell a group's legal provider (a free fn)
      ## from an object's own member, which belongs to the interface/satisfies
      ## mechanism instead.
    topLevelFnDecl*: Table[string, Decl]
      ## The top-level decl ITSELF for each name in topLevelFns. Needed
      ## because that set holds NAMES: when an object member and a top-level
      ## fn share one, `d.name in topLevelFns` is true of both decls and
      ## cannot tell them apart. Same shape of mistake as the name-keyed
      ## narrowing noted below.
    knownModules*: HashSet[string]    # imported modules + qualified-pending prefixes
    currentErrTypes*: seq[string]     # [error: A | B] of the fn being checked
    # Narrowing (`if r.ok:`) used to live here as a HashSet[string] keyed by
    # bare name. It moved ONTO Binding, because two bindings can share a name:
    # an inner `let r` inherited the outer's narrowing and read `.value` off an
    # unhandled wrapper. See Binding.narrowed and setNarrowed/isNarrowed.
    varErrTypes*: Table[string, seq[string]]  # result vars -> the declared
                                      # [error: ...] enums of the fn that
                                      # produced them (match r.err typing)
    loopDepth*: int               # break/continue legality (innermost loop only)
    varVariants*: Table[string, seq[string]]  # spec 4.4b: per-var possible-
                                      # variant SET for transitions-declared
                                      # types (Type@Variant). Forked/unioned
                                      # at branches; reassignments checked
                                      # against the transition table.
    shadowedVariants*: seq[seq[tuple[name: string, prev: seq[string],
                                     had: bool]]]
      ## Undo log for varVariants, one frame per open scope. Because
      ## varVariants is name-keyed, an inner binding overwrites an outer one's
      ## entry; this remembers what was there so popScope can put it back.
      ## `had` distinguishes "the outer had no entry" from "the outer had an
      ## empty one" — deleting and restoring-empty are different states.
      ##
      ## WHY NOT ON `Binding`, where narrowing lives. Considered and rejected
      ## 2026-08-14. Narrowing is a bool with no join, so it moved cleanly.
      ## Variant state has a real one: the three join sites snapshot and
      ## restore the WHOLE table (`tc.varVariants = entryVariants`) and merge
      ## with mergeVariants, which is three readable lines. Per-binding state
      ## would turn each of those into a scope-stack walk — a bigger, subtler
      ## diff at exactly the places merge bugs live, to delete this log. The
      ## log is the cheaper correct answer; leave it.

proc addFnDecl*(tc: var TypeChecker, name: string, d: Decl) =
  ## Record one declaration under `name`, keeping any already there.
  if tc.fnDecls.hasKey(name): tc.fnDecls[name].add(d)
  else: tc.fnDecls[name] = @[d]

proc externFnNames*(tc: TypeChecker): HashSet[string] =
  ## Every extern fn the program declares, by the name the source uses.
  for name, ds in tc.fnDecls:
    for d in ds:
      if d != nil and d.kind == dkFn and d.isExtern: result.incl name

proc declOfFn*(tc: TypeChecker, name: string): Decl =
  ## The declaration for `name` when the caller has no way to choose — the
  ## last registered, matching what the flat table held. nil when unknown.
  if not tc.fnDecls.hasKey(name) or tc.fnDecls[name].len == 0: return nil
  tc.fnDecls[name][^1]

proc topLevelDeclOfFn*(tc: TypeChecker, name: string): Decl =
  ## The TOP-LEVEL fn named `name`, preferred over an object member of the
  ## same name. A call written `{r: x} peek` names the free fn; a member is
  ## reached through a receiver and is not what this call resolves to.
  ## Falls back to whatever is registered when there is no top-level one.
  if tc.topLevelFnDecl.hasKey(name): return tc.topLevelFnDecl[name]
  if not tc.fnDecls.hasKey(name): return nil
  tc.declOfFn(name)

proc addFnSig*(tc: var TypeChecker, name: string, sig: FnSig) =
  ## Register one signature under `name`, keeping any already there. A second
  ## `hash` does not evict the first — that eviction WAS the bug.
  if tc.fnSigs.hasKey(name): tc.fnSigs[name].add(sig)
  else: tc.fnSigs[name] = @[sig]

proc setFnSig*(tc: var TypeChecker, name: string, sig: FnSig) =
  ## Register `name` as having exactly this signature, discarding any others.
  ## For entries that genuinely have one meaning — a pool's generated
  ## `.acquire`/`.release`, a `fnsig` type — where a second registration is a
  ## re-registration rather than an overload.
  tc.fnSigs[name] = @[sig]

proc sigOf*(tc: TypeChecker, name: string): FnSig =
  ## The signature for `name` when the caller has no receiver to choose by.
  ## Answers with the LAST registered, which is exactly what the old flat
  ## table held after the same sequence of writes — so every site that cannot
  ## know a receiver keeps its current behaviour.
  tc.fnSigs[name][^1]

proc sigOfCallByName*(tc: TypeChecker, name: string): FnSig =
  ## The signature for a call that NAMES a fn (`{r: x} peek`) rather than
  ## reaching one through a receiver. Prefers the top-level fn, since that is
  ## what such a call resolves to — an object member sharing the name is
  ## reached only via a receiver, and picking it demanded a `self` the caller
  ## had no reason to pass. Derived from the decl itself rather than by index,
  ## so it cannot drift out of step with fnSigs' own ordering.
  let d = tc.topLevelDeclOfFn(name)
  if d != nil and d.kind == dkFn:
    return (d.fnParams, d.fnReturnType, d.fnGenerics, d.fnEffects,
            d.fnResourceKinds)
  tc.sigOf(name)

proc sigsOf*(tc: TypeChecker, name: string): seq[FnSig] =
  ## Every signature declared under `name`.
  if tc.fnSigs.hasKey(name): tc.fnSigs[name] else: @[]

proc pushScope*(tc: var TypeChecker) =
  tc.scopes.add(initTable[string, Binding]())
  tc.shadowedVariants.add(@[])

proc popScope*(tc: var TypeChecker) =
  ## Dropping a scope undoes the variant state of everything it BOUND.
  ##
  ## varVariants is keyed by bare NAME, so an inner `var s` overwrites the
  ## outer `s`'s entry. Without this, the inner one's state outlived its scope
  ## and merged into the outer at the enclosing branch join — widening
  ## `{Running}` to `{Idle|Running}` and REJECTING a declared, legal edge.
  ##
  ## Only names this scope actually REBOUND are touched (bindName records
  ## them), so a scope that merely reads or reassigns an outer var leaves its
  ## state alone — which is what keeps branch merging working.
  if tc.scopes.len == 0: return
  discard tc.scopes.pop()
  if tc.shadowedVariants.len > 0:
    for (name, prev, had) in tc.shadowedVariants.pop():
      if had: tc.varVariants[name] = prev
      else: tc.varVariants.del(name)

proc bindName*(tc: var TypeChecker, name: string, typ: Type, isVar: bool,
               isParam = false, span = Span(), site: Expr = nil) =
  ## A fresh binding is never narrowed: guarding is something that happens to
  ## a result AFTER it is bound, and a new binding of the same name is a
  ## different result.
  # Record what this name's variant state was before the binding shadowed it,
  # once per scope — the FIRST bind is the one that shadowed an outer entry.
  if tc.shadowedVariants.len > 0 and not tc.scopes[^1].hasKey(name):
    let had = tc.varVariants.hasKey(name)
    tc.shadowedVariants[^1].add((name,
                                 (if had: tc.varVariants[name] else: @[]), had))
  tc.scopes[^1][name] = (typ, isVar, isParam, false, false, false, span, site)

proc setNarrowed*(tc: var TypeChecker, name: string, on: bool) =
  ## Mark the INNERMOST binding of `name` as guarded, or unmark it. Walks the
  ## same way `lookup` does, so the binding that gets marked is the one a read
  ## would resolve to.
  for i in countdown(tc.scopes.high, 0):
    if tc.scopes[i].hasKey(name):
      tc.scopes[i][name].narrowed = on
      return

proc markUsed*(tc: var TypeChecker, name: string) =
  ## This binding was READ. A wrapper that is never read is never handled —
  ## see `unhandledBindings`. Reading covers every legitimate answer: guarding
  ## it, passing it on, returning it, storing it. Only ignoring it entirely is
  ## left, which is what the rule is for.
  for i in countdown(tc.scopes.high, 0):
    if tc.scopes[i].hasKey(name):
      tc.scopes[i][name].used = true
      return

proc markErrSeen*(tc: var TypeChecker, name: string) =
  ## The ERROR dimension of this binding was answered — `.err` was read, or
  ## the whole value was passed on, returned or discarded. Distinct from
  ## `used`: on a `!?T`, `if r.ok:` answers PRESENCE and leaves the error
  ## question open, which is the one that must not vanish.
  for i in countdown(tc.scopes.high, 0):
    if tc.scopes[i].hasKey(name):
      tc.scopes[i][name].errSeen = true
      return

proc unansweredErrors*(tc: TypeChecker): seq[(string, Span, Expr)] =
  ## `!?T` bindings whose ERROR was never answered.
  ##
  ## Only `!?`. A plain `!T` is left alone deliberately: there `not r.ok` can
  ## only mean "it errored", so guarding IS seeing the error path, which is
  ## what spec 4.9 rules. A `?T` carries no error at all. `!?T` is the one
  ## type where the two questions come apart, and where `if r.ok:` answers
  ## the benign one while the dangerous one disappears.
  if tc.scopes.len == 0: return
  for name, b in tc.scopes[^1]:
    if b.isParam or b.errSeen or b.typ == nil: continue
    if isBangQuestion(b.typ): result.add((name, b.span, b.site))

proc unhandledBindings*(tc: TypeChecker): seq[(string, Span)] =
  ## Wrapper-typed bindings in the innermost scope that were never read.
  ##
  ## `let r = {n: 1} find` and then nothing: a `?T` DROPPED in statement
  ## position was already an error, and keeping it and ignoring it was not —
  ## which is the shape that forgets to check whether a pool handed out a
  ## slot, on the exhaustion path nobody tests.
  ##
  ## Params are exempt: a `?T` parameter the callee never reads is a value
  ## the CALLER chose to pass, and refusing it would break passing a payload
  ## straight through.
  if tc.scopes.len == 0: return
  for name, b in tc.scopes[^1]:
    if b.isParam or b.used or b.typ == nil: continue
    if isWrapper(b.typ): result.add((name, b.span))

proc isNarrowed*(tc: TypeChecker, name: string): bool =
  ## Has the innermost binding of `name` been guarded?
  for i in countdown(tc.scopes.high, 0):
    if tc.scopes[i].hasKey(name):
      return tc.scopes[i][name].narrowed
  false

proc filled*(t: Type, field: string): Type =
  ## `t` with the marker off `field`, or off every field when `field` is "".
  ## Exported for asWithCall, which fills holes the same way a write does.
  if t == nil or t.kind != tkRecord: return t
  var fs: seq[FieldDef]
  for f in t.fields:
    if field == "" or f.name == field:
      fs.add(FieldDef(name: f.name, typ: unwrapUninit(f.typ), span: f.span))
    else: fs.add(f)
  Type(span: t.span, kind: tkRecord, fields: fs)

proc clearUninit*(tc: var TypeChecker, name: string, field = "") =
  ## A write filled one of `name`'s holes — rebuild its type without the
  ## marker. An empty `field` clears every one, which no caller does today:
  ## a mutator clears the fields its body provably assigns, one call per
  ## field (see mutatorFillsFields).
  ##
  ## No-op unless the binding's type is a record, so every write path can call
  ## this without first asking whether the feature applies.
  for i in countdown(tc.scopes.high, 0):
    if tc.scopes[i].hasKey(name):
      tc.scopes[i][name].typ = filled(tc.scopes[i][name].typ, field)
      return

proc resolvesToOwnerField*(tc: TypeChecker, name: string): bool =
  ## Does a bare `name` read the enclosing owner's field? Only if the
  ## innermost scope holding it is the one the owner's fields were bound in:
  ## a param or a `let` of the same name, bound inside that, wins.
  if tc.ownerFieldScope == 0 or name == "self": return false
  for i in countdown(tc.scopes.high, 0):
    if tc.scopes[i].hasKey(name): return i == tc.ownerFieldScope - 1
  false

template withOwnerFields*(tc: var TypeChecker, body: untyped) =
  ## Run `body` with the innermost scope as the one holding the owner's
  ## fields, restoring the enclosing owner's (if any) afterwards.
  let savedOwner = tc.ownerFieldScope
  tc.ownerFieldScope = tc.scopes.len
  body
  tc.ownerFieldScope = savedOwner

proc lookup*(tc: TypeChecker, name: string): tuple[found: bool, b: Binding] =
  for i in countdown(tc.scopes.high, 0):
    if tc.scopes[i].hasKey(name):
      return (true, tc.scopes[i][name])
  return (false, (Type(nil), false, false, false, false, false, Span(), nil))

# Resolve a named type to its declared body (aliases, one level at a time).
proc resolve*(tc: TypeChecker, t: Type, depth = 0): Type =
  if t == nil or depth > 10: return t
  if t.kind == tkNamed and tc.typeDecls.hasKey(t.name):
    return tc.resolve(tc.typeDecls[t.name], depth + 1)
  return t

# Field list of a type, resolving named/union/rename via lowering's helper.
# `Box[int]` resolves through the generic decl with T substituted.
proc actorDeclOf(tc: TypeChecker, name: string): Decl =
  ## The actor declaration named `name`, if one is in scope. Actors are
  ## nominal like objects but are NOT in objDecls: that table also gates
  ## `{...} Name` construction and `satisfies` lookup, neither of which
  ## applies to a singleton actor — this stays a field-lookup-only path.
  tc.module.findDecl(dkActor, name)

proc fieldsOf*(tc: TypeChecker, t: Type): seq[FieldDef] =
  if t == nil: return @[]
  if t.kind == tkNamed and tc.objDecls.hasKey(t.name):
    return composedFields(tc.module, tc.objDecls[t.name])
  if t.kind == tkNamed:
    let ad = tc.actorDeclOf(t.name)
    if ad != nil: return composedFields(tc.module, ad)
  if t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
     tc.typeGenerics.hasKey(t.base.name) and
     tc.typeGenerics[t.base.name].len == t.args.len:
    var b = initTable[string, Type]()
    let gs = tc.typeGenerics[t.base.name]
    for i in 0 ..< gs.len: b[gs[i]] = t.args[i]
    let body = tc.typeDecls[t.base.name]
    for f in getFieldsForType(semLayer, tc.module, body):
      result.add(FieldDef(name: f.name, typ: substituteType(f.typ, b), span: f.span))
    return
  getFieldsForType(semLayer, tc.module, t)
