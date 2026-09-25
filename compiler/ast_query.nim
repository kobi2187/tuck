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
import ast, strutils, tables, sets, options
import resolution
import name_prefix
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


proc seqElem*(t: Type): Type =
  ## The element type of a `Seq[T]`, or nil for anything else. One predicate
  ## for the several places that used to re-test `tkApp and base.name ==
  ## "Seq"` by hand — the D backend's own type mapping, declaration types,
  ## `.len`/`.dup` decisions, and lowering_d's Seq-copy marking pass.
  if t != nil and t.kind == tkApp and t.base != nil and
     t.base.kind == tkNamed and t.base.name == "Seq" and t.args.len == 1:
    t.args[0]
  else: nil

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

proc exportedNames*(m: Module): (bool, HashSet[string]) =
  ## `public:` — the names this module lets an importer see, and whether it
  ## said anything at all.
  ##
  ## A module with NO public block exports everything, which is what every
  ## module written before the block existed relies on. A module WITH one
  ## exports exactly the listed names: the list is the contract surface, and
  ## a name absent from it is the module's own business.
  ##
  ## One list for every kind of name — fn, type, object, group, fnsig —
  ## because an importer resolves all of them the same way, by name. Tuck has
  ## no overloading, so the name alone is unambiguous.
  var names = initHashSet[string]()
  var declared = false
  for d in m.decls:
    if d != nil and d.kind == dkPublic:
      declared = true
      for n in d.publicNames: names.incl(n)
  (declared, names)

proc memberSeq*(d: Decl): seq[Decl] =
  ## WHICH field holds a decl's nested declarations. Pure dispatch — one field
  ## read per arm and no test, which is the whole reason it is split from
  ## `members` below: the nil filter repeated inside six arms made this a
  ## 20-branch proc rather than the lookup table it actually is.
  ##
  ## Every remaining kind is named rather than caught by `else: discard`, so a
  ## new DeclKind fails to compile here and gets decided instead of skipped.
  ##
  ## dkTask is the one worth pausing on: a task is NOT memberless, but what it
  ## holds is an Expr (taskBody), not a nested Decl, and this yields
  ## declarations. Callers that want bodies to walk must reach taskBody
  ## themselves — rewriteModule and lowerModule both do. lowerModule did not
  ## until 2026-08-15, and emitted an unlowered registry raise from every task
  ## body as a result.
  if d == nil: return @[]
  case d.kind
  of dkMixin, dkExtern, dkPending: d.mixinMembers
  of dkType: d.typeMembers
  of dkObject: d.objMembers
  of dkActor: d.handlers
  of dkInterface: d.ifaceMembers
  of dkGroup: d.groupMembers
  of dkTask, dkFn, dkRegistry, dkPool, dkExpr, dkConst, dkRegister,
     dkStaticAssert, dkErrors, dkImport, dkSelect, dkFnSig, dkSatisfies,
     dkWhen, dkPublic, dkResources: @[]

iterator members*(d: Decl): Decl =
  ## The declarations nested inside another, whichever field holds them.
  ## Callers that just want "everything inside this decl" should not have to
  ## know that a mixin uses mixinMembers and an object uses objMembers.
  for mem in d.memberSeq():
    if mem != nil: yield mem

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

proc composedName(mem: Decl): string =
  ## The record a `+ Record` member composes in, or "" for any other member.
  if mem == nil or mem.kind != dkExpr or mem.expr == nil: return ""
  if mem.expr.kind != exkUnary or mem.expr.unaryOp != uoComposition: return ""
  let comp = mem.expr.operand
  if comp == nil or comp.kind != exkVar: "" else: comp.name

proc recordFieldsNamed(m: Module, name: string): seq[FieldDef] =
  ## The fields of every record type this module declares under `name`.
  for cd in m.decls:
    if cd == nil or cd.kind != dkType or cd.name != name: continue
    if cd.typeBody == nil or cd.typeBody.kind != tkRecord: continue
    for f in cd.typeBody.fields: result.add(f)

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
    let name = composedName(mem)
    if name.len > 0: result.add recordFieldsNamed(m, name)

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
  ## of a mixin/extern block or a manager type. Pending stubs do not count,
  ## wherever they sit — they have no body to call, and their emitted stub
  ## takes ONE generic payload rather than the params they declare, so a
  ## caller that found them here would explode the record into three args
  ## against a one-arg stub. (The top-level half of that test was missing
  ## until `...` started producing top-level pending fns; only a `pending:`
  ## block, whose members the loop below covers, could make one before.)
  ## One lookup behind every "what are this fn's params" question; callers that
  ## only need a bool or the param list read it off the returned Decl.
  for d in m.decls:
    if d == nil: continue
    if d.kind in {dkFn, dkTask} and d.name == name:
      # `isPending` lives only on the dkFn branch of the variant.
      if d.kind == dkTask or not d.isPending: return d
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

proc validatesItself*(m: Module, e: Expr): bool =
  ## Does emitting this expression ALREADY validate its own invariants?
  ##
  ## A construction of an invariant-carrying type does: every backend wraps it
  ## at the construction site. A `return` of that same expression then wrapped
  ## it a SECOND time, on a value nothing touched in between —
  ## `__validated_T(__validated_T(T{...}))` on Odin and D, and the same shape
  ## with two nested `let`s on Nim. Correct, but twice the work, and an
  ## invariant is arbitrary user code on a target where that is not free.
  ##
  ## Deliberately narrow: ONLY the expression node that IS the construction.
  ## A variable, a field read, a call result — anything that could have been
  ## produced elsewhere — must still be checked on the way out, because
  ## nothing here proves where it came from.
  if e == nil or e.kind != exkCall or e.callee == nil: return false
  if e.callee.kind != exkVar: return false
  hasInvariants(m, e.callee.name)

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

proc genPatternStr*(p: Pattern): string =
  ## A pattern's spelling as a case label. An or-pattern is its alternatives,
  ## comma-separated — `of 0, 4, 5` in Nim, `case 0, 4, 5` in Odin and D; a
  ## lowered decision table groups its keys this way.
  ##
  ## Exhaustive, with no `else`: this ended in `else: "_"`, so a pattern kind
  ## it did not know printed as the CATCH-ALL — an or-pattern would have
  ## become `case:` in every backend, silently matching everything.
  if p == nil: return "_"
  case p.kind
  of pkWild: "_"
  of pkVar: p.name
  of pkLit: p.litValue
  of pkOr: genPatternStr(p.left) & ", " & genPatternStr(p.right)
  of pkRecord, pkTuple: "_"   # destructuring binds; as a label it tests nothing

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
    # (A tail `..` chain is the base as its steps leave it: lowering_chains
    # writes that `return`, so no chain reaches here.)
    if lastS.kind == exkMatch and lastS.subject != nil and
         not matchArmsReturn(lastS):
      # `match subject:` whose arms are VALUES is an expression, so the tail
      # match is the fn's result. Arms that return on their own already are
      # the result — wrapping those in `return (case ...)` asks Nim to type a
      # case expression whose branches never produce a value. (A decision
      # table — subject == nil — keeps its per-row returns.)
      body.stmts[^1] = Expr(span: lastS.span, kind: exkReturn, returnVal: lastS)
    elif lastS.kind notin {exkReturn, exkRaise, exkIf, exkMatch, exkFor,
                           exkWhile, exkBreak, exkContinue,
                           exkAssign, exkBlock, exkSelect, exkSend,
                           exkDiscard, exkTripleDot}:
      body.stmts[^1] = Expr(span: lastS.span, kind: exkReturn, returnVal: lastS)


# --- sketch-mode type queries --------------------------------------------
#
# Both backends that must NAME a type (Odin and D — Nim infers) need these,
# and both had grown a private byte-identical copy. Shared here rather than
# in one backend's util module, since neither owns the question.

proc typeMentionsName*(t: Type, name: string): bool

proc anyMentionName(ts: seq[Type], name: string): bool =
  for t in ts:
    if typeMentionsName(t, name): return true
  false

proc fieldsMentionName(fs: seq[FieldDef], name: string): bool =
  for f in fs:
    if typeMentionsName(f.typ, name): return true
  false

proc typeMentionsName*(t: Type, name: string): bool =
  ## Does `name` appear anywhere in this type as written? Answers whether a
  ## type param is reachable from a parameter list at all — the predicate both
  ## the checker (deciding a call needs explicit type arguments) and the Odin
  ## backend (deciding which ones to pass) ask, so it is one proc.
  ##
  ## Every arm named rather than caught by a fallthrough: Type is a variant
  ## object, so reading `members` on a tkApp is a FieldDefect at runtime, not a
  ## compile error — which is exactly how a first cut of this crashed the
  ## checker on `Mapper[int, str]`.
  if t == nil or name == "": return false
  case t.kind
  of tkNamed: t.name == name
  of tkTuple: anyMentionName(t.elems, name)
  of tkApp: typeMentionsName(t.base, name) or anyMentionName(t.args, name)
  of tkFunc: anyMentionName(t.params, name) or typeMentionsName(t.result, name)
  of tkRecord: fieldsMentionName(t.fields, name)
  of tkUnion: anyMentionName(t.members, name)
  of tkEffect: typeMentionsName(t.inner, name)
  else: false

proc hasMissingType*(t: Type): bool =
  ## Does this type contain the checker's "I could not work it out" marker
  ## anywhere inside it? A backend that must spell a type needs to know
  ## before it tries.
  if t == nil: return true
  case t.kind
  of tkNamed: false
  of tkApp:
    if hasMissingType(t.base): return true
    for a in t.args:
      if hasMissingType(a): return true
    false
  of tkRecord:
    for f in t.fields:
      if hasMissingType(f.typ): return true
    false
  of tkTuple:
    for el in t.elems:
      if hasMissingType(el): return true
    false
  else: false

proc inferLitType*(e: Expr): Type =
  ## Best-effort type for a literal the checker could not type — sketch mode,
  ## where a shape still has to be emitted. The checker's own stamp wins when
  ## it says anything useful.
  if e != nil and semLayer.typeFor(e) != nil and
     not hasMissingType(semLayer.typeFor(e)): return semLayer.typeFor(e)
  if e != nil and e.kind == exkLit:
    case e.litKind
    of lkStr: return Type(kind: tkNamed, name: "str")
    of lkBool: return Type(kind: tkNamed, name: "bool")
    of lkFloat: return Type(kind: tkNamed, name: "float")
    else: return Type(kind: tkNamed, name: "int")
  nil

# --- backend-shared call/expression predicates ----------------------------
#
# Questions every backend asks of the same node and gets the same answer to.
# They lived as private copies in each emitter, which is how one gets fixed
# and the others do not — the injectTailReturn drift (an invalid-Odin bug for
# any match-with-returns) was exactly that, so these are shared on purpose.
#
# The test for belonging here: the answer depends only on the AST and the
# checker, never on the target language.

proc isStringConcat*(e: Expr): bool =
  ## `+` over strings. Every backend spells the RESULT differently (Nim `&`,
  ## D `~`, a runtime call in Odin) but they all ask this same question.
  if e == nil or e.kind != exkBinary: return false
  if e.binOp != boAdd or e.left == nil: return false
  let lt = semLayer.typeFor(e.left)
  lt != nil and lt.kind == tkNamed and lt.name in ["str", "string"]

proc isRecordConstruction*(m: Module, e: Expr): bool =
  ## `{fields} TypeName` — a construction, not a call.
  e != nil and e.kind == exkCall and e.args.len == 1 and
    e.args[0].kind == exkStruct and
    e.callee != nil and e.callee.kind == exkVar and
    isRecordType(m, e.callee.name)

proc isResultStatusTest*(e: Expr): bool =
  ## `r.ok` on a !T/?T value is a STATUS test, not a field read.
  if e == nil or e.kind != exkField: return false
  if e.fieldName != "ok" or e.receiver == nil: return false
  let rt = semLayer.typeFor(e.receiver)
  rt != nil and rt.kind == tkApp and rt.base != nil and
    rt.base.kind == tkNamed and rt.base.name in ["!", "?", "!?"]

proc returnsValue*(d: Decl): bool =
  ## Does this fn hand back something a caller can use?
  d != nil and d.fnReturnType != nil and
    not (d.fnReturnType.kind == tkNamed and
         d.fnReturnType.name in ["void", "unit"])

proc memberOwner*(m: Module, recvT: Type): string =
  ## The object type a member call dispatches on, or "" when the receiver is
  ## not an object (a record's `.fn` is a free fn and keeps its bare name).
  if recvT == nil or recvT.kind != tkNamed: return ""
  for d in m.decls:
    if d != nil and d.kind == dkObject and d.name == recvT.name: return d.name
  ""

proc memberCalleeOf*(m: Module, owner, calleeName: string): string =
  ## The qualified name a member call must emit, or "" when `calleeName` is
  ## not a member of `owner`.
  ##
  ## A member call arrives as a bare-name callee with the receiver as args[0]
  ## (the checker's rewrite), so the name alone cannot say which fn is meant
  ## once a top-level fn shares it. The receiver's TYPE can, and the
  ## declaration emitted under exactly this name — deriving it here is what
  ## keeps the two in step.
  if owner == "": return ""
  for d in m.decls:
    if d == nil or d.kind != dkObject or d.name != owner: continue
    for mem in d.objMembers:
      if mem == nil or mem.kind != dkFn: continue
      # The callee may arrive MANGLED and the member never is: mangling
      # renames a module's own decls, not an object's members, so a stamped
      # `noise` becomes `tuck_noise` whenever a top-level fn shares the name.
      # Both spellings mean this member. Same comparison
      # resolution.poolHandleName makes, for the same reason.
      if mem.name == calleeName or prefixed(mem.name, nkFn) == calleeName:
        return owner & "_" & mem.name
  ""

# --- compile-time whole numbers -----------------------------------------
#
# A mailbox depth, a pool's slot count, an arena's size, a resource cap, an
# array's width: five positions that all mean "a whole number the COMPILER
# must know". Each used to demand digits and say so — except `Array[N, T]`,
# which accepted any text and handed it to the backend, so a typo'd size
# reached the host and the array's own length check silently stopped running
# (#59).
#
# The grammar is deliberately narrow, and the narrowness is the feature:
#
#     attribute value ::= integer literal | const NAME
#
# so a wild expression cannot appear at a size — a const name is one token and
# there is nowhere for one to go. Anything derived gets a NAME, on its own
# line, in one place:
#
#     const MaxConns = 8
#     const FanQueue = MaxConns * 4
#     actor Fan [queue: FanQueue]
#
# Tuck had no evaluator at all because constant evaluation was DELEGATED: a
# `const` emits `const tuck_N = static:` and Nim works it out. That cannot
# help a checker which needs the number to size something before any backend
# runs, which is why this exists and why it only covers the subset a size
# needs.

proc evalConstExpr*(m: Module, e: Expr, depth = 0): Option[int]

proc constDeclFor*(m: Module, raw: string): Decl =
  ## The const declaration named `raw`, wherever it is declared.
  # THIS module first, then the program. A const declared in an IMPORTED module
  # used to resolve to nothing, and the three callers disagreed about what that
  # meant: the pool-count and actor-queue checks reported "must be a whole
  # number the compiler knows" — a false error about a const that plainly is
  # one — while failIfArrayLengthMismatched DECLINED TO CHECK, so
  # `Array[Cap, int] = [1, 2, 3]` with an imported `Cap = 4` was accepted and
  # the wrong length rode to the backend. Same code, one line moved across a
  # module boundary (#73).
  #
  # Local first means a module's own const shadows another's; an AMBIGUOUS name
  # (declared differently in two modules) stays unresolved rather than
  # resolving to whichever loaded first.
  result = m.findDecl(dkConst, raw)
  if result == nil: result = m.findDecl(dkConst, prefixed(raw, nkValue))
  if result != nil or raw in semLayer.ambiguousConsts: return
  result = semLayer.constNames.getOrDefault(raw, nil)
  if result == nil: result = semLayer.constNames.getOrDefault(prefixed(raw, nkValue), nil)

proc constIntOf*(m: Module, text: string, depth = 0): Option[int] =
  ## A size written as TEXT — an attribute's value, or an `Array[N, T]` size,
  ## both of which the parser keeps as source text rather than as an
  ## expression. Digits, or the name of a const that evaluates to a number.
  let t = text.strip().replace("_", "")
  if t.len == 0: return none(int)
  if allCharsInSet(t, {'0'..'9'}):
    try: return some(parseInt(t))
    except ValueError: return none(int)
  if t[0] == '-' and t.len > 1 and allCharsInSet(t[1 .. ^1], {'0'..'9'}):
    try: return some(parseInt(t))
    except ValueError: return none(int)
  # A NAME: one const, evaluated. Depth-bounded rather than cycle-tracked —
  # `const A = B` / `const B = A` is a declaration cycle the checker has its
  # own opinion about, and this only needs to not hang.
  if depth > 16: return none(int)
  # Either spelling: an attribute's text is never mangled, and by codegen the
  # const decl has been renamed, so `[queue: Fan]` must still find
  # `const tuck_Fan`. Same comparison resolution.poolHandleName and
  # ast_query.memberCalleeOf make, for the same reason.
  let d = constDeclFor(m, text.strip())
  if d == nil or d.constVal == nil: return none(int)
  evalConstExpr(m, d.constVal, depth + 1)



proc evalConstExpr*(m: Module, e: Expr, depth = 0): Option[int] =
  ## The constant subset: an integer literal, a const name, arithmetic over
  ## those. NOT a call, a field read, or anything whose value needs the
  ## program to run — a size that cannot be worked out here is refused with a
  ## diagnostic rather than passed to the backend to discover.
  if e == nil or depth > 16: return none(int)
  case e.kind
  of exkLit:
    if e.litKind != lkInt: return none(int)
    try: return some(parseInt(e.litValue.replace("_", "")))
    except ValueError: return none(int)
  of exkVar:
    # A const's initialiser is walked AFTER mangling too, so its references
    # carry the renamed spelling; constIntOf accepts both.
    return constIntOf(m, e.name, depth + 1)
  of exkUnary:
    let v = evalConstExpr(m, e.operand, depth + 1)
    if v.isNone: return none(int)
    if e.unaryOp == uoNeg: return some(-v.get)
    return none(int)
  of exkBinary:
    let l = evalConstExpr(m, e.left, depth + 1)
    if l.isNone: return none(int)
    let r = evalConstExpr(m, e.right, depth + 1)
    if r.isNone: return none(int)
    case e.binOp
    of boAdd: some(l.get + r.get)
    of boSub: some(l.get - r.get)
    of boMul: some(l.get * r.get)
    of boDivInt:
      if r.get == 0: none(int) else: some(l.get div r.get)
    of boMod:
      if r.get == 0: none(int) else: some(l.get mod r.get)
    else: none(int)
  else:
    none(int)

proc sumHasPayload*(body: Type): bool =
  ## Does any variant of this sum carry fields? The branch key for four
  ## emitters: a fieldless sum is a plain enum in both targets, a
  ## payload-carrying one needs a tagged representation.
  if body == nil: return false
  for v in body.variants:
    if v.fields.len > 0: return true
  false

proc payloadSumTypeName*(m: Module, t: Type): string =
  ## The name of the PAYLOAD-CARRYING sum type this value has, or "".
  ##
  ## Such a sum emits as a tagged union — a `kind` discriminant plus one
  ## payload field per variant — so a match dispatches on `.kind` and a
  ## variant's field is reached through the variant's own field, not off the
  ## value directly. A payload-FREE sum is a plain enum and needs neither.
  if t == nil or t.kind != tkNamed: return ""
  let d = m.findDecl(dkType, t.name)
  if d == nil or d.typeBody == nil or d.typeBody.kind != tkSum: return ""
  if not sumHasPayload(d.typeBody): return ""
  t.name

proc variantOwningField*(m: Module, typeName, fieldName: string): string =
  ## Which variant of a payload sum declares `fieldName`, or "". The emitted
  ## payload lives in a field named after that variant, so `s.length` on a
  ## `Line({length: int})` has to become `s.line.length`.
  let d = m.findDecl(dkType, typeName)
  if d == nil or d.typeBody == nil or d.typeBody.kind != tkSum: return ""
  for v in d.typeBody.variants:
    for f in v.fields:
      if f.name == fieldName: return v.name
  ""


type
  BitFieldInfo* = object
    ## One `bit N` / `bits LO..HI` field of a memory-mapped register, decoded
    ## from its declared type and attributes.
    ##
    ## The DECODING is target-independent — which bits, which directions —
    ## so it lives here; only the spelling of the masks and accessors differs
    ## per backend.
    prefix*: string    ## <register>_<field>, shared by every emitted symbol
    loBit*, hiBit*: string
    isRange*: bool     ## a multi-bit field, not a single flag
    canRead*, canWrite*: bool

proc groupNameOf*(t: Type): string =
  ## The group a bound names, written bare (`Sortable`) or applied
  ## (`Indexable[E]`). "" when the type names no group at all.
  if t == nil: return ""
  if t.kind == tkNamed: return t.name
  if t.kind == tkApp and t.base != nil and t.base.kind == tkNamed:
    return t.base.name
  ""

proc decodeBitField*(regName: string, f: FieldDef): BitFieldInfo =
  ## `bits 3..7` is a multi-bit FIELD: shift by the low bit and mask the
  ## width. A single `bit N` is the one-bit case of the same shape.
  let bitVal = f.typ.name.replace("bit ", "").replace("bits ", "")
  let dotPos = bitVal.find("..")
  result.loBit = if dotPos >= 0: bitVal[0 ..< dotPos].strip() else: bitVal
  result.hiBit = if dotPos >= 0: bitVal[dotPos + 2 .. ^1].strip() else: bitVal
  result.isRange = dotPos >= 0 and result.loBit != result.hiBit
  result.prefix = regName & "_" & f.name
  var hasRead, hasWrite = false
  for a in f.attrs:
    if a.name == "read": hasRead = true
    elif a.name == "write": hasWrite = true
  # An unmarked field is readable AND writable; marking one direction opts
  # out of the other.
  result.canRead = hasRead or not hasWrite
  result.canWrite = hasWrite or not hasRead

proc registerAccessorPrefix*(m: Module, regName, fieldName: string): string =
  ## The `<regName>_<fieldName>` accessor prefix genRegister/genDRegister
  ## already emit for this field (matching `decodeBitField`'s own `prefix`
  ## exactly), or "" if `regName` names no register or the register has no
  ## such field. A `.field` access on a register name must call the
  ## generated `<prefix>_get()`/`<prefix>_set(v)` — the register itself is
  ## a raw pointer with no real field, so ordinary field syntax on it is
  ## always wrong, never merely unimplemented.
  for d in m.decls:
    if d == nil or d.kind != dkRegister or d.name != regName: continue
    for f in d.regFields:
      if f.name == fieldName: return regName & "_" & fieldName
  ""

proc isCompositionEntry*(member: Decl): bool =
  ## `+ Name` inside an object body — the entry that pulls another
  ## declaration's members or data into this one. The operand is `exkVar`
  ## when `Name` is a type/object (resolve_refs.nim's rewrite pass does not
  ## touch those), or `exkMixinRef` when it is a mixin (resolved before
  ## typecheck ever sees it as a bare name).
  member.kind == dkExpr and member.expr != nil and
    member.expr.kind == exkUnary and member.expr.unaryOp == uoComposition and
    member.expr.operand != nil and
    member.expr.operand.kind in {exkVar, exkMixinRef}

proc compositionTargetName*(member: Decl): string =
  ## The name `+ Name` composes in — call only where `isCompositionEntry`
  ## already returned true. Same reason as the proc above: exkVar carries
  ## `.name`, exkMixinRef carries `.refName`.
  let operand = member.expr.operand
  if operand.kind == exkMixinRef: operand.refName else: operand.name

proc takesSelf*(m: Decl): bool =
  ## A fn with a `self` param materializes at `+ mixin` composition sites,
  ## not standalone.
  for p in m.fnParams:
    if p.name == "self": return true
  false

# --- the unwritten body ---------------------------------------------------

proc isUnwrittenBody*(body: Expr): bool =
  ## Is this body nothing but `...`?
  body != nil and body.kind == exkBlock and body.stmts.len == 1 and
    body.stmts[0].kind == exkTripleDot

proc markUnimplemented*(d: Decl) =
  ## Make `d` the same thing a `pending:` signature produces: no body, a stub
  ## that names itself at runtime (genPendingStub, one per backend), and a
  ## line in the build's PENDING report.
  ##
  ## `...` USED to emit a bare `discard`, so a fn declared `-> int` returned a
  ## silent zero — a plausible wrong answer indistinguishable from a computed
  ## one. Two mechanisms said "not implemented" and only one of them said it
  ## out loud. This is the other one, reused rather than reinvented; the
  ## pending machinery already handles every return type.
  ##
  ## NOT for a `self` member: every backend's pending stub is a free generic
  ## `(payload: T)`, which drops both the receiver and the owning type's name
  ## from the emitted symbol. A member keeps the old empty body until the
  ## stub learns to carry a receiver.
  if d.kind != dkFn or d.takesSelf(): return
  d.isPending = true
  d.fnBody = nil

# --- a GENERIC fnsig ---------------------------------------------------------
#
# `fnsig Pred[T] = {value: T} -> bool` has no named counterpart to emit. Odin's
# proc TYPES are not parametric (its generics are `$T` parapoly on PROCS, a
# different mechanism), and D's templated alias would need instantiating at
# every use anyway. So the declaration emits NOTHING and each use site spells
# the substituted signature inline — `Pred[int]` becomes the function type
# taking an int.
#
# Nothing is lost by erasing it: a fn type is structural in all three targets,
# so there was no nominal identity to keep.

proc substParams*(t: Type, binds: Table[string, Type]): Type =
  ## `t` with every type-param NAME replaced by what it was bound to.
  if t == nil: return nil
  case t.kind
  of tkNamed:
    if binds.hasKey(t.name): binds[t.name] else: t
  of tkApp:
    var args: seq[Type]
    for a in t.args: args.add(substParams(a, binds))
    Type(span: t.span, kind: tkApp, base: substParams(t.base, binds), args: args)
  else: t

proc fnSigInstance*(m: Module, t: Type): Type =
  ## `Pred[int]` -> the tkFunc it stands for, with T substituted. nil when `t`
  ## is not a generic fnsig application, so a caller can fall through to its
  ## ordinary handling.
  if t == nil or t.kind != tkApp or t.base == nil or t.base.kind != tkNamed:
    return nil
  for d in m.decls:
    if d == nil or d.kind != dkFnSig or d.name != t.base.name: continue
    if d.sigGenerics.len == 0 or d.sigGenerics.len != t.args.len: return nil
    var binds = initTable[string, Type]()
    for i, g in d.sigGenerics: binds[g] = t.args[i]
    var ps: seq[Type]
    var names: seq[string]
    for prm in d.sigParams:
      ps.add(substParams(prm.typ, binds))
      names.add(prm.name)
    return Type(span: t.span, kind: tkFunc, params: ps, paramNames: names,
                result: substParams(d.sigReturn, binds))
  nil
