# compiler/resolve_refs.nim
#
# Between load and typecheck: turn every bare name that outright NAMES an
# actor, register, registry, pool, or mixin into its own dedicated node
# (exkActorRef / exkRegisterRef / exkRegistryRef / exkPoolRef / exkMixinRef —
# compiler/ast.nim), instead of leaving it a generic exkVar for synthVar's
# local/nullary-call/sum-variant chain to guess at later. See
# typecheck.nim's synthBareVariant for what used to happen to a name none of
# those three steps claimed: silently `<unknown>`, one string-keyed re-scan
# of module.decls per construct, at every use site, forever guessing whether
# THIS particular name might be one of five things it has no way to ask about
# directly.
#
# Whole-program, not per-module: a module may reference another module's
# actor/registry/etc. (imports already make cross-module names visible), and
# running this once here — rather than inside the parser, whose output is
# AST-cache-persisted per file — means an unchanged, cache-hit file's names
# still get registered every run.

import tables
import ast
import ast_query
import resolution
import modules
import typecheck_util  # fail() — an ambiguous declaration is a real, located
                        # compile error, reported the same way every other
                        # checker error is

proc collectNames(prog: seq[LoadedModule]) =
  ## One pass over every declaration in the program, filling the five
  ## whole-program name tables on `semLayer`. A name reused for the SAME
  ## construct kind anywhere in the program is ambiguous — a real error,
  ## not a first-wins situation (unlike sum-type variants, which legitimately
  ## repeat across unrelated types).
  template collect(kind: DeclKind, table: untyped, what: string) =
    for lm in prog:
      for d in lm.m.decls(kind):
        if semLayer.table.hasKey(d.name):
          fail("Type Error: '" & d.name & "' is declared as " & what &
               " more than once in this program", d.span)
        semLayer.table[d.name] = d
  collect(dkActor, actorNames, "an actor")
  collect(dkRegister, registerNames, "a register")
  collect(dkRegistry, registryNames, "a registry")
  collect(dkPool, poolNames, "a pool")
  collect(dkMixin, mixinNames, "a mixin")

proc declRefFor(name: string): Expr =
  ## The dedicated reference node for a name found in one of the five
  ## tables, or nil if it names none of them. Checked in this order because
  ## the five sets are disjoint by construction (a name is declared as
  ## exactly one DeclKind) — order has no effect on the outcome.
  if semLayer.actorNames.hasKey(name):
    result = Expr(kind: exkActorRef, refName: name)
  elif semLayer.registerNames.hasKey(name):
    result = Expr(kind: exkRegisterRef, refName: name)
  elif semLayer.registryNames.hasKey(name):
    result = Expr(kind: exkRegistryRef, refName: name)
  elif semLayer.poolNames.hasKey(name):
    result = Expr(kind: exkPoolRef, refName: name)
  elif semLayer.mixinNames.hasKey(name):
    result = Expr(kind: exkMixinRef, refName: name)
  else:
    return nil
  let d = case result.kind
    of exkActorRef: semLayer.actorNames[name]
    of exkRegisterRef: semLayer.registerNames[name]
    of exkRegistryRef: semLayer.registryNames[name]
    of exkPoolRef: semLayer.poolNames[name]
    of exkMixinRef: semLayer.mixinNames[name]
    else: nil
  resolveTo(semLayer, result, d)

proc resolveRefsIn(e: Expr)  # forward: resolveVarSlot/resolveRefsIn recurse
                              # into each other (a slot may hold a name to
                              # replace; a replaced-or-kept node still needs
                              # its OWN children walked)

proc resolveVarSlot(e: Expr): Expr =
  ## `e`, or its replacement if `e` is a bare exkVar naming one of the five
  ## constructs — Capitalized only, matching the parser's own rule that
  ## these declarations (like fnsig/registry/pool/arena) must be. A local
  ## binding is never Capitalized by that same rule, so there is no
  ## shadowing question to ask here: this pass runs before typecheck even
  ## builds a scope, and does not need one.
  if e == nil: return e
  if e.kind == exkVar and e.name.len > 0 and e.name[0] in {'A'..'Z'}:
    let r = declRefFor(e.name)
    if r != nil:
      r.span = e.span
      return r
  resolveRefsIn(e)
  e

proc resolveRefsIn(e: Expr) =
  ## Rewrite every matching bare name reachable from `e`, one level at a
  ## time — mirrors ast.children's own case list, but reassigns the mutable
  ## Expr slots that can hold a bare name in receiver/base/callee position
  ## instead of only visiting them. Everything else recurses read-only via
  ## resolveVarSlot, which recurses further in turn — deliberately listed
  ## rather than `else: discard`, so a new ExprKind forces a decision here
  ## too, the same reason ast.children is exhaustive.
  if e == nil: return
  case e.kind
  of exkLit, exkVar, exkQualified, exkImport, exkBreak, exkContinue,
     exkActorRef, exkRegisterRef, exkRegistryRef, exkPoolRef, exkMixinRef:
    discard
  of exkField:
    e.receiver = resolveVarSlot(e.receiver)
    e.dotArg = resolveVarSlot(e.dotArg)
  of exkStruct:
    for f in e.fields.mitems: f.value = resolveVarSlot(f.value)
  of exkList:
    for i in 0 ..< e.items.len: e.items[i] = resolveVarSlot(e.items[i])
  of exkBracket:
    e.brReceiver = resolveVarSlot(e.brReceiver)
    for i in 0 ..< e.brArgs.len: e.brArgs[i] = resolveVarSlot(e.brArgs[i])
  of exkBracketAssign:
    e.brTarget = resolveVarSlot(e.brTarget)
    e.brValue = resolveVarSlot(e.brValue)
  of exkCall:
    e.callee = resolveVarSlot(e.callee)
    for i in 0 ..< e.args.len: e.args[i] = resolveVarSlot(e.args[i])
  of exkChain:
    e.base = resolveVarSlot(e.base)
    for s in e.steps.mitems: resolveRefsIn(s.arg)
  of exkBinary:
    e.left = resolveVarSlot(e.left)
    e.right = resolveVarSlot(e.right)
  of exkUnary: e.operand = resolveVarSlot(e.operand)
  of exkBlock:
    for i in 0 ..< e.stmts.len: e.stmts[i] = resolveVarSlot(e.stmts[i])
  of exkIf:
    e.cond = resolveVarSlot(e.cond)
    e.thenBranch = resolveVarSlot(e.thenBranch)
    e.elseBranch = resolveVarSlot(e.elseBranch)
  of exkMatch:
    e.subject = resolveVarSlot(e.subject)
    for arm in e.arms.mitems:
      arm.guard = resolveVarSlot(arm.guard)
      arm.body = resolveVarSlot(arm.body)
  of exkFor:
    e.iterable = resolveVarSlot(e.iterable)
    e.body = resolveVarSlot(e.body)
  of exkWhile:
    e.whileCond = resolveVarSlot(e.whileCond)
    e.whileBody = resolveVarSlot(e.whileBody)
  of exkAssign:
    e.target = resolveVarSlot(e.target)
    e.assignVal = resolveVarSlot(e.assignVal)
  of exkReturn: e.returnVal = resolveVarSlot(e.returnVal)
  of exkRaise: e.raiseVal = resolveVarSlot(e.raiseVal)
  of exkDiscard: e.discardVal = resolveVarSlot(e.discardVal)
  of exkSend: e.sendPayload = resolveVarSlot(e.sendPayload)
  of exkSelect:
    for arm in e.selArms.mitems:
      arm.arg = resolveVarSlot(arm.arg)
      arm.body = resolveVarSlot(arm.body)

proc resolveDeclRefs*(prog: seq[LoadedModule]) =
  ## Entry point: build the five whole-program name tables, then rewrite
  ## every matching bare reference across every module's fn/task/const
  ## bodies. Run once, after load + injectImportedTypes, before typecheck.
  collectNames(prog)
  for lm in prog:
    for fn in lm.m.allFns(): resolveRefsIn(fn.fnBody)
    for d in lm.m.decls(dkTask): resolveRefsIn(d.taskBody)
    for d in lm.m.decls(dkExpr): resolveRefsIn(d.expr)
    # `+ Name` composition (spec 5.1) parses as a dkExpr MEMBER of the
    # composing object/type/mixin/interface — `ast_query.members` is the
    # exhaustive "everything nested inside this decl" iterator (allFns
    # above already covers member FNS the same way; this is its dkExpr
    # sibling). Missed initially: `+ BulkOperations` (a mixin) stayed
    # exkVar, unrewritten, all the way to typecheck.
    for d in lm.m.decls:
      if d == nil: continue
      for mem in d.members():
        if mem != nil and mem.kind == dkExpr: resolveRefsIn(mem.expr)
