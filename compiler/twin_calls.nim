# compiler/twin_calls.nim
#
# WHICH CALLS TAKE THE MOVED TWIN — decided once, per backend tree, before
# any emitter runs (ROADMAP M3.5).
#
# A fn that threads a container through it (`f(c, ...) -> c`) is emitted twice
# on the backends whose containers alias: `f_moved`, free to consume its first
# parameter, and a wrapper `f` that copies and delegates. Two decisions sit on
# every call to such a fn:
#
#   TAKES THE TWIN   every call that is not a member call (members get no
#                    twin): the twin is the body itself, and the caller
#                    copies a live argument or moves a dead one (rule S at a
#                    consuming parameter), so the copying wrapper is only
#                    the entry for a fn value or an interface arm.
#   THREADED         `x = f(x, ...)`: the assignment is printed as the twin
#                    call stored back over its own argument.
#
# Both were answered by the Odin and D emitters as they printed, from
# predicates in codegen_common — the decision made while building a string,
# where nothing before emission could see it, and the two emitters each
# derived a member call's receiver type their own way. This pass records the
# answer on the node; the emitters print it.
#
# Runs as step 7 of `backend_prepare`, after `fillIds` (it keys by node id),
# on every backend's tree (Nim prints no twins, and does not ask).
#
# EVERY NODE AN EMITTER ASKS ABOUT MUST HAVE BEEN VISITED. The emitters print
# calls this walk may not reach — one they synthesize, or one hanging off a
# table the walk does not follow — and an unvisited call reads as "no twin",
# a silent slowdown rather than an error. So `callsTwin` and `threadedCall`
# assert the node was seen.
import tables, sets
import ast, ast_ops, ast_query
import resolution
import twin_shape

var takesTwin: HashSet[NodeId]
  ## calls that call the moved twin, by the call node's id
var threaded: Table[NodeId, Expr]
  ## assignments that thread a container through a twin: assignment -> call
var visited: HashSet[NodeId]
  ## every node the walk decided about, so an emitter's question about one it
  ## never saw fails loudly

proc movedCallInto(res: Resolution, m: Module, call: Expr,
                   targetName: string): bool =
  ## Is `call` a threaded-container call whose FIRST argument is the name it
  ## is assigned back over (`x = f(x, ...)`)? The old value is dead the
  ## instant the new one lands.
  if call == nil or call.kind != exkCall: return false
  if call.callee == nil or call.callee.kind notin {exkVar, exkQualified}: return false
  if movedFnParam(res, m, calleeDecl(res, m, call)) == "": return false
  call.args.len >= 1 and call.args[0] != nil and
    call.args[0].kind == exkVar and call.args[0].name == targetName

proc decideTakesTwin(res: Resolution, m: Module, e: Expr): bool =
  ## May this call take its first argument destructively, at ANY position?
  ## The one that matters beyond an assignment is RETURN:
  ## `return {sl: up, c: c} relight` with `up` dead there and owned — no
  ## assignment emitter ever sees that call.
  e.kind == exkCall and e.callee != nil and e.callee.kind in {exkVar, exkQualified} and
    e.args.len > 0 and e.args[0] != nil and
    movedFnParam(res, m, calleeDecl(res, m, e)) != "" and
    memberCallee(res, m, e) == ""

proc decideThreaded(res: Resolution, m: Module, e: Expr): Expr =
  ## `x = f(x, ...)`, or `let y = f(b.ask, ...)` with `b.ask` never read
  ## again: the CALL, or nil. Declarations are accepted — `let f = sweep(
  ## b.ask, ...)` is how the matching engine threads its ladders.
  if e.kind != exkAssign or e.target == nil or e.target.kind != exkVar:
    return nil
  var call = e.assignVal
  if call != nil and res.hasCall(call): call = res.call(call)
  if movedCallInto(res, m, call, e.target.name): call else: nil

proc decide(res: Resolution, m: Module, n: Expr) =
  ## Makes both decisions for one node and marks it visited, so an emitter
  ## asking about a node the pass never reached is caught by `assertVisited`.
  if not n.id.isSet: return
  visited.incl n.id
  if decideTakesTwin(res, m, n): takesTwin.incl n.id
  let c = decideThreaded(res, m, n)
  if c != nil: threaded[n.id] = c

proc markIn(res: Resolution, m: Module, body: Expr) =
  ## Every node in a body, and every call a node PRINTS AS — the emitters
  ## print `res.call(n)` in its place, so that is a node they ask about.
  ## The checker builds those calls without ids (`server.start` stamped as
  ## `start(server)`); they get one here, or the decision has no key.
  var stack = @[body]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil: continue
    for ch in n.children: stack.add ch
    if n.kind != exkCall and res.hasCall(n):
      let c = res.call(n)
      fillIdsIn(c)
      stack.add c
    decide(res, m, n)

proc markTwinCalls*(res: Resolution, m: Module) =
  ## Decide both, for EVERY body of this backend's copy of the module, so an
  ## actor handler, a member fn or a select arm is reached as surely as a
  ## top-level fn.
  for e in m.bodies: markIn(res, m, e)

proc markBuilt*(e: Expr) =
  ## Nodes built after this pass by one that knows they take no twin (the
  ## bindings and resets ownership_write inserts): decided, as "no twin".
  for n in e.nodes:
    if n.id.isSet: visited.incl n.id

proc assertVisited(e: Expr, what: string) =
  ## Fails loudly when an emitter asks `what` about a node this pass never
  ## visited — built after `prepare`, or unreachable by the walk — instead of
  ## quietly answering "no twin".
  let callee = if e.kind == exkCall and e.callee != nil and
                  e.callee.kind == exkVar: " to '" & e.callee.name & "'"
               else: ""
  doAssert e.id.isSet and e.id in visited,
    "twin_calls: an emitter asked " & what & " about a " & $e.kind & callee &
    " the pass never visited" & (if e.id.isSet: "" else: " (it has no id)") &
    " — a node built after `prepare`, or one the walk does not reach. Mark " &
    "it, or it silently misses the twin."

proc callsTwin*(e: Expr): bool =
  ## Does this call call the moved twin?
  assertVisited(e, "callsTwin")
  e.id in takesTwin

proc threadedCall*(e: Expr): Expr =
  ## The call this assignment threads through a moved twin, or nil.
  assertVisited(e, "threadedCall")
  threaded.getOrDefault(e.id, nil)
