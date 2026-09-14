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
import ast, tables, sets, strutils
import resolution
import diagnostics  # TK-RS03, the resource half of the propagation rule

type
  SemanticError* = object of ValueError
    line*, col*: int

proc reportError(msg: string, span: Span) =
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
    module: Module
    declared: Table[string, Demands]
    taskNames: HashSet[string]  # dkTask decl names, built once — see isTask
    everyKind: seq[string]      # kinds declared in THIS module — main's budget
    visiting: HashSet[string]

proc getDeclared(c: Checker, name: string): Demands =
  if c.declared.hasKey(name):
    return c.declared[name]
  return Demands()

# Bidirectional functions
proc synthesizeExpr(c: var Checker, e: Expr): Demands
proc checkExpr(c: var Checker, e: Expr, expected: Demands, currentFn: string)

proc unionEffects(a, b: seq[EffectMarker]): seq[EffectMarker] =
  var res = a
  for x in b:
    if x notin res: res.add(x)
  return res

proc union(a, b: Demands): Demands =
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
        let callee = c.getDeclared(calleeName)
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

proc checkExpr(c: var Checker, e: Expr, expected: Demands, currentFn: string) =
  ## Reject any effect this expression performs, or resource kind it acquires,
  ## that `currentFn` did not declare. `expected` is that declaration — an [io]
  ## fn may do IO, a fn with no markers may do none, so an undeclared effect
  ## anywhere in the body is an error naming the function that failed to
  ## declare it. §7.4 asks for the identical rule on `[resource: k]`, and gets
  ## it from the identical code.
  if e == nil: return

  # 1. Synthesize the actual demands bottom-up
  let actual = c.synthesizeExpr(e)

  # 2. Check them top-down against the declared budget
  for eff in actual.effects:
    if eff notin expected.effects:
      reportError("Semantic Error: Expression requires effect [" & effectName(eff) & "], which is not allowed in context of '" & currentFn & "'", e.span)
  for kind in actual.resources:
    if kind notin expected.resources:
      reportError(withCode(dcRsUndeclared,
        "Expression acquires resource kind '" & kind & "', which '" &
        currentFn & "' does not declare — add `[resource: " & kind &
        "]` to its bracket"), e.span)

proc verifyDecl*(c: var Checker, d: Decl) =
  if d == nil: return
  case d.kind
  of dkFn:
    if d.name in c.visiting: return
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
    let budget = if d.name == "main":
                   Demands(effects: @[emIo, emNoAlloc, emIrqSafe, emUnsafe,
                                      emMayBlock, emStack, emPriority],
                           resources: c.everyKind)
                 else: Demands(effects: d.fnEffects,
                               resources: d.fnResourceKinds)
    c.checkExpr(d.fnBody, budget, d.name)
    c.visiting.excl(d.name)
  of dkTask:
    if d.name in c.visiting: return
    c.visiting.incl(d.name)
    c.checkExpr(d.taskBody, Demands(effects: d.taskEffects,
                                    resources: d.taskResourceKinds), d.name)
    c.visiting.excl(d.name)
  of dkActor:
    for h in d.handlers:
      verifyDecl(c, h)
  of dkStaticAssert:
    c.checkExpr(d.assertExpr, Demands(), "static_assert")
  else:
    discard

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
      c.declared[d.name] = Demands(effects: d.taskEffects,
                                   resources: d.taskResourceKinds)
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
      for k in d.resKinds: c.everyKind.add(k.name)
    else: discard

proc verifyModuleEffects*(m: Module,
                          imported: Table[string, seq[EffectMarker]] =
                            initTable[string, seq[EffectMarker]](),
                          importedRes: Table[string, seq[string]] =
                            initTable[string, seq[string]]()) =
  ## Check every declaration in `m` performs only the effects it declares.
  ##
  ## `imported` carries the effects of fns this module IMPORTS, keyed the same
  ## way calls name them. Without it an imported [io] fn looks pure to its
  ## callers and the effect discipline stops at the file boundary; the driver
  ## fills it from the signature index (see checkOrDie in tuck.nim), so it
  ## works the same whether the callee came from source or from cache.
  var c = Checker(module: m, declared: initTable[string, Demands](),
                  visiting: initHashSet[string]())
  c.collectImported(imported, importedRes)
  c.collectLocal(m)
  for d in m.decls:
    c.verifyDecl(d)
