# compiler/typecheck_resources.nim
#
# Whole-program resource-kind validation (spec §7.4). Kinds are an OPEN SET —
# "a UDP library declares its own kind the same way a module declares its
# error enums" — so the table they live in is the program's, not a module's,
# and every rule about them is whole-program by construction.
#
# Runs as a pre-pass beside checkErrCodeCollisions and checkRegistry, for the
# same reason those do: it reads declared shapes only, never a synthesized
# type, so it has no dependency on the expression checker and nothing it finds
# depends on the order modules are checked in.
import ast, tables, sets, strutils
import ast_query
import typecheck_util
import diagnostics

type ResourceKinds* = Table[string, ResourceKindDef]
  ## Every kind the program declares, by name. The DEFINITION, not just the
  ## name: Phase 3's tables are emitted from exactly this, and a caller asking
  ## "what is this kind's cap" should not have to re-walk the declarations.

iterator markerSites*(m: Module): tuple[owner: string, kinds: seq[string],
                                        span: Span] =
  ## Every place a `[resource: k]` marker can be written: a top-level fn or
  ## task, and the fn members of anything that holds them — an `extern:` block
  ## above all, since §7.4's own example is an extern signature.
  ##
  ## Its own walk rather than `ast_query.allFns`, which yields dkFn only. That
  ## gap is recorded on `raisedEventsIn` as a KNOWN GAP and it is a real one:
  ## a marker on a task would go unchecked, which for a marker whose whole job
  ## is to be checked means the declaration silently stops meaning anything.
  ## Closing it here costs four lines; widening allFns would touch lowering.
  for d in m.decls:
    if d == nil: continue
    if d.kind == dkFn:
      if d.fnResourceKinds.len > 0: yield (d.name, d.fnResourceKinds, d.span)
    elif d.kind == dkTask:
      if d.taskResourceKinds.len > 0: yield (d.name, d.taskResourceKinds, d.span)
    else:
      for mem in d.members():
        if mem.kind == dkFn and mem.fnResourceKinds.len > 0:
          yield (mem.name, mem.fnResourceKinds, mem.span)

proc reachableFrom(start: string, edges: seq[Transition]): HashSet[string] =
  ## Transitive closure over the edge set. The same fixpoint
  ## typecheck_transitions.checkSealedReachability runs, kept here rather than
  ## shared because that one takes a Decl and reads a Type body — this has
  ## neither, only the kind's own states and edges.
  result = [start].toHashSet
  var grew = true
  while grew:
    grew = false
    for tr in edges:
      if tr.`from` in result and tr.to notin result:
        result.incl(tr.to)
        grew = true

proc terminalOf(states: seq[VariantDef], edges: seq[Transition]): seq[string] =
  ## The states with NO outgoing edge. Exactly one is the closing state.
  ##
  ## DERIVED, never declared — which is the point. A library supplies the
  ## states and the edges; anything it does not write it cannot write wrong,
  ## and "which state is final" follows from the edges with no room for the
  ## two to disagree.
  for v in states:
    var hasOut = false
    for tr in edges:
      if tr.`from` == v.name: hasOut = true; break
    if not hasOut: result.add(v.name)

proc protocolTypes*(mods: seq[tuple[name, path: string, m: Module]]):
                    Table[string, Decl] =
  ## Every sum type in the program, by name. Program-wide because a kind and
  ## the type it names live in DIFFERENT modules by design — that separation
  ## is the whole point of `states:` — so a per-module view could never
  ## resolve the reference.
  for (_, _, m) in mods:
    for d in m.decls:
      if d == nil or d.kind != dkType or d.typeBody == nil: continue
      if d.typeBody.kind == tkSum: result[d.name] = d

proc checkKindProtocol(k: ResourceKindDef, sums: Table[string, Decl]) =
  ## A kind's optional protocol: the sealed sum type named by `states:`, whose
  ## `transitions:` are the edges this resource moves along.
  ##
  ## The kind names the type rather than restating it, because the two halves
  ## have different OWNERS. A `resources:` block is the app's — it decides
  ## which tables exist and how large they are, which is a deployment question
  ## a library cannot answer. The protocol of an OS service is the library's —
  ## it knows a connection goes Open -> InTransaction -> Closed, which no app
  ## should have to restate and none should be able to restate differently.
  ##
  ## The type is an ORDINARY sum type (§4.4), not a shape a library has to get
  ## right: the compiler still generates `<Kind>Handle`, so there is no
  ## envelope here either — only the states, which are the one thing a library
  ## genuinely knows.
  if k.statesType == "": return
  if not sums.hasKey(k.statesType):
    fail(dcRsBadStatesType,
         "resource kind '" & k.name & "': `states: " & k.statesType &
         "` names no sum type in the program — a kind's protocol is a sealed " &
         "sum type with a `transitions:` block, declared by the library that " &
         "owns the resource", k.statesSpan)
  let body = sums[k.statesType].typeBody
  if body.transitions.len == 0:
    fail(dcRsBadStatesType,
         "resource kind '" & k.name & "': '" & k.statesType & "' has no " &
         "`transitions:` block, so it says nothing about how this resource " &
         "moves — a protocol without edges is the same as no protocol",
         k.statesSpan)

  let states = body.variants
  let edges = body.transitions
  var names = initHashSet[string]()
  for v in states: names.incl(v.name)
  for tr in edges:
    for endpoint in [tr.`from`, tr.to]:
      if endpoint notin names:
        fail(dcRsBadEdge,
             "resource kind '" & k.name & "': '" & endpoint &
             "' is not one of '" & k.statesType & "'s states", tr.span)

  let terminal = terminalOf(states, edges)
  if terminal.len != 1:
    let what = if terminal.len == 0:
                 "every state can still move, so the protocol never ends"
               else:
                 "these look final: " & terminal.join(", ")
    fail(dcRsNoTerminal,
         "resource kind '" & k.name & "' needs exactly one closing state — " &
         "the one with no outgoing edge, where `finish` leaves the handle — " &
         "but in '" & k.statesType & "' " & what, k.statesSpan)

  # `acquire` starts at the FIRST state, the same convention §4.4 uses for a
  # sum type's initial variant.
  let fromInitial = reachableFrom(states[0].name, edges)
  for v in states:
    if v.name notin fromInitial:
      fail(dcRsUnreachable,
           "resource kind '" & k.name & "': state '" & v.name &
           "' cannot be reached from '" & states[0].name &
           "', where `acquire` starts", v.span)

  # ...and the one that matters for a RESOURCE: you can always close.
  for v in states:
    if terminal[0] notin reachableFrom(v.name, edges):
      fail(dcRsCannotClose,
           "resource kind '" & k.name & "': '" & terminal[0] &
           "' cannot be reached from state '" & v.name &
           "' — a resource that cannot be closed from where it is, is a leak",
           v.span)

proc collectResourceKinds*(mods: seq[tuple[name, path: string, m: Module]]):
                           ResourceKinds =
  ## The program-wide kind table. A kind declared twice is refused rather than
  ## merged: a second block's `cap`, `policy` and `sweep_batch` would have
  ## nowhere to go, since all three are properties of the ONE table the kind
  ## names, and silently keeping the first block's knobs is the kind of
  ## last-writer-wins that only surfaces as a wrong cap in production.
  result = initTable[string, ResourceKindDef]()
  let sums = protocolTypes(mods)
  for (_, _, m) in mods:
    for d in m.decls:
      if d == nil or d.kind != dkResources: continue
      for k in d.resKinds:
        if result.hasKey(k.name):
          fail(dcRsDuplicateKind,
               "resource kind '" & k.name & "' is declared twice — a kind " &
               "names one registry table, so its cap, policy and sweep " &
               "batch cannot come from two blocks",
               k.span)
        checkKindProtocol(k, sums)
        result[k.name] = k

proc checkMarkedKinds*(mods: seq[tuple[name, path: string, m: Module]],
                       kinds: ResourceKinds) =
  ## §7.4: "An unknown kind in `[resource: k]` is a compile error, same as an
  ## undeclared error enum."
  for (_, _, m) in mods:
    for site in m.markerSites():
      for k in site.kinds:
        if kinds.hasKey(k): continue
        fail(dcRsUnknownKind,
             "'" & site.owner & "' is marked `[resource: " & k & "]`, but no " &
             "`resources:` block declares the kind '" & k & "'",
             site.span)

proc opKind(e: Expr): tuple[word, kind: string] =
  ## The keyword and kind name of a registry operation, or empty for anything
  ## else. One lookup so the walk below asks about the PAIR rather than
  ## special-casing each — they are one shape and share one rule.
  case e.kind
  of exkAcquire: ("acquire", e.acquireKind)
  of exkFinish: ("finish", e.finishKind)
  else: ("", "")

proc checkOpKinds(e: Expr, kinds: ResourceKinds) =
  ## Every `acquire`/`finish` in a body names a declared kind — the same rule
  ## the MARKER follows, asked separately because the marker walk reads
  ## signatures and these live in statements.
  ##
  ## Here rather than in the per-module checker because the kind SET is
  ## program-wide: a module may acquire into a kind an import declared, so no
  ## single module's view can answer it. The per-module checker asks the other
  ## halves — that `finish`'s kind matches the handle's type (TK-RS04), and
  ## that `acquire`'s operand is a raw number (TK-RS05) — both of which need a
  ## synthesized type this pass does not have.
  if e == nil: return
  let op = opKind(e)
  if op.word != "" and not kinds.hasKey(op.kind):
    fail(dcRsUnknownKind,
         "`" & op.word & "` names the kind '" & op.kind & "', but no " &
         "`resources:` block declares it",
         e.span)
  for c in e.children: checkOpKinds(c, kinds)

proc checkOpSites*(mods: seq[tuple[name, path: string, m: Module]],
                   kinds: ResourceKinds) =
  for (_, _, m) in mods:
    for d in m.decls:
      if d == nil: continue
      for ex in d.ownExprs(): checkOpKinds(ex, kinds)
      for mem in d.childDecls():
        if mem == nil: continue
        for ex in mem.ownExprs(): checkOpKinds(ex, kinds)

proc checkResources*(mods: seq[tuple[name, path: string, m: Module]]):
                     ResourceKinds {.discardable.} =
  ## spec §7.4, the declaration side. Returns the kind table so the stages
  ## that emit from it do not collect it a second time.
  result = collectResourceKinds(mods)
  checkMarkedKinds(mods, result)
  checkOpSites(mods, result)
