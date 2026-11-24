## isr_access — the shared-access table behind `tuck audit --isr`.
##
## It answers, for every fn that is ISR-reachable (via `[irq]` roots and call
## edges recorded by the checker), which pieces of shared state it touches and
## where. The report is deliberately an inventory FIRST; rejecting accesses is
## a later step (TK-EF10/11), gated behind `--isr-check:error`.
##
## Identity is a DECLARATION'S NODE ID, never its name: two declarations may
## share a name, and a name-keyed lookup is exactly the class of bug the call
## edge (`ast_query.calleeDecl`) exists to prevent. A signature string is kept
## only for DISPLAY, so a developer sees `isr() [irq, irq_safe, no_alloc]`,
## not a bare word or an id.
##
## Scope: the entry module and the fns its call edges reach. A body-less
## declaration is a leaf: the inventory cannot see inside it, and says so.

import std/[tables, sets, sequtils, strutils, algorithm]
import ./ast
import ./ast_ops
import ./ast_query
import ./typecheck_util  # typeName, for signature DISPLAY only
import ./resolution

type
  IsrAccess* = object
    state*: string        ## register / pool / slab / arena / actor / registry
    isWrite*: bool
    fnId*: NodeId         ## identity of the touching declaration
    fnSig*: string        ## display only: its signature
    span*: Span
    isr*: bool            ## true: reached from an [irq] fn
    protected*: bool      ## true: the access sits inside a `critical:` block

  IsrFn* = object
    id*: NodeId
    sig*: string          ## display only

  MultiVerdict* = enum
    ## Two interrupt handlers on one piece of state (bare-metal roadmap 2.5):
    ## whether they can race follows from the priorities the application's
    ## `bind`s give them. Equal priorities cannot preempt each other.
    mvSamePriority   ## every handler at one priority: no race
    mvGuarded        ## priorities differ; every preemptible access is in critical:
    mvRace           ## priorities differ; a preemptible handler's access is not
    mvUnbound        ## a handler has no `bind`, so its priority is unknown

  IsrHandler* = object
    sig*: string          ## display only
    priority*: int        ## its bind's priority (an unset one is the reset 0); -1 unbound

  MultiIsr* = object
    state*: string
    handlers*: seq[IsrHandler]
    verdict*: MultiVerdict
    preempted*: seq[IsrAccess]   ## mvRace: the unprotected accesses that can be preempted

  IsrAudit* = object
    roots*: seq[IsrFn]              ## declarations marked [irq]
    isrFns*: seq[IsrFn]             ## ISR-reachable closure, incl. roots
    access*: seq[IsrAccess]
    shared*: seq[string]            ## state touched by both ISR and non-ISR code
    unsafe*: seq[string]            ## shared state with at least one UNPROTECTED access
    multiIsr*: seq[MultiIsr]        ## written by one [irq] root and touched by another

proc stateRefName(n: Expr): string =
  ## The shared-state name an expression node refers to, or "".
  case n.kind
  of exkVar: n.name
  of exkRegisterRef, exkActorRef, exkPoolRef, exkSlabRef, exkArenaRef,
     exkRegistryRef: n.refName
  else: ""

proc stateNamesOf(m: Module): HashSet[string] =
  for d in m.decls:
    if d != nil and d.kind in {dkRegister, dkPool, dkSlab, dkArena, dkActor,
                               dkRegistry}:
      result.incl d.name

proc signature(d: Decl): string =
  ## DISPLAY of a fn or task: the signature, not a name-keyed identity. Local
  ## to this report so it changes with the report and cannot be mistaken for
  ## a key. Any other body owner (an `on select` arm, a const) shows its name.
  if d.kind notin {dkFn, dkTask}:
    return (if d.kind == dkSelect: "on select" else: writtenName(d))
  var params: seq[string]
  for p in d.fnParams: params.add p.name & ": " & typeName(p.typ)
  result = (if d.kind == dkTask: "task " else: "") & writtenName(d) &
    (if params.len == 0: "()" else: "({" & params.join(", ") & "})")
  if d.fnReturnType != nil: result.add " -> " & typeName(d.fnReturnType)
  if d.fnEffects.len > 0:
    var names: seq[string]
    for mk in d.fnEffects: names.add effectName(mk)
    result.add " [" & names.join(", ") & "]"

proc isrRoots(m: Module): seq[Decl] =
  for d in m.decls:
    if d != nil and d.kind == dkFn and emIrq in d.fnEffects:
      result.add d

proc reachable*(res: Resolution, m: Module, roots: seq[Decl]): seq[Decl] =
  ## Fixpoint over recorded call edges. Declarations are deduplicated by id;
  ## no function is ever looked up by name. Unknown callees are leaves: they
  ## are NOT assumed safe, but there is no body to walk.
  var seenIds: HashSet[NodeId]
  var work = roots
  while work.len > 0:
    let d = work.pop()
    if d == nil or d.id in seenIds: continue
    seenIds.incl d.id
    result.add d
    if d.fnBody == nil: continue
    for n in d.fnBody.nodes:
      if n.kind != exkCall: continue
      let callee = res.calleeDecl(m, n)
      if callee == nil or callee.kind != dkFn: continue
      if callee.id notin seenIds: work.add callee
  result.sort(proc (a, b: Decl): int = cmp(uint32(a.id), uint32(b.id)))

proc collectAccesses(e: Expr, prot: bool, states: HashSet[string],
                     fnId: NodeId, sig: string, result: var seq[IsrAccess]) =
  ## Walk one expression. A `critical:` block flips `prot` for its whole
  ## subtree; an assignment target is counted as a write and not walked again
  ## as a read. Everything else keeps the current protection state.
  if e == nil: return
  case e.kind
  of exkCritical:
    collectAccesses(e.criticalBody, true, states, fnId, sig, result)
    return
  of exkAssign:
    if e.target != nil:
      for t in e.target.nodes:
        let s = stateRefName(t)
        if s != "" and s in states:
          result.add IsrAccess(state: s, isWrite: true, fnId: fnId, fnSig: sig,
                               span: t.span, protected: prot)
    collectAccesses(e.assignVal, prot, states, fnId, sig, result)
    return
  else: discard
  let s = stateRefName(e)
  if s != "" and s in states:
    result.add IsrAccess(state: s, isWrite: false, fnId: fnId, fnSig: sig,
                         span: e.span, protected: prot)
  for ch in e.children:
    collectAccesses(ch, prot, states, fnId, sig, result)

proc accessesOf(m: Module, d: Decl, states: HashSet[string]): seq[IsrAccess] =
  ## Every access to shared state in every expression `d` owns; `d` is the
  ## declaration itself, never a name lookup. `ownExprs` reaches task bodies,
  ## `on select` arms and initialisers: the first version walked `dkFn`
  ## bodies only, so a TASK racing an ISR — the normal shape of firmware —
  ## was reported as "no shared state".
  if d == nil: return
  for body in d.ownExprs:
    if body != nil:
      collectAccesses(body, false, states, d.id, signature(d), result)

proc boundPriorities(m: Module): Table[string, int] =
  ## The priority each of this module's bound fns runs at: its bind's, or the
  ## NVIC reset value 0 when the bind gives none.
  for d in m.decls:
    if d != nil and d.kind == dkBind and d.bindModule == "":
      result[d.bindFn] = max(d.bindPriority, 0)

proc verdictOf(st: var MultiIsr, roots: seq[(Decl, HashSet[NodeId])],
               access: seq[IsrAccess]) =
  ## The most urgent level cannot be preempted by another handler of this
  ## state; every handler below it can, so its accesses must be protected.
  if st.handlers.anyIt(it.priority < 0): st.verdict = mvUnbound; return
  let top = st.handlers.mapIt(it.priority).min
  if st.handlers.allIt(it.priority == top): st.verdict = mvSamePriority; return
  for i, (_, ids) in roots:
    if st.handlers[i].priority == top: continue
    for a in access:
      if a.state == st.state and a.fnId in ids and not a.protected:
        st.preempted.add a
  st.verdict = if st.preempted.len > 0: mvRace else: mvGuarded

proc multiHandlerState(res: Resolution, m: Module, roots: seq[Decl],
                       access: seq[IsrAccess]): seq[MultiIsr] =
  ## State written by one interrupt handler and touched by another, judged
  ## against the priorities the module's `bind`s give the handlers.
  let prio = boundPriorities(m)
  var reach: seq[(Decl, HashSet[NodeId])]
  for r in roots:
    var ids: HashSet[NodeId]
    for d in reachable(res, m, @[r]): ids.incl d.id
    reach.add (r, ids)
  var states: HashSet[string]
  for a in access: states.incl a.state
  for s in states.toSeq.sorted:
    var touching: seq[(Decl, HashSet[NodeId])]
    var writers = 0
    for (r, ids) in reach:
      let mine = access.filterIt(it.state == s and it.fnId in ids)
      if mine.len == 0: continue
      touching.add (r, ids)
      if mine.anyIt(it.isWrite): inc writers
    if touching.len < 2 or writers == 0: continue
    var st = MultiIsr(state: s)
    for (r, _) in touching:
      st.handlers.add IsrHandler(sig: signature(r),
                                 priority: prio.getOrDefault(writtenName(r), -1))
    st.verdictOf(touching, access)
    result.add st

proc auditShared*(res: Resolution, m: Module): IsrAudit =
  let states = stateNamesOf(m)
  let rootDecls = isrRoots(m)
  let isrDecls = reachable(res, m, rootDecls)
  var isrIds: HashSet[NodeId]
  for d in isrDecls: isrIds.incl d.id
  for d in rootDecls:
    result.roots.add IsrFn(id: d.id, sig: signature(d))
  result.roots.sort(proc (a, b: IsrFn): int = cmp(uint32(a.id), uint32(b.id)))
  for d in isrDecls:
    result.isrFns.add IsrFn(id: d.id, sig: signature(d))

  var isrState: HashSet[string]
  var nonIsrState: HashSet[string]
  for d in m.allDecls:
    if d == nil: continue
    let isr = d.id in isrIds
    for a in accessesOf(m, d, states):
      result.access.add IsrAccess(state: a.state, isWrite: a.isWrite,
        fnId: a.fnId, fnSig: a.fnSig, span: a.span, isr: isr,
        protected: a.protected)
      if isr: isrState.incl a.state
      else: nonIsrState.incl a.state
  result.shared = (isrState * nonIsrState).toSeq
  result.shared.sort
  for s in result.shared:
    if result.access.anyIt(it.state == s and not it.protected):
      result.unsafe.add s

  result.multiIsr = multiHandlerState(res, m, rootDecls, result.access)

proc render*(a: IsrAudit, path: string): string =
  ## Human-readable first. The JSON/SARIF emitters (vision §9) are added by
  ## the shared reporter layer; the text is what a developer reads first.
  ## Every line is written for someone seeing the problem for the first time:
  ## what was found, why it matters, and what to do about it.
  proc fns(fs: seq[IsrFn]): string =
    if fs.len == 0: "(none)" else: fs.mapIt(it.sig).join(", ")
  result = "ISR roots: " & fns(a.roots) & "\n"
  result.add "ISR-reachable fns: " & fns(a.isrFns) & "\n"
  if a.shared.len == 0:
    result.add "Shared ISR state: none. No ISR-visible state is also touched by normal code.\n"
  else:
    result.add "Shared ISR state — touched by an interrupt AND by normal code:\n"
    result.add "  An interrupt can preempt the other access at any instruction. A read\n"
    result.add "  can see a half-updated value, and two writes can overwrite each other.\n"
    for s in a.shared:
      result.add "\n  " & s & "\n"
      for x in a.access.filterIt(it.state == s):
        let ctx = alignLeft(if x.isr: "ISR" else: "normal code", 12)
        let op = if x.isWrite: "writes" else: "reads "
        let guard = if x.protected: " [protected: critical:]" else: " [UNPROTECTED]"
        result.add "    " & ctx & ": " & x.fnSig & " " & op & " at " & path &
          ":" & $x.span.line & ":" & $x.span.col & guard & "\n"
    result.add "\n  Fix: put every access inside a `critical:` block, or make one\n"
    result.add "  context the sole writer (an ISR signals a task that writes it).\n"
  if a.unsafe.len > 0:
    result.add "\nUnprotected shared state: " & a.unsafe.join(", ") & "\n"
  elif a.shared.len > 0:
    result.add "\nAll shared accesses are inside critical: blocks.\n"
  for st in a.multiIsr:
    result.add "\nState written by one interrupt handler and touched by another: " &
      st.state & "\n"
    for h in st.handlers:
      result.add "    " & h.sig & (if h.priority < 0: "  (not bound)"
                                    else: "  priority " & $h.priority) & "\n"
    case st.verdict
    of mvSamePriority:
      result.add "  Safe: every handler runs at one priority, so none preempts another.\n"
    of mvGuarded:
      result.add "  Safe: the priorities differ, and every access a more urgent handler\n"
      result.add "  can preempt is inside a critical: block.\n"
    of mvRace:
      result.add "  RACE: the priorities differ, so a more urgent handler can preempt\n"
      result.add "  these accesses halfway (TK-EF13 under --isr-check:error):\n"
      for x in st.preempted:
        result.add "    " & x.fnSig & (if x.isWrite: " writes" else: " reads") &
          " at " & path & ":" & $x.span.line & ":" & $x.span.col & "\n"
      result.add "  Fix: wrap them in `critical:`, or bind the handlers at one priority.\n"
    of mvUnbound:
      result.add "  Unknown: a handler is not bound, so its priority is not known.\n"
      result.add "  Bind every handler (`bind LINE -> fn [priority: N]`) to decide it.\n"
  result.add "Inventory only: nothing is rejected yet. Under --isr-check:error,\n"
  result.add "TK-EF10 fires for the unprotected entries above and TK-EF13 for a RACE.\n"
