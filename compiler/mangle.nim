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
# a target language does. So the collision is inverted here: every user name
# is spelled `tuckˑ<kind>ˑ<name>` (name_prefix.nim, which says why that
# spelling cannot clash in any backend, with each other or with the runtime).
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
#   - ENUM VARIANTS / MATCH PATTERNS. Reached through their owning type.
#
# THE BOUNDARY: EMITTED IDENTIFIERS ONLY.
#
# Mangling exists to keep emitted IDENTIFIERS from colliding with
# target-language symbols. That is its entire scope. Anything that is not an
# emitted identifier must not be mangled.
#
# Error ids are the case to keep in mind. An id like `t/ParseError.Empty` is
# hashed to a uint16 at compile time and printed back to the user in reports —
# it never becomes an identifier in the output, so it must be spelled the way
# the user wrote it, not the way the backend emits it.
#
# That is what `sourceName` on Type / Expr / Decl (ast.nim) is for: this pass
# records the original name at the moment it renames, via rememberSource below,
# and anything needing the user-facing name reads it back with `writtenName`.
# Keep the fact rather than reconstructing it — stripping a prefix off a
# mangled name is a guess, and it breaks as soon as anything else adds one.
import ast, sets, tables, std/options
import resolution
import name_prefix
export name_prefix

proc mangleName*(name: string, kind: NameKind): string =
  ## Idempotent: re-running the pass over an already-lowered tree is a no-op,
  ## which matters because each backend lowers its own deepCopy.
  ##
  ## Mangled in ONE place for all three backends, so a name is spelled the
  ## same everywhere even though only Nim can fold it.
  if name.len == 0 or isMangledName(name): return name
  prefixed(name, kind)

type MangleNames* = Table[string, NameKind]
  ## Every top-level name the program declares and renames, under the name
  ## the user wrote, with the kind that picks its prefix.

proc rememberSource(slot: var Option[string], name: string) =
  ## Records the pre-mangle name, once. Guarded because each backend lowers
  ## its own deepCopy and re-runs this pass — a second run must not overwrite
  ## the original with the already-mangled name.
  if slot.isNone: slot = some(name)

proc renameDecl(d: Decl) =
  ## Renames a decl to its mangled form, keeping what the user wrote.
  rememberSource(d.sourceName, d.name)
  d.name = mangleName(d.name, declKind(d))

proc renameType(t: Type, kind: NameKind) =
  ## Renames a named type reference, keeping what the user wrote.
  rememberSource(t.sourceName, t.name)
  t.name = mangleName(t.name, kind)

proc renameVar(e: Expr, kind: NameKind) =
  ## Renames a variable reference — to a top-level decl, or a local (always
  ## nkLocal) — keeping what the user wrote.
  rememberSource(e.sourceName, e.name)
  e.name = mangleName(e.name, kind)

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
proc manglableNames*(m: Module): MangleNames =
  for d in m.decls:
    if isManglable(d): result[d.name] = declKind(d)
    # members of a mixin / extern / pending block become top-level fns in
    # every backend, so their names are manglable too
    if d != nil and d.kind in {dkMixin, dkExtern, dkPending}:
      for mem in d.mixinMembers:
        if isManglable(mem): result[mem.name] = declKind(mem)

# The union across the whole import closure. A qualified reference
# (`http::get`) names a decl in ANOTHER module, so deciding whether it is
# manglable needs the closure: `http::get` is a user fn and becomes
# tuck_get, while `fs::readFile` is an extern and must stay verbatim. One
# module alone cannot tell these apart.
proc programNames*(mods: seq[Module]): MangleNames =
  for m in mods:
    for n, k in manglableNames(m): result[n] = k

proc mangleType(t: Type, names: MangleNames) =
  ## Rename every type NAME reachable from `t`. Field and variant names stay
  ## bare — only the types they hold resolve to declarations, and ast.children
  ## yields exactly those.
  ##
  ## The walk used to be spelled out here, ending in `else: discard` — which
  ## covered tkEffect, the one kind resolveTypeRefs listed and this did not.
  ## Harmless today only because nothing constructs a tkEffect (effects ride on
  ## fnEffects, and `!T` is its own wrapper), so the divergence was latent
  ## rather than live. Sharing the iterator means the two cannot drift again.
  if t == nil: return
  if t.kind == tkNamed and t.name in names: renameType(t, names[t.name])
  for c in t.children: mangleType(c, names)

proc mangleRefName(e: Expr, names: MangleNames) =
  ## Same treatment as exkSend's sendActor: a bare name naming a top-level
  ## declaration, renamed to match that declaration's own mangled name.
  if e.refName in names: e.refName = mangleName(e.refName, names[e.refName])

proc mangleExpr(res: Resolution, e: Expr, names: MangleNames, locals: var HashSet[string],
                fields: HashSet[string] = initHashSet[string]())

proc bindLoopVars(pat: Pattern, locals: var HashSet[string]) =
  ## Every name a loop pattern BINDS, renamed here and recorded so the body's
  ## references follow. `for i, x in xs` is a pkTuple of pkVars, not a bare
  ## pkVar — handling only the simple shape left the indexed form's variables
  ## unmangled while everything around them moved.
  if pat == nil: return
  case pat.kind
  of pkVar:
    locals.incl(pat.name)
    pat.name = mangleName(pat.name, nkLocal)
  of pkTuple:
    for el in pat.elems: bindLoopVars(el, locals)
  else: discard

proc mangleFor(res: Resolution, e: Expr, names: MangleNames, locals: var HashSet[string],
               fields: HashSet[string]) =
  ## The loop variable is a local for the body's duration — bound here, so
  ## renamed here, with the written name added to the body's scope so its
  ## references rename to match. Pattern carries no sourceName slot, and
  ## nothing reads a loop variable's written name back the way a decl's is.
  mangleExpr(res, e.iterable, names, locals, fields)
  var inner = locals
  bindLoopVars(e.iter, inner)
  mangleExpr(res, e.body, names, inner, fields)

proc mangleAssign(res: Resolution, e: Expr, names: MangleNames, locals: var HashSet[string],
                  fields: HashSet[string]) =
  ## `let x = ...` introduces a local that shadows from here on. Value FIRST,
  ## then the name becomes local — so `let x = x` reads the outer one. A bare
  ## target IS the binding site: rename it, and record the name the user wrote
  ## so every later reference renames to match. A name that is one of the
  ## enclosing actor's/type's fields is never a new local — it is a field
  ## write the backend spells `self.name`.
  mangleExpr(res, e.assignVal, names, locals, fields)
  # `let x: T = ...` — the STATED type names a declaration like any other
  # type reference does, so it renames with the rest. Missing this emitted
  # the user's own `Bag` beside the declaration's `tuck_Bag`.
  if e.declType != nil: mangleType(e.declType, names)
  if e.target != nil and e.target.kind == exkVar and
     e.target.name notin fields and not res.isOwnerField(e.target):
    locals.incl(e.target.name)
    renameVar(e.target, nkLocal)
  else:
    mangleExpr(res, e.target, names, locals, fields)

proc isVariantOf(res: Resolution, subject: Expr, name: string): bool =
  ## Is `name` a variant of the subject's sum type? The checker reads a
  ## pattern as a variant first, so the mangler must not rename one that
  ## happens to share a declaration's name.
  var t = res.typeFor(subject)
  if t != nil and t.kind == tkNamed:
    let d = res.declForType(t)
    t = if d != nil and d.kind == dkType: d.typeBody else: nil
  if t == nil or t.kind != tkSum: return false
  for v in t.variants:
    if v.name == name: return true
  false

proc mangleMatch(res: Resolution, e: Expr, names: MangleNames,
                 locals: var HashSet[string], fields: HashSet[string]) =
  ## The subject, then each arm. A binding arm's name is a local of that arm,
  ## renamed with its reads — as a loop variable is (bindLoopVars). Left
  ## bare, a read of it would have been renamed to a GLOBAL of that name.
  ##
  ## A TAG naming a top-level declaration (`LIMIT:` for `const LIMIT`) is
  ## renamed with it, or the arm compares against a name nothing declares.
  ## A variant or an error name is not a declaration, so is left alone.
  mangleExpr(res, e.subject, names, locals, fields)
  for arm in e.arms:
    var inner = locals
    let p = arm.pattern
    if p != nil and p.kind == pkBind:
      inner.incl(p.name)
      p.name = mangleName(p.name, nkLocal)
    elif p != nil and p.kind == pkVar and p.name in names and
         names[p.name] == nkConst and not isVariantOf(res, e.subject, p.name):
      p.name = mangleName(p.name, nkConst)
    mangleExpr(res, arm.body, names, inner, fields)

proc mangleExpr(res: Resolution, e: Expr, names: MangleNames, locals: var HashSet[string],
                fields: HashSet[string] = initHashSet[string]()) =
  ## `locals` holds the names bound INSIDE this body — params, `let`/`var`
  ## bindings, loop variables — under the name the USER wrote.
  ##
  ## Locals are mangled too, and for the same reason globals are: an emitted
  ## identifier must not collide with something the target language already
  ## defines. `var out = ""` is legal Tuck and a syntax error in Nim, because
  ## `out` is a Nim keyword — the kind of break that surfaces as a Nim error
  ## about code the author never wrote. Scope makes a local safe from OTHER
  ## TUCK names, never from the backend's own.
  ##
  ## A local shadowing a global still shadows after both are mangled: each
  ## reference is resolved HERE, by this walk's scopes, and spelled as what it
  ## names — `tuckˑvˑready` inside the local's scope, `tuckˑfnˑready` outside.
  if e == nil: return
  # A bare name in call position (`if ready:`) is stamped by the checker as a
  # nullary call living in the SEMANTIC LAYER, not in this tree. Backends emit
  # that stamped expression instead of the exkVar, so it must be renamed too —
  # missing it declares tuck_ready while still calling ready().
  if res.hasCall(e):
    mangleExpr(res, res.call(e), names, locals, fields)

  case e.kind
  of exkVar:
    # A bare name the checker resolved to the enclosing owner's FIELD is
    # neither a local nor a global — the backends emit it as `self.name`,
    # against a field this pass never renames. Checked first, or an actor
    # handler's `state = ...` would be mistaken for a new local. (`fields`
    # also holds the params, which stay bare as a contract — mangleFnBody.)
    # A local shadows the global of the same name, so it is asked first.
    if res.isOwnerField(e) or e.name in fields: discard
    elif e.name in locals: renameVar(e, nkLocal)
    elif e.name in names: renameVar(e, names[e.name])
  of exkQualified:
    # `:fnref` (no module path) and `http::get` (qualified) both resolve
    # against the program-wide set, so a cross-module reference lands on the
    # same name that module's own pass produced — and an extern like
    # `fs::readFile`, which is never manglable, stays verbatim.
    if e.qualName in names:
      e.qualName = mangleName(e.qualName, names[e.qualName])
  # The uniform middle: kinds whose children are all walked with the SAME
  # locals set, in no particular order. Everything with a scoping rule of its
  # own — exkFor, exkAssign, exkMatch — is spelled out below instead, because
  # for those it matters WHICH children are visited and in what order.
  of exkField, exkStruct, exkList, exkBracket, exkBracketAssign, exkCall,
     exkCombinator, exkChain, exkBinary, exkUnary, exkBlock, exkIf, exkWhile,
     exkReturn, exkRaise, exkDiscard, exkDefer, exkFinish, exkAcquire,
     exkOrdinal, exkValidate, exkIfaceCall, exkPoolOp:
    for c in e.children: mangleExpr(res, c, names, locals, fields)
  of exkMatch: mangleMatch(res, e, names, locals, fields)
  of exkFor: mangleFor(res, e, names, locals, fields)
  of exkAssign: mangleAssign(res, e, names, locals, fields)
  of exkSend:
    if e.sendActor in names:
      e.sendActor = mangleName(e.sendActor, names[e.sendActor])
    mangleExpr(res, e.sendPayload, names, locals, fields)
  of exkSelect:
    for arm in e.selArms:
      mangleExpr(res, arm.arg, names, locals, fields)
      mangleExpr(res, arm.body, names, locals, fields)
  of exkActorRef, exkRegisterRef, exkRegistryRef, exkPoolRef, exkMixinRef:
    mangleRefName(e, names)
  # Nothing to rename, and spelled out rather than left to `else: discard`.
  # The `else` that used to close this case swallowed exkCombinator when it
  # was added: the emitted Nim read `(a: x.a, op: plus)` beside a
  # `var tuck_x`, because the declaration was renamed and the reference
  # inside the combinator was not. Every kind is listed now, so the next one
  # stops the build here instead.
  of exkLit, exkBreak, exkContinue, exkImport, exkTripleDot:
    discard

proc mangleFnBody(res: Resolution, d: Decl, names: MangleNames,
                  fields: HashSet[string] = initHashSet[string]()) =
  # Params are NOT renamed, and so are passed as `fields` rather than as
  # locals: a param name is a CONTRACT, not a free identifier. It is the
  # payload field the caller binds by name, it becomes an envelope struct's
  # field for a task or an actor handler, and `self` is matched literally by
  # every backend. Renaming one silently breaks that pairing — the envelope
  # keeps `fd` while the body reads `tuck_fd`. Locals have no such second
  # meaning, which is exactly why they can move.
  var locals = initHashSet[string]()
  var paramNames = fields
  for p in d.fnParams: paramNames.incl(p.name)
  mangleExpr(res, d.fnBody, names, locals, paramNames)
  for p in d.fnParams: mangleType(p.typ, names)
  mangleType(d.fnReturnType, names)

proc mangleMember(res: Resolution, mem: Decl, names: MangleNames,
                  fields: HashSet[string] = initHashSet[string]())

proc mangleManagerType(res: Resolution, d: Decl, names: MangleNames,
                       fields: HashSet[string]) =
  ## A manager type's members read its fields as bare names (codegen seeds
  ## fieldVars from typeBody.fields), so they are off limits in there.
  mangleType(d.typeBody, names)
  var inner = fields
  if d.typeBody != nil and d.typeBody.kind == tkRecord:
    for f in d.typeBody.fields: inner.incl(f.name)
  for m2 in d.typeMembers: mangleMember(res, m2, names, inner)

proc mangleSelectArms(res: Resolution, d: Decl, names: MangleNames,
                      fields: HashSet[string]) =
  ## An actor's `on select` arm is a handler whose params are its payload
  ## binding. They stay bare, as a handler's params do (mangleFnBody: a param
  ## is a contract), so they join the actor's fields as names left alone.
  ## Arms were once not walked at all, and a type named in one kept its
  ## unmangled spelling.
  for arm in d.selectArms:
    var inner = fields
    for p in arm.binding:
      inner.incl(p.name)
      mangleType(p.typ, names)
    var l = initHashSet[string]()
    mangleExpr(res, arm.body, names, l, inner)

proc mangleMember(res: Resolution, mem: Decl, names: MangleNames,
                  fields: HashSet[string] = initHashSet[string]()) =
  ## Members nest: a `pending:` block inside an object parses as a mixin whose
  ## own members are fns, so walking one level would miss their types — that
  ## is how `!{feed: Feed}` kept an unmangled Feed while the declaration
  ## became tuck_Feed. Recursive so no nesting depth is special.
  if mem == nil: return
  case mem.kind
  of dkFn:
    mangleFnBody(res, mem, names, fields)
  of dkExpr:
    var l = initHashSet[string]()
    mangleExpr(res, mem.expr, names, l, fields)
  of dkMixin, dkExtern, dkPending:
    for inner in mem.mixinMembers: mangleMember(res, inner, names, fields)
  of dkType: mangleManagerType(res, mem, names, fields)
  of dkObject:
    for f in mem.objFields: mangleType(f.typ, names)
    for inner in mem.objMembers: mangleMember(res, inner, names)
  of dkSelect: mangleSelectArms(res, mem, names, fields)
  # Exhaustive, so a new DeclKind has to be decided here (CLAUDE.md). None
  # of these holds code a member walk reaches: a top-level one is walked by
  # mangleDeclRefs, and `ownExprs` reaches its expressions.
  of dkActor, dkTask, dkConst, dkStaticAssert, dkRegistry, dkPool,
     dkRegister, dkErrors, dkResources, dkImport, dkFnSig, dkSatisfies,
     dkInterface, dkGroup, dkPublic, dkWhen:
    discard

proc mangleModuleWith(res: Resolution, m: Module, names: MangleNames)

proc mangleDeclRefs(res: Resolution, d: Decl, names: MangleNames) =
  ## Rename every reference INSIDE a declaration, before the declaration
  ## itself is renamed.
  ##
  ## Three jobs, each expressed once: the types it mentions, the bodies it
  ## owns, and its nested members. ownTypes / ownExprs / childDecls supply all
  ## three, so a new DeclKind is reached here automatically once it is listed
  ## in those iterators — which is the point of having them.
  for t in d.ownTypes: mangleType(t, names)

  # A fn's body needs its params in scope as locals; mangleFnBody knows that.
  # A task's is the same shape, spelled with taskParams. Both also re-mangle
  # their param/return types, which ownTypes above already covered —
  # harmless, since mangleName skips an already-prefixed name.
  if d.kind == dkFn:
    mangleFnBody(res, d, names)
  elif d.kind == dkTask:
    # Same rule as a fn's params, and for the sharper version of the same
    # reason: a task's params ARE the fields of the envelope struct its
    # spawn packs, so renaming a reference leaves the envelope naming `fd`
    # while the body reads `tuck_fd`.
    var locals = initHashSet[string]()
    var paramNames = initHashSet[string]()
    for p in d.taskParams: paramNames.incl(p.name)
    mangleExpr(res, d.taskBody, names, locals, paramNames)
  else:
    # Everything else owning an expression — dkExpr, dkConst, dkStaticAssert,
    # a select arm — has no parameters, so each gets a fresh empty scope.
    for e in d.ownExprs:
      var l = initHashSet[string]()
      mangleExpr(res, e, names, l)

  # An actor's handlers read its fields as bare names (`total += n` assigns
  # the singleton's field), so those names must reach the walk as fields —
  # renaming one turns a field write into a new local the backend then has
  # no type for.
  var ownFields = initHashSet[string]()
  if d.kind == dkActor:
    for f in d.actorFields: ownFields.incl(f.name)
  elif d.kind == dkType and d.typeBody != nil and d.typeBody.kind == tkRecord:
    for f in d.typeBody.fields: ownFields.incl(f.name)
  for mem in d.childDecls: mangleMember(res, mem, names, ownFields)

proc mangleProgram*(res: Resolution, mods: seq[Module]) =
  ## `res` is the semantic layer typechecking produced — taken as an argument
  ## so this stage cannot run before the one that fills it.
  ##
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
  ## constantly (`getFieldsForType(m, res.typeFor(e))`), so a Type still
  ## naming `Episode` after its module declares `tuck_Episode` resolves to
  ## nothing and the backend silently falls back — that is how `merge` began
  ## emitting a call to an undeclared name. It is shared by every backend, so
  ## this must run once, before the per-backend deepCopies.
  let names = programNames(mods)
  if names.len == 0: return

  for m in mods:
    mangleModuleWith(res, m, names)

  # Type and Expr are ref objects, so renaming through the value the table
  # yields updates what the table holds — no write-back needed.
  for t in res.types.values:
    mangleType(t, names)
  # Stamped call Exprs are renamed here too; mangleExpr's own recursion into
  # res.call() is then redundant but harmless, mangleName being
  # idempotent.
  var locals = initHashSet[string]()
  for e in res.calls.values:
    mangleExpr(res, e, names, locals)

proc mangleModuleWith(res: Resolution, m: Module, names: MangleNames) =
  ## Rename every manglable declaration in this module and every reference to
  ## one, resolving against the PROGRAM-WIDE name set so cross-module
  ## references land on the same symbol the target module produced.
  ## Idempotent — mangleName skips an already-prefixed name.
  for d in m.decls:
    if d == nil: continue
    # references inside bodies, before the declaration itself is renamed
    mangleDeclRefs(res, d, names)

  # now the declarations themselves
  for d in m.decls:
    if isManglable(d): renameDecl(d)
    elif d != nil and d.kind in {dkMixin, dkExtern, dkPending}:
      for mem in d.mixinMembers:
        if isManglable(mem): renameDecl(mem)
