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
#   TAKES THE TWIN   the call may hand its first argument over to be consumed:
#                    it is dead here (`isMovedArg`, stamped by provenance) and
#                    the call is not a member call (members get no twin).
#   THREADED         `x = f(x, ...)`, or `let y = f(b.ask, ...)` with `b.ask`
#                    dead: the result may skip its fix-up copy, because it can
#                    only be the moved argument or fresh storage — unless
#                    another argument the caller still reads could be it.
#
# Both were answered by the Odin and D emitters as they printed, from
# predicates in codegen_common — the decision made while building a string,
# where nothing before emission could see it, and the two emitters each
# derived a member call's receiver type their own way. This pass records the
# answer on the node; the emitters print it.
#
# Runs as step 7 of `backend_prepare`, after the copy marks (where provenance
# stamps the moved arguments) and after `fillIds` (it keys by node id), on the
# aliasing backends only.
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

proc otherArgLives(res: Resolution, m: Module, call: Expr): bool =
  ## Does any argument BESIDES the first still hold a container the caller
  ## will read again? Then the callee's result may BE that container, and
  ## the copy that separates them cannot be dropped.
  for i in 1 ..< call.args.len:
    let a = call.args[i]
    if a == nil: continue
    if not ownsHeap(m, res.typeFor(a)): continue
    if res.isLastUse(a): continue   # dead too, so nothing observes the share
    return true
  false

proc movedCallInto(res: Resolution, m: Module, call: Expr,
                   targetName: string): bool =
  ## Is `call` a threaded-container call whose FIRST argument may be handed
  ## over — its result then needing no fix-up copy?
  ##
  ## THE SYNTACTIC CASE: `x = f(x, ...)` overwrites its own argument, so the
  ## old value is dead the instant the new one lands. No liveness involved.
  ##
  ## THE ANALYSED CASE, for everything else: a value this body OWNS and will
  ## not read again, which `analysis_provenance` stamps as a moved argument —
  ## `sweep(b.ask, ...)` at PATH granularity, `pass(a, ...)` for a plain local
  ## dead after the call (EV-15). Being a last use says nobody HERE reads it
  ## again, which on D and Odin says nothing about the caller whose buffer a
  ## container parameter aliases; provenance joins the two.
  ##
  ## ...AND NO OTHER ARGUMENT MAY STILL BE LIVE. Reaching the twin is one
  ## decision; SKIPPING THE RESULT'S FIX-UP COPY is a second, resting on the
  ## result being unable to alias anything the caller still reads:
  ##
  ##     fn pick({p: Seq[int], q: Seq[int], which: int}) -> Seq[int]:
  ##       if which == 0: return p
  ##       return q
  ##
  ## is twinnable on `p` and returns `q`; dropping the copy of its result
  ## came back 65 instead of 17 on D and Odin (value_semantics).
  if call == nil or call.kind != exkCall: return false
  if call.callee == nil or call.callee.kind != exkVar: return false
  if movedFnParam(res, m, m.findFn(call.callee.name)) == "": return false
  if call.args.len < 1 or call.args[0] == nil: return false
  let a = call.args[0]
  if a.kind == exkVar and a.name == targetName: return true
  if a.kind in {exkVar, exkField}:
    return res.isMovedArg(a) and not otherArgLives(res, m, call)
  false

proc decideTakesTwin(res: Resolution, m: Module, e: Expr): bool =
  ## May this call take its first argument destructively, at ANY position?
  ## The one that matters beyond an assignment is RETURN:
  ## `return {sl: up, c: c} relight` with `up` dead there and owned — no
  ## assignment emitter ever sees that call.
  e.kind == exkCall and e.callee != nil and e.callee.kind == exkVar and
    e.args.len > 0 and e.args[0] != nil and
    movedFnParam(res, m, m.findFn(e.callee.name)) != "" and
    res.isMovedArg(e.args[0]) and memberCallee(res, m, e) == ""

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

proc assertVisited(e: Expr, what: string) =
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
