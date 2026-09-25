# compiler/lowering_strtemps.nim
#
# NAME THE UNNAMED `str` — so a temporary the runtime allocated has an owner.
#
#     let t = s + "-" + s
#
# On a backend whose runtime hands the CALLER the storage of a new string
# (Odin: `strings.concatenate`, `fmt.aprint`, ...), the inner `s + "-"` is a
# buffer nobody holds: it is consumed by the outer concatenation and never
# bound to a name, so the ownership pass — which frees LOCALS — never sees
# it. The cross-backend memory bench (benches/memory) found it: 2 million
# turns of the line above leaked 123 MB on Odin, and twice that at twice the
# turns, while Nim and D held 1-4 MB.
#
# The fix is to make it a local:
#
#     let tuckStrTmp1 = s + "-"
#     let t = tuckStrTmp1 + s
#
# after which step 4 of the ownership pass frees it at scope exit like any
# other `str` it allocated — one rule, no second mechanism for temporaries.
#
# WHAT MAY MOVE. Hoisting evaluates an expression EARLIER than it was
# written, ahead of the rest of its statement. That is only invisible when
# nothing evaluated before it in that statement could observe the order, so:
#   * only expressions evaluated unconditionally, exactly once: never inside
#     an `if`/`match` expression's arms, the right side of `and`/`or`, a
#     `while` condition, or any nested block;
#   * never past a call with effects: once one has been evaluated (in
#     evaluation order), nothing later in the statement is hoisted;
#   * never the statement's own value — `let t = <that>` already names it,
#     and a returned string belongs to the caller.
# Anything outside those lines stays where it is and leaks as before; the
# direction of failure is a leak, never a reordering.
#
# ONLY WHERE IT IS NEEDED: `backend_prepare` runs this when the backend's list
# of allocating procs is non-empty (Odin). Nim's ARC and D's GC free a
# temporary themselves, and their output stays as it was.
import ast, ast_ops, ast_query
import resolution
from ownership_str import ownedStrCall

var counter = 0
  ## Names are program-wide unique, like every other lowering-minted name.

type Hoist = object
  res: Resolution
  procs: seq[string]
  lifted: seq[Expr]    ## `let`s to insert ahead of the current statement
  settled: bool        ## an effect has been evaluated: nothing later moves

proc isStr(t: Type): bool = t != nil and t.kind == tkNamed and t.name == "str"

proc hasEffect(h: Hoist, n: Expr): bool =
  ## A call that is not one of the allocating `str` procs may do anything,
  ## including observe that a later expression ran first. A field or index
  ## the checker resolved to a call is one.
  let isCall = n.kind == exkCall or
               (n.kind in {exkField, exkBracket, exkBracketAssign} and
                h.res.hasCall(n))
  isCall and not ownedStrCall(h.res, h.procs, n)

proc lift(h: var Hoist, n: Expr) =
  ## `n` becomes a read of a new name, and what it was moves into a `let`.
  ##
  ## IN PLACE: the node object keeps its position, so anything that shares it
  ## — a resolved call whose argument IS this node — reads the name too. The
  ## expression moves to a new object carrying the OLD id, so everything the
  ## checker recorded about it stays attached.
  inc counter
  let name = "tuckStrTmp" & $counter
  let t = h.res.typeFor(n)
  let val = Expr()
  val[] = n[]
  n[] = Expr(span: val.span, kind: exkVar, name: name)[]
  h.res.setType(n, t)
  let target = Expr(span: val.span, kind: exkVar, name: name)
  h.res.setType(target, t)
  h.lifted.add Expr(span: val.span, kind: exkAssign, target: target,
                    assignVal: val, isDecl: true)

proc visit(h: var Hoist, n: Expr, own: bool) =
  ## Evaluation order: operands first, then the node. `own` marks the
  ## statement's own value, which is never lifted.
  if n == nil: return
  case n.kind
  of exkIf, exkMatch, exkBlock, exkWhile, exkFor, exkDefer, exkSelect,
     exkChain, exkCombinator, exkAssign, exkBracketAssign, exkSend,
     exkReturn, exkRaise, exkAcquire, exkFinish, exkDiscard:
    # Control flow, a scope, or a statement inside an expression: what is in
    # it is conditional, or ordered by something this pass does not model.
    # It may also do anything, so nothing after it may move before it.
    h.settled = true
    return
  of exkBinary:
    h.visit(n.left, false)
    if n.binOp in {boAnd, boOr}:
      h.settled = true           # the right side runs only sometimes
      return
    h.visit(n.right, false)
  of exkUnary:
    h.visit(n.operand, false)
    if n.unaryOp == uoPropagate: h.settled = true   # `x?` may return early
  of exkLit, exkVar, exkField, exkQualified, exkStruct, exkList, exkBracket,
     exkCall, exkBreak, exkContinue, exkTripleDot, exkImport, exkActorRef,
     exkRegisterRef, exkRegistryRef, exkPoolRef, exkMixinRef, exkOrdinal:
    for ch in n.children: h.visit(ch, false)
  if h.settled: return
  if not own and isStr(h.res.typeFor(n)) and ownedStrCall(h.res, h.procs, n):
    h.lift(n)
  elif h.hasEffect(n):
    h.settled = true

proc hoistStmt(h: var Hoist, s: Expr): seq[Expr] =
  ## The `let`s a statement's temporaries need, ahead of it.
  h.lifted = @[]
  h.settled = false
  case s.kind
  of exkAssign: h.visit(s.assignVal, true)
  of exkReturn: h.visit(s.returnVal, true)
  of exkDiscard: h.visit(s.discardVal, true)
  of exkCall: h.visit(s, true)          # a call for its effect
  of exkIf: h.visit(s.cond, false)      # evaluated once, before a branch
  of exkMatch: h.visit(s.subject, false)
  of exkFor: h.visit(s.iterable, false)
  of exkSend:
    # The payload is COPIED into the message (EV-13), so a temporary in it
    # is dead once the send is done.
    h.visit(s.sendPayload, false)
  else: discard                         # a `while` condition runs every turn
  h.lifted

proc hoistBlock(h: var Hoist, b: Expr)

proc hoistNested(h: var Hoist, s: Expr) =
  ## The blocks a statement owns, each hoisted within itself.
  case s.kind
  of exkIf:
    h.hoistBlock(s.thenBranch)
    h.hoistBlock(s.elseBranch)
  of exkWhile: h.hoistBlock(s.whileBody)
  of exkFor: h.hoistBlock(s.body)
  of exkMatch:
    for arm in s.arms: h.hoistBlock(arm.body)
  of exkDefer: h.hoistBlock(s.deferBody)
  else: discard

proc hoistBlock(h: var Hoist, b: Expr) =
  ## Every statement of a block, with its temporaries named just ahead of it.
  ## A body that is not a block holds a single expression, where there is
  ## nowhere to put a statement; it is left alone.
  if b == nil or b.kind != exkBlock: return
  var stmts: seq[Expr]
  for s in b.stmts:
    if s == nil:
      stmts.add s
      continue
    for l in h.hoistStmt(s): stmts.add l
    h.hoistNested(s)
    stmts.add s
  b.stmts = stmts

proc hoistStrTemps*(res: Resolution, m: Module, procs: seq[string]) =
  ## Name every nested allocating `str` expression in this module's bodies.
  ## `procs` is the backend's list (backend_prepare.ownedStrProcs); empty,
  ## there is nothing to own and nothing changes.
  if procs.len == 0: return
  var h = Hoist(res: res, procs: procs)
  for fn in m.allFns(): h.hoistBlock(fn.fnBody)
  for d in m.decls(dkTask): h.hoistBlock(d.taskBody)
