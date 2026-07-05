# compiler/semantics.nim
import ast, tables, sets, strutils

type
  SemanticError* = object of ValueError
    line*, col*: int

proc reportError(msg: string, span: Span) =
  let err = newException(SemanticError, msg)
  err.line = span.line
  err.col = span.col
  raise err

type
  Checker = object
    module: Module
    declared: Table[string, seq[EffectMarker]]
    visiting: HashSet[string]

proc getDeclaredEffects(c: Checker, name: string): seq[EffectMarker] =
  if c.declared.hasKey(name):
    return c.declared[name]
  return @[]

# Bidirectional functions
proc synthesizeExpr(c: var Checker, e: Expr): seq[EffectMarker]
proc checkExpr(c: var Checker, e: Expr, expected: seq[EffectMarker], currentFn: string)

proc unionEffects(a, b: seq[EffectMarker]): seq[EffectMarker] =
  var res = a
  for x in b:
    if x notin res: res.add(x)
  return res

proc synthesizeExpr(c: var Checker, e: Expr): seq[EffectMarker] =
  if e == nil: return @[]
  var res: seq[EffectMarker] = @[]
  case e.kind
  of exkCall:
    res = unionEffects(res, c.synthesizeExpr(e.callee))
    for a in e.args:
      res = unionEffects(res, c.synthesizeExpr(a))
    
    let calleeName = if e.callee != nil and e.callee.kind == exkVar: e.callee.name else: ""
    if calleeName != "":
      res = unionEffects(res, c.getDeclaredEffects(calleeName))
  of exkStruct:
    for f in e.fields:
      res = unionEffects(res, c.synthesizeExpr(f[1]))
  of exkList:
    for item in e.items:
      res = unionEffects(res, c.synthesizeExpr(item))
  of exkBinary:
    res = unionEffects(res, c.synthesizeExpr(e.left))
    res = unionEffects(res, c.synthesizeExpr(e.right))
  of exkUnary:
    res = unionEffects(res, c.synthesizeExpr(e.operand))
  of exkBlock:
    for s in e.stmts:
      res = unionEffects(res, c.synthesizeExpr(s))
  of exkIf:
    res = unionEffects(res, c.synthesizeExpr(e.cond))
    res = unionEffects(res, c.synthesizeExpr(e.thenBranch))
    res = unionEffects(res, c.synthesizeExpr(e.elseBranch))
  of exkMatch:
    res = unionEffects(res, c.synthesizeExpr(e.subject))
    for arm in e.arms:
      res = unionEffects(res, c.synthesizeExpr(arm.body))
  of exkFor:
    res = unionEffects(res, c.synthesizeExpr(e.iterable))
    res = unionEffects(res, c.synthesizeExpr(e.body))
  of exkAssign:
    res = unionEffects(res, c.synthesizeExpr(e.target))
    res = unionEffects(res, c.synthesizeExpr(e.assignVal))
  of exkReturn:
    res = unionEffects(res, c.synthesizeExpr(e.returnVal))
  of exkRaise:
    res = unionEffects(res, c.synthesizeExpr(e.raiseVal))
  of exkChain:
    res = unionEffects(res, c.synthesizeExpr(e.base))
    for step in e.steps:
      res = unionEffects(res, c.synthesizeExpr(step.target))
      res = unionEffects(res, c.synthesizeExpr(step.arg))
  else:
    discard
  return res

proc checkExpr(c: var Checker, e: Expr, expected: seq[EffectMarker], currentFn: string) =
  if e == nil: return
  
  # 1. Synthesize the actual effects bottom-up
  let actualEffects = c.synthesizeExpr(e)
  
  # 2. Check the synthesized effects top-down against the expected budget
  for eff in actualEffects:
    if eff notin expected:
      reportError("Semantic Error: Expression requires effect [" & ($eff).replace("em", "").toLowerAscii() & "], which is not allowed in context of '" & currentFn & "'", e.span)

proc verifyDecl*(c: var Checker, d: Decl) =
  if d == nil: return
  case d.kind
  of dkFn:
    if d.name in c.visiting: return
    c.visiting.incl(d.name)
    c.checkExpr(d.fnBody, d.fnEffects, d.name)
    c.visiting.excl(d.name)
  of dkTask:
    if d.name in c.visiting: return
    c.visiting.incl(d.name)
    c.checkExpr(d.taskBody, d.taskEffects, d.name)
    c.visiting.excl(d.name)
  of dkActor:
    for h in d.handlers:
      verifyDecl(c, h)
  of dkStaticAssert:
    c.checkExpr(d.assertExpr, @[], "static_assert")
  else:
    discard

proc verifyModuleEffects*(m: Module) =
  var c = Checker(module: m, declared: initTable[string, seq[EffectMarker]](), visiting: initHashSet[string]())
  
  # Cache declared effect signatures in a symbol table lookup
  for d in m.decls:
    if d.kind == dkFn:
      c.declared[d.name] = d.fnEffects
    elif d.kind == dkTask:
      c.declared[d.name] = d.taskEffects
    elif d.kind == dkActor:
      for h in d.handlers:
        if h.kind == dkFn:
          c.declared[h.name] = h.fnEffects
          
  for d in m.decls:
    c.verifyDecl(d)
