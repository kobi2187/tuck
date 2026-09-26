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

import tables, sets
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
  # Consts, on DIFFERENT terms: `collect` treats a repeat as an error, which is
  # right for the five singleton kinds above and wrong here — two modules each
  # with a private `const Cap` is ordinary code. First wins, collisions are
  # recorded, and an ambiguous name resolves to nothing rather than to whichever
  # module happened to load first. A module's OWN const shadows all of this;
  # ast_query.constIntOf scans the local module before consulting the table.
  for lm in prog:
    for d in lm.m.decls(dkConst):
      if semLayer.constNames.hasKey(d.name) and
         semLayer.constNames[d.name] != d:
        semLayer.ambiguousConsts.incl(d.name)
      else:
        semLayer.constNames[d.name] = d

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
  ## Rewrite every matching bare name reachable from `e`: each child slot
  ## (`ast_ops.childSlots`, the list `children` reads) is replaced when it
  ## holds one, and walked when it does not — resolveVarSlot recurses.
  ##
  ## A chain step is the one exception. Its target names a MEMBER
  ## (`..withDefaults`), never one of the declarations resolved here, so
  ## only the base and each step's argument are candidates.
  if e == nil: return
  if e.kind == exkChain:
    e.base = resolveVarSlot(e.base)
    for s in e.steps.mitems: resolveRefsIn(s.arg)
    return
  for s in e.childSlots: s = resolveVarSlot(s)

proc resolveDeclRefs*(prog: seq[LoadedModule]) =
  ## Entry point: build the five whole-program name tables, then rewrite
  ## every matching bare reference across every module's fn/task/const
  ## bodies. Run once, after load + injectImportedTypes, before typecheck.
  collectNames(prog)
  for lm in prog:
    # Every body, as a SLOT: a body that is itself a bare name (an actor
    # field's initialiser, #87; a `+ Name` composition member of an object,
    # which parses as a nested dkExpr) is replaced, not just walked. The
    # composition case was missed once: `+ BulkOperations` stayed exkVar all
    # the way to typecheck.
    for s in lm.m.bodySlots: s = resolveVarSlot(s)
