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
#     meet at a join stage; a `match` whose arms pause is the backend's own
#     `case`, each arm body replaced by a JUMP to that arm's chain;
#   * a loop whose body pauses keeps its iteration state in the frame (a
#     counter and an end, or an index over a Seq) and runs as head, body and
#     step stages; `break` and `continue` in it become jumps.
#
# SCOPES. A stage's return is not a scope exit, so each split list that is a
# scope (a branch, an arm, a loop body, a block) gets an id, and its `defer`s
# are ARMED by flags in the frame. Every jump that leaves a scope names the
# scopes it leaves; the backend runs their armed `defer`s, innermost first.
# The frame's end runs whatever is still armed.
#
# JUMPS are the one thing a backend prints in place of a statement: a
# `break`/`continue` inside a split loop, or a match arm's body, each mapped
# (by node identity) to a target stage and the scopes it leaves.
#
# WAITS (phase 4): an [io] extern, `on select`, a send, an actor wait park
# INSIDE the runtime's own code, so the statement holding one runs on a
# helper stack (tkOnStack, tuck_async's tuckSlOnStack); a condition that
# waits is computed there into a frame field first. A pause inside `defer`
# is refused by name.
import std/[tables, sets, strutils, hashes]
import ast, ast_ops, ast_query, resolution, concurrency
import frames   # callOf: the one answer to "which call is this node"
from twin_calls import markBuilt
from typecheck_util import typeName

type
  TermKind* = enum
    tkFall    ## the body's end: a void frame finishes
    tkGoto    ## continue in `next`, directly
    tkYield   ## requeue, continue in `next`
    tkBranch  ## `if cond`: `thenS`, else `elseS`
    tkCall    ## call frame fn `call`, continue in `next`
    tkAwait   ## spawn task `call` into slot field `slot`, park until done
    tkLoopEnter ## start loop `loop`: set its state, then body or exit
    tkLoopNext  ## advance loop `loop`: step its state, then body or exit
    tkOnStack   ## run statement `stmt` on a helper stack (it may park), then `next`

  LoopKind* = enum
    lkRange   ## `for i in a .. b` / `a ..< b`: counter + end in the frame
    lkSeq     ## `for x in xs`, xs a named Seq: an index; x views xs[index]
    lkWhile   ## `for cond:` / `loop:`: re-test at the head stage

  Loop* = object
    kind*: LoopKind
    node*: Expr             ## the exkFor / exkWhile
    varName*: string        ## lkRange: the counter field; lkSeq: the element alias
    stateField*: string     ## lkRange: the end field; lkSeq: the index field
    elemType*: Type         ## lkSeq: the element type (a backend with no
                            ## view to alias copies the element instead)
    head*, body*, exit*: int ## head: the step (`continue` lands there; for
                             ## lkWhile, the re-test); body; after the loop

  Jump* = object
    target*: int
    leaves*: seq[int]       ## scope ids this jump leaves, innermost first
  Term* = object
    kind*: TermKind
    next*, thenS*, elseS*: int
    cond*: Expr
    call*: Expr             ## tkCall / tkAwait: the call node
    callee*: Decl           ## tkCall / tkAwait: the frame decl it reaches
    target*: Expr           ## where the result goes; nil: nowhere
    slot*: string           ## tkAwait: the frame field holding the slot
    leaves*: seq[int]       ## tkGoto: scope ids it leaves, innermost first
    loop*: int              ## tkLoopEnter / tkLoopNext: index into loops
    embed*: bool            ## tkCall / tkAwait: the callee's frame is built
                            ## inside this frame's `tuckSub` (#219), not on
                            ## the heap
    stmt*: Expr             ## tkOnStack: the statement that may park
    site*: int              ## tkOnStack: its number, naming its helper

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
    scopeDefers*: seq[seq[int]] ## per scope id: the defers it arms, in order
    subs*: seq[Decl]        ## the callee frames embedded in this one (one
                            ## at a time: `tuckSub` is their union)
    loops*: seq[Loop]
    jumps*: Table[Expr, Jump] ## by node identity: what to print instead
    error*: string          ## non-empty: this body uses a shape not built yet

  Splitter = object
    decl: Decl              ## the frame fn or task being split
    res: Resolution
    m: Module
    isTask: bool
    plan: StagePlan
    fieldIdx: Table[string, int]
    open: seq[int]          ## the scope ids open here, outermost first
    sites: int              ## tkOnStack sites numbered so far
    temps: int              ## hoisted frame-call temps numbered so far
    loopStack: seq[tuple[loop, depth: int]] ## split loops open here, and the
                            ## `open` depth of each one's body scope
    awaited: HashSet[NodeId] ## task calls a binding awaits; an unbound one
                             ## only spawns, which is not a pause

const Nested = {exkIf, exkMatch, exkFor, exkWhile, exkBlock, exkSelect, exkDefer}

proc hash*(e: Expr): Hash = hash(cast[pointer](e))
  ## Jumps are keyed by node IDENTITY: two `break`s are equal by value.

# --- what a node is ------------------------------------------------------------

proc callOf(sp: Splitter, n: Expr): Expr = frames.callOf(sp.res, n)

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

const ActorWaits = ["waitUntil", "alive", "pingUs"]

proc isIoExtern(d: Decl): bool =
  d != nil and d.kind == dkFn and d.isExtern and hasIo(d.fnEffects)

proc parksAt(sp: Splitter, n: Expr): bool =
  ## Does this node wait inside the runtime's own code (phase 4)? An [io]
  ## extern (an fd, a timer, an offloaded file read), `on select`, a send
  ## (into a full mailbox it waits), an actor wait. Such a statement runs
  ## on a helper stack: the frame has none to park on.
  case n.kind
  of exkSelect, exkSend: true
  of exkField: n.receiver != nil and n.receiver.kind == exkActorRef and n.fieldName in ActorWaits
  else:
    let c = sp.callOf(n)
    if c == nil: return false
    let callee = calleeDecl(sp.res, sp.m, c)
    # an [io] extern; a generic fn that may wait (no frame of its own); or an
    # [io] call resolved only at run time — a group requirement, a fnsig
    # value — whose waiting nothing here can see
    callee.isIoExtern or (callee != nil and callee.id.isSet and callee.id in helperDecls) or
      (callee.isUnseen and sp.res.isAsync(c))

proc isCut(sp: Splitter, n: Expr): bool =
  ## A pause that must end a stage of this frame: a frame call or an await.
  let c = sp.callOf(n)
  c != nil and sp.frameCallee(c) != nil

proc isPause(sp: Splitter, n: Expr): bool =
  ## Any pause at this node: a yield, a frame call or task await, a park.
  sp.yieldsAt(n) or sp.isCut(n) or sp.parksAt(n)

proc pausesIn(sp: Splitter, e: Expr): bool =
  if e == nil: return false
  for n in e.nodes:
    if sp.isPause(n): return true

proc framePausesIn(sp: Splitter, e: Expr): bool =
  ## A frame call or a task await inside `e`: the pauses that cannot be
  ## hoisted out of a condition and run on a helper.
  if e == nil: return false
  for n in e.nodes:
    if sp.isCut(n): return true

proc parksIn(sp: Splitter, e: Expr): bool =
  if e == nil: return false
  for n in e.nodes:
    if sp.parksAt(n): return true

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
                    " is not cut by the stackless transform yet (#216); build " &
                    "with --concurrency:stackful"

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
  let embed = embeds(sp.decl, callee)
  if embed and callee notin sp.plan.subs: sp.plan.subs.add callee
  if callee.kind == dkTask:
    let slot = "tuckSlot" & $sp.plan.fields.len
    sp.addField(s, slot, callee.fnReturnType, isSlot = true)
    Term(kind: tkAwait, call: c, callee: callee, target: target, slot: slot, embed: embed)
  else:
    Term(kind: tkCall, call: c, callee: callee, target: target, embed: embed)

proc onStack(sp: var Splitter, cur: var int, s: Expr) =
  ## A statement that may park, run whole on a helper stack. It must not
  ## leave the frame itself: a `return`, `err` or loop jump inside it would
  ## return from the helper instead.
  for n in s.nodes:
    if n.kind in {exkReturn, exkRaise, exkBreak, exkContinue}:
      sp.fail(s, "a `return`, `err`, `break` or `continue` in a statement that waits")
    if n != s and sp.isCut(n): sp.fail(s, "a frame call inside a statement that waits")
  cur = sp.endWith(cur, Term(kind: tkOnStack, stmt: s, site: sp.sites))
  inc sp.sites

proc boolType(): Type = Type(kind: tkNamed, name: "bool")

proc built(e: Expr): Expr =
  ## A node the splitter builds, made known to the passes after `prepare`:
  ## an id, and "decided, no twin" for twin_calls, which otherwise fails
  ## loudly on a node it never visited.
  fillIdsIn(e)
  markBuilt(e)
  e

proc temp(sp: var Splitter, name: string, t: Type, span: Span): Expr =
  ## A read of frame temp `name`, its type recorded so a printer that asks
  ## (a match on it reads `.kind`) gets the answer it would for a local.
  result = built(Expr(kind: exkVar, name: name, span: span))
  if t != nil: sp.res.setType(result, t)

proc hoisted(sp: var Splitter, cur: var int, e: Expr, t: Type): Expr =
  ## A condition (or subject) that may park, computed on a helper into a
  ## frame field first; what the branch then tests is that field.
  if not sp.parksIn(e): return e
  let name = "tuckCond" & $sp.sites
  sp.addField(e, name, t)
  let v = sp.temp(name, t, e.span)
  sp.onStack(cur, built(Expr(kind: exkAssign, target: v, assignVal: e, span: e.span)))
  sp.temp(name, t, e.span)

proc hoistCuts(sp: var Splitter, cur: var int, slot: var Expr) =
  ## Every frame call nested in `slot`, cut out and run FIRST into a frame
  ## temp (`tuckTmpN`), the slot then reading the temp: `({n: 1} f).v + 1`
  ## becomes a frame call into tuckTmp0, then `tuckTmp0.v + 1`. Inner calls
  ## before outer, left to right, as they would evaluate.
  if slot == nil: return
  for child in slot.childSlots: sp.hoistCuts(cur, child)
  let c = sp.callOf(slot)
  if c == nil: return
  let callee = sp.frameCallee(c)
  if callee == nil or callee.kind == dkTask: return   # a nested task call only spawns
  var t = sp.res.typeFor(slot)
  if t == nil: t = sp.res.typeFor(c)
  let name = "tuckTmp" & $sp.temps
  inc sp.temps
  sp.addField(slot, name, t)
  cur = sp.endWith(cur, sp.callTerm(slot, c, callee, sp.temp(name, t, slot.span)))
  slot = sp.temp(name, t, slot.span)

proc hoistNested(sp: var Splitter, cur: var int, s: Expr) =
  ## The frame calls nested anywhere in statement `s` below its own value
  ## call (which ends the stage itself), hoisted out first.
  if s.kind == exkAssign: sp.hoistCuts(cur, s.target)
  for child in s.childSlots:
    if child == nil: continue
    if s.kind == exkAssign and child == s.target: continue
    let top = sp.callOf(child)
    if top != nil and sp.frameCallee(top) != nil and s.kind in {exkAssign, exkDiscard}:
      for arg in child.childSlots: sp.hoistCuts(cur, arg)   # its arguments
    else: sp.hoistCuts(cur, child)

proc simpleStmt(sp: var Splitter, cur: var int, s: Expr) =
  ## A statement with no nested body: yields before it, then it runs, or it
  ## IS a frame call / task await that ends the stage. A frame call nested
  ## deeper is hoisted out into a temp first; a `return` whose value waits
  ## computes it on a helper stack first.
  sp.emitYields(cur, sp.yieldCount(s))
  if s.kind == exkCall:
    for arg in s.childSlots: sp.hoistCuts(cur, arg)
  else: sp.hoistNested(cur, s)
  let (v, target) = valueCall(s)
  let c = if v != nil: sp.callOf(v) else: nil
  let callee = if c != nil: sp.frameCallee(c) else: nil
  if callee != nil:
    sp.noteLocal(s)
    cur = sp.endWith(cur, sp.callTerm(s, c, callee, target))
  elif s.kind == exkReturn and sp.parksIn(s.returnVal):
    let t = sp.res.typeFor(s.returnVal)
    s.returnVal = sp.hoisted(cur, s.returnVal, t)
    sp.plan.stages[cur].stmts.add s
  elif sp.parksIn(s): sp.onStack(cur, s)
  else: sp.plan.stages[cur].stmts.add s

proc splitList(sp: var Splitter, stmts: seq[Expr], cur: var int)

# --- scopes and jumps -------------------------------------------------------------

proc openScope(sp: var Splitter): int =
  result = sp.plan.scopeDefers.len
  sp.plan.scopeDefers.add @[]
  sp.open.add result

proc leaving(sp: Splitter, depth: int): seq[int] =
  ## The open scopes from `depth` in, innermost first: what a jump out of
  ## them leaves.
  for i in countdown(sp.open.high, depth): result.add sp.open[i]

proc chain(sp: var Splitter, body: Expr, next: int): int =
  ## A scope's stage chain: its statements, then a jump to `next` that
  ## leaves the scope.
  result = sp.newStage()
  var cur = result
  let depth = sp.open.len
  discard sp.openScope()
  if body != nil:
    sp.splitList(if body.kind == exkBlock: body.stmts else: @[body], cur)
  sp.plan.stages[cur].term = Term(kind: tkGoto, next: next, leaves: sp.leaving(depth))
  sp.open.setLen depth

proc jumpsIn(sp: var Splitter, e: Expr) =
  ## Every `break`/`continue` of the innermost split loop inside `e`, which
  ## the backend prints itself (an inline `if`): each becomes a jump. A
  ## loop nested in `e` is native and keeps its own.
  if e == nil or sp.loopStack.len == 0: return
  if e.kind in {exkFor, exkWhile}: return
  if e.kind in {exkBreak, exkContinue}:
    let (k, depth) = sp.loopStack[^1]
    let lp = sp.plan.loops[k]
    # `break` leaves for the exit; `continue` for the step (`head`), which
    # re-tests a `for cond:` and advances a counted loop.
    sp.plan.jumps[e] = Jump(target: (if e.kind == exkBreak: lp.exit else: lp.head),
                            leaves: sp.leaving(depth))
    return
  for c in e.children: sp.jumpsIn(c)

# --- if, match, block -------------------------------------------------------------

proc ifStmt(sp: var Splitter, cur: var int, s: Expr) =
  sp.emitYields(cur, sp.yieldCount(s.cond))
  sp.hoistCuts(cur, s.cond)
  let cond = sp.hoisted(cur, s.cond, boolType())
  let join = sp.newStage()
  let thenS = sp.chain(s.thenBranch, join)
  let elseS = sp.chain(s.elseBranch, join)
  sp.plan.stages[cur].term = Term(kind: tkBranch, cond: cond, thenS: thenS, elseS: elseS)
  cur = join

proc matchStmt(sp: var Splitter, cur: var int, s: Expr) =
  ## The backend prints its own `case` on the subject; each arm's body is a
  ## jump carrier sending control to that arm's chain.
  sp.emitYields(cur, sp.yieldCount(s.subject))
  sp.hoistCuts(cur, s.subject)
  if sp.parksIn(s.subject):
    var t = sp.res.typeFor(s.subject)
    s.subject = sp.hoisted(cur, s.subject, t)
  let join = sp.newStage()
  var arms: seq[MatchArm]
  for arm in s.arms:
    let carrier = built(Expr(kind: exkBreak, span: arm.span))
    sp.plan.jumps[carrier] = Jump(target: sp.chain(arm.body, join))
    arms.add MatchArm(pattern: arm.pattern, span: arm.span,
                      body: Expr(kind: exkBlock, stmts: @[carrier], span: arm.span))
  sp.plan.stages[cur].stmts.add Expr(kind: exkMatch, subject: s.subject, arms: arms,
                                     span: s.span, id: s.id)   # the match's own id
  sp.plan.stages[cur].term = Term(kind: tkGoto, next: join)   # not reached: every arm jumps
  cur = join

proc blockStmt(sp: var Splitter, cur: var int, s: Expr) =
  ## A nested block is a scope of its own, entered directly.
  let join = sp.newStage()
  let entry = sp.chain(s, join)
  sp.plan.stages[cur].term = Term(kind: tkGoto, next: entry)
  cur = join

# --- loops ------------------------------------------------------------------------

proc intType(): Type = Type(kind: tkNamed, name: "int")

proc loopKind(sp: var Splitter, s: Expr): LoopKind =
  if s.kind == exkWhile: return lkWhile
  if s.iter == nil or s.iter.kind != pkVar:
    sp.fail(s, "a destructuring `for` whose body pauses")
  let it = s.iterable
  if it.kind == exkBinary and it.binOp in {boRangeIncl, boRangeExcl}: return lkRange
  if it.kind != exkVar: sp.fail(s, "a `for` over a computed sequence whose body pauses")
  lkSeq

proc loopState(sp: var Splitter, s: Expr, kind: LoopKind, k: int): Loop =
  result = Loop(kind: kind, node: s)
  case kind
  of lkRange:
    result.varName = s.iter.name
    result.stateField = "tuckEnd" & $k
    var t = sp.res.typeFor(s.iterable.left)
    if t == nil: t = intType()
    sp.addField(s, result.varName, t)
    sp.addField(s, result.stateField, t)
  of lkSeq:
    result.varName = s.iter.name
    result.stateField = "tuckIdx" & $k
    result.elemType = seqElem(sp.res.typeFor(s.iterable))
    sp.addField(s, result.stateField, intType())
  of lkWhile: discard

proc whileHead(sp: var Splitter, k: int, s: Expr) =
  ## A `for cond:` re-tests at its head, yielding first for an [io] call in
  ## the condition, every iteration; a `loop:` just goes round.
  var head = sp.plan.loops[k].head
  var cond = s.whileCond
  if cond != nil:
    sp.emitYields(head, sp.yieldCount(cond))
    sp.hoistCuts(head, s.whileCond)   # a frame call: run first, every iteration
    cond = sp.hoisted(head, s.whileCond, boolType())   # waits: on a helper
  let lp = sp.plan.loops[k]
  sp.plan.stages[head].term =
    if cond == nil: Term(kind: tkGoto, next: lp.body)
    else: Term(kind: tkBranch, cond: cond, thenS: lp.body, elseS: lp.exit)

proc loopBody(sp: var Splitter, k: int, s: Expr) =
  ## The body: a scope of its own, entered at `body`, ending in the step.
  let depth = sp.open.len
  sp.loopStack.add (k, depth)
  var cur = sp.plan.loops[k].body
  discard sp.openScope()
  let body = if s.kind == exkWhile: s.whileBody else: s.body
  if body != nil:
    sp.splitList(if body.kind == exkBlock: body.stmts else: @[body], cur)
  sp.plan.stages[cur].term = Term(kind: tkGoto, next: sp.plan.loops[k].head,
                                  leaves: sp.leaving(depth))
  sp.open.setLen depth
  discard sp.loopStack.pop()

proc loopStmt(sp: var Splitter, cur: var int, s: Expr) =
  let kind = sp.loopKind(s)
  if kind != lkWhile:
    sp.emitYields(cur, sp.yieldCount(s.iterable))
    if s.iterable.kind == exkBinary:
      sp.hoistCuts(cur, s.iterable.left)       # a range's ends, once
      sp.hoistCuts(cur, s.iterable.right)
    if sp.parksIn(s.iterable): sp.fail(s, "a loop range that waits")
  let k = sp.plan.loops.len
  sp.plan.loops.add sp.loopState(s, kind, k)
  sp.plan.loops[k].head = sp.newStage()
  sp.plan.loops[k].exit = sp.newStage()
  sp.plan.loops[k].body = sp.newStage()
  if kind == lkWhile: sp.whileHead(k, s)
  else: sp.plan.stages[sp.plan.loops[k].head].term = Term(kind: tkLoopNext, loop: k)
  sp.loopBody(k, s)
  sp.plan.stages[cur].term =
    if kind == lkWhile: Term(kind: tkGoto, next: sp.plan.loops[k].head)
    else: Term(kind: tkLoopEnter, loop: k)
  cur = sp.plan.loops[k].exit

# --- one statement ----------------------------------------------------------------

proc deferStmt(sp: var Splitter, cur: int, s: Expr) =
  ## A `defer` arms an exit action, run when its scope is left: by a jump
  ## out of it, or by the frame's end.
  if sp.pausesIn(s.deferBody): sp.fail(s, "a pause inside a `defer`")
  if sp.open.len > 0: sp.plan.scopeDefers[sp.open[^1]].add sp.plan.defers.len
  sp.plan.defers.add s
  sp.plan.stages[cur].stmts.add s

proc branchesPause(sp: Splitter, s: Expr): bool =
  sp.pausesIn(s.thenBranch) or sp.pausesIn(s.elseBranch)

proc inline(sp: var Splitter, cur: int, s: Expr) =
  ## A statement the backend prints as it is; its loop jumps become jumps.
  sp.jumpsIn(s)
  sp.plan.stages[cur].stmts.add s

proc nestedStmt(sp: var Splitter, cur: var int, s: Expr) =
  case s.kind
  of exkIf:
    if sp.branchesPause(s) or sp.parksIn(s.cond) or sp.framePausesIn(s.cond):
      sp.ifStmt(cur, s)
    else:
      sp.emitYields(cur, sp.yieldCount(s.cond))   # only the condition yields
      sp.inline(cur, s)
  of exkSelect:
    # A task's `on select` waits inside the runtime: the whole statement
    # runs on a helper, its one-line arms writing the frame's locals.
    sp.emitYields(cur, sp.yieldCount(s))
    sp.onStack(cur, s)
  of exkMatch: sp.matchStmt(cur, s)
  of exkFor, exkWhile: sp.loopStmt(cur, s)
  of exkBlock: sp.blockStmt(cur, s)
  else: sp.fail(s, "a pause inside " & ($s.kind)[3 .. ^1].toLowerAscii)

proc splitStmt(sp: var Splitter, cur: var int, s: Expr) =
  sp.noteLocal(s)
  if s.kind == exkDefer: sp.deferStmt(cur, s)
  elif not sp.pausesIn(s): sp.inline(cur, s)
  elif s.kind in Nested: sp.nestedStmt(cur, s)
  else: sp.simpleStmt(cur, s)

proc splitList(sp: var Splitter, stmts: seq[Expr], cur: var int) =
  for s in stmts: sp.splitStmt(cur, s)

proc planStages*(res: Resolution, m: Module, d: Decl): StagePlan =
  ## The stages of frame fn or task `d` (its lowered, mangled copy).
  var sp = Splitter(decl: d, res: res, m: m, isTask: d.kind == dkTask)
  var cur = sp.newStage()
  let body = d.fnBody
  if body != nil:
    sp.noteAwaits(body)
    discard sp.openScope()          # scope 0: the body, left only at the end
    sp.splitList(if body.kind == exkBlock: body.stmts else: @[body], cur)
  sp.plan
