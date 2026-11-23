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

  IsrAudit* = object
    roots*: seq[IsrFn]              ## declarations marked [irq]
    isrFns*: seq[IsrFn]             ## ISR-reachable closure, incl. roots
    access*: seq[IsrAccess]
    shared*: seq[string]            ## state touched by both ISR and non-ISR code
    unsafe*: seq[string]            ## shared state with at least one UNPROTECTED access
    multiIsr*: seq[string]          ## written by one [irq] root and touched by another

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

proc multiHandlerState(res: Resolution, m: Module, roots: seq[Decl],
                       access: seq[IsrAccess]): seq[string] =
  ## State written by one interrupt handler and touched by another. Whether
  ## that races depends on their NVIC priorities (equal priorities cannot
  ## preempt each other), which Tuck does not know yet — so it is reported,
  ## never gated.
  var touchedBy, writtenBy: Table[string, HashSet[NodeId]]
  for r in roots:
    var ids: HashSet[NodeId]
    for d in reachable(res, m, @[r]): ids.incl d.id
    for a in access:
      if a.fnId notin ids: continue
      touchedBy.mgetOrPut(a.state, initHashSet[NodeId]()).incl r.id
      if a.isWrite: writtenBy.mgetOrPut(a.state, initHashSet[NodeId]()).incl r.id
  for s, rs in touchedBy:
    if rs.len >= 2 and writtenBy.getOrDefault(s).len >= 1: result.add s
  result.sort

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
  if a.multiIsr.len > 0:
    result.add "\nState written by one interrupt handler and touched by another: " &
      a.multiIsr.join(", ") & "\n"
    result.add "  Safe only if both handlers run at the same priority (neither can\n"
    result.add "  preempt the other). Tuck does not know NVIC priorities yet, so this\n"
    result.add "  is reported, never rejected.\n"
  result.add "Inventory only: nothing is rejected yet. TK-EF10 fires under\n"
  result.add "--isr-check:error only for the unprotected entries above.\n"
