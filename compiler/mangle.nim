# compiler/mangle.nim
#
# Name mangling as a LOWERING PASS, not an emission-time concern.
#
# Without it, user-declared names land in the target's global namespace and
# collide with two moving targets:
#
#   1. The runtime's own procs. 19 of them already share a name with a fn in
#      examples/ or std/ — `ready`, `at`, `reset`, `print`, `spawn`, `exit`.
#      27-actor-select declares `fn ready`, which is exactly the scheduler's.
#   2. The target language's keywords, which DIFFER PER BACKEND. `context`,
#      `matrix`, `in` are Odin's; `addr`, `ptr`, `method`, `end` are Nim's.
#
# Both lists are invisible to the Tuck author and grow whenever a runtime or
# a target language does. So the collision is inverted here: user names get a
# `tuck_` prefix that cannot clash in any backend, now or later.
#
# WHY A PASS, NOT PER-BACKEND EMISSION:
#   - Written once; every backend (Nim, Odin, and any future one) gets
#     it without re-deriving the rule.
#   - Declarations and references are renamed by the SAME walk, so they
#     cannot drift apart. Mangling a declaration but missing one of its
#     reference sites produces broken output rather than a compile error —
#     the likeliest bug in a per-backend approach with ~20 sites each.
#   - Backends stay dumb: they emit `d.name` and need not know this exists.
#   - Inspectable: `tuck --ast` shows exactly what was renamed.
#
# NOT MANGLED:
#   - FIELDS. A field is namespaced by its record type and cannot collide
#     with a global. Leaving them bare keeps literals readable.
#   - EXTERNS. `std/fs.tuck` declaring `fn readFile` means "bind to the
#     runtime's readFile", so the name must survive verbatim. This is the
#     existing FFI escape hatch; an explicit `[extern: "c_name"]` attribute
#     would extend the same predicate here rather than in three backends.
#   - LOCALS AND PARAMS. Not global, cannot collide.
#   - ENUM VARIANTS / MATCH PATTERNS. Reached through their owning type.
import ast, strutils, sets, tables
import resolution

const TuckNamePrefix* = "tuck_"

proc mangleName*(name: string): string =
  ## Idempotent: re-running the pass over an already-lowered tree is a no-op,
  ## which matters because each backend lowers its own deepCopy.
  if name.len == 0 or name.startsWith(TuckNamePrefix): return name
  TuckNamePrefix & name

proc isManglable(d: Decl): bool =
  ## Externs bind a foreign symbol by name, so they keep theirs.
  if d == nil or d.name.len == 0: return false
  case d.kind
  of dkFn: not d.isExtern
  # a type declared inside an `extern [c, header: ...]` block IS the C struct,
  # so it keeps its name for the same reason extern fns do — the Nim backend
  # emits it as the importc name, which must match the header.
  of dkType: d.typeExternHeader == ""
  of dkObject, dkActor, dkTask, dkConst, dkPool, dkRegistry,
     dkRegister, dkFnSig: true
  else: false

# The set of names a module declares and will rename. Built first so
# reference sites can tell a global from a local without re-scanning.
proc manglableNames*(m: Module): HashSet[string] =
  result = initHashSet[string]()
  for d in m.decls:
    if isManglable(d): result.incl(d.name)
    # a mixin's members become top-level fns in every backend
    if d != nil and d.kind == dkMixin:
      for mem in d.mixinMembers:
        if isManglable(mem): result.incl(mem.name)

# The union across the whole import closure. A qualified reference
# (`http::get`) names a decl in ANOTHER module, so deciding whether it is
# manglable needs the closure: `http::get` is a user fn and becomes
# tuck_get, while `fs::readFile` is an extern and must stay verbatim. One
# module alone cannot tell these apart.
proc programNames*(mods: seq[Module]): HashSet[string] =
  result = initHashSet[string]()
  for m in mods:
    let ns = manglableNames(m)
    for n in ns: result.incl(n)

proc mangleType(t: Type, names: HashSet[string]) =
  if t == nil: return
  case t.kind
  of tkNamed:
    if t.name in names: t.name = mangleName(t.name)
  of tkApp:
    mangleType(t.base, names)
    for a in t.args: mangleType(a, names)
  of tkTuple:
    for e in t.elems: mangleType(e, names)
  of tkFunc:
    for p in t.params: mangleType(p, names)
    mangleType(t.result, names)
  of tkRecord:
    # field NAMES stay bare; their types still resolve to declarations
    for f in t.fields: mangleType(f.typ, names)
  of tkSum:
    for v in t.variants:
      for f in v.fields: mangleType(f.typ, names)
  of tkUnion:
    for mem in t.members: mangleType(mem, names)
  of tkRename:
    mangleType(t.underlying, names)
  else: discard

proc mangleExpr(e: Expr, names: HashSet[string], locals: var HashSet[string]) =
  ## `locals` shadows: a param or `let` named the same as a global refers to
  ## the local, so it must NOT be renamed.
  if e == nil: return
  # A bare name in call position (`if ready:`) is stamped by the checker as a
  # nullary call living in the SEMANTIC LAYER, not in this tree. Backends emit
  # that stamped expression instead of the exkVar, so it must be renamed too —
  # missing it declares tuck_ready while still calling ready().
  if semLayer.hasCall(e):
    mangleExpr(semLayer.call(e), names, locals)

  case e.kind
  of exkVar:
    if e.name in names and e.name notin locals:
      e.name = mangleName(e.name)
  of exkQualified:
    # `:fnref` (no module path) and `http::get` (qualified) both resolve
    # against the program-wide set, so a cross-module reference lands on the
    # same name that module's own pass produced — and an extern like
    # `fs::readFile`, which is never manglable, stays verbatim.
    if e.qualName in names:
      e.qualName = mangleName(e.qualName)
  of exkField:
    mangleExpr(e.receiver, names, locals)
    mangleExpr(e.dotArg, names, locals)
  of exkStruct:
    # field names bare; values walked
    for f in e.fields: mangleExpr(f[1], names, locals)
  of exkList:
    for it in e.items: mangleExpr(it, names, locals)
  of exkBracket:
    mangleExpr(e.brReceiver, names, locals)
    for a in e.brArgs: mangleExpr(a, names, locals)
  of exkBracketAssign:
    mangleExpr(e.brTarget, names, locals)
    mangleExpr(e.brValue, names, locals)
  of exkCall:
    mangleExpr(e.callee, names, locals)
    for a in e.args: mangleExpr(a, names, locals)
  of exkChain:
    mangleExpr(e.base, names, locals)
    for s in e.steps:
      mangleExpr(s.target, names, locals)
      mangleExpr(s.arg, names, locals)
  of exkBinary:
    mangleExpr(e.left, names, locals)
    mangleExpr(e.right, names, locals)
  of exkUnary:
    mangleExpr(e.operand, names, locals)
  of exkBlock:
    for s in e.stmts: mangleExpr(s, names, locals)
  of exkIf:
    mangleExpr(e.cond, names, locals)
    mangleExpr(e.thenBranch, names, locals)
    mangleExpr(e.elseBranch, names, locals)
  of exkMatch:
    mangleExpr(e.subject, names, locals)
    for arm in e.arms: mangleExpr(arm.body, names, locals)
  of exkFor:
    mangleExpr(e.iterable, names, locals)
    # the loop variable is a local for the body's duration
    var inner = locals
    if e.iter != nil and e.iter.kind == pkVar: inner.incl(e.iter.name)
    mangleExpr(e.body, names, inner)
  of exkWhile:
    mangleExpr(e.whileCond, names, locals)
    mangleExpr(e.whileBody, names, locals)
  of exkAssign:
    # `let x = ...` introduces a local that shadows from here on
    mangleExpr(e.assignVal, names, locals)
    if e.target != nil and e.target.kind == exkVar:
      locals.incl(e.target.name)
    else:
      mangleExpr(e.target, names, locals)
  of exkReturn:
    mangleExpr(e.returnVal, names, locals)
  of exkRaise:
    mangleExpr(e.raiseVal, names, locals)
  of exkSend:
    if e.sendActor in names: e.sendActor = mangleName(e.sendActor)
    mangleExpr(e.sendPayload, names, locals)
  of exkSelect:
    for arm in e.selArms:
      mangleExpr(arm.arg, names, locals)
      mangleExpr(arm.body, names, locals)
  else: discard

proc mangleFnBody(d: Decl, names: HashSet[string]) =
  var locals = initHashSet[string]()
  for p in d.fnParams: locals.incl(p.name)
  mangleExpr(d.fnBody, names, locals)
  for p in d.fnParams: mangleType(p.typ, names)
  mangleType(d.fnReturnType, names)

proc mangleMember(mem: Decl, names: HashSet[string])

proc mangleMember(mem: Decl, names: HashSet[string]) =
  ## Members nest: a `pending:` block inside an object parses as a mixin whose
  ## own members are fns, so walking one level would miss their types — that
  ## is how `!{feed: Feed}` kept an unmangled Feed while the declaration
  ## became tuck_Feed. Recursive so no nesting depth is special.
  if mem == nil: return
  case mem.kind
  of dkFn:
    mangleFnBody(mem, names)
  of dkExpr:
    var l = initHashSet[string]()
    mangleExpr(mem.expr, names, l)
  of dkMixin:
    for inner in mem.mixinMembers: mangleMember(inner, names)
  of dkType:
    mangleType(mem.typeBody, names)
    for inner in mem.typeMembers: mangleMember(inner, names)
  of dkObject:
    for f in mem.objFields: mangleType(f.typ, names)
    for inner in mem.objMembers: mangleMember(inner, names)
  else: discard

proc mangleModuleWith(m: Module, names: HashSet[string])

proc mangleProgram*(mods: seq[Module]) =
  ## Mangle a whole import closure — the entry module plus every module it
  ## imports — in ONE pass, then the shared Resolution.
  ##
  ## Whole-program is required, not merely tidier: a qualified reference
  ## names a decl in another module, so `http::get` (a user fn, becomes
  ## tuck_get) and `fs::readFile` (an extern, stays verbatim) are only
  ## distinguishable with the closure in hand.
  ##
  ## The Resolution is a GLOBAL side-table keyed by node id holding the Types
  ## the checker inferred and the call Exprs it stamped. Backends read it
  ## constantly (`getFieldsForType(m, semLayer.typeFor(e))`), so a Type still
  ## naming `Episode` after its module declares `tuck_Episode` resolves to
  ## nothing and the backend silently falls back — that is how `merge` began
  ## emitting a call to an undeclared name. It is shared by every backend, so
  ## this must run once, before the per-backend deepCopies.
  let names = programNames(mods)
  if names.len == 0: return

  for m in mods:
    mangleModuleWith(m, names)

  # Type and Expr are ref objects, so renaming through the value the table
  # yields updates what the table holds — no write-back needed.
  for t in semLayer.types.values:
    mangleType(t, names)
  # Stamped call Exprs are renamed here too; mangleExpr's own recursion into
  # semLayer.call() is then redundant but harmless, mangleName being
  # idempotent.
  var locals = initHashSet[string]()
  for e in semLayer.calls.values:
    mangleExpr(e, names, locals)

proc mangleModuleWith(m: Module, names: HashSet[string]) =
  ## Rename every manglable declaration in this module and every reference to
  ## one, resolving against the PROGRAM-WIDE name set so cross-module
  ## references land on the same symbol the target module produced.
  ## Idempotent — mangleName skips an already-prefixed name.
  for d in m.decls:
    if d == nil: continue
    # references inside bodies, before the declaration itself is renamed
    case d.kind
    of dkFn:
      mangleFnBody(d, names)
    of dkTask:
      var locals = initHashSet[string]()
      for p in d.taskParams: locals.incl(p.name)
      mangleExpr(d.taskBody, names, locals)
      for p in d.taskParams: mangleType(p.typ, names)
      mangleType(d.taskReturnType, names)
    of dkObject:
      for f in d.objFields: mangleType(f.typ, names)
      for mem in d.objMembers: mangleMember(mem, names)
    of dkType:
      mangleType(d.typeBody, names)
      for mem in d.typeMembers: mangleMember(mem, names)
    of dkActor:
      for f in d.actorFields: mangleType(f.typ, names)
      for h in d.handlers: mangleMember(h, names)
    of dkMixin:
      for mem in d.mixinMembers: mangleMember(mem, names)
    of dkExpr:
      var l = initHashSet[string]()
      mangleExpr(d.expr, names, l)
    of dkConst:
      var l = initHashSet[string]()
      mangleExpr(d.constVal, names, l)
    of dkPool:
      mangleType(d.poolElem, names)
    of dkStaticAssert:
      var l = initHashSet[string]()
      mangleExpr(d.assertExpr, names, l)
    else: discard

  # now the declarations themselves
  for d in m.decls:
    if isManglable(d): d.name = mangleName(d.name)
    elif d != nil and d.kind == dkMixin:
      for mem in d.mixinMembers:
        if isManglable(mem): mem.name = mangleName(mem.name)
