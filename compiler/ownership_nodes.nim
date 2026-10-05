# compiler/ownership_nodes.nim
#
# OWNERSHIP DECISIONS, MADE INTO NODES — Stage C of the ownership rules
# (thoughts/shared/plans/2026-10-05-ownership-rules-proposal.md, §8).
#
# The rules say every read is a borrow or a sink, and every owned place is
# dropped once. Today those decisions are spread over predicates the
# emitters ask while they print — "is this assignment an append?", "does
# this binding need a copy?", "free the old value here?" — so the decision
# exists only in the string a backend built, where nothing after it can see
# it and three backends each re-derive it their own way. Stage C turns each
# decision into an AST node the pass makes once and every emitter prints.
# Stage D then makes the same nodes from the rules instead of from today's
# predicates, and a differential compares the two.
#
# FIRST NODE: `exkAppend` — `xs += v`, a container grown in place.
#
#   `xs = {items: xs, value: v} push`  an append assigned back over its own
#                                     argument (ast_query.selfAppendValue)
#   `s = s + t` on a str              a concat assigned back over its own LEFT
#                                     operand (ast_query.selfConcatValue) — on
#                                     a backend whose strings grow in place
#
# Both are rule S at the one place it is syntactic: the old value is dead the
# instant the new one lands, so its last read is a SINK into the new value,
# and a sink into a value built from it is a growth in place. The emitters
# used to recognise both shapes while printing (Nim twice, D twice, Odin
# once); the decision now lives here and they print `exkAppend`.
#
# RUNS LAST in `backend_prepare`, after every pass that reads the assignment
# it replaces: the copy marks and provenance (which ask selfAppendValue
# themselves, to learn that `xs` keeps its buffer), ownership and the twin
# marks. The node keeps the assignment's id, so every fact recorded against
# the statement — its type (void), a shortcut site — stays attached.
#
# IT SAYS SO. The SSA cache asserts a body's shape has not changed since its
# lowered graph was built; a pass that rewrites a body after that must drop
# the graph, or the next fetch fails as "a pass rewrote it without saying
# so". No consumer fetches the lowered graph after this pass today; dropping
# it keeps that true by construction rather than by luck.
import tables
import ast, ast_ops, ast_query
import resolution
import ssa_ir

proc materializeAppend(n: Expr, parts: tuple[read, value: Expr],
                       element: bool) =
  ## `n` becomes `target += value`, IN PLACE: the node object keeps its
  ## position in every parent, and its id.
  ##
  ## THE TARGET IS THE READ, not the assignment's target. `xs += v` both reads
  ## and writes `xs`, and every fact about the read — that it is `xs`'s final
  ## use, that `xs` is an actor's field — was recorded against the READ node
  ## (`items: xs`, or the concat's left operand), keyed by its id. Keeping the
  ## write node instead dropped the final-use stamp with the payload it sat
  ## in, and Nim's `sink` inference (codegen_common.keptAt) stopped seeing
  ## `std/string`'s `add` keep its `text`.
  n[] = Expr(span: n.span, id: n.id, sourceName: n.sourceName,
             kind: exkAppend, appendTarget: parts.read,
             appendValue: parts.value, appendsElement: element)[]

proc materialize(res: Resolution, n: Expr, strGrows: bool): bool =
  ## Rewrites `n` if it is an append assigned back over its own argument.
  let pushed = selfAppendParts(res, n)
  if pushed.value != nil:
    materializeAppend(n, pushed, element = true)
    return true
  if not strGrows: return false
  let concatenated = selfConcatParts(res, n)
  if concatenated.value == nil: return false
  materializeAppend(n, concatenated, element = false)
  true

proc materializeAppends*(res: Resolution, m: Module, strGrows: bool) =
  ## Every append assigned back over its own argument becomes `exkAppend`.
  ## `strGrows`: the backend's `str` grows in place (Nim, D — not Odin, whose
  ## strings are a pointer and a length, so `s = s + t` stays a concat and a
  ## free of the old value).
  for d in m.allDecls:
    var changed = false
    for body in d.ownExprs:
      if body == nil: continue
      for n in body.nodes:
        if n.kind == exkAssign and materialize(res, n, strGrows):
          changed = true
    if changed and d.id.isSet:
      res.ssaGraphs.del((d.id, ssLowered))
