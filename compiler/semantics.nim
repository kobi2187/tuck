# compiler/semantics.nim
#
# STAGE 5 OF THE PIPELINE — the effect audit.
#
# An EFFECT is a marker on a function saying what it does besides compute:
# [io] touches the outside world, [may_block] can wait, [no_alloc] promises not
# to allocate. Think of it as a type system for side effects — you can read a
# signature and know whether calling it can print, block, or allocate, without
# opening the body.
#
# The rule this file enforces: a function may only perform effects it declares.
# Call an [io] function from one that never declared [io], and that is an
# error — the caller would be doing IO while its signature promised it did not.
# Effects propagate up the call graph, so the declaration has to as well.
#
# Why it matters for Tuck specifically: the target is embedded work, where
# "does this allocate?" and "can this block?" are the questions that decide
# whether code is usable in an interrupt handler. Better to answer them at
# compile time than to discover it on the device.
#
# ORDERING — THIS IS A REAL CONSTRAINT, NOT A PREFERENCE. This pass must run
# AFTER typecheck.nim, never before. Typechecking resets the shared semantic
# side-table (resolution.nim), so an effect pass that ran first would have all
# of its async call-site marks wiped before codegen ever read them. The
# sequencing lives in `checkOrDie` in tuck.nim, where it is commented.
#
# This kind of hidden inter-pass dependency is common in compilers and almost
# never obvious from the code. When you find one, write it down where the
# ordering is decided.
import ast, ast_ops, tables, sets, strutils, sequtils
import resolution
import ast_query   # memberCallDecl: which member a call reaches
import diagnostics  # TK-RS03, the resource half of the propagation rule

type
  SemanticError* = object of ValueError
    ## An effect or resource-propagation violation, with its source position.
    ## Raised, not collected: the first violation stops the pass.
    line*, col*: int

proc reportError(msg: string, span: Span) =
  ## Raises a `SemanticError` at `span`.
  let err = newException(SemanticError, msg)
  err.line = span.line
  err.col = span.col
  raise err

type
  Demands* = object
    ## What a call site COSTS its caller, and therefore what the caller has to
    ## have declared. Two ledgers rather than one because they are spelled
    ## differently — an effect is a marker from a closed enum, a resource kind
    ## is a user-chosen name — but they are one concept and they propagate by
    ## one rule (spec §3.7: explicit, not inferred), so they ride one walk.
    ##
    ## Kept as a record rather than a second parallel pass: the pass this file
    ## exists for already visits every node exactly once, and a second copy of
    ## that walk is a second chance to miss a node kind — which is the bug
    ## `synthesizeExpr`'s own comment records having had.
    effects*: seq[EffectMarker]
    resources*: seq[string]

  Checker = object
    ## The effect pass's state for one module: what each callable name demands,
    ## the task names, every resource kind the program declares (main's budget),
    ## and the fns being visited (recursion guard).
    module: Module
    declared: Table[string, Demands]
    taskNames: HashSet[string]  # dkTask decl names, built once — see isTask
    everyKind: seq[string]      # every kind the PROGRAM declares — main's budget
    visiting: HashSet[string]
    pendingNames: HashSet[string]  # imported `pending:` stubs — never a restriction violation

proc getDeclared(c: Checker, name: string): Demands =
  ## What calling `name` demands of its caller; nothing for a name this module
  ## neither declares nor imports (locals, builtins).
  if c.declared.hasKey(name):
    return c.declared[name]
  return Demands()

# Bidirectional functions
proc synthesizeExpr(c: var Checker, e: Expr): Demands
proc checkExpr(c: var Checker, e: Expr, expected: Demands,
               currentFn: string): Demands

proc unionEffects(a, b: seq[EffectMarker]): seq[EffectMarker] =
  ## `a` followed by the markers of `b` not already in it — order-preserving,
  ## so messages list effects in a stable order.
  var res = a
  for x in b:
    if x notin res: res.add(x)
  return res

proc union(a, b: Demands): Demands =
  ## Both ledgers of two demands, each merged without duplicates.
  result.effects = unionEffects(a.effects, b.effects)
  result.resources = a.resources
  for k in b.resources:
    if k notin result.resources: result.resources.add(k)

# The effect checker is the same synthesize/check pair as the TYPE checker,
# one level over: synthesizeExpr asks "what effects does this expression
# perform?" and checkExpr asks "are those allowed here?". Reading them side by
# side is the quickest way to see that effects really are a type system, just
# for side effects rather than values.
proc callEffects(c: var Checker, e: Expr, res: var Demands) =
  ## What a CALL adds beyond its subexpressions: the callee's own declared
  ## effects and resource kinds, and the async mark that goes with [io].
  ## A pool operation (the other thing the checker stamps) declares none.
  if e.kind != exkCall: return
  let calleeName = if e.callee != nil and e.callee.kind == exkVar: e.callee.name
                   else: ""
  if calleeName != "":
      # Calling a TASK is a spawn — it decouples the [io] work onto the
      # scheduler, so the task's effects do NOT propagate to the caller and
      # the caller does not suspend here (the yields happen inside the task).
      # taskNames is built once in verifyModuleEffects; scanning c.module.decls
      # here instead would cost one pass per call expression, quadratic over a
      # module (the same mistake lowering's payload explosion made, fixed the
      # same way: record it once where it is already known).
      #
      # A spawned task's RESOURCE kinds do not propagate either, and for a
      # stronger reason than its effects: the handle it acquires never reaches
      # this caller's scope at all, so there is nothing here to finish. The
      # registry is what closes it (§7.4 — escape into the registry is always
      # sound), which is exactly the safety net that makes the caller's local
      # analysis sufficient.
      if calleeName notin c.taskNames:
        # A MEMBER call reaches the member its receiver's type names, which a
        # bare-name lookup cannot find (members are not top-level names) —
        # so an [io] member looked pure to its callers, and a call to it was
        # never marked as a suspend point.
        let member = memberCallDecl(semLayer, c.module, e)
        let callee = if member != nil:
                       Demands(effects: member.fnEffects,
                               resources: member.fnResourceKinds)
                     else: c.getDeclared(calleeName)
        res = union(res, callee)
        # The [io] marker IS the async annotation: a call to an [io] fn is a
        # suspend point. Flag the call site so codegen emits the async transform.
        if emIo in callee.effects:
          semLayer.markAsync(e)

proc synthesizeExpr(c: var Checker, e: Expr): Demands =
  ## Every effect this expression performs, and every resource kind it acquires, gathered from the whole subtree.
  ##
  ## Walks EVERY child via ast.children. It used to list fourteen kinds and
  ## `else: discard`, which skipped exkSend, exkSelect, exkField, exkBracket
  ## and exkBracketAssign — so an [io] call inside a send payload or a select
  ## arm was neither counted against the enclosing fn's declared effects nor
  ## marked async, and an unmarked suspend point is a codegen bug, not just a
  ## missing diagnostic.
  if e == nil: return Demands()
  var res = Demands()
  for child in e.children:
    res = union(res, c.synthesizeExpr(child))
  if e.kind == exkCall: c.callEffects(e, res)
  # A BARE NULLARY CALL is an exkVar the checker stamped with its call — spec
  # 2.3, "a bare name IS a call". It never reached callEffects, so `let x =
  # noisy` in a fn declaring no effects passed clean, and so did every other
  # spelling that is not a literal `{...} f`. The construct was only visible
  # through the verbose `{} noisy`, which IS an exkCall; TK-PA13 removed that
  # spelling from payloads and the hole surfaced immediately.
  elif semLayer.hasCall(e): c.callEffects(semLayer.call(e), res)
  res

proc culpritCall(c: var Checker, e: Expr, eff: EffectMarker):
    tuple[name: string, span: Span] =
  ## The first call in `e` (source order) whose callee carries `eff` — the one
  ## that makes the enclosing fn need it, so the error can point at it rather
  ## than at the whole body.
  for n in e.nodes:
    var d = Demands()
    var call: Expr = nil
    if n.kind == exkCall: call = n
    elif semLayer.hasCall(n): call = semLayer.call(n)
    else: continue
    c.callEffects(call, d)
    if eff in d.effects:
      let name = if call.callee != nil and call.callee.kind == exkVar:
                   call.callee.name
                 else: ""
      return (name, n.span)
  ("", e.span)

proc checkExpr(c: var Checker, e: Expr, expected: Demands,
               currentFn: string): Demands =
  ## Reject any effect this expression performs, or resource kind it acquires,
  ## that `currentFn` did not declare. `expected` is that declaration — an [io]
  ## fn may do IO, a fn with no markers may do none, so an undeclared effect
  ## anywhere in the body is an error naming the function that failed to
  ## declare it. §7.4 asks for the identical rule on `[resource: k]`, and gets
  ## it from the identical code. Returns what the body actually demands, for
  ## the caller that wants to say what a bracket declares in vain.
  if e == nil: return Demands()

  # 1. Synthesize the actual demands bottom-up
  let actual = c.synthesizeExpr(e)
  result = actual

  # 2. Check them top-down against the declared budget. The compiler already
  # knows the whole set that is missing and the call that needs each, so it
  # says what to WRITE, at that call (issue #14: the user declares in the
  # code; the compiler infers and helps).
  var missing: seq[string]
  # Only CAPABILITIES are obligations passed up. A restriction is held from the
  # restricted side (checkRestrictions), and an attribute propagates nowhere;
  # treating them as obligations rejected a plain fn calling a `[no_alloc]` one.
  for eff in actual.effects:
    if familyOf(eff) == mfCapability and eff notin expected.effects:
      missing.add effectName(eff)
  for eff in actual.effects:
    if familyOf(eff) == mfCapability and eff notin expected.effects:
      let (callee, span) = c.culpritCall(e, eff)
      reportError(withCode(dcEfBudget,
        "Expression requires effect [" & effectName(eff) & "], which is " &
        "not allowed in context of '" & currentFn & "'" &
        (if callee != "": " — '" & callee & "' is [" & effectName(eff) & "]"
         else: "") &
        ". Fix: declare [" & missing.join(", ") & "] on '" & currentFn & "'" &
        " (`fn " & currentFn & "(...) -> ... [" & missing.join(", ") & "]:`)" &
        ", or do not call it from there"), span)
  for kind in actual.resources:
    if kind notin expected.resources:
      reportError(withCode(dcRsUndeclared,
        "Expression acquires resource kind '" & kind & "', which '" &
        currentFn & "' does not declare — add `[resource: " & kind &
        "]` to its bracket"), e.span)

proc mayDoIoUnseen(c: Checker, body: Expr): bool =
  ## Does the body do something that suspends or spawns without calling an
  ## `[io]` fn by name? Such a body may legitimately need `[io]` although no
  ## callee declares it, so the unused-effect warning stays quiet for it.
  for n in body.nodes:
    case n.kind
    of exkSelect, exkSend, exkAcquire, exkFinish, exkDefer, exkActorRef,
       exkTripleDot:   # `...` is a stub: its bracket is the contract to come
      return true
    of exkCall:
      if n.callee != nil and n.callee.kind == exkVar and
         n.callee.name in c.taskNames: return true
    else: discard

type
  CalleeKind = enum
    ckUnknown   ## a name this module cannot place (a constructor, a builtin, a
                ## `pending` stub): says nothing, so it is never a violation
    ckTask      ## a spawn: allocates a coroutine and does not run here
    ckFn        ## a declared fn, extern or member with a known marker set

  Callee = object
    kind: CalleeKind
    name: string
    markers: seq[EffectMarker]

proc callOf(n: Expr): Expr =
  ## The call a node stands for: an `exkCall`, or a bare nullary name the
  ## checker stamped with one (spec 2.3, "a bare name IS a call").
  if n.kind == exkCall: n
  elif semLayer.hasCall(n): semLayer.call(n)
  else: nil

proc resolveCallee(c: Checker, call: Expr): Callee =
  ## Who a call reaches and what that callee DECLARES. The restriction rule asks
  ## this of every call in a restricted fn; unlike the capability rule it must
  ## know whether the callee is known at all, so an unplaceable name is
  ## `ckUnknown` rather than "declares nothing".
  if call.kind != exkCall: return Callee(kind: ckUnknown)
  let name = if call.callee != nil and call.callee.kind == exkVar:
               call.callee.name
             else: ""
  if name == "": return Callee(kind: ckUnknown)
  if name in c.taskNames: return Callee(kind: ckTask, name: name)
  let member = memberCallDecl(semLayer, c.module, call)
  if member != nil:
    return Callee(kind: ckFn, name: member.name, markers: member.fnEffects)
  if c.declared.hasKey(name) and name notin c.pendingNames:
    return Callee(kind: ckFn, name: name, markers: c.declared[name].effects)
  Callee(kind: ckUnknown, name: name)

proc restrictionsOf(markers: seq[EffectMarker]): seq[EffectMarker] =
  for m in markers:
    if familyOf(m) == mfRestriction: result.add m

proc failRestriction(fnName: string, r: EffectMarker, callee: Callee, sp: Span) =
  let rn = effectName(r)
  if callee.kind == ckTask:
    reportError(withCode(dcEfRestriction,
      "'" & fnName & "' is [" & rn & "] but spawns task '" & callee.name &
      "', and a spawn is not [" & rn & "]. Fix: do not spawn from a [" & rn &
      "] fn"), sp)
  reportError(withCode(dcEfRestriction,
    "'" & fnName & "' is [" & rn & "] but calls '" & callee.name &
    "', which is not. Fix: declare [" & rn & "] on '" & callee.name &
    "' if that is true (an extern with no marker is not known to be), or do " &
    "not call it from a [" & rn & "] fn"), sp)

proc checkIsrSends(d: Decl) =
  ## TK-EF07: an `irq_safe` fn does not send — the mailbox takes a lock.
  if emIrqSafe notin d.fnEffects or d.fnBody == nil: return
  for n in d.fnBody.nodes:
    if n.kind == exkSend:
      reportError(withCode(dcEfIsrSend,
        "'" & d.name & "' is [irq_safe] but sends to an actor, whose mailbox " &
        "takes a lock an interrupted thread may hold. Fix: set a flag or ring " &
        "buffer that a task drains, or drop [irq_safe]"), n.span)

proc checkRestrictions(c: Checker, d: Decl) =
  ## The restriction call rule (TK-EF03): in a fn declaring `no_alloc`,
  ## `irq_safe` or `pure`, every call must reach a callee that declares it.
  ## A plain fn calling a restricted one is fine — the rule runs from the
  ## restricted side only.
  let restr = restrictionsOf(d.fnEffects)
  if restr.len == 0 or d.fnBody == nil: return
  for n in d.fnBody.nodes:
    let call = callOf(n)
    if call == nil: continue
    let callee = c.resolveCallee(call)
    case callee.kind
    of ckUnknown: discard
    of ckTask: failRestriction(d.name, restr[0], callee, n.span)
    of ckFn:
      for r in restr:
        if r notin callee.markers: failRestriction(d.name, r, callee, n.span)

proc allocatingConstruct(n: Expr): string =
  ## What `n` allocates, or "" if it does not. THE list of allocating syntax
  ## for `[no_alloc]` (TK-EF05): a new construct that allocates has to be
  ## classified here. Calls are not listed — the restriction rule sees them.
  case n.kind
  of exkList:
    if seqElem(semLayer.typeFor(n)) != nil: "a Seq literal" else: ""
  of exkBinary:
    if isStringConcat(n): "a str concatenation" else: ""
  else: ""

proc checkNoAlloc(d: Decl) =
  ## TK-EF05: the body of a `[no_alloc]` fn holds no allocating construct.
  if emNoAlloc notin d.fnEffects or d.fnBody == nil: return
  for n in d.fnBody.nodes:
    let what = allocatingConstruct(n)
    if what != "":
      reportError(withCode(dcEfAllocation,
        "'" & d.name & "' is [no_alloc] but contains " & what &
        ", which allocates. Fix: use an Array or a pool, or drop [no_alloc]"),
        n.span)

proc calleeNames(c: Checker, d: Decl): seq[string] =
  ## The distinct fn names `d`'s body calls (members resolved like any call).
  if d.fnBody == nil: return
  for n in d.fnBody.nodes:
    let call = callOf(n)
    if call == nil: continue
    let callee = c.resolveCallee(call)
    if callee.kind == ckFn and callee.name notin result:
      result.add callee.name

proc recursiveFrom(c: Checker, bodies: Table[string, Decl], start: string,
                   seen: var seq[string]): bool =
  ## Does the call graph below `start` reach a cycle? `seen` is the path.
  if start in seen: return true
  if not bodies.hasKey(start): return false
  seen.add start
  for next in c.calleeNames(bodies[start]):
    if c.recursiveFrom(bodies, next, seen): return true
  seen.setLen(seen.len - 1)

proc checkStackBound(c: Checker, d: Decl) =
  ## TK-EF06: a fn declaring `stack` has a call graph below it with no cycle.
  ## Only fns whose bodies are in this module are followed; an extern or an
  ## imported fn is a leaf here.
  if emStack notin d.fnEffects or d.fnBody == nil: return
  var bodies: Table[string, Decl]
  for x in c.module.allDecls:
    if x.kind == dkFn and x.fnBody != nil: bodies[x.name] = x
  var path: seq[string]
  if c.recursiveFrom(bodies, d.name, path):
    reportError(withCode(dcEfRecursion,
      "'" & d.name & "' declares [stack] but can recurse (via " &
      path.join(" -> ") & "), so its depth has no static bound. Fix: turn " &
      "the recursion into a loop, or drop [stack]"), d.span)

proc checkMarkerCombinations(d: Decl) =
  ## TK-EF04: markers that exclude each other, and implications that must be
  ## written (`irq_safe` requires `no_alloc`).
  for m in d.fnEffects:
    for x in excludes(m):
      if x in d.fnEffects:
        reportError(withCode(dcEfCombination,
          "'" & d.name & "' declares [" & effectName(m) & "] together with [" &
          effectName(x) & "], which it excludes. Fix: remove [" &
          effectName(x) & "] or remove [" & effectName(m) & "]"), d.span)
    for x in requires(m):
      if x notin d.fnEffects:
        reportError(withCode(dcEfCombination,
          "'" & d.name & "' is [" & effectName(m) & "], which also requires [" &
          effectName(x) & "]. Fix: add [" & effectName(x) & "] to its bracket"),
          d.span)

proc verifyFn(c: var Checker, d: Decl) =
  ## One fn body against its own bracket — `main`'s budget aside, below.
  # A contradictory bracket is a fault of the DECLARATION, so a body-less
  # signature gets it too.
  if d != nil:
    checkMarkerCombinations(d)
    checkNoAlloc(d)
  if d == nil or d.fnBody == nil or d.name in c.visiting: return
  c.visiting.incl(d.name)
  # main is ASSUMED to touch I/O — the [io] marker distinguishes pure fns
  # from impure ones (and drives async); it is not a gate on main. So main
  # may call [io] externs without declaring [io]. Every other effect too:
  # main is the program's impure entry point.
  # main is ASSUMED impure, resource kinds included: a program that opens a
  # socket in `main` is the ordinary case, and `fn main() -> int` has no
  # natural place to carry the marker. c.everyKind is every kind the program
  # declares, so the pass on main is exactly as wide as its effect pass and
  # no wider — a kind nothing declares is still TK-RS01.
  #
  # Its OWN marker is unioned in rather than replaced. A blanket budget that
  # discards what the author wrote means `[resource: db]` on main reads as a
  # no-op, and it was one: before the kind set went program-wide, a kind an
  # IMPORT declared was in neither half, so the one thing an author could do
  # about it changed nothing.
  let budget = if d.name == "main":
                 Demands(effects: @[emIo, emNoAlloc, emIrqSafe, emUnsafe,
                                    emMayBlock, emStack, emPriority],
                         resources: c.everyKind & d.fnResourceKinds)
               else: Demands(effects: d.fnEffects,
                             resources: d.fnResourceKinds)
  c.checkRestrictions(d)
  checkIsrSends(d)
  c.checkStackBound(d)
  let actual = c.checkExpr(d.fnBody, budget, d.name)
  # The other direction (issue #14): a declared [io] the body never needs.
  if d.name != "main" and emIo in d.fnEffects and emIo notin actual.effects and
     not c.mayDoIoUnseen(d.fnBody):
    warn(dcEfUnused, "'" & d.name & "' declares [io], but nothing in its " &
         "body performs I/O, suspends or spawns. Fix: remove [io] from its " &
         "bracket", d.span.line, d.span.col)
  c.visiting.excl(d.name)

proc verifyMembers(c: var Checker, members: seq[Decl]) =
  ## Every member fn with a body, each against its own bracket. An object's
  ## members, a type's, a mixin's: `fn poke({self: Box}) -> int` declares its
  ## effects exactly as a top-level fn does, and was never held to them.
  for m in members:
    if m != nil and m.kind == dkFn: c.verifyFn(m)

proc verifyDecl*(c: var Checker, d: Decl) =
  ## Checks one declaration's body against its declared budget. `main` gets
  ## every effect and every program-declared resource kind.
  ##
  ## Names every DeclKind, as `checkDecl` does: this used to end in
  ## `else: discard`, and object, type and mixin members fell into it — an
  ## `[io]` call inside a member with no `[io]` checked clean.
  if d == nil: return
  case d.kind
  of dkFn: c.verifyFn(d)
  of dkTask:
    if d.name in c.visiting: return
    c.visiting.incl(d.name)
    discard c.checkExpr(d.fnBody, Demands(effects: d.fnEffects,
                                           resources: d.fnResourceKinds), d.name)
    c.visiting.excl(d.name)
  of dkActor:
    for h in d.handlers:
      verifyDecl(c, h)
  of dkObject: c.verifyMembers(d.objMembers)
  of dkType: c.verifyMembers(d.typeMembers)
  of dkMixin: c.verifyMembers(d.mixinMembers)
  of dkStaticAssert:
    discard c.checkExpr(d.assertExpr, Demands(), "static_assert")
  of dkSelect:
    # NOT CHECKED, knowingly: an `on select` arm has no bracket, so it has no
    # budget to be checked against. Checking it against an empty one would
    # make every [io] call in an arm an error with no way to declare it; how
    # an arm states its effects is a ruling (thoughts/shared/audits,
    # 2026-09-27 F2). Until then an arm is as unchecked as it always was.
    discard
  of dkExtern, dkPending:
    # signatures only: no body, but a bracket can still contradict itself
    for mem in d.mixinMembers:
      if mem != nil and mem.kind == dkFn: checkMarkerCombinations(mem)
  of dkFnSig, dkInterface, dkGroup:
    discard   # signatures only: no body to check
  of dkErrors:
    discard   # the `on unhandled` handler runs from the runtime, not a caller
  of dkExpr:
    discard   # a top-level statement runs as part of main, which may do anything
  of dkConst, dkRegistry, dkPool, dkSlab, dkArena, dkRegister, dkResources, dkImport,
     dkSatisfies, dkPublic:
    discard   # no body
  of dkWhen:
    discard   # resolved away at load (modules.resolveWhenBlocks)

proc collectImported(c: var Checker, imported: Table[string, seq[EffectMarker]],
                     importedRes: Table[string, seq[string]]) =
  ## What this module's IMPORTS declare. Two tables in, one out: they are
  ## filled independently (a module may export an [io] fn that acquires
  ## nothing, and vice versa), so a name present in only one still lands.
  for name, effects in imported:
    c.declared[name] = Demands(effects: effects,
                               resources: importedRes.getOrDefault(name, @[]))
  for name, kinds in importedRes:
    if not c.declared.hasKey(name): c.declared[name] = Demands(resources: kinds)

proc collectLocal(c: var Checker, m: Module) =
  ## What this module itself declares. Runs AFTER collectImported so a local
  ## declaration of an imported name wins.
  for d in m.decls:
    if d == nil: continue
    case d.kind
    of dkFn:
      c.declared[d.name] = Demands(effects: d.fnEffects,
                                   resources: d.fnResourceKinds)
    of dkTask:
      c.declared[d.name] = Demands(effects: d.fnEffects,
                                   resources: d.fnResourceKinds)
      c.taskNames.incl(d.name)
    of dkActor:
      for h in d.handlers:
        if h.kind == dkFn:
          c.declared[h.name] = Demands(effects: h.fnEffects,
                                       resources: h.fnResourceKinds)
    of dkExtern:
      # local `extern:` block — register each declared fn's effects so an [io]
      # extern marks its call sites async (else a task calling it never yields).
      # §7.4's own acquire example is an extern signature, so the resource
      # kinds have to come along the same way or the one form the spec shows
      # would propagate to nobody.
      for mem in d.mixinMembers:
        if mem.kind == dkFn:
          c.declared[mem.name] = Demands(effects: mem.fnEffects,
                                         resources: mem.fnResourceKinds)
    of dkResources:
      for k in d.resKinds:
        if k.name notin c.everyKind: c.everyKind.add(k.name)
    else: discard


# --- derived facts (proposal §7.1) -------------------------------------------
#
# Nothing here is written by the user. For every top-level fn with a body the
# compiler works out which restrictions it COULD carry, bottom-up over the
# calls it can see. UNKNOWN => NO FACT: a callee that is not a declared fn, a
# task, or a fn already derived is never assumed to be safe, and the iteration
# starts from "nothing holds" so a cycle never proves itself.

type
  Facts* = object
    name*: string
    declared*: seq[EffectMarker]
    needs*: seq[EffectMarker]    # capabilities the body requires
    pure*, noAlloc*, irqSafe*, bounded*: bool
    suggest*: seq[EffectMarker]  # restrictions it satisfies but does not declare

proc stateNames(m: Module): HashSet[string] =
  ## Names that stand for state outside a fn's own values: a register, a pool,
  ## slab or arena, an actor. Touching one makes a fn not pure.
  for d in m.decls:
    if d != nil and d.kind in {dkRegister, dkPool, dkSlab, dkArena, dkActor,
                               dkRegistry}:
      result.incl d.name

proc touchesState(d: Decl, state: HashSet[string]): bool =
  for n in d.fnBody.nodes:
    case n.kind
    of exkSend, exkAcquire, exkFinish, exkSelect: return true
    of exkVar: (if n.name in state: return true)
    else: discard

proc holds(c: Checker, facts: Table[string, Facts], callee: Callee,
           r: EffectMarker): bool =
  ## Does the callee carry restriction `r`: declared, or derived so far.
  if callee.kind != ckFn: return false
  if r in callee.markers: return true
  if not facts.hasKey(callee.name): return false
  let f = facts[callee.name]
  case r
  of emPure: f.pure
  of emNoAlloc: f.noAlloc
  of emIrqSafe: f.irqSafe
  else: false

proc callsOf(c: Checker, d: Decl): seq[Callee] =
  ## Every call in `d`'s body, resolved.
  for n in d.fnBody.nodes:
    let call = callOf(n)
    if call != nil: result.add c.resolveCallee(call)

proc allocates(d: Decl): bool =
  for n in d.fnBody.nodes:
    if allocatingConstruct(n) != "": return true

proc derive(c: Checker, d: Decl, state: HashSet[string],
            facts: Table[string, Facts]): Facts =
  ## One round for one fn, against the facts known so far.
  result = facts[d.name]
  let calls = c.callsOf(d)
  let allKnown = calls.allIt(it.kind == ckFn)
  let capFree = result.needs.len == 0 and
                d.fnEffects.allIt(familyOf(it) != mfCapability)
  let stateFree = not touchesState(d, state)
  proc all(r: EffectMarker): bool = calls.allIt(c.holds(facts, it, r))
  result.noAlloc = emNoAlloc in d.fnEffects or
                   (not allocates(d) and all(emNoAlloc))
  result.pure = emPure in d.fnEffects or
                (capFree and allKnown and all(emPure) and stateFree)
  result.irqSafe = emIrqSafe in d.fnEffects or
                   (capFree and result.noAlloc and all(emIrqSafe) and
                    stateFree)

proc cyclic(c: Checker, bodies: Table[string, Decl], name: string): bool =
  var path: seq[string]
  c.recursiveFrom(bodies, name, path)

proc restrictionHolds(f: Facts, r: EffectMarker): bool =
  case r
  of emPure: f.pure
  of emNoAlloc: f.noAlloc
  else: f.irqSafe

proc settle(c: var Checker, order: seq[Decl], state: HashSet[string],
            facts: var Table[string, Facts]) =
  ## Iterate `derive` from "nothing holds" until nothing changes.
  var changed = true
  while changed:
    changed = false
    for d in order:
      let nf = c.derive(d, state, facts)
      let old = facts[d.name]
      if (nf.pure, nf.noAlloc, nf.irqSafe) != (old.pure, old.noAlloc, old.irqSafe):
        facts[d.name] = nf
        changed = true

proc deriveFacts*(c: var Checker): seq[Facts] =
  ## The facts of every top-level fn with a body in the checked module, in
  ## source order, at the least fixed point.
  var bodies: Table[string, Decl]
  var order: seq[Decl]
  for d in c.module.decls:
    if d != nil and d.kind == dkFn and d.fnBody != nil and d.name != "main":
      bodies[d.name] = d
      order.add d
  var facts: Table[string, Facts]
  for d in order:
    let needs = c.synthesizeExpr(d.fnBody).effects
    facts[d.name] = Facts(name: d.name, declared: d.fnEffects,
      needs: needs.filterIt(familyOf(it) == mfCapability))
  c.settle(order, stateNames(c.module), facts)
  for d in order:
    var f = facts[d.name]
    f.bounded = not c.cyclic(bodies, d.name)
    for r in [emPure, emNoAlloc, emIrqSafe]:
      if f.restrictionHolds(r) and r notin f.declared: f.suggest.add r
    result.add f

proc formatFacts*(facts: seq[Facts]): string =
  ## The `--report-effects` text: per fn, what it declares, needs and could
  ## carry, then the markers it may add.
  proc names(ms: seq[EffectMarker]): string =
    if ms.len == 0: "-" else: ms.mapIt(effectName(it)).join(", ")
  for f in facts:
    var derived: seq[string]
    if f.pure: derived.add "pure"
    if f.noAlloc: derived.add "no_alloc"
    if f.irqSafe: derived.add "irq_safe"
    if f.bounded: derived.add "bounded-depth"
    result.add f.name & ": declares [" & names(f.declared) & "], needs [" &
      names(f.needs) & "], derived: " &
      (if derived.len == 0: "-" else: derived.join(", ")) & "\n"
    if f.suggest.len > 0:
      result.add "  suggest: add [" & names(f.suggest) & "]\n"

var effectReportOn*: bool
  ## Set by `tuck effects`; verifyModuleEffects then leaves its report here.
var effectReportText*: string

proc verifyModuleEffects*(m: Module,
                          imported: Table[string, seq[EffectMarker]] =
                            initTable[string, seq[EffectMarker]](),
                          importedRes: Table[string, seq[string]] =
                            initTable[string, seq[string]](),
                          programKinds: seq[string] = @[],
                          importedPending: HashSet[string] =
                            initHashSet[string]()) =
  ## Check every declaration in `m` performs only the effects it declares.
  ##
  ## `imported` carries the effects of fns this module IMPORTS, keyed the same
  ## way calls name them. Without it an imported [io] fn looks pure to its
  ## callers and the effect discipline stops at the file boundary; the driver
  ## fills it from the signature index (see checkOrDie in tuck.nim), so it
  ## works the same whether the callee came from source or from cache.
  ##
  ## `programKinds` is the §7.4 twin of that argument, and exists for the same
  ## reason: a resource KIND is program-wide (§7.4 calls kinds an open set
  ## declared the way error enums are), so a module that acquires into a kind
  ## its import declared cannot answer "is this kind known" from its own decls
  ## — and `main`, whose budget is every kind, would get an empty one.
  var c = Checker(module: m, declared: initTable[string, Demands](),
                  visiting: initHashSet[string](), everyKind: programKinds,
                  pendingNames: importedPending)
  c.collectImported(imported, importedRes)
  c.collectLocal(m)
  for d in m.decls:
    c.verifyDecl(d)
  if effectReportOn: effectReportText = formatFacts(c.deriveFacts())
