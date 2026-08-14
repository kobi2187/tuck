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

proc getFieldsForType*(m: Module, t: Type): seq[FieldDef] =
  ## The fields of a type, whichever way it was written: an inline record has
  ## them directly, a named type needs its declaration looked up, a union or
  ## rename needs its members flattened first. Callers asking "what fields does
  ## this have?" should not have to care which case they are in.
  if t == nil: return @[]
  case t.kind
  of tkRecord:
    return t.fields
  of tkNamed:
    # Follow the edge the checker recorded (resolveTypeNames) rather than
    # matching t.name against the decl list — the name is what the user wrote,
    # the edge is what it means, and after mangling the two differ.
    var d = semLayer.declForType(t)
    if d == nil: d = m.findDecl(dkType, t.name)
    if d != nil:
      # An object keeps its fields in objFields, not typeBody, and `+ Record`
      # merges more in — composedFields answers both. Records fall through to
      # their body as before.
      if d.kind != dkType: return composedFields(m, d)
      return getFieldsForType(m, d.typeBody)
  of tkUnion:
    var res: seq[FieldDef]
    for mem in t.members:
      res.add(getFieldsForType(m, mem))
    return res
  of tkRename:
    var fields = getFieldsForType(m, t.underlying)
    for f in fields.mitems:
      for r in t.renames:
        if f.name == r[0]:
          f.name = r[1]
          break
    return fields
  else:
    discard
  return @[]

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

proc explodePayload(e: Expr) =
  ## `{a: 1, b: 2} f` -> `f(1, 2)`. One arg per declared param, in order.
  ##
  ## The checker recorded the callee's params when it resolved the call, and
  ## only for top-level fns — so a non-empty value already means "safe to
  ## explode". A member fn's payload explosion belongs to the backends, which
  ## see the receiver, and a task is theirs to schedule.
  if e.callee == nil or e.callee.kind != exkVar: return
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
  else: discard

  for c in e.children: lowerExpr(c, m)

  if e.kind == exkCall:
    flattenRegistryRaise(e)
    explodePayload(e)

# Entry point for the pass. Two phases, in this order: type bodies are
# flattened first so the call-rewriting phase can look up a type's fields and
# get a plain record back, whatever the source declared.
proc lowerModule*(m: Module) =
  ## Rewrite a module in place into the simpler form the backends expect.
  # Phase 1: union / rename type bodies collapse to plain records
  for d in m.decls(dkType):
    if d.typeBody != nil and d.typeBody.kind in {tkUnion, tkRename}:
      d.typeBody = Type(span: d.typeBody.span, kind: tkRecord,
                        fields: getFieldsForType(m, d.typeBody),
                        attrs: d.typeBody.attrs)

  # Phase 2: rewrite call arguments (subset matching) in every fn body
  for fn in m.allFns():
    lowerExpr(fn.fnBody, m)
  for d in m.decls(dkExpr):
    lowerExpr(d.expr, m)
