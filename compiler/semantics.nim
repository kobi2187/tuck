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

type
  SemanticError* = object of ValueError
    line*, col*: int

proc reportError(msg: string, span: Span) =
  let err = newException(SemanticError, msg)
  err.line = span.line
  err.col = span.col
  raise err

type
  Checker = object
    module: Module
    declared: Table[string, seq[EffectMarker]]
    taskNames: HashSet[string]  # dkTask decl names, built once — see isTask
    visiting: HashSet[string]

proc getDeclaredEffects(c: Checker, name: string): seq[EffectMarker] =
  if c.declared.hasKey(name):
    return c.declared[name]
  return @[]

# Bidirectional functions
proc synthesizeExpr(c: var Checker, e: Expr): seq[EffectMarker]
proc checkExpr(c: var Checker, e: Expr, expected: seq[EffectMarker], currentFn: string)

proc unionEffects(a, b: seq[EffectMarker]): seq[EffectMarker] =
  var res = a
  for x in b:
    if x notin res: res.add(x)
  return res

# The effect checker is the same synthesize/check pair as the TYPE checker,
# one level over: synthesizeExpr asks "what effects does this expression
# perform?" and checkExpr asks "are those allowed here?". Reading them side by
# side is the quickest way to see that effects really are a type system, just
# for side effects rather than values.
proc synthesizeExpr(c: var Checker, e: Expr): seq[EffectMarker] =
  ## Every effect this expression performs, gathered from the whole subtree.
  if e == nil: return @[]
  var res: seq[EffectMarker] = @[]
  case e.kind
  of exkCall:
    res = unionEffects(res, c.synthesizeExpr(e.callee))
    for a in e.args:
      res = unionEffects(res, c.synthesizeExpr(a))
    
    let calleeName = if e.callee != nil and e.callee.kind == exkVar: e.callee.name else: ""
    if calleeName != "":
      # Calling a TASK is a spawn — it decouples the [io] work onto the
      # scheduler, so the task's effects do NOT propagate to the caller and
      # the caller does not suspend here (the yields happen inside the task).
      # taskNames is built once in verifyModuleEffects; scanning c.module.decls
      # here instead would cost one pass per call expression, quadratic over a
      # module (the same mistake lowering's payload explosion made, fixed the
      # same way: record it once where it is already known).
      if calleeName notin c.taskNames:
        let calleeEffects = c.getDeclaredEffects(calleeName)
        res = unionEffects(res, calleeEffects)
        # The [io] marker IS the async annotation: a call to an [io] fn is a
        # suspend point. Flag the call site so codegen emits the async transform.
        if emIo in calleeEffects:
          semLayer.markAsync(e)
  of exkStruct:
    for f in e.fields:
      res = unionEffects(res, c.synthesizeExpr(f[1]))
  of exkList:
    for item in e.items:
      res = unionEffects(res, c.synthesizeExpr(item))
  of exkBinary:
    res = unionEffects(res, c.synthesizeExpr(e.left))
    res = unionEffects(res, c.synthesizeExpr(e.right))
  of exkUnary:
    res = unionEffects(res, c.synthesizeExpr(e.operand))
  of exkBlock:
    for s in e.stmts:
      res = unionEffects(res, c.synthesizeExpr(s))
  of exkIf:
    res = unionEffects(res, c.synthesizeExpr(e.cond))
    res = unionEffects(res, c.synthesizeExpr(e.thenBranch))
    res = unionEffects(res, c.synthesizeExpr(e.elseBranch))
  of exkMatch:
    res = unionEffects(res, c.synthesizeExpr(e.subject))
    for arm in e.arms:
      res = unionEffects(res, c.synthesizeExpr(arm.body))
  of exkFor:
    res = unionEffects(res, c.synthesizeExpr(e.iterable))
    res = unionEffects(res, c.synthesizeExpr(e.body))
  of exkWhile:
    if e.whileCond != nil:
      res = unionEffects(res, c.synthesizeExpr(e.whileCond))
    res = unionEffects(res, c.synthesizeExpr(e.whileBody))
  of exkBreak, exkContinue:
    discard
  of exkAssign:
    res = unionEffects(res, c.synthesizeExpr(e.target))
    res = unionEffects(res, c.synthesizeExpr(e.assignVal))
  of exkReturn:
    res = unionEffects(res, c.synthesizeExpr(e.returnVal))
  of exkRaise:
    res = unionEffects(res, c.synthesizeExpr(e.raiseVal))
  of exkChain:
    res = unionEffects(res, c.synthesizeExpr(e.base))
    for step in e.steps:
      res = unionEffects(res, c.synthesizeExpr(step.target))
      res = unionEffects(res, c.synthesizeExpr(step.arg))
  else:
    discard
  return res

proc checkExpr(c: var Checker, e: Expr, expected: seq[EffectMarker], currentFn: string) =
  ## Reject any effect this expression performs that `currentFn` did not
  ## declare. `expected` is that declaration — an [io] fn may do IO, a fn with
  ## no markers may do none, so an undeclared effect anywhere in the body is an
  ## error naming the function that failed to declare it.
  if e == nil: return
  
  # 1. Synthesize the actual effects bottom-up
  let actualEffects = c.synthesizeExpr(e)
  
  # 2. Check the synthesized effects top-down against the expected budget
  for eff in actualEffects:
    if eff notin expected:
      reportError("Semantic Error: Expression requires effect [" & ($eff).replace("em", "").toLowerAscii() & "], which is not allowed in context of '" & currentFn & "'", e.span)

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
    let budget = if d.name == "main":
                   @[emIo, emNoAlloc, emIrqSafe, emUnsafe, emMayBlock,
                     emStack, emPriority]
                 else: d.fnEffects
    c.checkExpr(d.fnBody, budget, d.name)
    c.visiting.excl(d.name)
  of dkTask:
    if d.name in c.visiting: return
    c.visiting.incl(d.name)
    c.checkExpr(d.taskBody, d.taskEffects, d.name)
    c.visiting.excl(d.name)
  of dkActor:
    for h in d.handlers:
      verifyDecl(c, h)
  of dkStaticAssert:
    c.checkExpr(d.assertExpr, @[], "static_assert")
  else:
    discard

proc verifyModuleEffects*(m: Module,
                          imported: Table[string, seq[EffectMarker]] =
                            initTable[string, seq[EffectMarker]]()) =
  ## Check every declaration in `m` performs only the effects it declares.
  ##
  ## `imported` carries the effects of fns this module IMPORTS, keyed the same
  ## way calls name them. Without it an imported [io] fn looks pure to its
  ## callers and the effect discipline stops at the file boundary; the driver
  ## fills it from the signature index (see checkOrDie in tuck.nim), so it
  ## works the same whether the callee came from source or from cache.
  var c = Checker(module: m, declared: initTable[string, seq[EffectMarker]](), visiting: initHashSet[string]())

  # Imported first, so a local declaration of the same name wins.
  for name, effects in imported:
    c.declared[name] = effects

  # Cache declared effect signatures in a symbol table lookup
  for d in m.decls:
    if d.kind == dkFn:
      c.declared[d.name] = d.fnEffects
    elif d.kind == dkTask:
      c.declared[d.name] = d.taskEffects
      c.taskNames.incl(d.name)
    elif d.kind == dkActor:
      for h in d.handlers:
        if h.kind == dkFn:
          c.declared[h.name] = h.fnEffects
    elif d.kind == dkMixin and d.name == "extern":
      # local `extern:` block — register each declared fn's effects so an [io]
      # extern marks its call sites async (else a task calling it never yields)
      for mem in d.mixinMembers:
        if mem.kind == dkFn:
          c.declared[mem.name] = mem.fnEffects
          
  for d in m.decls:
    c.verifyDecl(d)
