## Turn record combinators into explicit, typed constructions before
## ownership. A projection is a real read, not a decision made by an emitter.
import std/[tables, options]
import ast, ast_ops, ast_query, resolution, record_shape, lowering, codegen_common

proc lowerRecordArguments*(res: Resolution, m: Module,
                           real: Table[string, Module]) =
  ## A record standing for a function's payload becomes explicit projections
  ## before consumption inference. Unused fields remain owned by the record.
  for body in m.bodies:
    for e in body.nodes:
      if e.kind != exkCall or e.argsExploded: continue
      let picked = recordArgFields(res, m, real, e)
      if picked.isNone: continue
      let receiver = e.args[0]
      let defs = getFieldsForType(res, m, res.typeFor(receiver))
      var args: seq[Expr]
      for name in picked.get:
        var typ: Type
        for f in defs:
          if f.name == name: typ = f.typ
        args.add res.typed(Expr(kind: exkField, span: receiver.span,
          receiver: res.freshCopy(receiver), fieldName: name), typ)
      e.args = args
      e.argsExploded = true

proc lowerRecordCombinators*(res: Resolution, m: Module) =
  var serial = 0
  proc freshVariable(typ: Type, span: Span): Expr =
    inc serial
    res.typed(Expr(kind: exkVar, name: "tuckRecordTmp" & $serial, span: span), typ)
  proc bindValue(e: Expr, before: var seq[Expr]) =
    let typ = res.typeFor(e)
    let value = Expr()
    value[] = e[]
    let target = freshVariable(typ, e.span)
    e[] = res.freshCopy(target)[]
    let binding = Expr(kind: exkAssign, target: target, isDecl: true,
                        assignVal: value, span: value.span)
    let site = res.shortcut(value)
    if site.len > 0:
      res.setShortcut(binding, site)
      res.shortcuts.del value.id
    before.add binding
  proc lower(e: Expr, before: var seq[Expr])
  proc lower(e: Expr, before: var seq[Expr]) =
    if e == nil: return
    if e.kind notin {exkCall, exkBracket, exkBracketAssign} and res.hasCall(e):
      # Resolved sugar may carry fresh operand objects. Rewrite the call
      # actually emitted, not a stale syntax-only copy of its receiver.
      lower(res.call(e), before)
      return
    if e.kind == exkBlock:
      var stmts: seq[Expr]
      for s in e.stmts:
        var pre: seq[Expr]
        lower(s, pre)
        stmts.add pre
        stmts.add s
      e.stmts = stmts
      return
    if e.kind == exkBinary and e.binOp in {boAnd, boOr}:
      lower(e.left, before)
      var right: seq[Expr]
      lower(e.right, right)
      if right.len > 0:
        let typ = res.typeFor(e)
        let target = freshVariable(typ, e.span)
        before.add Expr(kind: exkAssign, target: target, isDecl: true,
                          declType: typ, span: e.span)
        right.add Expr(kind: exkAssign, target: res.freshCopy(target),
                        assignVal: e.right, span: e.span)
        let skipped = Expr(kind: exkAssign, target: res.freshCopy(target),
          assignVal: res.typed(Expr(kind: exkLit, litKind: lkBool,
            litValue: (if e.binOp == boOr: "true" else: "false")), typ))
        let evaluated = Expr(kind: exkBlock, stmts: right)
        let constant = Expr(kind: exkBlock, stmts: @[skipped])
        before.add res.typed(Expr(kind: exkIf, cond: e.left, span: e.span,
          thenBranch: (if e.binOp == boAnd: evaluated else: constant),
          elseBranch: (if e.binOp == boAnd: constant else: evaluated)),
          Type(kind: tkNamed, name: "unit"))
        e[] = res.freshCopy(target)[]
      return
    if e.kind == exkWhile:
      var head, body: seq[Expr]
      lower(e.whileCond, head)
      lower(e.whileBody, body)
      if body.len > 0:
        e.whileBody = Expr(kind: exkBlock, stmts: body & @[e.whileBody])
      if head.len > 0:
        let boolean = Type(kind: tkNamed, name: "bool")
        head.add res.typed(Expr(kind: exkIf, span: e.span,
          cond: res.typed(Expr(kind: exkUnary, unaryOp: uoNot,
                              operand: e.whileCond), boolean),
          thenBranch: Expr(kind: exkBlock, stmts: @[Expr(kind: exkBreak)])),
          Type(kind: tkNamed, name: "unit"))
        e.whileBody = Expr(kind: exkBlock, stmts: head & @[e.whileBody])
        e.whileCond = res.typed(Expr(kind: exkLit, litKind: lkBool,
                                    litValue: "true"), boolean)
      return
    if e.kind == exkFor:
      lower(e.iterable, before)
      var body: seq[Expr]
      lower(e.body, body)
      if body.len > 0: e.body = Expr(kind: exkBlock, stmts: body & @[e.body])
      return
    if e.kind == exkMatch:
      lower(e.subject, before)
      var prefixes: seq[seq[Expr]]
      var needsStatements = false
      for arm in e.arms:
        var pre: seq[Expr]
        lower(arm.body, pre)
        needsStatements = needsStatements or pre.len > 0
        prefixes.add pre
      let typ = res.typeFor(e)
      let isValue = typ != nil and
        not (typ.kind == tkNamed and typ.name in ["void", "unit"])
      if isValue and needsStatements:
        let target = freshVariable(typ, e.span)
        before.add Expr(kind: exkAssign, target: target, isDecl: true,
                          declType: typ, span: e.span)
        for i, arm in e.arms.mpairs:
          prefixes[i].add Expr(kind: exkAssign, target: res.freshCopy(target),
                                assignVal: arm.body, span: arm.body.span)
          arm.body = Expr(kind: exkBlock, stmts: prefixes[i])
        let statement = Expr()
        statement[] = e[]
        statement.id = newNodeId()
        res.setType(statement, Type(kind: tkNamed, name: "unit"))
        before.add statement
        e[] = res.freshCopy(target)[]
      else:
        for i, arm in e.arms.mpairs:
          if prefixes[i].len > 0:
            arm.body = Expr(kind: exkBlock, stmts: prefixes[i] & @[arm.body])
      return
    if e.kind == exkIf:
      lower(e.cond, before)
      var yes, no: seq[Expr]
      lower(e.thenBranch, yes)
      lower(e.elseBranch, no)
      if isValueIf(e) and (yes.len > 0 or no.len > 0):
        let typ = res.typeFor(e)
        let target = freshVariable(typ, e.span)
        # A compiler-generated, typed default declaration. Both branches
        # overwrite it; no branch expression executes during declaration.
        before.add Expr(kind: exkAssign, target: target, isDecl: true,
                          declType: typ, span: e.span)
        yes.add Expr(kind: exkAssign, target: res.freshCopy(target),
                      assignVal: e.thenBranch, span: e.span)
        no.add Expr(kind: exkAssign, target: res.freshCopy(target),
                     assignVal: e.elseBranch, span: e.span)
        before.add res.typed(Expr(kind: exkIf, cond: e.cond, span: e.span,
          thenBranch: Expr(kind: exkBlock, stmts: yes),
          elseBranch: Expr(kind: exkBlock, stmts: no)), Type(kind: tkNamed, name: "unit"))
        e[] = res.freshCopy(target)[]
      else:
        if yes.len > 0:
          e.thenBranch = Expr(kind: exkBlock, stmts: yes & @[e.thenBranch])
        if no.len > 0:
          e.elseBranch = Expr(kind: exkBlock, stmts: no & @[e.elseBranch])
      return
    var previous: seq[Expr]
    for c in e.children:
      var pre: seq[Expr]
      lower(c, pre)
      if pre.len > 0:
        # Evaluate earlier value operands before this child's new statements.
        # Syntax-only children have no value type and are never materialized.
        if e.kind in {exkStruct, exkList, exkCall, exkBinary, exkField, exkWrapOk}:
          for p in previous:
            if res.typeFor(p) != nil: bindValue(p, before)
          previous.setLen(0)
        before.add pre
      previous.add c
    if e.kind != exkCombinator: return
    let shape = shapeOf(m, res, e)
    if shape.ctor == ckPassThrough:
      let value = res.freshCopy(shape.passThrough)
      e[] = value[]
      return
    var receivers: Table[NodeId, Expr]
    for recv in shape.receivers:
      if recv.kind == exkVar and not res.hasCall(recv):
        receivers[recv.id] = recv
      else:
        let id = recv.id
        bindValue(recv, before)
        receivers[id] = recv
        receivers[recv.id] = recv
    let typ = res.typeFor(e)
    let defs = if shape.ctor == ckNamedType:
                 getFieldsForType(res, m, shape.namedType)
               else: shape.declFields
    var fields: seq[FieldInit]
    for f in shape.fields:
      var value: Expr
      if f.src == vsExpr:
        value = f.value
      else:
        var ft: Type
        for d in defs:
          if d.name == f.name: ft = d.typ
        value = res.typed(Expr(kind: exkField, span: e.span,
          receiver: res.freshCopy(receivers[f.fromExpr.id]),
          fieldName: f.fromField), ft)
      fields.add (name: f.name, value: value)
    let payloadType = Type(kind: tkRecord, fields: defs)
    let payload = res.typed(Expr(kind: exkStruct, fields: fields, span: e.span),
                            payloadType)
    let id = e.id
    if shape.ctor == ckNamedType:
      e[] = Expr(kind: exkCall, id: id, span: e.span, args: @[payload],
                  callee: Expr(kind: exkVar, name: shape.typeName))[]
    else:
      e[] = payload[]
      e.id = id
    res.setType(e, typ)
  for body in m.bodies:
    var before: seq[Expr]
    lower(body, before)
    doAssert before.len == 0, "record temporaries require a statement scope"
