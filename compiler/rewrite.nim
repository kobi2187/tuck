# compiler/rewrite.nim
#
# STAGE 2.5 OF THE PIPELINE — decide what the user's construct MEANS, before
# anything tries to interpret it.
#
# THE CHARTER. `rewrite` replaces a construct with an EQUIVALENT one that is
# simpler for the rest of the compiler. A rule belongs here when the language
# decides something on the user's behalf, and that decision does not depend on
# any type. Rules run UNCONDITIONALLY — they never consult fnSigs, typeDecls,
# or a synthesized type. If a rewrite needs to know a type, it is a type rule
# and belongs in the checker.
#
# Where this sits among its neighbours:
#
#   rewrite     after parse, before check   serves everyone   what a construct MEANS
#   typecheck   after rewrite               serves itself     what things ARE
#   lowering    after check, compile only   serves backends   how to EMIT it
#
# WHY THIS STAGE EXISTS. These rewrites used to live inside the type checker,
# performed as a side effect of typing an expression. A rewrite written that way
# inherits the type rule's preconditions, so when a precondition fails the
# rewrite silently does not happen — and the tree carries a shape the later
# stages were never meant to see.
#
# The bug that produced this file: `5.ms` means `{value: 5} .ms`, because a bare
# literal IS the payload. That wrap lived in asPostfixApplication, which bails
# when the fn name is not in fnSigs. Written without `import time`, `ms` did not
# resolve, the wrap never ran, and `5.ms` stayed a FIELD ACCESS all the way to
# codegen — which emitted a bare `5`. The unit vanished and `tuck ch` said OK.
# Both backends had grown a branch to cope with the shape that should never have
# arrived; normalizing here let both be deleted.
#
# An implicit decision made unconditionally, in one declared place, cannot fail
# that way. The decision belongs to the language, so it does not wait on a
# lookup.
#
# WHAT LANDS HERE NEXT. Other implicit decisions still living in the checker,
# each a candidate when next touched: a bare name is a call (spec 2.3,
# synthNullaryCall), `Pool.acquire` (asStaticMemberCall), `x.f` -> `f(x)`
# (asFnByName's bare arm). Subset matching and the auto-wrap into !T are
# type-DEPENDENT and stay in the checker — they are the boundary, not tenants.
#
# ORDERING NOTE. This runs inside parseSource, so the msgpack module cache
# stores already-rewritten trees. That is safe because buildStamp is
# CompileDate & CompileTime (modules.nim), so rebuilding the compiler
# invalidates every cache entry — a pre-rewrite tree cannot outlive the change
# that introduced a rule. If caching ever stops keying on the build, this pass
# must move to the load path instead.
import ast
import ast_query

proc rewriteExpr(e: Expr)

proc isLiteralPayload*(e: Expr): bool =
  ## Was this receiver built by payloadOfLiteral below? The checker asks so it
  ## can blame the LITERAL the user wrote rather than the `{value: n}` wrap it
  ## never saw. Kept beside the constructor so the shape has one definition.
  if e == nil or e.kind != exkStruct or e.fields.len != 1: return false
  let f = e.fields[0]
  f.name == "value" and f.value != nil and f.value.kind == exkLit

proc payloadOfLiteral(lit: Expr): Expr =
  ## A bare literal applied to a fn IS the one-field payload `{value: lit}`
  ## (spec: the literal-value payload). `5.ms` is `{value: 5} .ms`, and `ms`
  ## reads `value` in its body.
  ##
  ## Unconditional by design: whether `ms` resolves is the checker's question,
  ## not this one. Deciding it here is what made the wrap fail silently when
  ## the fn was unknown.
  Expr(span: lit.span, kind: exkStruct, fields: @[("value", lit)])

proc rewriteFieldReceiver(e: Expr) =
  ## `<literal>.name` — wrap the receiver as the payload it denotes.
  ##
  ## Only a BARE literal: one already inside a record or a list is a value in
  ## that structure, not a receiver standing in for a payload.
  if e.receiver != nil and e.receiver.kind == exkLit:
    e.receiver = payloadOfLiteral(e.receiver)

proc rewriteExpr(e: Expr) =
  ## Walk every expression, applying the rules on the way down.
  ##
  ## The traversal is ast.children — exhaustive by construction, so a new Expr
  ## kind cannot be silently skipped here. Only exkField does any work; the
  ## rest of the walk exists to reach it.
  if e == nil: return
  if e.kind == exkField: rewriteFieldReceiver(e)
  for c in e.children: rewriteExpr(c)

proc rewriteModule*(m: Module) =
  ## Normalize a module in place. Walks fn bodies via allFns rather than a
  ## hand-rolled case over decl kinds — that is how dkActor came to be silently
  ## skipped by an earlier pass.
  ##
  ## Tasks are walked SEPARATELY: allFns yields dkFn only, and a task keeps its
  ## body in taskBody. Seven examples declare tasks, so a rule that skipped them
  ## would be silently half-applied. (lowerModule has this same gap — it walks
  ## allFns and never reaches taskBody.)
  for fn in m.allFns(): rewriteExpr(fn.fnBody)
  for d in m.decls(dkTask): rewriteExpr(d.taskBody)
  for d in m.decls(dkExpr): rewriteExpr(d.expr)
