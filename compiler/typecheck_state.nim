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
  Binding* = tuple[typ: Type, isVar: bool]
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
    topLevelFns*: HashSet[string]     # plain top-level `fn` decls: the only
                                      # callees lowering explodes payloads for
                                      # (tasks and member fns are the backends')
    knownModules*: HashSet[string]    # imported modules + qualified-pending prefixes
    currentErrTypes*: seq[string]     # [error: A | B] of the fn being checked
    okNarrowed*: HashSet[string]      # results guarded by `if x.ok` in scope:
                                      # .value is legal only under the guard
    varErrTypes*: Table[string, seq[string]]  # result vars -> the declared
                                      # [error: ...] enums of the fn that
                                      # produced them (match r.err typing)
    loopDepth*: int               # break/continue legality (innermost loop only)
    varVariants*: Table[string, seq[string]]  # spec 4.4b: per-var possible-
                                      # variant SET for transitions-declared
                                      # types (Type@Variant). Forked/unioned
                                      # at branches; reassignments checked
                                      # against the transition table.

proc pushScope*(tc: var TypeChecker) = tc.scopes.add(initTable[string, Binding]())
proc popScope*(tc: var TypeChecker) = discard tc.scopes.pop()

proc bindName*(tc: var TypeChecker, name: string, typ: Type, isVar: bool) =
  tc.scopes[^1][name] = (typ, isVar)

proc lookup*(tc: TypeChecker, name: string): tuple[found: bool, b: Binding] =
  for i in countdown(tc.scopes.high, 0):
    if tc.scopes[i].hasKey(name):
      return (true, tc.scopes[i][name])
  return (false, (Type(nil), false))

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
