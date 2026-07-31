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
    let d = m.findDecl(dkType, t.name)
    if d != nil: return getFieldsForType(m, d.typeBody)
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

proc lookupRegistryVariantParams(m: Module, registryName, variantName: string): seq[string] =
  let d = m.findDecl(dkRegistry, registryName)
  if d == nil: return @[]
  for v in d.variants:
    if v.name == variantName:
      for f in v.fields: result.add(f.name)
      return result
  @[]

proc lowerExpr(e: Expr, m: Module)

proc lowerExpr(e: Expr, m: Module) =
  if e == nil: return
  case e.kind
  of exkField:
    lowerExpr(e.receiver, m)
  of exkCall:
    lowerExpr(e.callee, m)
    for a in e.args:
      lowerExpr(a, m)
    
    # Check if this is an Event Registry raise call:
    # e.callee: exkCall(callee: exkVar(name: variantName), args: [exkField(receiver: exkVar(name: registryName), fieldName: "raise")])
    if e.callee != nil and e.callee.kind == exkCall and e.callee.callee != nil and e.callee.callee.kind == exkVar:
      if e.callee.args.len == 1 and e.callee.args[0].kind == exkField:
        let fieldNode = e.callee.args[0]
        if fieldNode.receiver != nil and fieldNode.receiver.kind == exkVar and fieldNode.fieldName == "raise":
          let registryName = fieldNode.receiver.name
          let variantName = e.callee.callee.name
          e.callee = Expr(span: e.span, kind: exkVar, name: "raise_" & registryName & "_" & variantName)
    
    let calleeName = if e.callee != nil and e.callee.kind == exkVar: e.callee.name else: ""
    if calleeName != "":
      var expectedParams: seq[string]
      if calleeName.startsWith("raise_"):
        let parts = calleeName.split("_")
        if parts.len == 3:
          expectedParams = lookupRegistryVariantParams(m, parts[1], parts[2])
      elif e.resolvedParams.len > 0:
        # TOP-LEVEL dkFn ONLY, deliberately. A member fn's payload explosion is
        # the backends' job (they see the receiver) and doing it here too would
        # apply it twice; a TASK is likewise left alone, since scheduling it is
        # the backends' concern.
        #
        # The checker recorded these when it resolved the call, and only for
        # top-level fns — so a non-empty value already means "safe to explode"
        # and no lookup is needed to find that out. Asking the decl list here
        # instead costs a scan per call expression, which is quadratic over a
        # module (lowering grew 18.3x across an 8x input increase while lexing
        # and parsing grew 8.9x; benches/bench_phases.nim).
        expectedParams = e.resolvedParams
        
      if expectedParams.len > 0 and e.args.len == 1 and e.args[0].kind == exkStruct:
        var newArgs: seq[Expr]
        let originalStruct = e.args[0]
        for paramName in expectedParams:
          var found = false
          for field in originalStruct.fields:
            if field[0] == paramName:
              newArgs.add(field[1])
              found = true
              break
          if not found:
            newArgs.add(Expr(span: e.span, kind: exkLit, litKind: lkUnit, litValue: "none"))
        e.args = newArgs
  of exkStruct:
    for f in e.fields:
      lowerExpr(f[1], m)
  of exkList:
    for item in e.items:
      lowerExpr(item, m)
  of exkBinary:
    lowerExpr(e.left, m)
    lowerExpr(e.right, m)
  of exkUnary:
    lowerExpr(e.operand, m)
  of exkBlock:
    for s in e.stmts:
      lowerExpr(s, m)
  of exkIf:
    lowerExpr(e.cond, m)
    lowerExpr(e.thenBranch, m)
    lowerExpr(e.elseBranch, m)
  of exkMatch:
    lowerExpr(e.subject, m)
    for arm in e.arms:
      lowerExpr(arm.body, m)
  of exkFor:
    lowerExpr(e.iterable, m)
    lowerExpr(e.body, m)
  of exkWhile:
    if e.whileCond != nil: lowerExpr(e.whileCond, m)
    lowerExpr(e.whileBody, m)
  of exkBreak, exkContinue:
    discard
  of exkAssign:
    lowerExpr(e.target, m)
    lowerExpr(e.assignVal, m)
  of exkReturn:
    lowerExpr(e.returnVal, m)
  of exkRaise:
    lowerExpr(e.raiseVal, m)
  of exkChain:
    lowerExpr(e.base, m)
    for step in e.steps:
      lowerExpr(step.target, m)
      lowerExpr(step.arg, m)
  of exkBracket:
    # the checker-stamped at() call is what codegen emits — lower it, not
    # the sugar node (a type application has no call and nothing to lower)
    let c = semLayer.call(e)
    if c != nil: lowerExpr(c, m)
  of exkBracketAssign:
    let c = semLayer.call(e)
    if c != nil: lowerExpr(c, m)
  of exkLit, exkVar, exkQualified, exkImport:
    # leaves: nothing beneath them to lower
    discard
  of exkSend:
    lowerExpr(e.sendPayload, m)
  of exkSelect:
    for arm in e.selArms:
      lowerExpr(arm.arg, m); lowerExpr(arm.body, m)

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
