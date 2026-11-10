# compiler/frames.nim
#
# Phase 1 of the stackless transform (#216, docs/stackless-concurrency.md):
# which fns become FRAMES, and where each one can pause. Nothing here
# rewrites the tree. `tuck frames f.tuck` prints the answer, and
# tests/suites/frames.nim pins it, so that the splitting in Phase 2 starts
# from a colouring that has already been checked.
#
# THE RULES, which keep today's stackful semantics:
#   * Roots are the bodies the scheduler runs: tasks, actor `on` handlers
#     and `on select` arms. A root is always a frame.
#   * A PAUSE SITE is somewhere the stackful runtime can switch away:
#       - in a TASK body, every [io] call: codegen emits
#         `(tuckYield(); call)` there today;
#       - anywhere, a call to an [io] extern, which may park inside the
#         runtime (fd I/O, sleep, the offloaded blocking calls);
#       - a call to a fn that itself pauses (a frame call);
#       - `on select` inside a body, a send into an actor whose `on_full` is
#         `wait`, a binding that awaits a task, and `Actor.waitUntil` /
#         `.alive` / `.pingUs`.
#   * A fn is a FRAME when a root reaches it through call edges and it has
#     a pause site. A reachable fn with none stays native, even an [io] one:
#     it runs to completion inside whichever stage calls it.
#
# Call edges come from `ast_query.calleeDecl`, never from a callee's name.

import std/[tables, sets, strutils, algorithm, hashes]
import ast, ast_ops, ast_query, resolution, modules
from codegen_common import actorOnFull, OnFull

type
  PauseKind* = enum
    pkYieldCall   ## [io] call in a task body: yield, then call
    pkExtern      ## [io] extern call: may park inside the runtime
    pkFrameCall   ## call to a fn that pauses
    pkSelect      ## `on select` in a body
    pkSend        ## send into an `on_full: wait` actor
    pkAwait       ## a binding that awaits a task
    pkActorWait   ## Actor.waitUntil / .alive / .pingUs
    pkOpaque      ## an [io] call resolved only at run time (a group
                  ## requirement, a fnsig value): it may wait, unseen
    pkHelperCall  ## a call to a GENERIC fn that may wait: no frame (its
                  ## frame type would be generic), so it runs on a helper

  PauseSite* = object
    kind*: PauseKind
    line*, col*: int
    what*: string           ## the callee, actor or task named

  FrameRole* = enum
    frTask = "task"
    frHandler = "handler"
    frArm = "select arm"
    frFn = "fn"

  BodyRef = object
    ## One body the analysis walks: a fn or task decl, or a select arm.
    decl: Decl              ## nil for a select arm
    actor: Decl             ## the actor a handler, arm or member belongs to
    body: Expr
    module: string          ## the declaring module, as `import` names it
    m: Module
    label: string
    role: FrameRole
    line: int

  Frame* = object
    label*: string
    module*: string
    line*: int
    role*: FrameRole
    pauses*: seq[PauseSite]

  FramePlan* = object
    frames*: seq[Frame]      ## in module order, then source order
    nativeIo*: seq[string]   ## [io] fns a root reaches that never pause
    nativeRoots*: seq[string] ## handlers and select arms that never pause:
                              ## the actor loop calls them, no frame needed
    helpers*: seq[string]    ## their labels, for the report
    frameActors*: seq[string]  ## their names, for the report
    sccOf*: Table[NodeId, int] ## each body decl's call-graph component: a
                               ## frame call inside one keeps the heap (#219)
    recursiveIds*: HashSet[NodeId] ## the decls on a call cycle
    heapReasons*: seq[string] ## why a frame (or a stack) would still be
                              ## allocated: what --frames:static refuses
    pureActorIds*: HashSet[NodeId] ## actors whose handlers and select arms
                                   ## wait only on mailboxes (sends, actor
                                   ## waits): under stackless and
                                   ## --actors:single they run as frames
    helperIds*: HashSet[NodeId] ## generic fns that may wait: never frames;
                                ## a call to one runs on a helper stack
    frameIds*: HashSet[NodeId] ## the frame decls (tasks and fns), by id:
                               ## what codegen reads under stackless

  Analysis = object
    res: Resolution
    bodies: seq[BodyRef]
    byDecl: Table[Decl, int]          ## fn/task decl -> index in bodies
    actors: Table[string, Decl]
    calls: seq[seq[(Expr, Decl)]]     ## per body: each call and its callee
    awaited: seq[HashSet[Expr]]       ## per body: task calls a binding awaits
    pauses: Table[int, bool]          ## fixpoint: does body i pause

const ActorWaits = ["waitUntil", "alive", "pingUs"]

# Decls and call nodes are keyed by IDENTITY: two fns may share a name.
proc hash(d: Decl): Hash = hash(cast[pointer](d))
proc hash(e: Expr): Hash = hash(cast[pointer](e))

# --- collecting the bodies ---------------------------------------------------

proc addBody(a: var Analysis, b: BodyRef) =
  if b.decl != nil: a.byDecl[b.decl] = a.bodies.len
  a.bodies.add b

proc collectArms(a: var Analysis, lm: LoadedModule, actor, sel: Decl) =
  for arm in sel.selectArms:
    a.addBody BodyRef(body: arm.body, actor: actor, module: lm.name, m: lm.m, role: frArm,
                      label: actor.name & ".select | " & arm.source, line: arm.span.line)

proc collectMember(a: var Analysis, lm: LoadedModule, actor, h: Decl) =
  let role = if h.isOnHandler: frHandler else: frFn
  a.addBody BodyRef(decl: h, actor: actor, body: h.fnBody, module: lm.name, m: lm.m,
                    label: actor.name & "." & h.name, role: role, line: h.span.line)

proc collectActor(a: var Analysis, lm: LoadedModule, d: Decl) =
  a.actors[d.name] = d
  for h in d.handlers:
    if h == nil: continue
    if h.kind == dkFn and h.fnBody != nil: a.collectMember(lm, d, h)
    elif h.kind == dkSelect: a.collectArms(lm, d, h)

proc collectFn(a: var Analysis, lm: LoadedModule, d: Decl) =
  if d.kind == dkTask:
    a.addBody BodyRef(decl: d, body: d.fnBody, module: lm.name, m: lm.m,
                      label: d.name, role: frTask, line: d.span.line)
  elif not d.isExtern and not d.isPending and d.fnBody != nil:
    a.addBody BodyRef(decl: d, body: d.fnBody, module: lm.name, m: lm.m,
                      label: d.name, role: frFn, line: d.span.line)

proc isOwnActor(d: Decl): bool =
  d != nil and d.kind == dkActor and not d.isImportedCopy

proc collectModule(a: var Analysis, lm: LoadedModule) =
  for d in lm.m.decls:
    if d.isOwnActor: a.collectActor(lm, d)
  for d in lm.m.allFnsAndTasks:
    if not d.isImportedCopy and not a.byDecl.hasKey(d): a.collectFn(lm, d)

proc collect(a: var Analysis, prog: seq[LoadedModule]) =
  for lm in prog: a.collectModule(lm)

# --- the calls in one body ---------------------------------------------------

proc callOf*(res: Resolution, n: Expr): Expr =
  ## The call a node stands for: an exkCall, or a bare nullary name the
  ## checker stamped with one (spec 2.3). What the checker stamped may be a
  ## pool or slab operation rather than a call: that is no call here.
  let c = if n.kind == exkCall: n
          elif res.hasCall(n): res.call(n)
          else: nil
  if c != nil and c.kind == exkCall: c else: nil

proc scanCalls(a: var Analysis, i: int) =
  var calls: seq[(Expr, Decl)]
  var awaited: HashSet[Expr]
  let b = a.bodies[i]
  for n in b.body.nodes:
    if n.kind == exkAssign and n.assignVal != nil and n.assignVal.kind == exkCall:
      awaited.incl n.assignVal
    let c = callOf(a.res, n)
    if c != nil: calls.add (c, calleeDecl(a.res, b.m, c))
  a.calls.add calls
  a.awaited.add awaited

# --- pause sites -------------------------------------------------------------

proc site(kind: PauseKind, n: Expr, what: string): PauseSite =
  PauseSite(kind: kind, line: n.span.line, col: n.span.col, what: what)

proc calleeBodyPauses(a: Analysis, callee: Decl): bool =
  callee != nil and a.byDecl.hasKey(callee) and a.pauses.getOrDefault(a.byDecl[callee])

proc isIoExtern(callee: Decl): bool =
  callee != nil and callee.kind == dkFn and callee.isExtern and hasIo(callee.fnEffects)

proc taskCallSite(a: Analysis, i: int, c: Expr): seq[PauseSite] =
  ## A task call pauses only when a binding awaits it: a spawn enqueues.
  if c in a.awaited[i]: result.add site(pkAwait, c, callKey(c.callee))

proc isGeneric(d: Decl): bool = d != nil and d.kind == dkFn and d.fnGenerics.len > 0

proc isUnseen*(d: Decl): bool =
  ## Is what this call runs invisible here? Nothing resolved, or a
  ## declaration with no body that is no extern: an interface or group
  ## member, whose implementation is chosen at run time or instantiation.
  d == nil or (d.kind in {dkFn, dkTask} and d.fnBody == nil and not d.isExtern)

proc callSite(a: Analysis, i: int, c: Expr, callee: Decl): seq[PauseSite] =
  ## The pause one call makes, if any (see the rules at the top).
  let name = callKey(c.callee)
  if callee != nil and callee.kind == dkTask: return a.taskCallSite(i, c)
  if a.bodies[i].role == frTask and a.res.isAsync(c):
    result.add site(pkYieldCall, c, name)
  elif a.bodies[i].decl.isGeneric and a.res.isAsync(c) and not callee.isIoExtern:
    # A generic body's call edges are not to be trusted: a call through a
    # group requirement (`{self: s} pull` with `s: S`) runs whichever
    # implementation the instantiation picks, not the one the checker saw.
    # Any [io] call in one may wait; the fn runs whole on a helper anyway.
    result.add site(pkOpaque, c, name)
  elif a.calleeBodyPauses(callee):
    result.add site((if callee.isGeneric: pkHelperCall else: pkFrameCall), c, name)
  elif callee.isIoExtern: result.add site(pkExtern, c, name)
  elif callee.isUnseen and a.res.isAsync(c): result.add site(pkOpaque, c, name)

proc sendPauses(a: Analysis, n: Expr): bool =
  n.sendActor in a.actors and actorOnFull(a.actors[n.sendActor]) == ofWait

proc nodeSite(a: Analysis, n: Expr): seq[PauseSite] =
  ## The pause a node that is not a call makes, if any.
  case n.kind
  of exkSelect: result.add site(pkSelect, n, "select")
  of exkSend:
    if a.sendPauses(n): result.add site(pkSend, n, n.sendActor & "." & n.sendHandler)
  of exkField:
    if n.receiver != nil and n.receiver.kind == exkActorRef and n.fieldName in ActorWaits:
      result.add site(pkActorWait, n, n.receiver.refName & "." & n.fieldName)
  else: discard

proc sitesOf(a: Analysis, i: int): seq[PauseSite] =
  for (c, callee) in a.calls[i]: result.add a.callSite(i, c, callee)
  for n in a.bodies[i].body.nodes: result.add a.nodeSite(n)
  result.sort(proc (x, y: PauseSite): int = cmp((x.line, x.col), (y.line, y.col)))

proc settle(a: var Analysis) =
  ## The fixpoint: a body pauses when one of its sites does. Monotone, so it
  ## stops after at most one round per body.
  var changed = true
  while changed:
    changed = false
    for i in 0 ..< a.bodies.len:
      if a.pauses.getOrDefault(i): continue
      if a.sitesOf(i).len > 0:
        a.pauses[i] = true
        changed = true

# --- reachability from the roots ---------------------------------------------

proc roots(a: Analysis): seq[int] =
  for i, b in a.bodies:
    if b.role in {frTask, frHandler, frArm}: result.add i

proc callees(a: Analysis, i: int): seq[int] =
  ## The bodies body i calls, by call edge.
  for (_, callee) in a.calls[i]:
    if callee != nil and a.byDecl.hasKey(callee): result.add a.byDecl[callee]

# --- recursion: strongly connected components of the call graph ---------------
# Phase 6 (#219) embeds a callee's frame in its caller's (a union of what it
# calls), which is only a finite type where the call graph has no cycle. A
# call between two bodies of one component (or a body and itself) keeps the
# heap; every other call embeds.

type Tarjan = object
  index, low, comp: Table[int, int]
  stack: seq[int]
  onStack: HashSet[int]
  counter, ncomp: int

proc pop(t: var Tarjan, v: int) =
  ## v is a component's root: everything above it on the stack is that component.
  while true:
    let w = t.stack.pop()
    t.onStack.excl w
    t.comp[w] = t.ncomp
    if w == v: break
  inc t.ncomp

proc strong(a: Analysis, t: var Tarjan, v: int) =
  t.index[v] = t.counter
  t.low[v] = t.counter
  inc t.counter
  t.stack.add v
  t.onStack.incl v
  for w in a.callees(v):
    if w notin t.index:
      a.strong(t, w)
      t.low[v] = min(t.low[v], t.low[w])
    elif w in t.onStack:
      t.low[v] = min(t.low[v], t.index[w])
  if t.low[v] == t.index[v]: t.pop(v)

proc selfCalls(a: Analysis, i: int): bool = i in a.callees(i)

proc components(a: Analysis, plan: var FramePlan) =
  ## Each frame decl's component, and the ones that recurse.
  var t: Tarjan
  for i in 0 ..< a.bodies.len:
    if i notin t.index: a.strong(t, i)
  var size: Table[int, int]
  for i in 0 ..< a.bodies.len: size.mgetOrPut(t.comp[i], 0) += 1
  for i, b in a.bodies:
    if b.decl == nil or not b.decl.id.isSet: continue
    plan.sccOf[b.decl.id] = t.comp[i]
    if size[t.comp[i]] > 1 or a.selfCalls(i): plan.recursiveIds.incl b.decl.id

# --- what --frames:static refuses (#219) ---------------------------------------

proc where(b: BodyRef, n: Expr): string =
  b.module & ":" & $n.span.line & ": in " & b.label & ", "

proc waitsOnStack(a: Analysis, i: int, c: Expr, callee: Decl): bool =
  ## Does this call, in a task or frame fn, wait inside the runtime (and so
  ## borrow a helper stack)?
  callee.isIoExtern or (callee.isUnseen and a.res.isAsync(c)) or
    (callee.isGeneric and a.calleeBodyPauses(callee))

proc stackSites(a: Analysis, i: int): seq[string] =
  let b = a.bodies[i]
  for (c, callee) in a.calls[i]:
    if a.waitsOnStack(i, c, callee):
      result.add b.where(c) & "'" & callKey(c.callee) & "' waits inside the runtime, on a helper stack"
  for n in b.body.nodes:
    if a.nodeSite(n).len > 0:
      result.add b.where(n) & "a " & ($n.kind)[3 .. ^1].toLowerAscii &
                 " may wait inside the runtime, on a helper stack"

proc spawnSites(a: Analysis, i: int): seq[string] =
  let b = a.bodies[i]
  for (c, callee) in a.calls[i]:
    if callee != nil and callee.kind == dkTask and c notin a.awaited[i]:
      result.add b.where(c) & "task '" & callKey(c.callee) &
                 "' is spawned, not awaited: its frame comes from the heap"

proc staticReasons(a: Analysis, plan: var FramePlan, reach: HashSet[int]) =
  ## Every frame that would come from the heap, and every stack a frame
  ## would borrow: what --frames:static refuses, each with its place.
  for i, b in a.bodies:
    plan.heapReasons.add a.spawnSites(i)
    if i notin reach or b.decl == nil or b.decl.id notin plan.frameIds: continue
    if b.role in {frTask, frFn}: plan.heapReasons.add a.stackSites(i)
    if b.decl.id in plan.recursiveIds:
      plan.heapReasons.add b.module & ":" & $b.line & ": " & b.label &
        " is on a call cycle: its frame comes from the heap"

proc reachable(a: Analysis): HashSet[int] =
  var work = a.roots()
  while work.len > 0:
    let i = work.pop()
    if i notin result:
      result.incl i
      work.add a.callees(i)

# --- the plan ----------------------------------------------------------------

proc isNativeIo(a: Analysis, i: int): bool =
  let d = a.bodies[i].decl
  d != nil and d.kind == dkFn and hasIo(d.fnEffects) and not a.pauses.getOrDefault(i)

proc place(a: Analysis, plan: var FramePlan, i: int) =
  ## File one reachable body under frames, native handlers or native [io].
  let b = a.bodies[i]
  if b.decl.isGeneric and a.pauses.getOrDefault(i):
    plan.helperIds.incl b.decl.id
    plan.helpers.add b.label
  elif b.role == frTask or a.pauses.getOrDefault(i):
    if b.decl != nil: plan.frameIds.incl b.decl.id
    plan.frames.add Frame(label: b.label, module: b.module, line: b.line,
                          role: b.role, pauses: a.sitesOf(i))
  elif b.role in {frHandler, frArm}: plan.nativeRoots.add b.label
  elif a.isNativeIo(i): plan.nativeIo.add b.label

proc mailboxOnly(a: Analysis, i: int, seen: var HashSet[int]): bool =
  ## Does body i wait only on MAILBOXES — sends, actor waits, or calls to
  ## bodies that wait only so? A frame actor in --actors:single serves those
  ## by pumping the scheduler, as `main` does; any other wait (an [io] call,
  ## a select, a task await) needs a stack to park on.
  if i in seen: return true
  seen.incl i
  for p in a.sitesOf(i):
    if p.kind notin {pkSend, pkActorWait, pkFrameCall}: return false
  for (_, callee) in a.calls[i]:
    if callee != nil and a.byDecl.hasKey(callee):
      let j = a.byDecl[callee]
      if a.pauses.getOrDefault(j) and not a.mailboxOnly(j, seen): return false
  true

proc pureActors(a: Analysis): HashSet[NodeId] =
  ## The actors whose every root (handler, select arm) waits, if at all,
  ## only on mailboxes: under stackless and --actors:single, frames.
  var impure: HashSet[NodeId]
  for i, b in a.bodies:
    if b.actor == nil or b.role notin {frHandler, frArm}: continue
    var seen: HashSet[int]
    if not a.mailboxOnly(i, seen): impure.incl b.actor.id
  for _, d in a.actors:
    if d.id.isSet and d.id notin impure: result.incl d.id

proc planFrames*(res: Resolution, prog: seq[LoadedModule]): FramePlan =
  ## Which fns the stackless transform turns into frames, and their pause
  ## sites. Reads a checked program; changes nothing.
  var a = Analysis(res: res)
  a.collect(prog)
  for i in 0 ..< a.bodies.len: a.scanCalls(i)
  a.settle()
  let reach = a.reachable()
  for i in 0 ..< a.bodies.len:
    if i in reach: a.place(result, i)
  result.pureActorIds = a.pureActors()
  a.components(result)
  a.staticReasons(result, reach)
  for _, d in a.actors:
    if d.id in result.pureActorIds: result.frameActors.add d.name
  result.frameActors.sort()

# --- rendering ---------------------------------------------------------------

proc describe(p: PauseSite): string =
  case p.kind
  of pkYieldCall: "yield, then call " & p.what
  of pkExtern: "call " & p.what & " (extern, may park)"
  of pkFrameCall: "call " & p.what & " (frame)"
  of pkSelect: "on select"
  of pkSend: "send " & p.what & " (waits when full)"
  of pkAwait: "await task " & p.what
  of pkActorWait: p.what
  of pkOpaque: "call " & p.what & " (resolved at run time, may wait)"
  of pkHelperCall: "call " & p.what & " (generic, on a helper stack)"

proc renderFrame(f: Frame): string =
  result = "frame " & $f.role & " " & f.label & "  (" & f.module & ":" & $f.line & ")\n"
  if f.pauses.len == 0: result.add "  never pauses (a task still needs its frame)\n"
  for p in f.pauses:
    result.add "  " & $p.line & ":" & $p.col & "  " & describe(p) & "\n"

proc render*(plan: FramePlan): string =
  ## The `tuck frames` report: one block per frame, then what stays native.
  for f in plan.frames: result.add renderFrame(f)
  if plan.helpers.len > 0:
    result.add "generic, may wait (called on a helper stack): " & plan.helpers.join(", ") & "\n"
  if plan.nativeRoots.len > 0:
    result.add "native handlers, never pause: " & plan.nativeRoots.join(", ") & "\n"
  if plan.nativeIo.len > 0:
    result.add "native [io], reached from a root: " & plan.nativeIo.join(", ") & "\n"
  if plan.frameActors.len > 0:
    result.add "actors that run as frames under --actors:single (wait only on mailboxes): " &
               plan.frameActors.join(", ") & "\n"
  if plan.frames.len > 0:
    if plan.heapReasons.len == 0:
      result.add "--frames:static: every frame is embedded (no heap, no helper stack)\n"
    else:
      result.add "--frames:static would refuse:\n"
      for r in plan.heapReasons: result.add "  " & r & "\n"
  if plan.frames.len == 0 and plan.nativeRoots.len == 0:
    result.add "no frames: nothing runs on the scheduler\n"
