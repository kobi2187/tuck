# compiler/slab_owner.nim
#
# WHO MAY TOUCH A SLAB (thoughts/shared/plans/2026-09-29-slab-proposal.md §7,
# ruled Q6).
#
# A slab is plain shared memory with no lock, and under `--actors:thread` an
# actor runs on a thread of its own. So a slab belongs to where it is
# declared — at top level to MAIN'S THREAD (`main`, the fns it calls, tasks,
# top-level statements), inside an actor to THAT ACTOR (rewrite.hoistSlabs
# lifts it to the module and records the owner) — and two rules follow:
#
#   TK-AC08  an owner reaches another owner's slab, through any chain of
#            calls: an actor touching a top-level slab, main touching an
#            actor's, one actor another's.
#   TK-AC09  a reference crosses an actor boundary: in a handler's payload
#            (directly, or inside a record, a Seq, a `?`), or in an actor's
#            field when it points into a slab that actor does not own.
#
# WHAT "TOUCH" MEANS. An operation on the slab (`Nodes.new`, `.free`, `.get`,
# ...) or a field read or written through one of its references (`r.data`).
# Holding or passing a reference touches nothing: it is 8 bytes of value.
# Both are stamped by the checker — the operation as the field's resolved
# exkSlabOp (asSlabOp), the access in Resolution.slabDerefs (asSlabDeref) —
# so this pass reads answers rather than re-deriving them.
#
# WHAT "REACHES" MEANS. The call graph over every module of the program:
# a call names its callee (the checker's `declFor`, an actor's own member, a
# member by the receiver's type, a top-level fn by name, `mod::fn`), and a fn
# NAMED as a value (`:touch`, a callback handed on) counts as called, so a
# slab reached through a callback is not missed. Each owner's entries — an actor's
# handlers, members and select arms; main, every task and the entry module's
# top-level statements — are walked breadth-first, and the first slab of
# another owner ends the walk with the chain that reached it.
#
# ORDERING. After typecheck (it reads the semantic layer's stamps), over the
# whole program at once, before mangling (names as written). checkOrDie.
import tables, sets, strutils
import ast, ast_ops, ast_query
import resolution
import diagnostics
import semantics    # SemanticError
from modules import LoadedModule
from typecheck_util import typeName

type
  Touch = object
    ## One place a body touches a slab — or an arena's slabs all at once
    ## (`Frame.reset`).
    slab: Decl            ## a dkSlab, or a dkArena
    site: Expr
    what: string          ## `Nodes.new`, `.data through a NodesRef`

  Edge = object
    ## One callee a body reaches, and the node that reaches it.
    callee: Decl
    site: Expr

  Facts = object
    touches: seq[Touch]
    edges: seq[Edge]

  Scan = object
    mods: seq[LoadedModule]
    pathOf: Table[int, string]       ## decl address -> its module's path
    moduleOf: Table[int, int]        ## decl address -> index into mods
    actorOf: Table[int, Decl]        ## a decl inside an actor -> the actor
    facts: Table[int, Facts]
    fnValues: seq[Decl]              ## every fn the program names as a VALUE
                                     ## (`:touch`): what a call through a
                                     ## slot may run (audit C3)
    predicates: Table[string, seq[Decl]]  ## actor -> the fns handed to its
                                     ## `waitUntil`, which run on its thread

proc key(d: Decl): int = cast[int](d)

proc ownerOf(d: Decl): string =
  ## Whose a slab or an arena is: an actor's name, "" for main's thread.
  if d.kind == dkArena: d.arenaOwner else: d.slabOwner

proc kindWord(d: Decl): string =
  if d.kind == dkArena: "arena" elif d.slabArena != "": "arena" else: "slab"

proc shownName(d: Decl): string =
  ## A slab by its name; an arena's slab by its arena's.
  if d.kind == dkSlab and d.slabArena != "": d.slabArena else: d.name

proc refWord(d: Decl): string =
  if d.kind == dkArena: arenaRefName(d.name) & "[T]"
  elif d.slabArena != "": arenaRefName(d.slabArena) & "[" & typeName(d.slabElem) & "]"
  else: slabRefName(d.name)

proc ownerWord(owner: string): string =
  if owner == "": "main's thread" else: "actor '" & owner & "'"

proc entryWord(d: Decl): string =
  ## How a chain names one of its steps.
  case d.kind
  of dkFn:
    if d.isOnHandler: "on " & d.name else: d.name
  of dkTask: "task " & d.name
  of dkSelect: "on select"
  of dkExpr: "a top-level statement"
  of dkType, dkObject, dkRegistry, dkPool, dkSlab, dkArena, dkMixin, dkExtern,
     dkPending, dkActor, dkConst, dkRegister, dkBuffer, dkBind, dkStaticAssert, dkErrors,
     dkResources, dkImport, dkFnSig, dkSatisfies, dkWhen, dkPublic,
     dkInterface, dkGroup:
    d.name

# --- indexing the program ------------------------------------------------------

proc index(s: var Scan) =
  ## Which module and actor every declaration sits in.
  for i, lm in s.mods:
    for d in lm.m.allDecls:
      s.pathOf[key(d)] = lm.path
      s.moduleOf[key(d)] = i
    for a in lm.m.decls(dkActor):
      if isImportedCopy(a): continue   # its origin is the actor
      for h in a.handlers:
        if h != nil: s.actorOf[key(h)] = a

proc topLevelFn(m: Module, name: string): Decl =
  ## A top-level fn or task `name` declares, or nil.
  for d in m.decls:
    if d != nil and d.kind in {dkFn, dkTask} and d.name == name: return d
  nil

proc fnNamed(s: Scan, home: int, name: string): Decl =
  ## A top-level fn or task by name: the module's own first, then the rest
  ## of the program's (an imported name is injected unqualified).
  result = topLevelFn(s.mods[home].m, name)
  if result != nil: return
  for i, lm in s.mods:
    if i == home: continue
    result = topLevelFn(lm.m, name)
    if result != nil: return

proc qualifiedFn(s: Scan, home: int, q: Expr): Decl =
  ## `mod::fn`, or `:fn` — a fn named as a value (a callback), which parses
  ## as a qualified name with no module.
  if q.modulePath.len == 0: return s.fnNamed(home, q.qualName)
  for lm in s.mods:
    if lm.name == q.modulePath[^1]: return topLevelFn(lm.m, q.qualName)
  nil

proc memberOfActor(a: Decl, name: string): Decl =
  ## An actor's own member `fn` (not a handler) by name.
  if a == nil: return nil
  for h in a.handlers:
    if h != nil and h.kind == dkFn and not h.isOnHandler and h.name == name:
      return h
  nil

proc calleeOf(s: Scan, home: int, actor: Decl, call: Expr): Decl =
  ## The declaration a call reaches, or nil for a builtin, an extern, a
  ## local fn value or anything else with no body here.
  # An actor's own member first: inside the actor a bare name means it.
  if semLayer.declFor(call) == nil and call.callee != nil and
     call.callee.kind == exkVar:
    result = memberOfActor(actor, call.callee.name)
    if result != nil: return
  result = calleeDecl(semLayer, s.mods[home].m, call)
  if result != nil and result.fnBody != nil: return
  # A member of an IMPORTED object: the importer holds its signature only,
  # and this pass reads bodies, so take it from the module that declares it.
  for lm in s.mods:
    let member = memberCallDecl(semLayer, lm.m, call)
    if member != nil and member.fnBody != nil: return member

proc isFnValue(n: Expr): bool =
  ## A name whose value is a fn — a callback being handed on.
  let t = semLayer.typeFor(n)
  t != nil and t.kind == tkFunc

proc slabNamed(name: string): Decl =
  semLayer.slabNames.getOrDefault(name, nil)

proc touchesAt(n: Expr, f: var Facts) =
  ## A slab operation (the field the checker resolved to an exkSlabOp), an
  ## arena's reset, or a field through a reference (Resolution.slabDerefs)
  ## at `n`.
  let stamped = semLayer.call(n)
  if n.kind == exkField and stamped != nil and stamped.kind == exkSlabOp:
    let slab = slabNamed(stamped.slabRef.refName)
    if slab != nil:
      f.touches.add Touch(slab: slab, site: n,
                          what: shownName(slab) & "." & n.fieldName)
  if n.kind == exkField and stamped != nil and stamped.kind == exkArenaReset:
    let arena = semLayer.arenaNames.getOrDefault(n.receiver.refName, nil)
    if arena != nil:
      f.touches.add Touch(slab: arena, site: n, what: arena.name & ".reset")
  let deref = semLayer.slabDerefOf(n)
  if deref != nil:
    f.touches.add Touch(slab: deref, site: n, what: "." & n.fieldName &
                        " through a " & refWord(deref))

proc reachedAt(s: Scan, home: int, actor: Decl, n: Expr): Decl =
  ## The declaration `n` calls or names as a value, or nil.
  let stamped = semLayer.call(n)
  if n.kind == exkCall: return s.calleeOf(home, actor, n)
  if n.kind == exkField and stamped != nil and stamped.kind == exkCall:
    return s.calleeOf(home, actor, stamped)
  if n.kind == exkQualified: return s.qualifiedFn(home, n)
  if n.kind == exkVar and isFnValue(n): return s.fnNamed(home, n.name)
  nil

proc fnValueAt(s: Scan, home: int, n: Expr): Decl =
  ## The fn `n` names as a value (`:touch`, or a fn-valued name), or nil.
  if n.kind == exkQualified: return s.qualifiedFn(home, n)
  if n.kind == exkVar and isFnValue(n): return s.fnNamed(home, n.name)
  nil

proc predicateOf(s: Scan, home: int, n: Expr): (string, Decl) =
  ## `A.waitUntil {pred: :p}`: the actor and the fn handed to it.
  if n.kind != exkField or n.fieldName != "waitUntil" or n.receiver == nil or
     n.receiver.kind != exkActorRef or n.dotArg == nil or
     n.dotArg.kind != exkStruct: return ("", nil)
  for f in n.dotArg.fields:
    if f.value == nil: continue
    let p = s.fnValueAt(home, f.value)
    if p != nil: return (n.receiver.refName, p)
  ("", nil)

proc indexIndirect(s: var Scan) =
  ## The fns a slot call may run, and the predicates each actor runs. Taken
  ## before any walk: an edge to them is added wherever they may be called.
  for i, lm in s.mods:
    for d in lm.m.allDecls:
      if d == nil or isImportedCopy(d): continue
      for body in d.ownExprs:
        if body == nil: continue
        for n in nodes(body):
          let v = s.fnValueAt(i, n)
          if v != nil and v.fnBody != nil and v notin s.fnValues: s.fnValues.add v
          let (actor, p) = s.predicateOf(i, n)
          if actor != "" and p.fnBody != nil:
            s.predicates.mgetOrPut(actor, @[]).add p

proc membersNamed(s: Scan, name: string): seq[Decl] =
  ## Every object member with a body called `name`: what an interface
  ## dispatch of `name` may run.
  for lm in s.mods:
    for o in lm.m.decls(dkObject):
      if isImportedCopy(o): continue
      for mem in o.objMembers:
        if mem != nil and mem.kind == dkFn and mem.fnBody != nil and
           mem.name == name: result.add mem

proc indirectEdges(s: Scan, home: int, n: Expr): seq[Decl] =
  ## What a call with no single callee may run. A call through a slot: any fn
  ## the program names as a value. An interface dispatch: every member of its
  ## name. Neither had an edge, so a slab reached through a callback or a
  ## dispatch was invisible to this pass (audit C3).
  let c = if n.kind == exkCall: n else: semLayer.call(n)
  if c == nil or c.kind != exkCall: return
  if semLayer.isSlotCall(c) and raisedEvent(c) == "": return s.fnValues
  if ifaceMemberDecl(semLayer, s.mods[home].m, c) != nil and
     c.callee != nil and c.callee.kind == exkVar:
    return s.membersNamed(c.callee.name)

proc factsOf(s: var Scan, d: Decl): Facts =
  ## What one declaration's own bodies touch and call. Memoised.
  if key(d) in s.facts: return s.facts[key(d)]
  let home = s.moduleOf.getOrDefault(key(d), s.mods.high)
  let actor = s.actorOf.getOrDefault(key(d), nil)
  var f: Facts
  for body in d.ownExprs:
    if body == nil: continue
    for n in nodes(body):
      touchesAt(n, f)
      let c = s.reachedAt(home, actor, n)
      if c != nil and c != d: f.edges.add Edge(callee: c, site: n)
      for other in s.indirectEdges(home, n):
        if other != d: f.edges.add Edge(callee: other, site: n)
  s.facts[key(d)] = f
  f

# --- TK-AC08: an owner reaching another owner's slab -----------------------------

proc failAt(s: Scan, d: Decl, dc: DiagCode, msg: string, span: Span) {.noreturn.} =
  ## A diagnostic in the module that holds `d`, its path on the message — the
  ## violation may sit in a module other than the one being checked.
  let path = s.pathOf.getOrDefault(key(d), "")
  let err = newException(SemanticError,
    path & ":" & $span.line & ":" & $span.col & ": " & withCode(dc, msg))
  err.line = span.line
  err.col = span.col
  raise err

proc chainTo(parent: Table[int, Decl], entry, d: Decl): seq[string] =
  ## The steps from `entry` to `d`, by the breadth-first parents.
  var cur = d
  while cur != nil:
    result.insert(entryWord(cur), 0)
    if cur == entry: break
    cur = parent.getOrDefault(key(cur), nil)

proc walkEntry(s: var Scan, entry: Decl, owner: string) =
  ## Every slab `entry` reaches must be `owner`'s.
  var parent: Table[int, Decl]
  var seen = initHashSet[int]()
  var queue = @[entry]
  seen.incl key(entry)
  var i = 0
  while i < queue.len:
    let d = queue[i]
    inc i
    let f = s.factsOf(d)
    for t in f.touches:
      let theirs = ownerOf(t.slab)
      if theirs == owner: continue
      let steps = chainTo(parent, entry, d) & @[t.what]
      s.failAt(d, dcAcSlabOwner,
        ownerWord(owner) & " reaches " & kindWord(t.slab) & " '" &
        shownName(t.slab) & "', which belongs to " & ownerWord(theirs) & ": " &
        steps.join(" → ") & ". A slab is touched only by its owner — " &
        (if theirs == "":
           "declare it inside the actor, or send the actor the values it needs"
         else:
           "ask actor '" & theirs & "' with a message instead"),
        t.site.span)
    for e in f.edges:
      if key(e.callee) in seen: continue
      seen.incl key(e.callee)
      parent[key(e.callee)] = d
      queue.add e.callee

proc walkActor(s: var Scan, a: Decl) =
  ## An actor's entries: its handlers, members and select arms, and every
  ## `waitUntil` predicate handed to it, which runs on its thread after each
  ## message, whoever handed it over (audit C3).
  for h in a.handlers:
    if h != nil and h.kind in {dkFn, dkSelect}: s.walkEntry(h, a.name)
  for p in s.predicates.getOrDefault(a.name): s.walkEntry(p, a.name)

proc checkReach(s: var Scan) =
  ## Each owner's entries, in source order.
  for i, lm in s.mods:
    for a in lm.m.decls(dkActor):
      if not isImportedCopy(a): s.walkActor(a)
    for d in lm.m.decls:
      if d == nil: continue
      if d.kind == dkTask or (d.kind == dkFn and d.name == "main") or
         (d.kind == dkExpr and i == s.mods.high):
        s.walkEntry(d, "")

# --- TK-AC09: a reference crossing an actor boundary -------------------------------

proc typeNamed(s: Scan, name: string): seq[FieldDef] =
  ## The fields a named record, object or sum's variants hold — what a
  ## reference could hide inside.
  for lm in s.mods:
    for d in lm.m.decls:
      if d == nil or d.name != name: continue
      if d.kind == dkObject: return d.objFields
      if d.kind == dkType and d.typeBody != nil:
        case d.typeBody.kind
        of tkRecord: return d.typeBody.fields
        of tkSum:
          for v in d.typeBody.variants: result.add v.fields
          return
        of tkNamed, tkTuple, tkApp, tkFunc, tkUnion, tkEffect, tkRename:
          return @[FieldDef(name: "", typ: d.typeBody)]

proc fieldTypes(fields: seq[FieldDef]): seq[Type] =
  for f in fields: result.add f.typ

proc variantTypes(variants: seq[VariantDef]): seq[Type] =
  for v in variants: result.add fieldTypes(v.fields)

proc innerTypes(t: Type): seq[Type] =
  ## The types a value of `t` is built from, one level down.
  case t.kind
  of tkApp: @[t.base] & t.args
  of tkTuple: t.elems
  of tkRecord: fieldTypes(t.fields)
  of tkSum: variantTypes(t.variants)
  of tkUnion: t.members
  of tkEffect: @[t.inner]
  of tkRename: @[t.underlying]
  of tkNamed, tkFunc: @[]       # a name is followed by slabsIn; a fn value
                                # carries code, not cells

proc slabsIn(s: Scan, t: Type, seen: var HashSet[string],
             found: var seq[Decl]) =
  ## Every slab whose references a value of type `t` can hold.
  if t == nil: return
  if t.kind == tkNamed:
    let slab = slabOfRefType(t.name)
    if slab != nil:
      if slab notin found: found.add slab
    elif t.name notin seen:
      seen.incl t.name
      for f in s.typeNamed(t.name): s.slabsIn(f.typ, seen, found)
    return
  let arena = arenaOfRefType(t)          # `FrameRef[T]`
  if arena != nil:
    if arena notin found: found.add arena
    return
  for inner in innerTypes(t): s.slabsIn(inner, seen, found)

proc slabsIn(s: Scan, t: Type): seq[Decl] =
  var seen = initHashSet[string]()
  s.slabsIn(t, seen, result)

proc checkPayloads(s: Scan, a: Decl) =
  ## No handler of `a` takes a reference, however deep in its payload.
  for h in a.handlers:
    if h == nil or h.kind != dkFn or not h.isOnHandler: continue
    for p in h.fnParams:
      let slabs = s.slabsIn(p.typ)
      if slabs.len == 0: continue
      let direct = p.typ != nil and
                   ((p.typ.kind == tkNamed and slabOfRefType(p.typ.name) != nil) or
                    arenaOfRefType(p.typ) != nil)
      let holds = if direct: "a " & typeName(p.typ) & " in '" & p.name & "'"
                  else: "'" & p.name & "', which can hold a " & refWord(slabs[0])
      s.failAt(h, dcAcRefCrossing,
        "actor '" & a.name & "''s handler '" & h.name & "' takes " &
        holds & " — a reference cannot be sent: it names a cell in " &
        kindWord(slabs[0]) & " '" & shownName(slabs[0]) & "', which only " &
        ownerWord(ownerOf(slabs[0])) & " touches. Send the value (`" &
        shownName(slabs[0]) & ".get {r}`) instead",
        p.span)

proc checkFields(s: Scan, a: Decl) =
  ## `a`'s fields hold references into its own slabs only.
  for f in a.actorFields:
    for slab in s.slabsIn(f.typ):
      if ownerOf(slab) == a.name: continue
      s.failAt(a, dcAcRefCrossing,
        "actor '" & a.name & "''s field '" & f.name & "' holds a " &
        refWord(slab) & ", a reference into " & kindWord(slab) & " '" &
        shownName(slab) & "', which belongs to " & ownerWord(ownerOf(slab)) &
        ". An actor's fields may hold references into its own slabs only — " &
        "declare the " & kindWord(slab) & " inside the actor",
        f.span)

proc checkCrossing(s: Scan) =
  ## Handler payloads and actor fields, every actor of the program.
  for lm in s.mods:
    for a in lm.m.decls(dkActor):
      if isImportedCopy(a): continue
      s.checkPayloads(a)
      s.checkFields(a)

proc checkSlabOwnership*(mods: seq[LoadedModule]) =
  ## The whole program's slabs against their owners. Raises SemanticError
  ## (TK-AC08, TK-AC09) at the first violation.
  if semLayer.slabNames.len == 0 and semLayer.arenaNames.len == 0: return
  var s = Scan(mods: mods)
  s.index()
  s.indexIndirect()
  s.checkCrossing()
  s.checkReach()
