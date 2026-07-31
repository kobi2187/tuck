# compiler/ast_serializer.nim
#
# The AST as JSON — a debugging window, not part of the pipeline.
#
# `tuck p file.tuck --ast` prints the tree this produces. That is the fastest
# way to answer "what did the parser actually build?", and the fastest way to
# see what mangling renamed, since you can diff the tree before and after a
# pass.
#
# If you are learning how this compiler works, run it on a three-line file
# early. Seeing text become tokens become a tree makes the first three stages
# concrete in a way that reading about them does not.
#
# EXHAUSTIVE ON PURPOSE — no `else: discard` anywhere in this file.
#
# Every `case` here covers every node kind, so Nim's exhaustiveness check
# applies: add a kind to ast.nim and this file stops compiling until it is
# handled. That keeps the dump honest — whatever the parser built, the dump
# shows — and makes this the cheapest place in the codebase to catch a node
# kind nobody has wired up yet. A dump is not correctness critical, so the
# forced update costs a minute and surfaces the omission before codegen hits
# it.
import std/json, ast

proc toJson*(t: Type): JsonNode
proc toJson*(e: Expr): JsonNode
proc toJson*(p: Pattern): JsonNode
proc toJson*(d: Decl): JsonNode

proc paramsJson(params: seq[Param]): JsonNode =
  ## `[{name, typ}, ...]` — the shape used wherever a node carries params.
  result = newJArray()
  for p in params:
    var pj = newJObject()
    pj["name"] = %p.name
    pj["typ"] = toJson(p.typ)
    result.add(pj)

proc fieldsJson(fields: seq[FieldDef]): JsonNode =
  ## `[{name, typ}, ...]` — same, for declared fields.
  result = newJArray()
  for f in fields:
    var fj = newJObject()
    fj["name"] = %f.name
    fj["typ"] = toJson(f.typ)
    result.add(fj)

proc declsJson(decls: seq[Decl]): JsonNode =
  ## A list of member declarations.
  result = newJArray()
  for d in decls: result.add(toJson(d))

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
  of exkWhile:
    res["whileCond"] = toJson(e.whileCond)
    res["whileBody"] = toJson(e.whileBody)
  of exkBreak, exkContinue:
    discard
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
  of exkBracket:
    res["receiver"] = toJson(e.brReceiver)
    var brArgs = newJArray()
    for a in e.brArgs: brArgs.add(toJson(a))
    res["args"] = brArgs
  of exkBracketAssign:
    res["target"] = toJson(e.brTarget)
    res["val"] = toJson(e.brValue)
  of exkQualified:
    res["modulePath"] = %e.modulePath
    res["qualName"] = %e.qualName
  of exkImport:
    res["path"] = %e.path
  of exkSend:
    res["actor"] = %e.sendActor
    res["handler"] = %e.sendHandler
    if e.sendPayload != nil: res["payload"] = toJson(e.sendPayload)
  of exkSelect:
    var arms = newJArray()
    for arm in e.selArms:
      var aj = newJObject()
      aj["source"] = %arm.source
      if arm.arg != nil: aj["arg"] = toJson(arm.arg)
      if arm.binding.len > 0: aj["binding"] = paramsJson(arm.binding)
      aj["body"] = toJson(arm.body)
      arms.add(aj)
    res["arms"] = arms
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
    res["generics"] = %d.fnGenerics
    res["params"] = paramsJson(d.fnParams)
    res["returnType"] = toJson(d.fnReturnType)
    var effects = newJArray()
    for eff in d.fnEffects: effects.add(% $eff)
    res["effects"] = effects
    res["body"] = toJson(d.fnBody)
    res["isPending"] = %d.isPending
    res["isDecision"] = %d.isDecision
    res["isExtern"] = %d.isExtern
    res["isInline"] = %d.isInline
    if d.externHeader != "": res["externHeader"] = %d.externHeader
    if d.externEmit != "": res["externEmit"] = %d.externEmit
    if d.externLib != "": res["externLib"] = %d.externLib
    if d.fnErrorTypes.len > 0: res["errorTypes"] = %d.fnErrorTypes
  of dkRegister:
    res["address"] = %d.regAddress
    res["fields"] = fieldsJson(d.regFields)
  of dkActor:
    res["fields"] = fieldsJson(d.actorFields)
    res["handlers"] = declsJson(d.handlers)
  of dkExpr:
    res["expr"] = toJson(d.expr)
  of dkTask:
    res["params"] = paramsJson(d.taskParams)
    res["returnType"] = toJson(d.taskReturnType)
    var effects = newJArray()
    for eff in d.taskEffects: effects.add(% $eff)
    res["effects"] = effects
    res["body"] = toJson(d.taskBody)
  of dkMixin, dkExtern, dkPending:
    res["members"] = declsJson(d.mixinMembers)
  of dkRegistry:
    var variants = newJArray()
    for v in d.variants:
      var vj = newJObject()
      vj["name"] = %v.name
      vj["fields"] = fieldsJson(v.fields)
      if v.value != "": vj["value"] = %v.value
      variants.add(vj)
    res["variants"] = variants
  of dkPool:
    res["elem"] = toJson(d.poolElem)
    res["count"] = %d.poolCount
  of dkFnSig:
    res["params"] = paramsJson(d.sigParams)
    res["returnType"] = toJson(d.sigReturn)
    res["isCCallback"] = %d.sigIsCCallback
  of dkConst:
    res["val"] = toJson(d.constVal)
  of dkStaticAssert:
    res["assert"] = toJson(d.assertExpr)
  of dkErrors:
    res["policy"] = %d.policyName
    if d.errHandler != nil: res["handler"] = toJson(d.errHandler)
  of dkImport:
    discard  # the module name is already in `name`
  of dkSelect:
    var arms = newJArray()
    for arm in d.selectArms:
      var aj = newJObject()
      aj["source"] = %arm.source
      if arm.arg != nil: aj["arg"] = toJson(arm.arg)
      if arm.binding.len > 0: aj["binding"] = paramsJson(arm.binding)
      aj["body"] = toJson(arm.body)
      arms.add(aj)
    res["arms"] = arms
  return res

proc toJson*(m: Module): JsonNode =
  var res = newJObject()
  var decls = newJArray()
  for d in m.decls:
    decls.add(toJson(d))
  res["decls"] = decls
  return res
