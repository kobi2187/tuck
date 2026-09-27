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
import tables
import ast
from ast_query import isCompositionEntry, compositionTargetName
from ast_ops import clearIds

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

proc boundSelf(t: Type, owner: Type): Type =
  ## `t` with every `Self` in it read as `owner`. Rebuilds only the spine it
  ## changes, so a type without `Self` comes back as the same node.
  if t == nil: return nil
  case t.kind
  of tkNamed:
    if t.name == "Self": owner else: t
  of tkApp:
    var args: seq[Type]
    for a in t.args: args.add(boundSelf(a, owner))
    Type(span: t.span, kind: tkApp, base: boundSelf(t.base, owner), args: args)
  else: t

proc bindSelf(mem: Decl, owner: Type) =
  ## In an object's member, the placeholder `Self` means that object — the
  ## language decides it from where the member is written, not from any
  ## type. Bound here so the checker sees `{self: Box}` whichever way it was
  ## spelled: left as `Self`, a call `b.poke` was refused ("expects Self but
  ## got Box") and the body's `self.v` went unchecked as an open receiver.
  if mem == nil or mem.kind != dkFn: return
  for i in 0 ..< mem.fnParams.len:
    mem.fnParams[i].typ = boundSelf(mem.fnParams[i].typ, owner)
  mem.fnReturnType = boundSelf(mem.fnReturnType, owner)

proc composedMixinMembers(mx: Decl): seq[Decl] =
  ## What `+ Mixin` brings into an object: a private copy of each of its fns
  ## with a body. A COPY, because binding `Self` rewrites the member — two
  ## objects composing one mixin must not share, and bind, the same node.
  ## The copy's ids are cleared: ids key the semantic layer, and a copy
  ## still carrying the original's would read and write its types.
  ## parseSource's fillIds numbers it afresh.
  for mm in mx.mixinMembers:
    if mm != nil and mm.kind == dkFn and mm.fnBody != nil:
      let copy = deepCopy(mm)
      clearIds(copy)
      result.add(copy)

proc composeMixins(m: Module) =
  ## `+ Mixin` in an object means the mixin's fns ARE the object's members
  ## (spec §4.5: composition is set union). Materialised here, before the
  ## checker, so a call on the object finds the member with `Self` bound to
  ## this object and the copied body is checked against this object's
  ## fields. Only a mixin this module declares — the same reach lowering's
  ## merge had; an entry naming anything else stays for later stages (a
  ## record's fields merge in lowering; an unknown name is a sketch).
  var mixins: Table[string, Decl]
  for d in m.decls:
    if d != nil and d.kind == dkMixin: mixins[d.name] = d
  for d in m.decls:
    if d == nil or d.kind != dkObject: continue
    var members: seq[Decl]
    for mem in d.objMembers:
      if mem != nil and isCompositionEntry(mem) and
         compositionTargetName(mem) in mixins:
        members.add(composedMixinMembers(mixins[compositionTargetName(mem)]))
      else:
        members.add(mem)
    d.objMembers = members
    let owner = Type(span: d.span, kind: tkNamed, name: d.name)
    for mem in d.objMembers: bindSelf(mem, owner)

proc rewriteModule*(m: Module) =
  ## Normalize a module in place, over EVERY body (`ast_ops.bodies`) — a
  ## hand-rolled walk over decl kinds is how dkActor, and later task bodies,
  ## came to be silently skipped. Mixins compose first, so the bodies they
  ## copy into objects are walked like any other.
  composeMixins(m)
  for e in m.bodies: rewriteExpr(e)
