# compiler/ast_serializer.nim
import std/json, ast

proc toJson*(t: Type): JsonNode
proc toJson*(e: Expr): JsonNode
proc toJson*(p: Pattern): JsonNode
proc toJson*(d: Decl): JsonNode

proc toJson*(t: Type): JsonNode =
  if t == nil: return newJNull()
  var res = newJObject()
  res["kind"] = % $t.kind
  case t.kind
  of tkNamed:
    res["name"] = %t.name
  of tkTuple:
    var elems = newJArray()
    for el in t.elems: elems.add(toJson(el))
    res["elems"] = elems
  of tkApp:
    res["base"] = toJson(t.base)
    var args = newJArray()
    for a in t.args: args.add(toJson(a))
    res["args"] = args
  of tkFunc:
    var params = newJArray()
    for p in t.params: params.add(toJson(p))
    res["params"] = params
    res["result"] = toJson(t.result)
  of tkRecord:
    var fields = newJArray()
    for f in t.fields:
      var fj = newJObject()
      fj["name"] = %f.name
      fj["typ"] = toJson(f.typ)
      fields.add(fj)
    res["fields"] = fields
  of tkSum:
    var variants = newJArray()
    for v in t.variants:
      var vj = newJObject()
      vj["name"] = %v.name
      if v.fields.len > 0:
        var vf = newJArray()
        for f in v.fields:
          var fj = newJObject()
          fj["name"] = %f.name
          fj["typ"] = toJson(f.typ)
          vf.add(fj)
        vj["fields"] = vf
      variants.add(vj)
    res["variants"] = variants
    var transitions = newJArray()
    for tr in t.transitions:
      var tj = newJObject()
      tj["from"] = %tr.`from`
      tj["to"] = %tr.to
      transitions.add(tj)
    res["transitions"] = transitions
  of tkUnion:
    var members = newJArray()
    for m in t.members: members.add(toJson(m))
    res["members"] = members
  of tkEffect:
    res["inner"] = toJson(t.inner)
    var effects = newJArray()
    for ef in t.effects: effects.add(% $ef)
    res["effects"] = effects
  of tkRename:
    res["underlying"] = toJson(t.underlying)
    var renames = newJArray()
    for r in t.renames:
      var rj = newJObject()
      rj["original"] = %r[0]
      rj["target"] = %r[1]
      renames.add(rj)
    res["renames"] = renames
  return res

proc toJson*(e: Expr): JsonNode =
  if e == nil: return newJNull()
  var res = newJObject()
  res["kind"] = % $e.kind
  case e.kind
  of exkLit:
    res["litKind"] = % $e.litKind
    res["value"] = %e.litValue
  of exkVar:
    res["name"] = %e.name
  of exkField:
    res["receiver"] = toJson(e.receiver)
    res["fieldName"] = %e.fieldName
  of exkCall:
    res["callee"] = toJson(e.callee)
    var args = newJArray()
    for a in e.args: args.add(toJson(a))
    res["args"] = args
  of exkStruct:
    var fields = newJArray()
    for f in e.fields:
      var fj = newJObject()
      fj["name"] = %f[0]
      fj["val"] = toJson(f[1])
      fields.add(fj)
    res["fields"] = fields
  of exkList:
    var items = newJArray()
    for item in e.items: items.add(toJson(item))
    res["items"] = items
  of exkBinary:
    res["op"] = % $e.binOp
    res["left"] = toJson(e.left)
    res["right"] = toJson(e.right)
  of exkUnary:
    res["op"] = % $e.unaryOp
    res["operand"] = toJson(e.operand)
  of exkBlock:
    var stmts = newJArray()
    for s in e.stmts: stmts.add(toJson(s))
    res["stmts"] = stmts
  of exkIf:
    res["cond"] = toJson(e.cond)
    res["thenBranch"] = toJson(e.thenBranch)
    if e.elseBranch != nil: res["elseBranch"] = toJson(e.elseBranch)
  of exkMatch:
    if e.subject != nil: res["subject"] = toJson(e.subject)
    var arms = newJArray()
    for arm in e.arms:
      var aj = newJObject()
      aj["pattern"] = toJson(arm.pattern)
      if arm.guard != nil: aj["guard"] = toJson(arm.guard)
      aj["body"] = toJson(arm.body)
      arms.add(aj)
    res["arms"] = arms
  of exkFor:
    res["iter"] = toJson(e.iter)
    res["iterable"] = toJson(e.iterable)
    res["body"] = toJson(e.body)
  of exkAssign:
    res["target"] = toJson(e.target)
    res["val"] = toJson(e.assignVal)
  of exkReturn:
    if e.returnVal != nil: res["val"] = toJson(e.returnVal)
  of exkRaise:
    res["val"] = toJson(e.raiseVal)
  of exkChain:
    res["base"] = toJson(e.base)
    var steps = newJArray()
    for s in e.steps:
      var sj = newJObject()
      sj["target"] = toJson(s.target)
      if s.arg != nil: sj["arg"] = toJson(s.arg)
      steps.add(sj)
    res["steps"] = steps
  else:
    discard
  return res

proc toJson*(p: Pattern): JsonNode =
  if p == nil: return newJNull()
  var res = newJObject()
  res["kind"] = % $p.kind
  case p.kind
  of pkWild: discard
  of pkVar:
    res["name"] = %p.name
  of pkLit:
    res["value"] = %p.litValue
  of pkTuple:
    var elems = newJArray()
    for el in p.elems: elems.add(toJson(el))
    res["elems"] = elems
  of pkRecord:
    var fields = newJArray()
    for f in p.fields:
      var fj = newJObject()
      fj["name"] = %f[0]
      fj["pattern"] = toJson(f[1])
      fields.add(fj)
    res["fields"] = fields
  of pkOr:
    res["left"] = toJson(p.left)
    res["right"] = toJson(p.right)
  return res

proc toJson*(d: Decl): JsonNode =
  if d == nil: return newJNull()
  var res = newJObject()
  res["name"] = %d.name
  res["kind"] = % $d.kind
  case d.kind
  of dkType:
    res["typeBody"] = toJson(d.typeBody)
    var members = newJArray()
    for m in d.typeMembers: members.add(toJson(m))
    res["typeMembers"] = members
  of dkObject:
    var fields = newJArray()
    for f in d.objFields:
      var fj = newJObject()
      fj["name"] = %f.name
      fj["typ"] = toJson(f.typ)
      fields.add(fj)
    res["fields"] = fields
    var members = newJArray()
    for m in d.objMembers: members.add(toJson(m))
    res["members"] = members
  of dkFn:
    var params = newJArray()
    for p in d.fnParams:
      var pj = newJObject()
      pj["name"] = %p.name
      pj["typ"] = toJson(p.typ)
      params.add(pj)
    res["params"] = params
    res["body"] = toJson(d.fnBody)
  of dkRegister:
    res["address"] = %d.regAddress
    var fields = newJArray()
    for f in d.regFields:
      var fj = newJObject()
      fj["name"] = %f.name
      fj["typ"] = toJson(f.typ)
      fields.add(fj)
    res["fields"] = fields
  of dkActor:
    var fields = newJArray()
    for f in d.actorFields:
      var fj = newJObject()
      fj["name"] = %f.name
      fj["typ"] = toJson(f.typ)
      fields.add(fj)
    res["fields"] = fields
    var handlers = newJArray()
    for h in d.handlers: handlers.add(toJson(h))
    res["handlers"] = handlers
  of dkExpr:
    res["expr"] = toJson(d.expr)
  else:
    discard
  return res

proc toJson*(m: Module): JsonNode =
  var res = newJObject()
  var decls = newJArray()
  for d in m.decls:
    decls.add(toJson(d))
  res["decls"] = decls
  return res
