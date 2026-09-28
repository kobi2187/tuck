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

proc boundedByIface(m: Module, d: Decl): seq[int] =
  ## Indexes of `d`'s type params bounded by an interface this module
  ## declares.
  if d == nil or d.kind != dkFn: return
  for i in 0 ..< min(d.fnGenerics.len, d.fnGenericBounds.len):
    for b in d.fnGenericBounds[i]:
      if m.findDecl(dkInterface, groupNameOf(b)) != nil:
        result.add(i)
        break

proc concreteArgs(m: Module, args: seq[Type], idx: seq[int]): seq[Type] =
  ## The bounded params' types at one call, or empty when any is not a
  ## declared object — a type param of an enclosing generic body, which a
  ## later round sees concrete.
  for i in idx:
    if i >= args.len: return @[]
    let t = args[i]
    if t == nil or t.kind != tkNamed or m.findDecl(dkObject, t.name) == nil:
      return @[]
    result.add(t)

proc substBodyTypes(e: Expr, subs: Table[string, Type]) =
  ## Type annotations written inside the body (`let x: T = ...`).
  if e == nil: return
  if e.kind == exkAssign and e.declType != nil:
    e.declType = substType(e.declType, subs)
  for c in e.children: substBodyTypes(c, subs)

proc expandOne(orig: Decl, idx: seq[int], args: seq[Type], name: string): Decl =
  ## One instantiation: a deep copy, ids cleared (typecheck's caller numbers
  ## them), the bounded params replaced and dropped from the generics. Any
  ## other type param stays: the clone is still generic in it.
  var subs = initTable[string, Type]()
  for k, i in idx: subs[orig.fnGenerics[i]] = args[k]
  result = deepCopy(orig)
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

proc expandIfaceGenerics*(res: Resolution, m: var Module): bool =
  ## One round over module `m`: every call to an interface-bounded fn whose
  ## bounded params are objects here is pointed at its clone, made on first
  ## use. True when a call was retargeted — the program must be checked
  ## again.
  var generic = initTable[string, Decl]()
  for d in m.decls:
    if boundedByIface(m, d).len > 0: generic[d.name] = d
  if generic.len == 0: return false
  var declared = initHashSet[string]()
  for d in m.decls:
    if d != nil: declared.incl(d.name)
  var clones: seq[Decl]
  for body in m.bodies:
    for n in nodes(body):
      let name = calleeName(n)
      if name notin generic or not n.id.isSet or
         n.id notin res.ifaceInstances: continue
      let d = generic[name]
      let idx = boundedByIface(m, d)
      let args = concreteArgs(m, res.ifaceInstances[n.id], idx)
      if args.len == 0: continue
      let inst = instName(name, args)
      if inst notin declared:
        clones.add(expandOne(d, idx, args, inst))
        declared.incl(inst)
      n.callee.name = inst
      result = true
  for c in clones: m.decls.add(c)

proc dropIfaceGenerics*(m: var Module) =
  ## Remove the generic originals once every call reaches a clone. Never
  ## emitted: a member call on a bare T has no target in any backend.
  var kept: seq[Decl]
  for d in m.decls:
    if boundedByIface(m, d).len == 0: kept.add(d)
  m.decls = kept
