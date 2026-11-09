# compiler/stages.nim
#
# Stackless transform, phase 2 (#216, docs/stackless-concurrency.md): split a
# frame fn's body into STAGES at its pause points. Backend-neutral: it decides
# where the cuts go and what each stage ends with; a backend prints the plan
# (codegen_stages.nim for Nim), reusing its own statement emitter for the
# code between the cuts. Splitting is decided here, once, so the backends
# cannot disagree about where a task pauses.
#
# It runs on a backend's lowered, mangled copy, just before printing, so it
# sees the simple statements lowering leaves behind.
#
# THE CUTS keep today's stackful semantics:
#   * in a TASK body, an [io] call yields first and then calls. The yield
#     goes before the STATEMENT holding the call: the statement has not
#     started, so nothing observable moves across it;
#   * a call to a frame fn ends the stage; the caller resumes in the next
#     one, reading the result the callee wrote through its destination;
#   * a binding that awaits a task ends the stage; the next one starts by
#     taking the value out of the task's slot;
#   * an `if` whose branches pause becomes a branch to two stage chains that
#     meet at a join stage.
# Pauses inside loops, `match`, `on select` and `defer` are phase 3/4: they
# are refused by name rather than run wrongly.
import std/[tables, sets, strutils]
import ast, ast_ops, ast_query, resolution, concurrency
from typecheck_util import typeName

type
  TermKind* = enum
    tkFall    ## the body's end: a void frame finishes
    tkGoto    ## continue in `next`, directly
    tkYield   ## requeue, continue in `next`
    tkBranch  ## `if cond`: `thenS`, else `elseS`
    tkCall    ## call frame fn `call`, continue in `next`
    tkAwait   ## spawn task `call` into slot field `slot`, park until done

  Term* = object
    kind*: TermKind
    next*, thenS*, elseS*: int
    cond*: Expr
    call*: Expr             ## tkCall / tkAwait: the call node
    callee*: Decl           ## tkCall / tkAwait: the frame decl it reaches
    target*: Expr           ## where the result goes; nil: nowhere
    slot*: string           ## tkAwait: the frame field holding the slot
    runDefers*: seq[int]    ## tkGoto out of a branch: the branch's armed
                            ## `defer`s, run (last first) and disarmed

  Stage* = object
    stmts*: seq[Expr]
    term*: Term

  FrameField* = object
    name*: string
    typ*: Type
    isSlot*: bool           ## a task slot: `typ` is the TASK's result type

  StagePlan* = object
    stages*: seq[Stage]     ## stage 0 is the entry
    defers*: seq[Expr]      ## the `defer`s of the lists that are split, in
                            ## order. A stage's return is not a scope exit,
                            ## so each is ARMED by a flag in the frame
                            ## (`tuckDeferK`) and run at its scope's real
                            ## exit: a branch's jump out, or the frame's end.
    fields*: seq[FrameField] ## the locals that live in the frame (params not included)
    error*: string          ## non-empty: this body uses a shape not built yet

  Splitter = object
    res: Resolution
    m: Module
    isTask: bool
    plan: StagePlan
    fieldIdx: Table[string, int]
    scopes: seq[seq[int]]   ## per open branch: the `defer`s it arms
    awaited: HashSet[NodeId] ## task calls a binding awaits; an unbound one
                             ## only spawns, which is not a pause

const Nested = {exkIf, exkMatch, exkFor, exkWhile, exkBlock, exkSelect, exkDefer}

# --- what a node is ------------------------------------------------------------

proc callOf(sp: Splitter, n: Expr): Expr =
  if n.kind == exkCall: n
  elif sp.res.hasCall(n): sp.res.call(n)
  else: nil

proc frameCallee(sp: Splitter, c: Expr): Decl =
  ## The frame decl a call reaches when the call pauses on it: a frame fn,
  ## or a task whose result is bound. Nil otherwise.
  let d = calleeDecl(sp.res, sp.m, c)
  if d == nil or not d.id.isSet or d.id notin frameDecls: return nil
  if d.kind == dkTask and not (c.id.isSet and c.id in sp.awaited): return nil
  d

proc noteAwaits(sp: var Splitter, body: Expr) =
  for n in body.nodes:
    if n.kind == exkAssign and n.assignVal != nil and n.assignVal.kind == exkCall and
       n.assignVal.id.isSet:
      sp.awaited.incl n.assignVal.id

proc yieldsAt(sp: Splitter, n: Expr): bool =
  ## Does the task body yield before this node's statement?
  if not sp.isTask: return false
  let c = sp.callOf(n)
  c != nil and sp.res.isAsync(c)

proc isPause(sp: Splitter, n: Expr): bool =
  ## Any pause at this node: a yield, a frame call or task await, a select.
  if n.kind == exkSelect or sp.yieldsAt(n): return true
  let c = sp.callOf(n)
  c != nil and sp.frameCallee(c) != nil

proc pausesIn(sp: Splitter, e: Expr): bool =
  if e == nil: return false
  for n in e.nodes:
    if sp.isPause(n): return true

proc framePausesIn(sp: Splitter, e: Expr): bool =
  ## A pause other than a yield: a frame call, a task await, a select.
  if e == nil: return false
  for n in e.nodes:
    if sp.isPause(n) and not sp.yieldsAt(n): return true

proc yieldCount(sp: Splitter, e: Expr): int =
  for n in e.nodes:
    if sp.yieldsAt(n): inc result

# --- stages and fields -----------------------------------------------------------

proc newStage(sp: var Splitter): int =
  sp.plan.stages.add Stage(term: Term(kind: tkFall))
  sp.plan.stages.high

proc fail(sp: var Splitter, n: Expr, what: string) =
  if sp.plan.error == "":
    sp.plan.error = "line " & $n.span.line & ": " & what &
                    " is not supported by --concurrency:stackless yet (#216)"

proc addField(sp: var Splitter, n: Expr, name: string, t: Type, isSlot = false) =
  if name in sp.fieldIdx:
    if not isSlot and typeName(sp.plan.fields[sp.fieldIdx[name]].typ) != typeName(t):
      sp.fail(n, "two locals named '" & name & "' with different types")
    return
  if t == nil: sp.fail(n, "a local whose type is unknown ('" & name & "')")
  sp.fieldIdx[name] = sp.plan.fields.len
  sp.plan.fields.add FrameField(name: name, typ: t, isSlot: isSlot)

proc noteLocal(sp: var Splitter, s: Expr) =
  ## A local declared in a list that is split lives in the frame.
  if s.kind != exkAssign or not s.isDecl or s.target == nil or s.target.kind != exkVar:
    return
  var t = sp.res.typeFor(s.target)
  if t == nil: t = sp.res.typeFor(s.assignVal)
  sp.addField(s, s.target.name, t)

# --- one statement ----------------------------------------------------------------

proc valueCall(s: Expr): tuple[call, target: Expr] =
  ## The call a simple statement IS (`f x`, `discard f x`, `x = f y`), with
  ## where its value goes.
  case s.kind
  of exkCall: (s, nil)
  of exkDiscard: (s.discardVal, nil)
  of exkAssign: (s.assignVal, s.target)
  else: (nil, nil)

proc endWith(sp: var Splitter, cur: int, t: Term): int =
  ## End stage `cur` with `t`, continuing in a fresh stage.
  result = sp.newStage()
  var t = t
  t.next = result
  sp.plan.stages[cur].term = t

proc emitYields(sp: var Splitter, cur: var int, n: int) =
  for _ in 0 ..< n: cur = sp.endWith(cur, Term(kind: tkYield))

proc callTerm(sp: var Splitter, s: Expr, c: Expr, callee: Decl, target: Expr): Term =
  if callee.kind == dkTask:
    let slot = "tuckSlot" & $sp.plan.fields.len
    sp.addField(s, slot, callee.fnReturnType, isSlot = true)
    Term(kind: tkAwait, call: c, callee: callee, target: target, slot: slot)
  else:
    Term(kind: tkCall, call: c, callee: callee, target: target)

proc simpleStmt(sp: var Splitter, cur: var int, s: Expr) =
  ## A statement with no nested body: yields before it, then it runs, or it
  ## IS a frame call / task await that ends the stage.
  sp.emitYields(cur, sp.yieldCount(s))
  let (v, target) = valueCall(s)
  let c = if v != nil: sp.callOf(v) else: nil
  let callee = if c != nil: sp.frameCallee(c) else: nil
  if callee == nil:
    for n in s.nodes:
      if n.kind != exkCall and sp.callOf(n) != nil and sp.frameCallee(sp.callOf(n)) != nil:
        sp.fail(s, "a frame call inside a larger expression")
    sp.plan.stages[cur].stmts.add s
  else:
    sp.noteLocal(s)
    cur = sp.endWith(cur, sp.callTerm(s, c, callee, target))

proc splitList(sp: var Splitter, stmts: seq[Expr], cur: var int)

proc branchEntry(sp: var Splitter, body: Expr, join: int): int =
  ## A branch's stage chain, ending in a jump to `join`.
  result = sp.newStage()
  var cur = result
  sp.scopes.add @[]
  if body != nil:
    sp.splitList(if body.kind == exkBlock: body.stmts else: @[body], cur)
  sp.plan.stages[cur].term = Term(kind: tkGoto, next: join, runDefers: sp.scopes.pop())

proc ifStmt(sp: var Splitter, cur: var int, s: Expr) =
  sp.emitYields(cur, sp.yieldCount(s.cond))
  let join = sp.newStage()
  let thenS = sp.branchEntry(s.thenBranch, join)
  let elseS = sp.branchEntry(s.elseBranch, join)
  sp.plan.stages[cur].term = Term(kind: tkBranch, cond: s.cond, thenS: thenS, elseS: elseS)
  cur = join

proc deferStmt(sp: var Splitter, cur: int, s: Expr) =
  ## A `defer` arms an exit action: the frame's end for one in the body's
  ## own list, the jump out of the branch for one inside a branch (and the
  ## frame's end too, should the branch return).
  if sp.pausesIn(s.deferBody): sp.fail(s, "a pause inside a `defer`")
  if sp.scopes.len > 0: sp.scopes[^1].add sp.plan.defers.len
  sp.plan.defers.add s
  sp.plan.stages[cur].stmts.add s

proc branchesPause(sp: Splitter, s: Expr): bool =
  sp.pausesIn(s.thenBranch) or sp.pausesIn(s.elseBranch)

proc splitStmt(sp: var Splitter, cur: var int, s: Expr) =
  sp.noteLocal(s)
  if s.kind == exkDefer: sp.deferStmt(cur, s)
  elif not sp.pausesIn(s): sp.plan.stages[cur].stmts.add s
  elif s.kind == exkIf and sp.branchesPause(s): sp.ifStmt(cur, s)
  elif s.kind == exkIf and not sp.framePausesIn(s.cond):
    sp.emitYields(cur, sp.yieldCount(s.cond))   # only the condition yields
    sp.plan.stages[cur].stmts.add s
  elif s.kind in Nested:
    sp.fail(s, "a pause inside " & ($s.kind)[3 .. ^1].toLowerAscii)
  else: sp.simpleStmt(cur, s)

proc splitList(sp: var Splitter, stmts: seq[Expr], cur: var int) =
  for s in stmts: sp.splitStmt(cur, s)

proc planStages*(res: Resolution, m: Module, d: Decl): StagePlan =
  ## The stages of frame fn or task `d` (its lowered, mangled copy).
  var sp = Splitter(res: res, m: m, isTask: d.kind == dkTask)
  var cur = sp.newStage()
  let body = d.fnBody
  if body != nil:
    sp.noteAwaits(body)
    sp.splitList(if body.kind == exkBlock: body.stmts else: @[body], cur)
  sp.plan
