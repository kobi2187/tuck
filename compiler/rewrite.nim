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
import ../lexer
from diagnostics import DiagCode, dcCoUnknownRename, dcMeSlabInValue, code
from ast_query import isCompositionEntry, compositionTargetName
from ast_ops import clearIds, nodes

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

proc failRewrite(dc: DiagCode, msg: string, sp: Span,
                 stage = "Composition Error") =
  ## A declaration the language cannot honour. A SyntaxError because this
  ## stage runs inside parseSource, whose one error type that is;
  ## parseSource fills in the source line for the caret.
  var err = newException(SyntaxError, msg)
  err.line = sp.line
  err.col = sp.col
  err.stage = stage
  err.code = code(dc)
  raise err

proc failComposition(dc: DiagCode, msg: string, sp: Span) =
  ## A `+ Name {…}` entry the language cannot honour.
  failRewrite(dc, msg, sp)

proc checkRenamesExist(entry: Decl, target: string, names: seq[string]) =
  ## Every `{old -> new}` on a `+ target` entry must rename one of `names`:
  ## a rename of nothing would silently do nothing.
  for (old, renamed) in entry.renames:
    if old notin names:
      failComposition(dcCoUnknownRename,
        "`+ " & target & " {" & old & " -> " & renamed & "}` renames '" &
        old & "', but '" & target & "' has no fn or field '" & old & "'",
        entry.span)

proc renameSelfMember(fn: Decl, old, renamed: string) =
  ## Inside a copied mixin fn, `self.old` means the member the object now
  ## holds as `renamed` — the mixin's own code follows its rename.
  if fn.fnParams.len == 0 or fn.fnBody == nil: return
  let selfName = fn.fnParams[0].name
  for n in nodes(fn.fnBody):
    if n.kind == exkField and n.fieldName == old and n.receiver != nil and
       n.receiver.kind == exkVar and n.receiver.name == selfName:
      n.fieldName = renamed

proc composedMixinMembers(mx: Decl, entry: Decl): seq[Decl] =
  ## What `+ Mixin {old -> new}` brings into an object: a private copy of
  ## each of its fns with a body, a renamed one under its new name. A COPY,
  ## because binding `Self` rewrites the member — two objects composing one
  ## mixin must not share, and bind, the same node. The copy's ids are
  ## cleared: ids key the semantic layer, and a copy still carrying the
  ## original's would read and write its types. parseSource's fillIds
  ## numbers it afresh.
  ##
  ## A rename may name a body-less member too: that is a fn the mixin
  ## REQUIRES of the object, and the rename says the object provides it
  ## under the new name. Either way the copied bodies' `self.old` follow.
  var names: seq[string]
  for mm in mx.mixinMembers:
    if mm != nil and mm.kind == dkFn: names.add(mm.name)
  checkRenamesExist(entry, mx.name, names)
  for mm in mx.mixinMembers:
    if mm != nil and mm.kind == dkFn and mm.fnBody != nil:
      let copy = deepCopy(mm)
      clearIds(copy)
      for (old, renamed) in entry.renames:
        if copy.name == old: copy.name = renamed
        renameSelfMember(copy, old, renamed)
      result.add(copy)

proc checkRecordRenames(records: Table[string, Decl], entry: Decl) =
  ## `+ Record {old -> new}` on a record this module declares: every `old`
  ## must be one of its fields. The merge itself happens in lowering
  ## (mergeComposed) and in the checker's field view (composedFields).
  let target = compositionTargetName(entry)
  if entry.renames.len == 0 or target notin records: return
  var names: seq[string]
  for f in records[target].typeBody.fields: names.add(f.name)
  checkRenamesExist(entry, target, names)

proc isRecordDecl(d: Decl): bool =
  ## A `type` declaring a record — what `+ Name` merges fields from.
  d.kind == dkType and d.typeBody != nil and d.typeBody.kind == tkRecord

proc composedEntry(mem: Decl, mixins, records: Table[string, Decl]): seq[Decl] =
  ## What one object-body member becomes: a `+ Mixin` entry, the mixin's
  ## copied fns; anything else, itself (a `+ Record` entry's renames checked
  ## here, its fields merged later).
  if mem == nil or not isCompositionEntry(mem): return @[mem]
  let target = compositionTargetName(mem)
  if target in mixins: return composedMixinMembers(mixins[target], mem)
  checkRecordRenames(records, mem)
  @[mem]

proc composeMixins(m: Module) =
  ## `+ Mixin` in an object means the mixin's fns ARE the object's members
  ## (spec §4.5: composition is set union). Materialised here, before the
  ## checker, so a call on the object finds the member with `Self` bound to
  ## this object and the copied body is checked against this object's
  ## fields. Only a mixin this module declares — the same reach lowering's
  ## merge had; an entry naming anything else stays for later stages (a
  ## record's fields merge in lowering; an unknown name is a sketch).
  var mixins, records: Table[string, Decl]
  for d in m.decls:
    if d == nil: continue
    if d.kind == dkMixin: mixins[d.name] = d
    if isRecordDecl(d): records[d.name] = d
  for d in m.decls:
    if d == nil or d.kind != dkObject: continue
    var members: seq[Decl]
    for mem in d.objMembers:
      members.add(composedEntry(mem, mixins, records))
    d.objMembers = members
    let owner = Type(span: d.span, kind: tkNamed, name: d.name)
    for mem in d.objMembers: bindSelf(mem, owner)

proc failSlabInValue(owner: Decl, slab: Decl) =
  failRewrite(dcMeSlabInValue, (if slab.kind == dkArena: "arena '" else: "slab '") &
              slab.name & "' is declared inside " &
              (if owner.kind == dkMixin: "mixin '" else: "object '") &
              owner.name & "'. A slab belongs to the module or to an " &
              "actor; an object is a value, and each copy would need a slab " &
              "of its own. Declare it at top level, and keep references to " &
              "its cells in the object's fields", slab.span, "Memory Error")

proc liftActorSlabs(a: Decl, decls: var seq[Decl]) =
  ## An actor's slabs and arenas, out of its body and onto `decls`, owned by
  ## it.
  var kept: seq[Decl]
  for mem in a.handlers:
    if mem != nil and mem.kind == dkSlab:
      mem.slabOwner = a.name
      decls.add mem
    elif mem != nil and mem.kind == dkArena:
      mem.arenaOwner = a.name
      decls.add mem
    else: kept.add mem
  a.handlers = kept

proc refuseSlabsIn(owner: Decl, members: seq[Decl]) =
  for mem in members:
    if mem != nil and mem.kind in {dkSlab, dkArena}: failSlabInValue(owner, mem)

proc hoistSlabs(m: var Module) =
  ## A slab declared inside an actor belongs to that actor (slab proposal
  ## §7): lifted to the module's top level, just before the actor, carrying
  ## its owner — so every later stage sees one kind of slab, and slab_owner
  ## refuses any other owner reaching it. Inside an object or a mixin it is
  ## refused (TK-ME03).
  var decls: seq[Decl]
  for d in m.decls:
    if d != nil:
      case d.kind
      of dkActor: liftActorSlabs(d, decls)
      of dkObject: refuseSlabsIn(d, d.objMembers)
      of dkMixin: refuseSlabsIn(d, d.mixinMembers)
      of dkType, dkFn, dkTask, dkInterface, dkGroup, dkRegistry, dkPool,
         dkSlab, dkArena, dkExpr, dkConst, dkRegister, dkStaticAssert, dkErrors,
         dkImport, dkSelect, dkFnSig, dkSatisfies, dkWhen, dkPublic,
         dkResources, dkExtern, dkPending:
        discard
    decls.add d
  m.decls = decls

proc rewriteModule*(m: var Module) =
  ## Normalize a module in place, over EVERY body (`ast_ops.bodies`) — a
  ## hand-rolled walk over decl kinds is how dkActor, and later task bodies,
  ## came to be silently skipped. Mixins compose first, so the bodies they
  ## copy into objects are walked like any other.
  hoistSlabs(m)
  composeMixins(m)
  for e in m.bodies: rewriteExpr(e)
