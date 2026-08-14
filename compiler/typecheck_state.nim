# compiler/typecheck_state.nim
#
# The type checker's shared state: the TypeChecker object plus the scope stack
# and the small operations that read/resolve it (bind/lookup, alias resolution,
# field lists). The synthesis, flow, and validation modules all operate on a
# `var TypeChecker` threaded through their signatures, so this type and its core
# operations live here for them to import.
import ast, lowering, tables, sets
import typecheck_util

type
  Binding* = tuple[typ: Type, isVar: bool, isParam: bool, narrowed: bool]
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
                 effects: seq[EffectMarker]]
  TypeChecker* = object
    module*: Module
    fnSigs*: Table[string, FnSig]
    typeDecls*: Table[string, Type]
    typeGenerics*: Table[string, seq[string]]  # generic type decls: Box -> @["T"]
    currentGenerics*: HashSet[string]          # type params of the fn body being checked
    scopes*: seq[Table[string, Binding]]
    currentRet*: Type
    currentFn*: string
    pendingFns*: Table[string, Span]
    implementedFns*: HashSet[string]
    errPolicy*: string            # strict (default) | continue | exit
    unhandledSites*: seq[string]  # strict: error list; continue/exit: SHORTCUTS
    bodyBlock*: Expr              # current fn's outermost block: its last stmt
                                  # is the implicit return, not a discard
    transitionCtx*: bool          # constructing THROUGH transitionTo: sealed
                                  # non-initial variants are legal there
    distinctNames*: HashSet[string]   # distinct types: nominal, never widened
    fnSigNames*: HashSet[string]      # `fnsig NAME` — named function-signature types
    fnDecls*: Table[string, Decl]     # the DECLARATION behind each fnSigs entry,
                                      # so a resolved call can be recorded as an
                                      # edge to it (resolution.resolveTo)
    typeDeclsByName*: Table[string, Decl]  # same, for type declarations: lets a
                                      # tkNamed reference be resolved to the
                                      # decl it names instead of carrying only
                                      # the name into later passes
    ifaceDecls*: Table[string, Decl]  # `interface NAME` (spec §5.2). Kept apart
                                      # from typeDeclsByName because an
                                      # interface is NOT a type: it has no size
                                      # and nothing is ever an instance of one.
    objDecls*: Table[string, Decl]    # `object NAME` — to answer "does this
                                      # object declare `satisfies I`" at a call
                                      # site without rescanning the decl list
    topLevelFns*: HashSet[string]     # plain top-level `fn` decls: the only
                                      # callees lowering explodes payloads for
                                      # (tasks and member fns are the backends')
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
               isParam = false) =
  ## A fresh binding is never narrowed: guarding is something that happens to
  ## a result AFTER it is bound, and a new binding of the same name is a
  ## different result.
  # Record what this name's variant state was before the binding shadowed it,
  # once per scope — the FIRST bind is the one that shadowed an outer entry.
  if tc.shadowedVariants.len > 0 and not tc.scopes[^1].hasKey(name):
    let had = tc.varVariants.hasKey(name)
    tc.shadowedVariants[^1].add((name,
                                 (if had: tc.varVariants[name] else: @[]), had))
  tc.scopes[^1][name] = (typ, isVar, isParam, false)

proc setNarrowed*(tc: var TypeChecker, name: string, on: bool) =
  ## Mark the INNERMOST binding of `name` as guarded, or unmark it. Walks the
  ## same way `lookup` does, so the binding that gets marked is the one a read
  ## would resolve to.
  for i in countdown(tc.scopes.high, 0):
    if tc.scopes[i].hasKey(name):
      tc.scopes[i][name].narrowed = on
      return

proc isNarrowed*(tc: TypeChecker, name: string): bool =
  ## Has the innermost binding of `name` been guarded?
  for i in countdown(tc.scopes.high, 0):
    if tc.scopes[i].hasKey(name):
      return tc.scopes[i][name].narrowed
  false

proc retype*(tc: var TypeChecker, name: string, typ: Type) =
  ## Replace the innermost binding's TYPE, keeping its permissions.
  ##
  ## This is how an unsupplied field stops being one: assignment rebuilds the
  ## record type with that field's `<uninit>` marker removed. Storing the
  ## state in the binding rather than a name-keyed table beside it means
  ## shadowing and scope exit are already handled — an inner `let c` has its
  ## own binding with its own type, and it dies with its scope.
  for i in countdown(tc.scopes.high, 0):
    if tc.scopes[i].hasKey(name):
      tc.scopes[i][name].typ = typ
      return

proc filled(t: Type, field: string): Type =
  ## `t` with the marker off `field`, or off every field when `field` is "".
  if t == nil or t.kind != tkRecord: return t
  var fs: seq[FieldDef]
  for f in t.fields:
    if field == "" or f.name == field:
      fs.add(FieldDef(name: f.name, typ: unwrapUninit(f.typ), span: f.span))
    else: fs.add(f)
  Type(span: t.span, kind: tkRecord, fields: fs)

proc clearUninit*(tc: var TypeChecker, name: string, field = "") =
  ## A write filled one of `name`'s holes — rebuild its type without the
  ## marker. An empty `field` clears them ALL, which is what a `..fn` mutator
  ## does: it may write anything and the checker only sees its return type, so
  ## the permissive answer is the useful one (a missed hole beats refusing a
  ## working builder).
  ##
  ## No-op unless the binding's type is a record, so every write path can call
  ## this without first asking whether the feature applies.
  for i in countdown(tc.scopes.high, 0):
    if tc.scopes[i].hasKey(name):
      tc.scopes[i][name].typ = filled(tc.scopes[i][name].typ, field)
      return

proc lookup*(tc: TypeChecker, name: string): tuple[found: bool, b: Binding] =
  for i in countdown(tc.scopes.high, 0):
    if tc.scopes[i].hasKey(name):
      return (true, tc.scopes[i][name])
  return (false, (Type(nil), false, false, false))

# Resolve a named type to its declared body (aliases, one level at a time).
proc resolve*(tc: TypeChecker, t: Type, depth = 0): Type =
  if t == nil or depth > 10: return t
  if t.kind == tkNamed and tc.typeDecls.hasKey(t.name):
    return tc.resolve(tc.typeDecls[t.name], depth + 1)
  return t

# Field list of a type, resolving named/union/rename via lowering's helper.
# `Box[int]` resolves through the generic decl with T substituted.
proc fieldsOf*(tc: TypeChecker, t: Type): seq[FieldDef] =
  if t == nil: return @[]
  if t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
     tc.typeGenerics.hasKey(t.base.name) and
     tc.typeGenerics[t.base.name].len == t.args.len:
    var b = initTable[string, Type]()
    let gs = tc.typeGenerics[t.base.name]
    for i in 0 ..< gs.len: b[gs[i]] = t.args[i]
    let body = tc.typeDecls[t.base.name]
    for f in getFieldsForType(tc.module, body):
      result.add(FieldDef(name: f.name, typ: substituteType(f.typ, b), span: f.span))
    return
  getFieldsForType(tc.module, t)
