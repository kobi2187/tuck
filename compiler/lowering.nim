# compiler/lowering.nim
#
# STAGE 7 OF THE PIPELINE — make the tree boring before emitting it.
#
# Lowering rewrites constructs that are pleasant to WRITE into constructs that
# are easy to EMIT. Every shape eliminated here is one that neither backend
# has to learn — and with two backends, that saving doubles.
#
# Two jobs in this compiler, both worth understanding as examples of the idea:
#
# 1. REGISTRY RAISES BECOME ORDINARY CALLS. `Registry.raise SomeEvent` reads
#    nicely and parses into an awkward tree: a call whose callee is a call
#    whose argument is a field access. Lowering flattens it into a plain call
#    to `raise_Registry_SomeEvent`. Codegen then emits it like any other call
#    and never learns that registries exist at all.
#
# 2. PAYLOAD EXPLOSION. Tuck lets you hand a struct to a function that declares
#    separate parameters, matched up BY NAME rather than by position. That
#    matching happens here, and the call is rewritten into positional
#    arguments, so codegen just emits arguments in order.
#
# Both have the same shape: something friendly at the source level becomes
# something dull before the emitter sees it. That is the entire purpose of a
# lowering pass, in any compiler.
#
# WHY EACH BACKEND LOWERS ITS OWN COPY. lowerModule mutates the tree in place.
# tuck.nim gives each backend a deepCopy to lower, because otherwise the second
# backend would be lowering already-lowered code — mangling names twice,
# exploding payloads that were already exploded. The passes here are written to
# be idempotent where practical, but the deep copy is what actually guarantees
# it.
import ast
import resolution, strutils
import ast_query

proc getFieldsForType*(m: Module, t: Type): seq[FieldDef]

proc namedTypeFields(m: Module, t: Type): seq[FieldDef] =
  ## The fields behind a NAME. Follows the edge the checker recorded
  ## (resolveTypeNames) rather than matching t.name against the decl list — the
  ## name is what the user wrote, the edge is what it means, and after mangling
  ## the two differ.
  var d = semLayer.declForType(t)
  if d == nil: d = m.findDecl(dkType, t.name)
  if d == nil: return @[]
  # An object keeps its fields in objFields, not typeBody, and `+ Record`
  # merges more in — composedFields answers both. Records fall through to
  # their body as before.
  if d.kind != dkType: return composedFields(m, d)
  getFieldsForType(m, d.typeBody)

proc renamedFields(m: Module, t: Type): seq[FieldDef] =
  ## The underlying type's fields, with `renames` applied to their names.
  result = getFieldsForType(m, t.underlying)
  for f in result.mitems:
    for r in t.renames:
      if f.name == r[0]:
        f.name = r[1]
        break

proc unionFields(m: Module, t: Type): seq[FieldDef] =
  ## Every member's fields, concatenated — a union is flattened, not tagged.
  for mem in t.members:
    result.add(getFieldsForType(m, mem))

proc getFieldsForType*(m: Module, t: Type): seq[FieldDef] =
  ## The fields of a type, whichever way it was written: an inline record has
  ## them directly, a named type needs its declaration looked up, a union or
  ## rename needs its members flattened first. Callers asking "what fields does
  ## this have?" should not have to care which case they are in.
  if t == nil: return @[]
  case t.kind
  of tkRecord: t.fields
  of tkNamed: namedTypeFields(m, t)
  of tkUnion: unionFields(m, t)
  of tkRename: renamedFields(m, t)
  # Named rather than `else: discard`: these kinds genuinely have no fields to
  # flatten, and saying so per kind means a new TypeKind stops compiling here
  # rather than silently answering "no fields".
  of tkTuple, tkApp, tkFunc, tkSum, tkEffect: @[]

proc lowerExpr(e: Expr, m: Module)

proc flattenRegistryRaise(e: Expr) =
  ## `Registry.raise SomeEvent` — a call whose callee is a call whose argument
  ## is a field access. Flatten it to a plain call to `raise_Registry_Event`,
  ## which codegen emits like any other and never learns registries exist.
  if e.callee == nil or e.callee.kind != exkCall: return
  if e.callee.callee == nil or e.callee.callee.kind != exkVar: return
  if e.callee.args.len != 1 or e.callee.args[0].kind != exkField: return
  let fieldNode = e.callee.args[0]
  if fieldNode.receiver == nil or fieldNode.receiver.kind != exkVar: return
  if fieldNode.fieldName != "raise": return
  e.callee = Expr(span: e.span, kind: exkVar,
                  name: "raise_" & fieldNode.receiver.name & "_" &
                        e.callee.callee.name)

proc memberParams(e: Expr, inner: Expr, m: Module): seq[string] =
  ## The member fn's parameter names, in order.
  ##
  ## The checker does not record callParams for a MEMBER call (finding F2 in
  ## the stage-boundary audit), so fall back to the declaration. `findFn` does
  ## NOT see object members — it walks top-level, mixin and extern fns —
  ## whereas `allFns` yields exactly the set whose bodies lowering rewrites.
  result = semLayer.callParamsFor(e)
  if result.len > 0 or inner.callee.kind != exkVar: return
  for d in m.allFns():
    if d.name == inner.callee.name:
      return d.paramNames()

proc payloadArgsForMember(e: Expr, params: seq[string]): seq[Expr] =
  ## The payload's fields, ordered to match the member's params and SKIPPING
  ## the receiver — the resolved inner call already supplied it, and the
  ## payload names `self` explicitly (it is an ordinary param, spec §5.1), so
  ## passing it again would duplicate the argument.
  let resolved = semLayer.argFieldsFor(e)
  for i, paramName in params:
    if paramName == "self": continue
    let fieldName = if i < resolved.len and resolved[i].len > 0: resolved[i]
                    else: paramName
    for field in e.args[0].fields:
      if field[0] == fieldName:
        result.add(field[1])
        break

proc flattenMemberCallPayload(e: Expr, m: Module) =
  ## `{self: b, count: 7} b.grow` — a call whose CALLEE is a member access the
  ## checker already resolved to its own call.
  ##
  ## Left alone the two calls nest: the callee emits `grow(b)` and the outer
  ## call appends its arguments, giving `grow(b)(b, 7)` — which every backend
  ## emitted, and which no target compiler accepts. `tuck ch` passed, so this
  ## reached all three as identically-wrong output.
  ##
  ## Same shape as flattenRegistryRaise above, and fixed the same way: one
  ## call, built once, here. Threading the receiver used to be left to the
  ## backends "which see the receiver" — but a decision made in three places
  ## was made wrong in three places.
  if e.callee == nil or e.callee.kind != exkField: return
  if not semLayer.hasCall(e.callee): return
  let inner = semLayer.call(e.callee)
  if inner == nil or inner.callee == nil: return
  var merged: seq[Expr]
  if inner.args.len > 0: merged.add(inner.args[0])   # the receiver
  let params = memberParams(e, inner, m)
  if params.len > 0 and e.args.len == 1 and e.args[0].kind == exkStruct:
    merged.add(payloadArgsForMember(e, params))
  else:
    for a in e.args: merged.add(a)
  e.callee = inner.callee
  e.args = merged

proc explodePayload(e: Expr) =
  ## `{a: 1, b: 2} f` -> `f(1, 2)`. One arg per declared param, in order.
  ##
  ## The checker recorded the callee's params when it resolved the call, and
  ## only for top-level fns — so a non-empty value already means "safe to
  ## explode". A member fn's payload explosion belongs to the backends, which
  ## see the receiver, and a task is theirs to schedule.
  ##
  ## A QUALIFIED callee (`fs::readFile`) explodes here too — the checker's
  ## mapping decides either way, so the callee's spelling was never a reason
  ## to treat the two differently. It used to be excluded, which left every
  ## backend re-implementing this loop for the qualified case.
  ##
  ## WHAT STILL REACHES THE BACKENDS, and why they keep a fallback: this
  ## pass needs `callParamsFor`, and the checker leaves it EMPTY for pending
  ## fns, distinct-type constructors (`5 Milliseconds`) and the combinators
  ## (`alias`) — measured, not assumed. Those fall through to a decl-list
  ## scan in the emitter. Filling them in at the checker is what would let
  ## the backend copies go.
  if e.callee == nil or e.callee.kind notin {exkVar, exkQualified}: return
  let expectedParams = semLayer.callParamsFor(e)
  if expectedParams.len == 0: return
  if e.args.len != 1 or e.args[0].kind != exkStruct: return

  # The checker's mapping wins. It matches a payload field to a param by NAME
  # first and then, for whatever is left, by TYPE when the match is
  # unambiguous (typecheck.nim, checkCallArgs pass 2) — so a field may
  # legitimately feed a param it shares no name with. Re-deriving the mapping
  # by name here would miss exactly those, and the unmatched-param fallback
  # below would then emit `none` in their place.
  let originalStruct = e.args[0]
  let resolved = semLayer.argFieldsFor(e)
  var newArgs: seq[Expr]
  for i, paramName in expectedParams:
    let fieldName = if i < resolved.len and resolved[i].len > 0: resolved[i]
                    else: paramName
    var found = false
    for field in originalStruct.fields:
      if field[0] == fieldName:
        newArgs.add(field[1])
        found = true
        break
    if not found:
      newArgs.add(Expr(span: e.span, kind: exkLit, litKind: lkUnit,
                       litValue: "none"))
  e.args = newArgs

proc lowerExpr(e: Expr, m: Module) =
  ## Rewrite one expression and everything under it.
  ##
  ## The traversal is `ast.children`; only two node kinds do anything beyond
  ## recursing, and both are calls. The bracket kinds are the one exception to
  ## the generic walk — they lower the checker-stamped `at()` call instead of
  ## their own children, because that call is what codegen emits and it is not
  ## a child of the sugar node.
  if e == nil: return
  case e.kind
  of exkBracket, exkBracketAssign:
    let c = semLayer.call(e)
    if c != nil: lowerExpr(c, m)
    return
  # Every other kind walks its children generically. Listed rather than
  # `else: discard` so adding an ExprKind forces a decision here.
  of exkLit, exkVar, exkField, exkQualified, exkStruct, exkList, exkCall,
     exkChain, exkBinary, exkUnary, exkBlock, exkIf, exkMatch, exkFor,
     exkWhile, exkBreak, exkContinue, exkAssign, exkReturn, exkRaise,
     exkImport, exkSend, exkSelect:
    discard

  for c in e.children: lowerExpr(c, m)

  if e.kind == exkCall:
    flattenRegistryRaise(e)
    flattenMemberCallPayload(e, m)
    explodePayload(e)

# Entry point for the pass. Two phases, in this order: type bodies are
# flattened first so the call-rewriting phase can look up a type's fields and
# get a plain record back, whatever the source declared.
proc mergeComposed(m: Module, d: Decl, compName: string,
                   kept: var seq[Decl]): bool =
  ## Merge one `+ compName` into object `d`. False when nothing by that name
  ## is declared, which leaves the entry in place as a sketch.
  for cd in m.decls:
    if cd == nil or cd.name != compName: continue
    if cd.kind == dkMixin:
      for mm in cd.mixinMembers:
        if mm != nil and mm.kind == dkFn and mm.fnBody != nil: kept.add(mm)
      return true
    if cd.kind == dkType and cd.typeBody != nil and
       cd.typeBody.kind == tkRecord:
      for f in cd.typeBody.fields: d.objFields.add(f)
      return true
  false

proc composeObject(m: Module, d: Decl) =
  ## Materialise every `+ X` entry in an object body, then drop the entry.
  ##
  ## `+` is SET UNION (spec §4.5), and it means two different things
  ## depending on what it names:
  ##   `+ AudioPlayer` — a record type: its FIELDS merge in flat.
  ##   `+ BulkOperations` — a mixin: its FNS become members of this object.
  ## Merge, not embed. Embedding a composed type as a nested field made the
  ## two forms mean different things, and the checker already treats a
  ## composed field as the object's own — `self.volume` typechecks, so the
  ## field has to actually be there.
  ##
  ## This ran at EMIT TIME in both existing backends, as two copies of the
  ## same walk (codegen.composeInto and codegen_odin's) differing only in
  ## how a field line is spelled. It is a whole-program fact, so it belongs
  ## here; each backend then emits a plain object and never learns that `+`
  ## exists. An unresolved name is left in place for the backend to report
  ## as a sketch, which is the one thing it does need to know.
  var kept: seq[Decl]
  for member in d.objMembers:
    if member == nil: continue
    if not isCompositionEntry(member):
      kept.add(member)
      continue
    if not mergeComposed(m, d, member.expr.operand.name, kept):
      kept.add(member)   # named nothing declared — sketch, the backend says so
  d.objMembers = kept

proc normalizeSelf(d: Decl) =
  ## An object member takes its object as `self`.
  ##
  ## This was re-derived at emit time by BOTH existing backends (codegen's
  ## genMemberFn and codegen_odin's genOdinMemberFn held the same twenty
  ## lines with one word different), and the D backend had no copy at all —
  ## which is how a zero-parameter member came to emit a fn taking nothing
  ## and a body still mentioning `self`.
  ##
  ## Only the two facts that are the same everywhere move here: `self`
  ## EXISTS, and the placeholder type `Self` means this object. HOW self is
  ## passed stays a backend question — Nim spells it `var T`, Odin `^T`,
  ## D `ref T` — decided from the parameter's name at emit time.
  ##
  ## Idempotent: a member that already declares `self` is left alone.
  let objType = Type(span: d.span, kind: tkNamed, name: d.name)
  for mem in d.objMembers:
    if mem == nil or mem.kind != dkFn: continue
    var hasSelf = false
    for i in 0 ..< mem.fnParams.len:
      if mem.fnParams[i].name == "self": hasSelf = true
      let pt = mem.fnParams[i].typ
      if pt != nil and pt.kind == tkNamed and pt.name == "Self":
        mem.fnParams[i].typ = objType
    if mem.fnReturnType != nil and mem.fnReturnType.kind == tkNamed and
       mem.fnReturnType.name == "Self":
      mem.fnReturnType = objType
    if not hasSelf:
      mem.fnParams = @[Param(name: "self", typ: objType, span: mem.span)] &
                     mem.fnParams

proc lowerModule*(m: Module) =
  ## Rewrite a module in place into the simpler form the backends expect.
  # Phase 1: union / rename type bodies collapse to plain records
  for d in m.decls(dkType):
    if d.typeBody != nil and d.typeBody.kind in {tkUnion, tkRename}:
      d.typeBody = Type(span: d.typeBody.span, kind: tkRecord,
                        fields: getFieldsForType(m, d.typeBody),
                        attrs: d.typeBody.attrs)

  # Composition first: a mixin fn spliced in here must still get its `self`
  # from normalizeSelf below, so the order is load-bearing.
  for d in m.decls(dkObject):
    composeObject(m, d)
    normalizeSelf(d)

  # Phase 2: rewrite call arguments (subset matching) in every fn body
  #
  # Tasks are walked SEPARATELY, for the same reason rewriteModule does it:
  # allFns yields dkFn (plus nested fn members), and a task keeps its body in
  # taskBody, which is an Expr rather than a member Decl. Omitting this line
  # meant a task body reached codegen UNLOWERED — a registry raise inside a
  # task emitted `LowMemory(tuck_AppEvents.raise)(42)`, the awkward pre-lowering
  # tree, which is not valid Nim. rewrite.nim's own comment recorded this gap
  # before it was fixed here.
  for fn in m.allFns():
    lowerExpr(fn.fnBody, m)
  for d in m.decls(dkTask):
    lowerExpr(d.taskBody, m)
  for d in m.decls(dkExpr):
    lowerExpr(d.expr, m)
