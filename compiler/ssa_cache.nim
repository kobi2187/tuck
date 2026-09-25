# compiler/ssa_cache.nim
#
# THE ONE PLACE A BODY'S SSA GRAPH IS BUILT.
#
# Every consumer asks `ssaOf(res, d, stage)`. Before this, each built its
# own: a compile of world_server for Odin built 129 graphs for 19 bodies —
# stamping liveness, checking it, and then provenance rebuilding every body
# for each of the two times it ran after lowering. Each rebuild was also a
# chance to answer differently, which is the bug class the spine exists to
# remove.
#
# Stored in `Resolution.ssaGraphs`, keyed by the body's declaration id and
# the STAGE the graph describes (ssa_ir.SsaStage). Two stages exist because
# lowering rewrites the tree: a graph of what the user wrote is not a graph
# of what the backend prints.
#
# THE FINGERPRINT. A cache over a tree that later passes mutate is a stale
# answer waiting to happen. Each entry records the body's shape — every node
# kind, and the id of every node the graph indexes — and every fetch
# recomputes and asserts it.
# Walking a body is a small fraction of building its graph, so the check
# stays on.
import hashes, tables
import ast, ast_ops
import resolution
import ssa_ir, ssa_build, ssa_query

proc bodyOf(d: Decl): Expr =
  if d.kind == dkTask: d.taskBody else: d.fnBody

proc shapeOf(e: Expr, fn: SsaFn): int =
  ## Every node kind under `e` in walk order, and the id of every node the
  ## graph REFERENCES.
  ##
  ## Not every id. Passes give ids to nodes as they need them — the liveness
  ## oracle does, between the stamping and the check — and a node gaining an
  ## id the graph never looked at changes nothing the graph says. It fired
  ## on exactly that, the first time it ran. A pass that REPLACES a node the
  ## graph indexes changes that node's id, and that is still caught.
  var h: Hash = 0
  var stack = @[e]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil:
      h = h !& 0
      continue
    h = h !& ord(n.kind)
    if n.id.isSet and n.id in fn.byNode: h = h !& int(uint32(n.id))
    for ch in n.children: stack.add ch
  !$h

proc ssaOf*(res: Resolution, d: Decl, stage: SsaStage): CachedSsa =
  ## This body's graph at `stage`: built on first request, reused after.
  if not d.id.isSet: d.id = newNodeId()
  let key = (d.id, stage)
  if key in res.ssaGraphs:
    result = res.ssaGraphs[key]
    let now = shapeOf(d.bodyOf, result.fn)
    doAssert now == result.shape,
      "ssa_cache: " & d.name & "'s body changed after its " & $stage &
      " graph was built — a pass rewrote it without saying so"
    return
  let fn = buildFn(res, d)
  # AFTER the build: the builder gives ids to the nodes it indexes, so the
  # shape it leaves is the one every later fetch will see.
  result = CachedSsa(fn: fn, final: finalUses(fn), stage: stage,
                     shape: shapeOf(d.bodyOf, fn))
  res.ssaGraphs[key] = result
