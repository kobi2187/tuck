## HOW tasks and actors pause — one choice per build, made on the CLI
## (`--concurrency:stackful|stackless`, #216, docs/stackless-concurrency.md).
##
## The SEMANTICS are identical: the same pause points, the same order, the
## same results. What changes is the machinery:
##
##   stackless  THE DEFAULT (ruled 2026-11-10). A fn that can pause becomes a
##              FRAME (its locals) and STAGES (the code between pauses); a
##              pause returns to a driver loop. No stack per task, no stack
##              switch; a statement that waits inside the runtime borrows a
##              pooled helper stack while it waits. What examples/ tracks.
##   stackful   every task is a minicoro coroutine with its own mmap'd stack;
##              a pause switches stacks. Kept for debugging: a debugger shows
##              a task's real call stack, where a stage's ends at the driver.
##              examples/stackful/ tracks its output where it differs.
##
## The plan — which decls become frames — is computed once, from the checked
## program and before mangling (compiler/frames.nim), and read by codegen
## by decl id, which every backend's deep copy keeps.
import std/[sets, tables]
import ast, ast_ops

type
  ConcurrencyMode* = enum
    cmStackful = "stackful"
    cmStackless = "stackless"

var concurrencyMode* = cmStackless
var helperDecls*: HashSet[NodeId]
  ## Under stackless: generic fns that may wait. Never frames (a frame type
  ## would be generic); a call to one runs on a helper stack.
var pureActorDecls*: HashSet[NodeId]
  ## Under stackless: actors no handler or select arm of which can pause.
  ## With --actors:single each runs as a frame on main's scheduler.
var framesStatic* = false
  ## `--frames:static` (#219): every frame must be embedded — in its caller,
  ## its awaiter, main's stack or an actor's slot — and no statement may
  ## borrow a helper stack. The build fails, naming each reason, otherwise.
var frameScc*: Table[NodeId, int]
  ## Under stackless: each decl's call-graph component (frames.nim). A frame
  ## call or task await between two components EMBEDS the callee's frame in
  ## the caller's; one inside a component (recursion) keeps the heap (#219).
var frameDecls*: HashSet[NodeId]
  ## Under stackless: the ids of the decls that are frames (tasks, and fns a
  ## root reaches that can pause).

proc parseConcurrencyMode*(name: string): (ConcurrencyMode, bool) =
  for m in ConcurrencyMode:
    if $m == name: return (m, true)
  (cmStackful, false)

proc isFrameDecl*(d: Decl): bool =
  ## Is `d` emitted as a frame and stages in this build?
  concurrencyMode == cmStackless and d != nil and d.id.isSet and d.id in frameDecls

proc drainsFrames*(hasTasks: bool): bool =
  ## Does the entry point run leftover frames before the coroutine loop? A
  ## stackless program with tasks does: a spawned task nobody awaited must
  ## still run to its end. Kept here so the three entry points add no
  ## branch of their own for it.
  hasTasks and concurrencyMode == cmStackless

proc actorStarter*(d: Decl): string =
  ## The runtime proc that starts actor `d`: a pure actor under stackless
  ## starts as a frame (the runtime decides per `--actors:` mode; only
  ## `single` makes it one), every other as before.
  if concurrencyMode == cmStackless and d != nil and d.id.isSet and d.id in pureActorDecls:
    "tuckStartActorFrame"
  else: "tuckStartActor"

proc embeds*(caller, callee: Decl): bool =
  ## Does a call from frame `caller` to frame `callee` build the callee's
  ## frame inside the caller's (no heap)? Yes unless the two are on one
  ## call cycle, where the frame types would contain each other.
  if caller == nil or callee == nil or not caller.id.isSet or not callee.id.isSet: return false
  if caller.id notin frameScc or callee.id notin frameScc: return false
  caller.id != callee.id and frameScc[caller.id] != frameScc[callee.id]
