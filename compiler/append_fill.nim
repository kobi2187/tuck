# compiler/append_fill.nim
#
# A LOOP THAT FILLS A SEQ: reserve it once, then store (issue #210).
#
#   var out: Seq[u8] = []
#   for i in 0 ..< n:
#     out = {items: out, value: f(i)} push       # one push per iteration
#
# Every push asks "is there room?" and, when there is not, moves the block.
# This loop knows how many times it will ask: n. So it asks once, before the
# loop, and the pushes inside it store without asking. On D, where an append
# is a runtime call costing ~35 ns (reverse-complement, pidigits and fasta
# are 15x C there), it is the difference between a call and a store; on Nim
# it is the check and the reallocations.
#
# The program is unchanged and the author wrote nothing new. The decision
# is a property of the loop, read off the tree:
#
#   - a `for` over a range whose bounds are plain names, numbers and their
#     arithmetic: evaluating one twice (once to reserve, once to loop) does
#     nothing anyone can see
#   - a body that cannot leave early (no break, continue, return, raise):
#     every iteration reaches its push, so the room reserved is the room used
#   - a push at the top of the body's own statements (not inside an `if`),
#     to a local that is not declared in the body
#   - and the local mentioned nowhere else in the body: not read (it would see
#     a length the loop has not reached), not passed on, not pushed twice
#
# `fillTargets` on the loop names what to reserve; each qualifying push is
# marked `appendFilled`. Every emitter prints both; a backend whose append is
# already a plain store may print the mark as the push it always was.
import ast, ast_ops, ast_query
import resolution

proc simpleBound(res: Resolution, e: Expr): bool =
  ## Names, numbers and arithmetic: evaluating it twice changes nothing.
  if e == nil: return false
  case e.kind
  of exkLit: e.litKind == lkInt
  of exkVar: true
  of exkField:
    e.dotArg == nil and not res.hasCall(e) and e.receiver != nil and
      res.simpleBound(e.receiver)
  of exkBinary:
    e.binOp in {boAdd, boSub, boMul} and res.simpleBound(e.left) and
      res.simpleBound(e.right)
  else: false

proc countedRange(res: Resolution, loop: Expr): bool =
  ## `for i in lo ..< hi` / `lo .. hi`, with bounds that can be read twice.
  let r = loop.iterable
  r != nil and r.kind == exkBinary and r.binOp in {boRangeExcl, boRangeIncl} and
    res.simpleBound(r.left) and res.simpleBound(r.right)

proc leavesEarly(body: Expr): bool =
  for n in body.nodes:
    if n.kind in {exkBreak, exkContinue, exkReturn, exkRaise}: return true

proc mentions(body: Expr, name: string): int =
  for n in body.nodes:
    if n.kind == exkVar and n.name == name: inc result

proc declaredIn(body: Expr, name: string): bool =
  for n in body.nodes:
    if n.kind == exkAssign and n.isDecl and n.target != nil and
       n.target.kind == exkVar and n.target.name == name: return true

proc fillable(res: Resolution, body: Expr, push: Expr): bool =
  ## Is this top-level push the only thing the body does with its target?
  let t = push.appendTarget
  push.appendsElement and t != nil and t.kind == exkVar and
    not res.isOwnerField(t) and body.mentions(t.name) == 1 and
    not body.declaredIn(t.name)

proc markLoop(res: Resolution, loop: Expr) =
  if loop.body == nil or loop.body.kind != exkBlock or
     not res.countedRange(loop) or loop.body.leavesEarly: return
  for s in loop.body.stmts:
    if s != nil and s.kind == exkAppend and res.fillable(loop.body, s):
      s.appendFilled = true
      loop.fillTargets.add s.appendTarget

proc markFills*(res: Resolution, m: Module) =
  ## Run after the appends are made (`materializeAppends`).
  for body in m.bodies:
    for n in body.nodes:
      if n.kind == exkFor: res.markLoop(n)
