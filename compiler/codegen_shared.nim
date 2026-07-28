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

# --- Declaration lookup ----------------------------------------------------
#
# Every backend needs the same handful of questions answered about a Module:
# "which decl is named X", "walk every extern member", "is this type a C
# struct". Written by hand at each site these are 4-6 line nested loops that
# bury the intent; named here, the call site reads as the question it asks.
# Add a helper rather than open-coding the loop again.

iterator decls*(m: Module, kind: DeclKind): Decl =
  ## Every non-nil top-level declaration of one kind.
  for d in m.decls:
    if d != nil and d.kind == kind: yield d

proc findDecl*(m: Module, kind: DeclKind, name: string): Decl =
  ## The named top-level declaration, or nil.
  for d in m.decls(kind):
    if d.name == name: return d
  nil

iterator externBlocks*(m: Module): Decl =
  ## `extern:` / `extern [c, ...]:` blocks — each parses as a mixin named
  ## "extern" whose members are the signatures.
  for d in m.decls(dkMixin):
    if d.name == "extern": yield d

iterator externMembers*(m: Module): Decl =
  ## Every member of every extern block, flattened. The common case: callers
  ## almost always want the members, not the block that holds them.
  for blk in m.externBlocks():
    for mem in blk.mixinMembers:
      if mem != nil: yield mem

iterator externFns*(m: Module): Decl =
  ## Extern FUNCTIONS only — skips the types and callback signatures that may
  ## share the block.
  for mem in m.externMembers():
    if mem.kind == dkFn and mem.isExtern: yield mem

proc cExternFn*(m: Module, name: string): Decl =
  ## An extern fn bound to a C header (as opposed to one the runtime provides),
  ## or nil.
  for mem in m.externFns():
    if mem.name == name and mem.externHeader != "": return mem
  nil

proc findFn*(m: Module, name: string): Decl =
  ## The fn declaration named `name`, wherever it sits: top level, or a member
  ## of a mixin/extern block or a manager type. Pending stubs do not count as
  ## members — they have no body to call.
  ## One lookup behind every "what are this fn's params" question; callers that
  ## only need a bool or the param list read it off the returned Decl.
  for d in m.decls:
    if d == nil: continue
    if d.kind in {dkFn, dkTask} and d.name == name: return d
    if d.kind in {dkMixin, dkType}:
      let members = if d.kind == dkMixin: d.mixinMembers else: d.typeMembers
      for mem in members:
        if mem != nil and mem.kind == dkFn and not mem.isPending and
           mem.name == name: return mem
  nil

proc params*(d: Decl): seq[Param] =
  ## A callable's parameters, in order. Tasks keep theirs in a separate field
  ## from fns; callers asking "what does this take" should not have to care.
  if d == nil: return @[]
  if d.kind == dkTask: d.taskParams else: d.fnParams

proc paramNames*(d: Decl): seq[string] =
  ## A callable's parameter names, in order; empty for nil.
  for p in d.params(): result.add(p.name)

proc paramTypes*(d: Decl): seq[Type] =
  ## A callable's parameter types, in order; empty for nil.
  for p in d.params(): result.add(p.typ)

proc hasInvariants*(m: Module, name: string): bool =
  ## A declared type carrying an `invariant:` block (stored as a dkExpr member).
  let d = m.findDecl(dkType, name)
  if d == nil: return false
  for member in d.typeMembers:
    if member.kind == dkExpr: return true
  false

proc externInvRet*(m: Module, fnName: string): string =
  ## An extern fn returning an invariant-carrying named type: values entering
  ## from outside the checked world validate at the CALL site (the body is not
  ## emitted). Returns the type name, or "".
  for mem in m.externFns():
    if mem.name == fnName and mem.fnReturnType != nil and
       mem.fnReturnType.kind == tkNamed and hasInvariants(m, mem.fnReturnType.name):
      return mem.fnReturnType.name
  ""

proc typeBodyKind*(m: Module, name: string): TypeKind =
  ## The shape of a declared type's body, or tkNamed when there is no such
  ## declaration. Distinguishes a record from a sum without re-walking decls.
  let d = m.findDecl(dkType, name)
  if d == nil or d.typeBody == nil: return tkNamed
  d.typeBody.kind

proc isRecordType*(m: Module, name: string): bool =
  ## `{fields} TypeName` — construction of a declared record type.
  m.typeBodyKind(name) == tkRecord

proc isErrEnumRef*(m: Module, e: Expr): bool =
  ## `err Enum.Variant` — a reference to a declared error enum's variant?
  if e == nil or e.kind != exkField or e.receiver == nil or
     e.receiver.kind != exkVar: return false
  m.typeBodyKind(e.receiver.name) == tkSum

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
