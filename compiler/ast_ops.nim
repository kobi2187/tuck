# compiler/ast_ops.nim
#
# Operations over the AST types (ast.nim's type block itself cannot split
# further — Expr/Decl/Type/Pattern are mutually recursive `ref object`s,
# and Nim requires mutually-recursive types to live in one `type` section).
# Everything here — the children/childDecls/ownTypes/ownExprs iterators,
# assignIds/clearIds, effectName, enumDomain, writtenName — operates ON
# those types from outside, so it moves freely. Re-exported by ast.nim so
# existing `import ast` call sites see no difference.
import tables, options, hashes
import ast

func effectName*(e: EffectMarker): string =
  ## How a marker is SPELLED IN SOURCE — what the author writes in the
  ## bracket, and therefore the only spelling a diagnostic may print.
  ##
  ## Two call sites used to derive this mechanically from the enum name
  ## (`($e)[2..^1].toLowerAscii`, `($e).replace("em","").toLowerAscii`), which
  ## silently drops the underscore: `[may_block]` was reported as
  ## `[mayblock]`, a word that appears nowhere in the language, so a reader
  ## could not search for it. `no_alloc` and `irq_safe` had it too.
  ##
  ## Spelled out rather than derived: the case is exhaustive, so a new marker
  ## fails to compile here until someone states its source spelling — which is
  ## the whole reason a mechanical derivation was the wrong tool.
  case e
  of emIo: "io"
  of emNoAlloc: "no_alloc"
  of emIrqSafe: "irq_safe"
  of emUnsafe: "unsafe"
  of emMayBlock: "may_block"
  of emStack: "stack"
  of emPriority: "priority"

proc enumDomain*(m: Module, t: Type): seq[string] =
  ## Values of an enumerable decision-table column: bool, or a fieldless sum
  ## type declared in the module. Empty result = not enumerable (open domain).
  if t == nil: return @[]
  if t.kind == tkNamed:
    if t.name == "bool": return @["false", "true"]
    for d in m.decls:
      if d.kind == dkType and d.name == t.name and d.typeBody != nil and
         d.typeBody.kind == tkSum:
        var vals: seq[string]
        for v in d.typeBody.variants:
          if v.fields.len > 0: return @[]  # payload variants: not a flat enum
          vals.add(v.name)
        return vals
  return @[]

# --- SourceName: the name the user wrote -----------------------------------

proc writtenName*(e: Expr): string =
  ## What the user wrote for this expression's name. Use it for anything the
  ## user sees or that must be stable across backends — never for an emitted
  ## identifier, which has to stay mangled. Only exkVar carries a name.
  if e == nil or e.kind != exkVar: return ""
  if e.sourceName.isSome: e.sourceName.get else: e.name

proc writtenName*(d: Decl): string =
  ## What the user wrote for this declaration's name. See the Expr overload.
  if d == nil: return ""
  if d.sourceName.isSome: d.sourceName.get else: d.name

# --- NodeId: identity for the semantic layer -------------------------------
# `==`/hash/`$` stay in ast.nim, next to NodeId's own declaration.

proc isSet*(a: NodeId): bool = uint32(a) != 0'u32

iterator children*(t: Type): Type =
  ## Every type one level down. The Type half of `children(Expr)`, and it
  ## exists for the same reason: this walk was hand-rolled in eight files, and
  ## the copies had already diverged — mangleType ended in `else: discard`
  ## while resolveTypeRefs listed tkEffect explicitly. Latent rather than live,
  ## since nothing constructs a tkEffect today, but that is exactly the kind of
  ## drift a shared iterator makes impossible.
  ##
  ## Exhaustive on purpose: a new TypeKind must be listed here or this stops
  ## compiling.
  ##
  ## Field and variant NAMES are not yielded — they are not types. A caller
  ## that needs them (codegen emitting a record) walks `fields` itself; this
  ## iterator answers "what types does this type refer to".
  if t != nil:
    case t.kind
    of tkNamed: discard
    of tkApp:
      yield t.base
      for a in t.args: yield a
    of tkTuple:
      for e in t.elems: yield e
    of tkFunc:
      for p in t.params: yield p
      yield t.result
    of tkRecord:
      for f in t.fields: yield f.typ
    of tkSum:
      for v in t.variants:
        for f in v.fields: yield f.typ
    of tkUnion:
      for mem in t.members: yield mem
    of tkEffect: yield t.inner
    of tkRename: yield t.underlying

iterator children*(e: Expr): Expr =
  ## Every sub-expression, one level down. For the walks that only need to
  ## VISIT nodes rather than rewrite them — the traversal is the boilerplate,
  ## and assignIds/clearIds already hand-roll it twice because they mutate.
  ##
  ## The case is exhaustive on purpose: a new ExprKind must be listed here or
  ## the compiler refuses, which is what stops a walk from silently missing a
  ## node and reporting a clean result over a subtree it never looked at.
  ##
  ## No `skip: set[ExprKind]` parameter, deliberately. It would be two lines,
  ## but every caller today wants the whole tree, and every bug this iterator
  ## replaced came from a walk that CHOSE which kinds to visit
  ## (raisedEventsIn, scanReturns, mentionsName, synthesizeExpr — four silent
  ## gaps, all the same shape). A skip set hands that choice back.
  ##
  ## The two callers that really do treat a kind differently — mangleExpr's
  ## scoping arms, lowerExpr's bracket nodes — do not merely skip it, they do
  ## something ELSE with it, which is an explicit `case` arm before the walk
  ## and not something a skip set could express. Add the parameter when a
  ## caller wants plain omission and can be named in this comment.
  if e != nil:
    case e.kind
    of exkLit, exkVar, exkQualified, exkImport, exkBreak, exkContinue,
       exkActorRef, exkRegisterRef, exkRegistryRef, exkPoolRef, exkMixinRef:
      discard
    of exkField:
      yield e.receiver
      yield e.dotArg
    of exkStruct:
      for f in e.fields: yield f.value
    of exkList:
      for it in e.items: yield it
    of exkBracket:
      yield e.brReceiver
      for a in e.brArgs: yield a
    of exkBracketAssign:
      yield e.brTarget
      yield e.brValue
    of exkCall:
      yield e.callee
      for a in e.args: yield a
    of exkChain:
      yield e.base
      for s in e.steps:
        yield s.target
        yield s.arg
    of exkBinary:
      yield e.left
      yield e.right
    of exkUnary: yield e.operand
    of exkBlock:
      for s in e.stmts: yield s
    of exkIf:
      yield e.cond
      yield e.thenBranch
      yield e.elseBranch
    of exkMatch:
      yield e.subject
      for arm in e.arms:
        yield arm.guard
        yield arm.body
    of exkFor:
      yield e.iterable
      yield e.body
    of exkWhile:
      yield e.whileCond
      yield e.whileBody
    of exkAssign:
      yield e.target
      yield e.assignVal
    of exkReturn: yield e.returnVal
    of exkRaise: yield e.raiseVal
    of exkDiscard: yield e.discardVal
    of exkSend: yield e.sendPayload
    of exkSelect:
      for arm in e.selArms:
        yield arm.arg
        yield arm.body

iterator childDecls*(d: Decl): Decl =
  ## Every declaration nested one level inside `d`, whichever field holds it.
  ##
  ## The Decl half of `children(Expr)`, and it exists for the same reason: the
  ## traversal is boilerplate, and assignIds/clearIds hand-rolled it twice —
  ## identical arms differing only in the action. A walk that lists kinds by
  ## hand is a walk that can silently miss one.
  ##
  ## Exhaustive on purpose. A new DeclKind must be listed here or this stops
  ## compiling, which is the whole guarantee.
  ##
  ## NOT the same as ast_query.members: that one is the API for "what is
  ## declared inside this thing" and deliberately excludes a `when` block's
  ## body (resolved away before checking) and a select arm's. This one is the
  ## TRAVERSAL — everything an id-assigning or id-clearing walk must reach.
  if d != nil:
    case d.kind
    of dkType:
      for m in d.typeMembers: yield m
    of dkObject:
      for m in d.objMembers: yield m
    of dkMixin, dkExtern, dkPending:
      for m in d.mixinMembers: yield m
    of dkWhen:
      for m in d.whenDecls: yield m
    of dkInterface:
      for m in d.ifaceMembers: yield m
    of dkActor:
      for h in d.handlers: yield h
    of dkFn, dkTask, dkConst, dkExpr, dkStaticAssert, dkSelect, dkRegistry,
       dkPool, dkRegister, dkErrors, dkImport, dkFnSig, dkSatisfies:
      discard

iterator ownTypes*(d: Decl): Type =
  ## Every type this declaration mentions DIRECTLY — its fields' types, its
  ## params and return, a pool's element type. Not its members' (walk
  ## childDecls for those) and not the types nested inside these (walk
  ## children(Type)).
  ##
  ## The third of the four iterators that together cover a Decl:
  ## childDecls / ownExprs / ownTypes, plus children(Type) beneath. Written
  ## once because resolveDeclTypeRefs and mangleDeclTypes were the same list
  ## of field accesses with a different action.
  if d != nil:
    case d.kind
    of dkFn:
      for p in d.fnParams: yield p.typ
      yield d.fnReturnType
    of dkTask:
      for p in d.taskParams: yield p.typ
      yield d.taskReturnType
    of dkFnSig:
      for p in d.sigParams: yield p.typ
      yield d.sigReturn
    of dkType: yield d.typeBody
    of dkObject:
      for f in d.objFields: yield f.typ
    of dkActor:
      for f in d.actorFields: yield f.typ
    of dkPool: yield d.poolElem
    of dkRegistry:
      for v in d.variants:
        for f in v.fields: yield f.typ
    # Nothing to yield. dkRegister's fields are `bit N` ranges, never a
    # user-named type; dkExpr/dkConst/dkStaticAssert carry expressions whose
    # types the expression walk reaches; dkErrors a policy name; dkImport a
    # module path; dkSelect arm bodies; dkSatisfies interface NAMES, resolved
    # by conformance. dkMixin/dkExtern/dkPending/dkInterface/dkWhen hold only
    # members — childDecls reaches those.
    of dkRegister, dkExpr, dkConst, dkStaticAssert, dkErrors, dkImport,
       dkSelect, dkSatisfies, dkMixin, dkExtern, dkPending, dkInterface,
       dkWhen:
      discard

iterator ownExprs*(d: Decl): Expr =
  ## Every expression this declaration owns directly — its body, initializer or
  ## arm bodies. Paired with `childDecls`, these two reach everything under a
  ## Decl, which is what an id walk needs.
  ##
  ## dkSelect is here rather than in childDecls because a select arm holds an
  ## Expr body, not a nested declaration.
  if d != nil:
    case d.kind
    of dkFn: yield d.fnBody
    of dkTask: yield d.taskBody
    of dkConst: yield d.constVal
    of dkExpr: yield d.expr
    of dkStaticAssert: yield d.assertExpr
    of dkSelect:
      for arm in d.selectArms: yield arm.body
    of dkType, dkObject, dkMixin, dkExtern, dkPending, dkWhen, dkInterface,
       dkActor, dkRegistry, dkPool, dkRegister, dkErrors, dkImport, dkFnSig,
       dkSatisfies:
      discard

proc assignIds*(e: Expr, next: var uint32) =
  ## Give every node in this tree an id. Idempotent: a node that already has
  ## one keeps it, so re-running over a partly-built tree is safe.
  ##
  ## The traversal is `children`; only exkChain needs an arm of its own,
  ## because a ChainStep carries its OWN id and is not an Expr, so the
  ## iterator cannot yield it. This used to list all 21 kinds, which is the
  ## same walk `children` exists to stop people writing.
  if e == nil: return
  if not e.id.isSet:
    next.inc
    e.id = NodeId(next)
  if e.kind == exkChain:
    for s in e.steps.mitems:
      if not s.id.isSet:
        next.inc
        s.id = NodeId(next)
  for c in e.children: assignIds(c, next)

proc assignIds*(d: Decl, next: var uint32) =
  ## The declaration itself, then every Expr reachable from it.
  ##
  ## The declaration needs its own id so a reference can point AT it: that is
  ## what turns "which decl is named X" from a scan of the decl list into a
  ## table read.
  if d == nil: return
  inc next
  d.id = NodeId(next)
  # The traversal is childDecls + ownExprs. Kinds with neither — dkSatisfies
  # carries only names, dkRegistry only event shapes — fall out of both
  # iterators and need no arm here.
  for e in d.ownExprs: assignIds(e, next)
  for m in d.childDecls: assignIds(m, next)

# The id supply. SINGLE-WRITER: one thread mints ids, which holds today because
# tuck is built --threads:off (tuck.nim pickFastCC — that flag is also what lets
# tcc, the fastest C backend here, build the runtime at all).
#
# If modules are ever parsed/checked in PARALLEL, this is the first thing that
# breaks, and it breaks SILENTLY: two threads racing `inc` hand out the same
# NodeId, and a duplicate id does not crash — it cross-wires the semantic layer,
# so one node reads another's type or resolved call. Two ways out, both cheap:
#
#   - RANGE-PARTITION: give thread N the id space N shl 24. Collision becomes
#     impossible by construction, NodeId stays 4 bytes.
#   - ATOMIC: fetchAdd on the counter. Simplest, but needs --threads:on.
#
# NOT a UUID. NodeId is a Table key on the compiler's hottest path (codegen
# alone does ~68 semLayer lookups), so 16-byte keys would cost 4x the key width
# and slower hashing to solve a problem partitioning solves for free.
var globalNodeCounter: uint32 = 0

proc assignIds*(m: var Module) =
  ## Give the whole module's expressions their ids. Runs once, right after
  ## parsing, so the semantic layer has a stable key for every source node.
  ##
  ## The counter is PROGRAM-wide, not per-module: a build checks and emits
  ## several modules, and the Resolution table spans all of them, so ids
  ## must not collide across modules.
  for d in m.decls: assignIds(d, globalNodeCounter)

proc clearIds*(e: Expr) =
  ## Drop ids so assignIds hands out fresh ones. Needed when a module comes
  ## back from the AST cache carrying ids from the run that wrote it.
  ## The traversal is `children` — this used to repeat all 21 arms of it.
  if e == nil: return
  e.id = NodeId(0)
  # A chain STEP carries its own id, which is not an Expr and so is not a
  # child. Everything else is reached by the iterator.
  if e.kind == exkChain:
    for s in e.steps.mitems: s.id = NodeId(0)
  for c in e.children: clearIds(c)

proc clearIds*(d: Decl) =
  if d == nil: return
  for e in d.ownExprs: clearIds(e)
  for m in d.childDecls: clearIds(m)

proc clearIds*(m: var Module) =
  for d in m.decls: clearIds(d)

proc newNodeId*(): NodeId =
  ## For nodes minted AFTER parsing (the checker synthesizes calls). Keeps
  ## the invariant that every node can key into the semantic layer.
  globalNodeCounter.inc
  NodeId(globalNodeCounter)
