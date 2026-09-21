# compiler/analysis_liveness.nim
#
# WHICH NAMES ARE STILL WANTED AFTER THIS POINT?
#
# This replaces the counting heuristic `analysis_lastuse.nim` used: it
# tallied every textual appearance of a name, stamped the last one, and
# refused to stamp ANYTHING appearing under a loop. Its own header called
# that loop rule "not an optimisation gap to close later for free", and it
# was right about why — a name read once per iteration is read again on the
# next one, so the textually-last occurrence is not dead there. The answer is
# not a better tally; it is to compute liveness properly and let the loop
# reach a fixpoint.
#
# WHY THIS NEEDS NO CONTROL-FLOW GRAPH. Tuck's control flow is entirely
# STRUCTURED — block, if, match, for, while, break, continue, return, raise,
# and nothing else. There is no goto and no exception that unwinds to an
# arbitrary handler, so every construct has one entry and a known set of
# exits, and a backward walk over the tree computes the same answer basic
# blocks would. Building a CFG would add a representation to keep in sync
# with the AST for no extra precision.
#
# WHY IT IS EXACT HERE AND APPROXIMATE ELSEWHERE. Liveness of a NAME is only
# liveness of a VALUE when nothing else can be holding that value. In C or
# C++ that needs alias analysis first; in Rust it needs the borrow graph.
# Tuck has no nil, no refs, and `let b = a` copies — so the name IS the
# value, and this walk is the whole answer rather than a first approximation.
#
# WHAT IS STILL DELIBERATELY NOT STAMPED, and each for its own reason:
#
#   ACTOR AND OBJECT FIELDS. Not locals: they outlive the body, so intra-body
#   liveness says nothing about them. They never reach this pass, because it
#   walks TOP-LEVEL `dkFn` and `dkTask` only — a handler body lives inside a
#   `dkActor` and is not visited. That is the scope the counting pass had and
#   it is kept deliberately: widening it would start stamping names that
#   codegen emits as `self.x`, where an intra-body answer is simply wrong.
#
#   A PLAIN WRITE TARGET. `x = e` stores into x without reading it, so the
#   write must not keep an earlier read from being the last one. `x[i] = e`
#   and `x.f = e` DO read x to find where to store, so those still count.
#
#   ANYTHING A `defer` BODY READS, anywhere in the enclosing scope. A defer
#   runs at scope exit, after the apparent last use of everything it touches,
#   so its reads are live throughout. This is the one place structured
#   control flow is less obliging than it looks.
import ast, tables, sets
import resolution
import ast_ops

const MaxLoopRounds = 8
  ## A loop's liveness is a fixpoint: what is live at the head depends on
  ## what the body leaves live, which depends on the head. The set only
  ## grows, and it is bounded by the names in the body, so this settles in
  ## two or three rounds. The cap is a guard against a shape the walk
  ## mishandles, and hitting it is answered by keeping everything live —
  ## which withholds stamps rather than granting wrong ones.

type
  Live = HashSet[string]

  Ctx = object
    res: Resolution
    skip: HashSet[string]     ## fields, and anything a `defer` reads
    afterLoop: Live           ## what `break` jumps to
    atLoopHead: Live          ## what `continue` jumps to
    inLoop: bool

proc uses(c: Ctx, e: Expr, acc: var Live)

proc usesOfAssign(c: Ctx, e: Expr, acc: var Live) =
  ## An assignment reads its value, and reads its target too UNLESS the
  ## target is a plain name.
  uses(c, e.assignVal, acc)
  if e.target != nil and e.target.kind != exkVar:
    uses(c, e.target, acc)

proc uses(c: Ctx, e: Expr, acc: var Live) =
  ## Every name this expression READS.
  if e == nil: return
  if e.kind == exkVar and e.name.len > 0:
    acc.incl(e.name)
    return
  if e.kind == exkAssign:
    usesOfAssign(c, e, acc)
    return
  for ch in e.children: uses(c, ch, acc)

proc collectDeferReads(c: var Ctx, e: Expr) =
  ## Everything any `defer` in this body reads is live for the whole body.
  if e == nil: return
  if e.kind == exkDefer:
    var d: Live
    uses(c, e.deferBody, d)
    for n in d: c.skip.incl(n)
  for ch in e.children: collectDeferReads(c, ch)

proc lastUseSites(c: Ctx, e: Expr, liveOut: Live, stamp: bool): Live

proc stampSites(c: Ctx, e: Expr, dead: Live) =
  ## Mark the FINAL read of each dead name inside `e`. Walks in evaluation
  ## order and keeps the last site seen, because `f(x, g(x))` reads x twice
  ## and only the second one may be moved from.
  if e == nil: return
  var lastFor: Table[string, Expr]
  proc walk(n: Expr) =
    if n == nil: return
    if n.kind == exkVar and n.name in dead:
      lastFor[n.name] = n
      return
    if n.kind == exkAssign:
      walk(n.assignVal)
      if n.target != nil and n.target.kind != exkVar: walk(n.target)
      return
    for ch in n.children: walk(ch)
  walk(e)
  for _, site in lastFor: markLastUse(c.res, site)

proc seqLive(c: Ctx, stmts: seq[Expr], liveOut: Live, stamp: bool): Live =
  ## A sequence, walked BACKWARD: each statement's liveOut is what the next
  ## one needs.
  result = liveOut
  for i in countdown(stmts.high, 0):
    result = lastUseSites(c, stmts[i], result, stamp)

proc loopLive(c: Ctx, cond, body: Expr, liveOut: Live, stamp: bool): Live =
  ## A loop, to a fixpoint. The body may run again, so anything the NEXT
  ## iteration reads is live at the end of this one — which is exactly what
  ## the old pass could not express and why it vetoed loops outright.
  var head = liveOut
  for _ in 0 ..< MaxLoopRounds:
    var c2 = c
    c2.inLoop = true
    c2.afterLoop = liveOut
    c2.atLoopHead = head
    var inner = lastUseSites(c2, body, head, false)
    uses(c, cond, inner)
    inner = inner + liveOut
    if inner == head: break
    head = inner
  if stamp:
    var c2 = c
    c2.inLoop = true
    c2.afterLoop = liveOut
    c2.atLoopHead = head
    discard lastUseSites(c2, body, head, true)
  head

proc lastUseSites(c: Ctx, e: Expr, liveOut: Live, stamp: bool): Live =
  ## Liveness flowing backward through one statement, stamping as it goes.
  if e == nil: return liveOut
  case e.kind
  of exkBlock:
    seqLive(c, e.stmts, liveOut, stamp)
  of exkIf:
    # Both arms see the same liveOut; the condition is read before either.
    let a = lastUseSites(c, e.thenBranch, liveOut, stamp)
    let b = lastUseSites(c, e.elseBranch, liveOut, stamp)
    var r = a + b
    if stamp:
      var dead: Live
      uses(c, e.cond, dead)
      stampSites(c, e.cond, dead - r - c.skip)
    uses(c, e.cond, r)
    r
  of exkMatch:
    var r: Live
    var any = false
    for arm in e.arms:
      var armOut = liveOut
      if arm.guard != nil: uses(c, arm.guard, armOut)
      let a = lastUseSites(c, arm.body, armOut, stamp)
      r = if any: r + a else: a
      any = true
    if not any: r = liveOut
    if stamp:
      var dead: Live
      uses(c, e.subject, dead)
      stampSites(c, e.subject, dead - r - c.skip)
    uses(c, e.subject, r)
    r
  of exkWhile: loopLive(c, e.whileCond, e.whileBody, liveOut, stamp)
  of exkFor:
    var r = loopLive(c, nil, e.body, liveOut, stamp)
    uses(c, e.iterable, r)
    r
  of exkBreak: c.afterLoop
  of exkContinue: c.atLoopHead
  of exkReturn, exkRaise:
    # An exit: nothing after it is live, only what it reads itself.
    var r: Live
    uses(c, e, r)
    if stamp: stampSites(c, e, r - c.skip)
    r
  of exkDefer:
    # Its reads were hoisted into `skip` for the whole body, so it neither
    # stamps nor kills here.
    liveOut
  else:
    var r: Live
    uses(c, e, r)
    if stamp:
      # A name this statement reads and nothing after it wants is dead here.
      # A plain `x = ...` also KILLS x, but only for statements before it.
      stampSites(c, e, r - liveOut - c.skip)
    var outp = liveOut
    if e.kind == exkAssign and e.target != nil and e.target.kind == exkVar:
      outp.excl(e.target.name)
    outp + r

proc markLiveness*(res: Resolution, m: Module) =
  ## Stamp every last use in every body this module declares.
  for d in m.decls:
    if d == nil: continue
    var body: Expr
    case d.kind
    of dkFn: body = d.fnBody
    of dkTask: body = d.taskBody
    else: discard
    if body == nil: continue
    var c = Ctx(res: res)
    collectDeferReads(c, body)
    var empty: Live
    discard lastUseSites(c, body, empty, true)
