# compiler/ssa_liveness.nim
#
# THE LAST-USE STAMPS, read off the SSA graph.
#
# Every consumer that may MOVE a value rather than copy it asks one question
# of a read site: is this the last time this buffer is read? The answer is
# `ssa_query.finalUses`; this pass writes it onto the shared Resolution so the
# codegen and the ownership pass can ask by node without rebuilding anything.
#
# `analysis_liveness` answered the same question with a backward walk over
# access paths and a loop fixpoint. It stays, as the ORACLE that
# `pipeline.assertSsaWellFormed` checks this against under --verify-stages.
import sets, os
import ast
import resolution
import ssa_ir, ssa_cache

proc echoFinals(fn: SsaFn, final: HashSet[NodeId]) =
  ## `TUCK_DEBUG_SSA=final`: one line per stamped read, in value order —
  ## what the tests assert on, since a stamp is otherwise visible only
  ## through whichever emitter happens to act on it.
  for v in fn.values:
    for u in v.uses:
      if u.at in final: echo "FINAL ", fn.name, " ", v.place

proc markLivenessSsa*(res: Resolution, m: Module) =
  ## Stamp every final read in every body this module declares.
  ##
  ## `m.decls`, NOT `m.allFns()`, so an actor handler is not visited: a
  ## handler's locals are actor FIELDS, which outlive the body, and an
  ## intra-body answer about one is simply wrong.
  for d in m.decls:
    if d == nil or d.kind notin {dkFn, dkTask}: continue
    let g = ssaOf(res, d, ssChecked)
    for n in g.final: markLastUseId(res, n)
    when not defined(release):
      if getEnv("TUCK_DEBUG_SSA") == "final": echoFinals(g.fn, g.final)

proc moduleSsa*(res: Resolution, m: Module): seq[CachedSsa] =
  ## Every body `markLivenessSsa` stamps, as the graphs it stamped from —
  ## for the checks that judge those stamps.
  for d in m.decls:
    if d == nil or d.kind notin {dkFn, dkTask}: continue
    let g = ssaOf(res, d, ssChecked)
    if g.fn.values.len > 0: result.add g
