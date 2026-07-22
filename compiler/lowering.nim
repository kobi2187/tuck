# compiler/lowering.nim
import ast
import resolution, strutils

proc getFieldsForType*(m: Module, t: Type): seq[FieldDef] =
  if t == nil: return @[]
  case t.kind
  of tkRecord:
    return t.fields
  of tkNamed:
    for d in m.decls:
      if d.kind == dkType and d.name == t.name:
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

proc lookupFnParams(m: Module, name: string): seq[string] =
  for d in m.decls:
    if d.kind == dkFn and d.name == name:
      var res: seq[string]
      for p in d.fnParams:
        res.add(p.name)
      return res
  return @[]

proc lookupRegistryVariantParams(m: Module, registryName: string, variantName: string): seq[string] =
  for d in m.decls:
    if d.kind == dkRegistry and d.name == registryName:
      for v in d.variants:
        if v.name == variantName:
          var res: seq[string]
          for f in v.fields:
            res.add(f.name)
          return res
  return @[]

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
      else:
        expectedParams = lookupFnParams(m, calleeName)
        
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
    let c = current.call(e)
    if c != nil: lowerExpr(c, m)
  of exkBracketAssign:
    let c = current.call(e)
    if c != nil: lowerExpr(c, m)
  of exkLit, exkVar, exkQualified, exkImport:
    # leaves: nothing beneath them to lower
    discard

proc lowerModule*(m: Module) =
  # Phase 1: Lower Union / Rename Types to Records
  for d in m.decls:
    if d.kind == dkType and d.typeBody != nil and (d.typeBody.kind == tkUnion or d.typeBody.kind == tkRename):
      let flattenedFields = getFieldsForType(m, d.typeBody)
      d.typeBody = Type(span: d.typeBody.span, kind: tkRecord, fields: flattenedFields, attrs: d.typeBody.attrs)
  
  # Phase 2: Lower Expressions (Subset Matching Call argument rewrites)
  for d in m.decls:
    case d.kind
    of dkFn:
      lowerExpr(d.fnBody, m)
    of dkObject:
      for member in d.objMembers:
        if member.kind == dkFn:
          lowerExpr(member.fnBody, m)
    of dkType:
      for member in d.typeMembers:
        if member.kind == dkFn:
          lowerExpr(member.fnBody, m)
    of dkMixin:
      for member in d.mixinMembers:
        if member.kind == dkFn:
          lowerExpr(member.fnBody, m)
    of dkExpr:
      lowerExpr(d.expr, m)
    else:
      discard
