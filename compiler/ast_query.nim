# compiler/ast_query.nim
#
# The vocabulary for asking questions about a parsed program. Pure functions
# over the AST — nothing here holds state, touches a codegen context, or emits
# target syntax. Every helper answers one question about a Module/Decl/Expr.
#
# It exists because the same questions ("which decl is named X", "walk every
# extern member", "what are this fn's params") were open-coded as nested loops
# at ~60 sites across the two backends, lowering and the type checker. Written
# out by hand they bury the intent in traversal, and copies drift: two
# `lookupFnParams` disagreed about tasks for months because nothing put them
# side by side.
#
# Add a helper here rather than open-coding the loop again.
#
# PERFORMANCE — READ THIS BEFORE ADDING A CALL IN A HOT LOOP.
#
# The lookups here (findDecl, findFn, allFns) are LINEAR SCANS over a module's
# declaration list. One call is O(N) in the number of declarations; calling one
# per declaration is O(N²).
#
# That is measurable today. Between a 4,000-line and a 32,000-line module (8x
# the input), lex and parse both grow 8.9x — linear, as expected — while
# lowering grows 18.3x and typechecking 14.4x. The gap is these scans. Overall
# throughput falls from ~140K to ~100K lines/sec across that range
# (benches/bench_phases.nim reproduces it).
#
# Callers that need many lookups should build a table ONCE instead. The type
# checker already does: typecheck_state.nim fills `fnSigs` and `typeDecls`
# up front, so its hottest lookups are O(1) hash hits rather than scans, which
# is why it degrades noticeably less than lowering despite doing far more work.
#
# These scans are fine for a handful of lookups and fine at current program
# sizes — 32,000 lines still checks in about a third of a second. The fix, when
# a real program makes it hurt, is a name -> decl table built once per module
# and shared by every pass, not micro-optimizing the scan.
import ast, strutils
export strutils.repeat, strutils.capitalizeAscii

# `repeat` and `capitalize` used to be hand-written here and were byte-for-byte
# strutils. Re-exported instead so the backends that relied on getting them
# from this module still do, and so the codebase has one implementation rather
# than a stdlib one nobody reached for.
template capitalize*(s: string): string = capitalizeAscii(s)

# --- Declaration lookup ----------------------------------------------------
#
# Every backend needs the same handful of questions answered about a Module:
# "which decl is named X", "walk every extern member", "is this type a C
# struct". Written by hand at each site these are 4-6 line nested loops that
# bury the intent; named here, the call site reads as the question it asks.
# Add a helper rather than open-coding the loop again.

proc sourceKind*(arm: SelectArm): SelectSourceKind =
  ## What a task select arm's source string means.
  ##
  ## The parser concatenates a dotted source into one opaque string
  ## (`timeout.5s`), so a bare `arm.source == "timeout"` compare misses it —
  ## which is precisely how an arm the emitter could not lower reached a
  ## `discard` and had its body dropped in silence. Classify once, here, and
  ## let every backend match on the result exhaustively.
  if arm.source == "read": sskRead
  elif arm.source == "timeout": sskTimeout
  elif arm.source.startsWith("timeout."): sskTimeoutTyped
  else: sskOther

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
  ## `extern:` / `extern [c, ...]:` blocks, whose members are the signatures.
  for d in m.decls(dkExtern): yield d

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

iterator members*(d: Decl): Decl =
  ## The declarations nested inside another, whichever field holds them.
  ## Callers that just want "everything inside this decl" should not have to
  ## know that a mixin uses mixinMembers and an object uses objMembers.
  if d != nil:
    case d.kind
    of dkMixin, dkExtern, dkPending:
      for mem in d.mixinMembers: (if mem != nil: yield mem)
    of dkType:
      for mem in d.typeMembers: (if mem != nil: yield mem)
    of dkObject:
      for mem in d.objMembers: (if mem != nil: yield mem)
    of dkActor:
      for mem in d.handlers: (if mem != nil: yield mem)
    of dkInterface:
      for mem in d.ifaceMembers: (if mem != nil: yield mem)
    # Every remaining kind, named rather than caught by `else: discard`, so a
    # new DeclKind fails to compile here and gets decided instead of skipped.
    #
    # dkTask is the one worth pausing on: a task is NOT memberless, but what it
    # holds is an Expr (taskBody), not a nested Decl, and this iterator yields
    # declarations. Callers that want bodies to walk must reach taskBody
    # themselves — rewriteModule and lowerModule both do. lowerModule did not
    # until 2026-08-15, and emitted an unlowered registry raise from every task
    # body as a result.
    of dkTask, dkFn, dkRegistry, dkPool, dkExpr, dkConst, dkRegister,
       dkStaticAssert, dkErrors, dkImport, dkSelect, dkFnSig, dkSatisfies,
       dkWhen: discard

proc declaredFields*(d: Decl): seq[FieldDef] =
  ## The fields a declaration introduces, whichever field holds them. A record
  ## type keeps them in its body; objects and actors have their own seq.
  if d == nil: return @[]
  case d.kind
  of dkType:
    if d.typeBody != nil and d.typeBody.kind == tkRecord: d.typeBody.fields
    else: @[]
  of dkObject: d.objFields
  of dkActor: d.actorFields
  else: @[]

proc composedFields*(m: Module, d: Decl): seq[FieldDef] =
  ## An object's fields INCLUDING everything `+ Record` merges in — composition
  ## is set union (spec §4.5), so a composed field is the object's own as far
  ## as every later pass is concerned. Needs the module, which is why this is
  ## separate from declaredFields above.
  ##
  ## A composed MIXIN contributes member fns, not fields, and adds nothing here.
  if d == nil: return @[]
  result = declaredFields(d)
  if d.kind != dkObject: return
  for mem in d.objMembers:
    if mem == nil or mem.kind != dkExpr or mem.expr == nil: continue
    if mem.expr.kind != exkUnary or mem.expr.unaryOp != uoComposition: continue
    let comp = mem.expr.operand
    if comp == nil or comp.kind != exkVar: continue
    for cd in m.decls:
      if cd == nil or cd.kind != dkType or cd.name != comp.name: continue
      if cd.typeBody == nil or cd.typeBody.kind != tkRecord: continue
      for f in cd.typeBody.fields: result.add(f)

iterator allFns*(m: Module): Decl =
  ## Every fn in the module with a body to walk: top-level, plus the members
  ## of objects, manager types, mixins and actors. Passes that rewrite bodies
  ## (lowering) want exactly this set, and expressing it as a case statement
  ## per site is how dkActor came to be silently skipped.
  for d in m.decls:
    if d == nil: continue
    if d.kind == dkFn: yield d
    else:
      for mem in d.members():
        if mem.kind == dkFn: yield mem

proc findFn*(m: Module, name: string): Decl =
  ## The fn declaration named `name`, wherever it sits: top level, or a member
  ## of a mixin/extern block or a manager type. Pending stubs do not count as
  ## members — they have no body to call.
  ## One lookup behind every "what are this fn's params" question; callers that
  ## only need a bool or the param list read it off the returned Decl.
  for d in m.decls:
    if d == nil: continue
    if d.kind in {dkFn, dkTask} and d.name == name: return d
    if d.kind in {dkMixin, dkExtern, dkPending, dkType}:
      for mem in d.members():
        if mem.kind == dkFn and not mem.isPending and mem.name == name:
          return mem
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

iterator sumTypes*(m: Module): Decl =
  ## Declared sum types (`type X = {A, B}` and payload-carrying variants).
  for d in m.decls(dkType):
    if d.typeBody != nil and d.typeBody.kind == tkSum: yield d

proc isRecordType*(m: Module, name: string): bool =
  ## `{fields} TypeName` — construction of a declared record type. An OBJECT
  ## constructs the same way (named fields, not positional), so it answers true
  ## here too; without it a backend emitted `tuck_Dog("rex")`, which neither
  ## Nim nor Odin accepts.
  if m.typeBodyKind(name) == tkRecord: return true
  for d in m.decls:
    if d != nil and d.kind == dkObject and d.name == name: return true
  false

proc isErrEnumRef*(m: Module, e: Expr): bool =
  ## `err Enum.Variant` — a reference to a declared error enum's variant?
  if e == nil or e.kind != exkField or e.receiver == nil or
     e.receiver.kind != exkVar: return false
  m.typeBodyKind(e.receiver.name) == tkSum

proc saturatingType*(m: Module, name: string): Type =
  ## The underlying Type of a `[saturating]` declaration, or nil. What makes a
  ## type saturating is the ATTRIBUTE, not the `distinct` keyword — so
  ## `type X = u16 [saturating]` and `distinct X = u16 [saturating]` are the
  ## same thing (user ruling). Each backend spells the base type itself.
  let d = m.findDecl(dkType, name)
  if d == nil or d.typeBody == nil or d.typeBody.kind != tkNamed: return nil
  for a in d.typeBody.attrs:
    if a.name == "saturating": return d.typeBody
  nil

proc isValueIf*(e: Expr): bool =
  ## An `if` used as a VALUE rather than a statement (ruling R2):
  ## `let x = if c: a else: b`. Both branches must be present and neither may
  ## be a block — a block body is the statement form, written across lines.
  ## The distinction is syntactic on purpose: it is visible at the call site,
  ## so no type inference decides how the same source emits.
  e != nil and e.kind == exkIf and
  e.thenBranch != nil and e.thenBranch.kind != exkBlock and
  e.elseBranch != nil and e.elseBranch.kind != exkBlock

proc isSingleFieldPayload*(e: Expr): bool =
  ## A payload carrying exactly one field: `{n}`, `{value: 5}`, `{host: h}`.
  e != nil and e.kind == exkStruct and e.fields.len == 1

proc soleFieldValue*(e: Expr): Expr =
  ## The value inside a single-field payload, else the expression itself.
  ## `{value: 5}` unwraps to `5`; anything else passes through untouched.
  if isSingleFieldPayload(e): e.fields[0].value else: e

proc isBareValuePayload*(e: Expr): bool =
  ## A payload holding one BARE value rather than a named pair: `{n}` or the
  ## `{value: x}` spelling of the same thing. `{host: 80}` is NOT bare — it
  ## names a specific field, which is a mutator fn's job, not a `..` set.
  ##
  ## The parser spells a bare `{n}` as the pair `(n, <var n>)`, so a field
  ## whose name equals its own variable's name is the bare form.
  if not isSingleFieldPayload(e): return false
  let f = e.fields[0]
  f.name == "value" or
    (f.value != nil and f.value.kind == exkVar and f.value.name == f.name)

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
