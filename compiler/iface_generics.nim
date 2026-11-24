## An interface as the bound of a free generic fn — `fn join[T: AudioSource]`
## (ruled 2026-09-27) — expanded to one plain fn per object type it is called
## with.
##
## Why expanded. An object's member is emitted under a per-object name
## (`tuckˑobjectˑFlacˑsampleRate`), so a body calling `a.sampleRate` on an
## `a: T` has nothing to call until T is known. The checker checks the
## generic body once, against the contract (typecheck.asBoundIfaceCall), and
## records what T is at every call (`Resolution.ifaceInstances`). This pass
## then clones the fn once per object type — T replaced, a concrete name,
## `join_Flac` — and points each call at its clone, and the program is
## checked again. Every clone is ordinary concrete code: its member calls
## reach that object's members, a T entering an interface slot is wrapped,
## and no later stage or backend learns that interface-bounded generics
## exist. generic_actors.nim does the same for generic actors; this runs
## AFTER the checker instead of before it, because only the checker knows
## what T is at a call.
##
## Rounds. A call inside one interface-bounded body to another binds T to
## the outer body's own type parameter, so it is expanded in the next round,
## from the outer fn's clone. typecheck.typecheckProgram repeats check and
## expand until a round changes nothing, then drops the generic originals —
## never emitted, since a member call on a bare T has no target.
import std/[tables, sets]
import ast, ast_ops, ast_query, resolution
import module_ids       # knownModule: a qualified name points at its module
import typecheck_util   # fail: a clone that cannot name what its body calls

type Program* = seq[tuple[name, path: string, m: Module]]

proc boundedByIface(m: Module, d: Decl): seq[int] =
  ## Indexes of `d`'s type params bounded by an interface `m` declares —
  ## `m` being the module that declares `d`.
  if d == nil or d.kind != dkFn or d.origin != NoModule: return
  for i in 0 ..< min(d.fnGenerics.len, d.fnGenericBounds.len):
    for b in d.fnGenericBounds[i]:
      if m.findDecl(dkInterface, groupNameOf(b)) != nil:
        result.add(i)
        break

proc isObject(prog: Program, name: string): bool =
  for (_, _, m) in prog:
    if m.findDecl(dkObject, name) != nil: return true

proc concreteArgs(prog: Program, args: seq[Type], idx: seq[int]): seq[Type] =
  ## The bounded params' types at one call, or empty when any is not a
  ## declared object — a type param of an enclosing generic body, which a
  ## later round sees concrete.
  for i in idx:
    if i >= args.len: return @[]
    let t = args[i]
    if t == nil or t.kind != tkNamed or not prog.isObject(t.name):
      return @[]
    result.add(t)

proc substBodyTypes(e: Expr, subs: Table[string, Type]) =
  ## Type annotations written inside the body (`let x: T = ...`).
  if e == nil: return
  if e.kind == exkAssign and e.declType != nil:
    e.declType = substType(e.declType, subs)
  for c in e.children: substBodyTypes(c, subs)

type
  Scopes* = Table[string, Table[string, string]]
    ## Module name -> the import that owns each name the module may write
    ## bare (`typecheck.moduleScopes`, as the checker decided it).

  Rehome = object
    ## Where a clone is going, and what names mean on each side.
    res: Resolution
    home, into: string          ## the generic's module, and the caller's
    homeM, intoM: Module
    scopes: Scopes
    exports: Table[string, (bool, HashSet[string])]
    generics: HashSet[string]   ## other interface-bounded fns: left bare,
                                ## the next round expands them by name
    site: Span                  ## the call that asks for the clone

proc ownerIn(r: Rehome, module: string, m: Module, name: string): string =
  ## The module a bare `name` means in `module`: its own, else the import the
  ## checker gave the name to, else "".
  if m.declaresCallable(name): module
  else: r.scopes.getOrDefault(module).getOrDefault(name)

proc rehomed(r: Rehome, generic, name: string): seq[string] =
  ## How the clone must spell a fn the generic's body calls `name`: @[] to
  ## keep it bare, or the module to qualify it with.
  ##
  ## The body was written, and checked, in its own module. Its clone is
  ## checked again in the CALLER's module, where the same bare name can mean
  ## the caller's own fn (which then ran instead of the library's, silently),
  ## or nothing at all (audit M14). So a name that means something else there
  ## is written `owner::name`. One the caller cannot reach itself — private
  ## to the library, or from an import the caller does not have — is still
  ## the library's to call: it is recorded in `cloneReach`, which puts that
  ## one name in the caller's scope for the clone. It used to be refused,
  ## asking the caller to import the library's internals or the library to
  ## publish them.
  let owner = r.ownerIn(r.home, r.homeM, name)
  if owner == "" or name in r.generics: return @[]
  if r.ownerIn(r.into, r.intoM, name) == owner: return @[]
  var imported = false
  for d in r.intoM.decls(dkImport):
    if d.name == owner: imported = true
  let (restricted, allowed) = r.exports.getOrDefault(owner)
  if not (imported and (not restricted or name in allowed)):
    cloneReach.mgetOrPut(r.into, initHashSet[string]()).incl owner & "::" & name
  @[owner]

proc qualifiedFn(e: Expr, name: string, q: seq[string]): Expr =
  Expr(span: e.span, kind: exkQualified, modulePath: q, qualName: name,
       qualModule: knownModule(q[0]))

proc isResolvedCall(r: Rehome, c: Expr): bool =
  ## A call the checker resolved to a declaration (not a requirement, a member
  ## or a fn-valued local, which keep their names).
  c != nil and c.kind == exkCall and r.res.declFor(c) != nil

proc rehomeCall(r: Rehome, generic: string, e: Expr) =
  if e.callee == nil or e.callee.kind != exkVar or not r.isResolvedCall(e): return
  let q = r.rehomed(generic, e.callee.name)
  if q.len > 0: e.callee = qualifiedFn(e.callee, e.callee.name, q)

proc rehomeBareCall(r: Rehome, generic: string, e: var Expr) =
  ## A bare nullary call, `helper`: a name the checker stamped as a call.
  if not r.isResolvedCall(r.res.call(e)): return
  let q = r.rehomed(generic, e.name)
  if q.len > 0:
    e = Expr(span: e.span, kind: exkCall, args: @[],
             callee: qualifiedFn(e, e.name, q))

proc rehomeNames(r: Rehome, generic: string, e: var Expr) =
  ## Every fn the clone's body names, spelled as the caller must spell it.
  ## Run on the deep copy BEFORE its ids are cleared: which bare names are
  ## calls is read from what the checker stamped on the original.
  if e == nil: return
  for slot in e.childSlots: r.rehomeNames(generic, slot)
  case e.kind
  of exkCall: r.rehomeCall(generic, e)
  of exkVar: r.rehomeBareCall(generic, e)
  of exkQualified:           # `:helper`, a fn named as a value
    if e.modulePath.len == 0:
      e.modulePath = r.rehomed(generic, e.qualName)
      if e.modulePath.len > 0: e.qualModule = knownModule(e.modulePath[0])
  else: discard

proc expandOne(orig: Decl, idx: seq[int], args: seq[Type], name: string,
               r: Rehome): Decl =
  ## One instantiation: a deep copy, ids cleared (typecheck's caller numbers
  ## them), the bounded params replaced and dropped from the generics. Any
  ## other type param stays: the clone is still generic in it.
  var subs = initTable[string, Type]()
  for k, i in idx: subs[orig.fnGenerics[i]] = args[k]
  result = deepCopy(orig)
  if r.home != r.into: r.rehomeNames(orig.name, result.fnBody)
  clearIds(result)
  result.name = name
  var generics: seq[string]
  var bounds: seq[seq[Type]]
  for i, g in orig.fnGenerics:
    if i in idx: continue
    generics.add(g)
    bounds.add(if i < orig.fnGenericBounds.len: orig.fnGenericBounds[i] else: @[])
  result.fnGenerics = generics
  result.fnGenericBounds = bounds
  for i in 0 ..< result.fnParams.len:
    result.fnParams[i].typ = substType(result.fnParams[i].typ, subs)
  result.fnReturnType = substType(result.fnReturnType, subs)
  substBodyTypes(result.fnBody, subs)

proc calleeName(e: Expr): string =
  ## The fn a payload call `{...} name` names, or "".
  if e.kind == exkCall and e.callee != nil and e.callee.kind == exkVar:
    e.callee.name
  else: ""

type Generic = tuple[home: Module, homeName: string, d: Decl, idx: seq[int]]

proc genericsOf(prog: Program): Table[string, Generic] =
  ## Every interface-bounded fn in the program, by name, with the module that
  ## declares it (whose interfaces bound it).
  for (name, _, m) in prog:
    for d in m.decls:
      let idx = boundedByIface(m, d)
      if idx.len > 0: result[d.name] = (m, name, d, idx)

proc expandIfaceGenerics*(res: Resolution, prog: var Program, at: int,
                          scopes: Scopes): bool =
  ## One round over module `prog[at]`: every call to an interface-bounded fn
  ## whose bounded params are objects is pointed at its clone, made on first
  ## use. True when a call was retargeted — the program must be checked
  ## again.
  ##
  ## The clone goes in the CALLING module, wherever the generic is declared.
  ## The usual shape is a library declaring the interface and the generic fn
  ## and an app declaring the object: only the app can see both. The body is
  ## the library's, written against names the library sees, so each fn it
  ## names is respelled for the app where the app would read it differently
  ## (`rehomeNames`).
  let generic = genericsOf(prog)
  if generic.len == 0: return false
  var m = prog[at].m
  var r = Rehome(res: res, into: prog[at].name, intoM: m, scopes: scopes)
  for name in generic.keys: r.generics.incl name
  for (name, _, pm) in prog: r.exports[name] = exportedNames(pm)
  var declared = initHashSet[string]()
  for d in m.decls:
    if d != nil: declared.incl(d.name)
  var clones: seq[Decl]
  for body in m.bodies:
    for n in nodes(body):
      let name = calleeName(n)
      if name notin generic or not n.id.isSet or
         n.id notin res.ifaceInstances: continue
      let g = generic[name]
      let args = concreteArgs(prog, res.ifaceInstances[n.id], g.idx)
      if args.len == 0: continue
      let inst = instName(name, args)
      if inst notin declared:
        r.home = g.homeName
        r.homeM = g.home
        r.site = n.span
        clones.add(expandOne(g.d, g.idx, args, inst, r))
        declared.incl(inst)
      n.callee.name = inst
      result = true
  for c in clones: m.decls.add(c)
  prog[at].m = m

proc dropIfaceGenerics*(m: var Module) =
  ## Remove the generic originals once every call reaches a clone. Never
  ## emitted: a member call on a bare T has no target in any backend.
  var kept: seq[Decl]
  for d in m.decls:
    if boundedByIface(m, d).len == 0: kept.add(d)
  m.decls = kept
