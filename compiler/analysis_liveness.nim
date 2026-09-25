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
import ast, tables, sets, strutils
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
    ## ACCESS PATHS, not bare names: `b`, `b.ask`, `b.inner.xs`.
    ##
    ## A record's fields are separate buffers, and the copies that remain in
    ## the matching engine are there because the analysis could only say "b
    ## is still live" when the question was "is b.ask still live". Reading
    ## `b.n` does not keep `b.ask` alive, and a name-granular set cannot
    ## express that.
    ##
    ## A bare `b` in the set stands for EVERY path under it — reading the
    ## whole record reads all of it — so membership is prefix-aware
    ## (`isLive`) rather than a plain lookup.

  Ctx = object
    res: Resolution
    skip: HashSet[string]     ## fields, and anything a `defer` reads
    afterLoop: Live           ## what `break` jumps to
    atLoopHead: Live          ## what `continue` jumps to
    inLoop: bool

proc pathOf(e: Expr): string =
  ## `b.ask` for a field chain rooted at a name, `b` for a bare name, "" for
  ## anything else — an index, a call result, a literal. "" means the walk
  ## could not name this location, and the caller falls back to treating the
  ## whole root as used.
  if e == nil: return ""
  case e.kind
  of exkVar: e.name
  of exkField:
    let base = pathOf(e.receiver)
    if base.len == 0: "" else: base & "." & e.fieldName
  else: ""

proc rootOf(path: string): string =
  let i = path.find('.')
  if i < 0: path else: path[0 ..< i]

proc isLive(live: Live, path: string): bool =
  ## Is this location still wanted? A path is live if it is in the set, or if
  ## any PREFIX of it is — `b` being live means every field of b is.
  if path.len == 0: return true          # unnameable: assume the worst
  if path in live: return true
  var i = path.find('.')
  while i >= 0:
    if path[0 ..< i] in live: return true
    i = path.find('.', i + 1)
  # ...and a path is also live if something UNDER it is: `b` is wanted when
  # `b.ask` is, because the record is how you reach the field.
  for l in live:
    if l.len > path.len and l.startsWith(path & "."): return true
  false

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
  if e.kind == exkField:
    # A call written as a field (`a.total`, `n.toStr`) reads its RECEIVER;
    # it is not the place `a.total`. The SSA graph had this wrong and the
    # oracle agreed with it, so neither caught a move of `a` before `a.total`
    # read it (value_semantics, "a method-style call reads its receiver").
    if c.res.hasCall(e):
      uses(c, c.res.call(e), acc)
      return
    let p = pathOf(e)
    if p.len > 0:
      acc.incl(p)
      return
    # Not a nameable path (an index or a call in the chain): fall through and
    # let the receiver be used wholesale.
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

proc deadOf(used, live, skip: Live): Live =
  ## Which of these locations is nobody going to want again? Plain set
  ## difference is wrong once the set holds paths: `b.ask` is still wanted
  ## when `b` is live, and a `defer` naming `b` keeps every field of it.
  for p in used:
    if isLive(live, p): continue
    if p in skip or rootOf(p) in skip: continue
    result.incl(p)
  # A ROOT whose every path is dead is itself dead, and it has to be said
  # separately: `paramIsMovable` asks about the WHOLE parameter, not one of
  # its fields, so stamping only `e.num.value` silently dropped the `sink`
  # off every fn that reads a parameter through a field. `isLive` already
  # answers this — a root is live if anything under it is.
  for p in used:
    let r = rootOf(p)
    if r.len == 0 or r in result: continue
    if isLive(live, r) or r in skip: continue
    result.incl(r)

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
    if n.kind == exkField and c.res.hasCall(n):
      walk(c.res.call(n))      # a call written as a field: see `uses`
      return
    if n.kind == exkField:
      let p = pathOf(n)
      if p.len > 0:
        if p in dead: lastFor[p] = n
        # Keep descending: the ROOT may be dead as a whole, and its stamp is
        # what `paramIsMovable` reads.
        walk(n.receiver)
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
      stampSites(c, e.cond, deadOf(dead, r, c.skip))
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
      stampSites(c, e.subject, deadOf(dead, r, c.skip))
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
    if stamp: stampSites(c, e, deadOf(r, Live(), c.skip))
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
      stampSites(c, e, deadOf(r, liveOut, c.skip))
    var outp = liveOut
    if e.kind == exkAssign and e.target != nil and e.target.kind == exkVar:
      outp.excl(e.target.name)
    outp + r

proc markLivenessInto(res: Resolution, m: Module)

proc referenceFinalUses*(res: Resolution, m: Module): HashSet[NodeId] =
  ## THE ORACLE, not the pass. `ssa_liveness.markLivenessSsa` is what stamps
  ## `lastUses` now; this walk is kept, and run only under `--verify-stages`,
  ## as the independent answer the mirror is checked against.
  ##
  ## Keeping it costs a file that nothing on the hot path calls, and buys the
  ## only check on the mirror that is not the mirror's own opinion. When the
  ## two disagree one of them is wrong, and having both is how you find out
  ## which — that is how six builder bugs were found in an afternoon.
  let saved = res.lastUses
  res.lastUses = initHashSet[NodeId]()
  markLivenessInto(res, m)
  result = res.lastUses
  res.lastUses = saved

proc markLivenessInto(res: Resolution, m: Module) =
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
