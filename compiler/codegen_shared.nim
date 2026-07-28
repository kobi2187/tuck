# compiler/codegen_shared.nim
#
# Backend-neutral codegen helpers — pure functions over the AST that both the
# Nim and Odin emitters need, factored out of the two backend modules so the
# logic lives once. Nothing here touches a codegen context or emits target
# syntax; each helper answers a question about a Module/Decl/Expr/Pattern.
import ast, strutils

proc repeat*(s: string, n: int): string =
  var res = ""
  for i in 0 ..< n: res.add(s)
  res

proc capitalize*(s: string): string =
  if s.len == 0: return ""
  s[0].toUpperAscii() & s[1 .. ^1]

proc hasInvariants*(m: Module, name: string): bool =
  ## A declared type carrying an `invariant:` block (stored as a dkExpr member).
  for d in m.decls:
    if d != nil and d.kind == dkType and d.name == name:
      for member in d.typeMembers:
        if member.kind == dkExpr: return true
  false

proc externInvRet*(m: Module, fnName: string): string =
  ## An extern fn returning an invariant-carrying named type: values entering
  ## from outside the checked world validate at the CALL site (the body is not
  ## emitted). Returns the type name, or "".
  for d in m.decls:
    if d != nil and d.kind == dkMixin:
      for mem in d.mixinMembers:
        if mem.kind == dkFn and mem.isExtern and mem.name == fnName and
           mem.fnReturnType != nil and mem.fnReturnType.kind == tkNamed and
           hasInvariants(m, mem.fnReturnType.name):
          return mem.fnReturnType.name
  ""

proc isRecordType*(m: Module, name: string): bool =
  ## `{fields} TypeName` — construction of a declared record type.
  for d in m.decls:
    if d != nil and d.kind == dkType and d.name == name and
       d.typeBody != nil and d.typeBody.kind == tkRecord:
      return true
  false

proc isErrEnumRef*(m: Module, e: Expr): bool =
  ## `err Enum.Variant` — a reference to a declared error enum's variant?
  if e == nil or e.kind != exkField or e.receiver == nil or
     e.receiver.kind != exkVar: return false
  for d in m.decls:
    if d != nil and d.kind == dkType and d.name == e.receiver.name and
       d.typeBody != nil and d.typeBody.kind == tkSum:
      return true
  false

proc isDecisionTable*(d: Decl): bool =
  ## A fn whose body is only subject-less `match` blocks — a decision table.
  if d.kind != dkFn or d.fnBody == nil or d.fnBody.kind != exkBlock: return false
  if d.fnBody.stmts.len == 0: return false
  for s in d.fnBody.stmts:
    if s.kind != exkMatch or s.subject != nil: return false
  true

proc genPatternStr*(p: Pattern): string =
  ## A pattern's surface spelling, for decision-table row labels / comments.
  if p == nil: return "_"
  case p.kind
  of pkWild: "_"
  of pkVar: p.name
  of pkLit: p.litValue
  else: "_"

proc matchArmsReturn*(m: Expr): bool =
  ## True when the arms produce control flow rather than values — a block arm
  ## ending in `return`, or a bare `return`. Such a match is already the
  ## function's result and must not be wrapped in another return.
  for arm in m.arms:
    if arm.body == nil: continue
    if arm.body.kind == exkReturn: return true
    if arm.body.kind == exkBlock and arm.body.stmts.len > 0 and
       arm.body.stmts[^1] != nil and arm.body.stmts[^1].kind == exkReturn:
      return true
  false

proc injectTailReturn*(body: Expr, retTypeStr: string) =
  ## Turn a fn body's trailing expression statement into an explicit `return`
  ## (Nim needs it), leaving control-flow tails and decision tables alone.
  if body != nil and body.kind == exkBlock and body.stmts.len > 0 and
     retTypeStr != "void":
    let lastS = body.stmts[^1]
    if lastS.kind == exkChain:
      # a chain's value is its base var: keep the mutation statements,
      # return the base afterwards
      if lastS.base != nil:
        body.stmts.add(Expr(span: lastS.span, kind: exkReturn,
                            returnVal: lastS.base))
    elif lastS.kind == exkMatch and lastS.subject != nil and
         not matchArmsReturn(lastS):
      # `match subject:` whose arms are VALUES is an expression, so the tail
      # match is the fn's result. Arms that return on their own already are
      # the result — wrapping those in `return (case ...)` asks Nim to type a
      # case expression whose branches never produce a value. (A decision
      # table — subject == nil — keeps its per-row returns.)
      body.stmts[^1] = Expr(span: lastS.span, kind: exkReturn, returnVal: lastS)
    elif lastS.kind notin {exkReturn, exkRaise, exkIf, exkMatch, exkFor,
                           exkWhile, exkBreak, exkContinue,
                           exkAssign, exkBlock, exkSelect, exkSend} and
       not (lastS.kind == exkVar and lastS.name == "..."):
      body.stmts[^1] = Expr(span: lastS.span, kind: exkReturn, returnVal: lastS)
