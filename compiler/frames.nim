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
    a.addBody BodyRef(body: arm.body, module: lm.name, m: lm.m, role: frArm,
                      label: actor.name & ".select | " & arm.source, line: arm.span.line)

proc collectMember(a: var Analysis, lm: LoadedModule, actor, h: Decl) =
  let role = if h.isOnHandler: frHandler else: frFn
  a.addBody BodyRef(decl: h, body: h.fnBody, module: lm.name, m: lm.m,
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

proc callOf(res: Resolution, n: Expr): Expr =
  ## The call a node stands for: an exkCall, or a bare nullary name the
  ## checker stamped with one (spec 2.3).
  if n.kind == exkCall: n
  elif res.hasCall(n): res.call(n)
  else: nil

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

proc callSite(a: Analysis, i: int, c: Expr, callee: Decl): seq[PauseSite] =
  ## The pause one call makes, if any (see the rules at the top).
  let name = callKey(c.callee)
  if callee != nil and callee.kind == dkTask: return a.taskCallSite(i, c)
  if a.bodies[i].role == frTask and a.res.isAsync(c):
    result.add site(pkYieldCall, c, name)
  elif a.calleeBodyPauses(callee): result.add site(pkFrameCall, c, name)
  elif callee.isIoExtern: result.add site(pkExtern, c, name)

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
  if b.role == frTask or a.pauses.getOrDefault(i):
    if b.decl != nil: plan.frameIds.incl b.decl.id
    plan.frames.add Frame(label: b.label, module: b.module, line: b.line,
                          role: b.role, pauses: a.sitesOf(i))
  elif b.role in {frHandler, frArm}: plan.nativeRoots.add b.label
  elif a.isNativeIo(i): plan.nativeIo.add b.label

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

proc renderFrame(f: Frame): string =
  result = "frame " & $f.role & " " & f.label & "  (" & f.module & ":" & $f.line & ")\n"
  if f.pauses.len == 0: result.add "  never pauses (a task still needs its frame)\n"
  for p in f.pauses:
    result.add "  " & $p.line & ":" & $p.col & "  " & describe(p) & "\n"

proc render*(plan: FramePlan): string =
  ## The `tuck frames` report: one block per frame, then what stays native.
  for f in plan.frames: result.add renderFrame(f)
  if plan.nativeRoots.len > 0:
    result.add "native handlers, never pause: " & plan.nativeRoots.join(", ") & "\n"
  if plan.nativeIo.len > 0:
    result.add "native [io], reached from a root: " & plan.nativeIo.join(", ") & "\n"
  if plan.frames.len == 0 and plan.nativeRoots.len == 0:
    result.add "no frames: nothing runs on the scheduler\n"
