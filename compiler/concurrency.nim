## HOW tasks and actors pause — one choice per build, made on the CLI
## (`--concurrency:stackful|stackless`, #216, docs/stackless-concurrency.md).
##
## The SEMANTICS are identical: the same pause points, the same order, the
## same results. What changes is the machinery:
##
##   stackful   every task is a minicoro coroutine with its own mmap'd stack;
##              a pause switches stacks. The default, and what every emitted
##              file under examples/ is.
##   stackless  a fn that can pause becomes a FRAME (its locals, on the heap)
##              and STAGES (the code between pauses); a pause returns to a
##              driver loop. No stacks, no stack switching. Phase 2: tasks on
##              the Nim backend.
##
## The plan — which decls become frames — is computed once, from the checked
## program and before mangling (compiler/frames.nim), and read by codegen
## by decl id, which every backend's deep copy keeps.
import std/sets
import ast, ast_ops

type
  ConcurrencyMode* = enum
    cmStackful = "stackful"
    cmStackless = "stackless"

var concurrencyMode* = cmStackful
var helperDecls*: HashSet[NodeId]
  ## Under stackless: generic fns that may wait. Never frames (a frame type
  ## would be generic); a call to one runs on a helper stack.
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
