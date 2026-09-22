# compiler/ssa_query.nim
#
# QUESTIONS ASKED OF THE VALUE GRAPH. Construction is `ssa_build.nim`; the
# types are `ssa_ir.nim`.
#
# Separate from both because the questions outnumber the construction and
# change for different reasons: a new consumer adds a query, it does not
# touch the algorithm.
#
# ---------------------------------------------------------------------------
# WHAT BLOCKS BOUGHT
# ---------------------------------------------------------------------------
#
# Every question here used to be string surgery on a `'/'`-joined region
# chain. "Can a read in A be followed by a read in B" was `split('/')`, then
# `split(':')`, then prefix comparison. With real blocks it is REACHABILITY,
# which is what it always was:
#
#   does this read repeat?      -> is its block on a cycle the definition
#                                  is not on
#   can both reads happen?      -> is either block reachable from the other
#   is anything after this arm? -> does the arm's exit reach the join
#
# The old encoding could answer the first two only for the shapes its author
# thought of. This answers them for any graph the builder can produce.
import tables, sets
import ast
import ssa_ir

# --- the graph, forwards ----------------------------------------------------

proc successors*(fn: SsaFn): seq[seq[BlockId]] =
  ## `preds` inverted. Built on demand rather than maintained, because the
  ## construction only ever needs the backwards edges and a stale forward
  ## list would be one more thing to keep in step.
  result = newSeq[seq[BlockId]](fn.blocks.len)
  for b in fn.blocks:
    for p in b.preds:
      result[int32(p)].add b.id

proc reachable*(fn: SsaFn, succ: seq[seq[BlockId]], src: BlockId,
                stopAt = NoBlock): HashSet[BlockId] =
  ## Every block that can run after `src`, `src` itself excluded unless a
  ## cycle comes back to it. `stopAt` is entered but not walked through.
  var stack = succ[int32(src)]
  while stack.len > 0:
    let b = stack.pop()
    if b in result: continue
    result.incl b
    if b == stopAt: continue
    for s in succ[int32(b)]: stack.add s

proc carriesItself*(fn: SsaFn, phi: ValueId): bool =
  ## Can this phi's own value come back round to it?
  ##
  ## For a loop-head phi this is THE question about its reads. If every path
  ## round the back edge defines a new value, the phi's operand from the latch
  ## is some other value and each turn reads a different buffer under one SSA
  ## name. If some path leaves the place alone, the operand chain leads back
  ## to the phi itself — the SAME buffer survives into the next turn, and a
  ## read in the body is read again.
  ##
  ##     for c:
  ##       f(x)                  # read again next turn when cond is false
  ##       if cond: x = g()
  ##
  ## Both the old builder and the first version of this one called `f(x)`
  ## final there. It was latent — nothing acted on that stamp in that shape —
  ## but a final use is licence to move, and moving `x` there frees what the
  ## next turn reads.
  var stack = fn.values[int32(phi)].def.inputs
  var seen: HashSet[int32]
  while stack.len > 0:
    let v = stack.pop()
    if v == phi: return true
    if int32(v) in seen: continue
    seen.incl int32(v)
    if fn.values[int32(v)].def.kind == dkPhi:
      for op in fn.values[int32(v)].def.inputs: stack.add op
  false

proc onCycle*(fn: SsaFn, succ: seq[seq[BlockId]], b: BlockId): bool =
  ## Can this block reach itself? That is exactly "inside a loop".
  b in fn.reachable(succ, b)

# --- last use ---------------------------------------------------------------

proc followedFrom(v: Value, i: int, after: HashSet[BlockId]): bool =
  ## Is use `i` of this value followed by another read of the SAME value?
  ##
  ## A READ IN A PHI'S OWN BLOCK IS THE NEXT INCARNATION'S READ, not a later
  ## read of this one. `for i < n: ... ; i = i + 1` reads `i` in the body and
  ## again in the head's condition; the head read belongs to the following
  ## turn, so the body read really is the last of this one. A read AFTER the
  ## loop is a different matter and does follow — which is why this excludes
  ## the phi's block specifically rather than pruning the path to it.
  for j, w in v.uses:
    if j == i: continue
    if v.def.kind == dkPhi and w.blk == v.blk and v.uses[i].blk != v.blk:
      continue
    if w.blk == v.uses[i].blk:
      if j > i: return true                  # same block, later in order
    elif w.blk in after:
      return true
  false

proc finalUses*(fn: SsaFn): HashSet[NodeId] =
  ## The reads after which a value is never read again.
  ##
  ## Three rules, and each was a bug in the previous implementation before it
  ## was a rule here:
  ##
  ##   1. A READ THAT REPEATS IS NEVER FINAL. If the read's block is on a
  ##      cycle that the DEFINITION's block is not on, the loop comes back
  ##      around and reads the same value again. (If the definition is on the
  ##      same cycle, each iteration defines a fresh value and its read does
  ##      not repeat.)
  ##   2. A READ FOLLOWED BY ANOTHER READ IS NOT FINAL. "Followed" is
  ##      reachability between blocks, plus program order within one block.
  ##   3. SIBLING ARMS CAN BOTH BE FINAL, and this needs no rule at all — two
  ##      arms of one branch do not reach each other, so rule 2 does not fire.
  ##      The old encoding needed an explicit test for it.
  let succ = fn.successors()

  for v in fn.values:
    if v.uses.len == 0: continue
    if rootOf(v.place) in fn.deferredRoots: continue   # live to scope exit
    let defOnCycle = fn.onCycle(succ, v.blk)
    # A LOOP-HEAD PHI is the case the two rules below were never written for.
    # If it carries itself round the loop, a read inside the loop is read
    # again next turn and is never final. If it does not, every turn is a new
    # value, and only what follows WITHOUT going back through the head counts.
    let loopPhi = v.def.kind == dkPhi and defOnCycle
    let carried = loopPhi and fn.carriesItself(v.id)
    let stop = if loopPhi and not carried: v.blk else: NoBlock
    for i, u in v.uses:
      let after = fn.reachable(succ, u.blk, stop)
      if carried and u.blk != v.blk and fn.onCycle(succ, u.blk): continue
      # RULE 1: a read that repeats is never final — unless the definition is
      # inside the same loop, in which case each turn defines a fresh value
      # and this read does not outlive the one it read.
      if u.blk in after and not defOnCycle: continue
      # RULE 2: a read followed by another read of the same value is not
      # final. Sibling arms need no rule of their own: they do not reach each
      # other, so this simply does not fire.
      if not v.followedFrom(i, after): result.incl u.at

# --- structural invariants --------------------------------------------------

proc blockErrors(fn: SsaFn): seq[string] =
  for b in fn.blocks:
    if not b.sealed:
      result.add "block " & b.label & " left unsealed"
    for p in b.preds:
      if not p.isSet or int32(p) >= fn.blocks.len:
        result.add "block " & b.label & " has a bogus predecessor"

proc phiErrors(fn: SsaFn, v: Value): seq[string] =
  # A LIVE phi has at least two operands; one means `tryRemoveTrivialPhi` did
  # not run, which is how five versions of an unchanging `exit` happened.
  # Zero means it was removed and the slot is a tombstone.
  if v.def.inputs.len == 1:
    result.add $v.id & " (" & v.place & ") is a trivial phi left in place"
  for op in v.def.inputs:
    if not op.isSet or int32(op) >= fn.values.len:
      result.add $v.id & " has a bogus phi operand"
      continue
    # An operand must belong to the SAME place. A phi merging `b.ask` with
    # `b.bid` is meaningless, and it happened.
    if fn.values[int32(op)].place != v.place:
      result.add $v.id & " (" & v.place & ") merges operand from " &
                 fn.values[int32(op)].place

proc structuralErrors*(fn: SsaFn): seq[string] =
  ## What must be true of any graph this builder produces. Checked under
  ## `--verify-stages`, and each line here is a bug that happened.
  result = blockErrors(fn)
  for v in fn.values:
    case v.def.kind
    of dkPhi: result.add phiErrors(fn, v)
    of dkUndef:
      result.add $v.id & " (" & v.place & ") is Undef — read before any " &
                 "definition reaches it"
    else: discard
  for node, vid in fn.byNode:
    if not vid.isSet or int32(vid) >= fn.values.len:
      result.add "byNode points at a value that does not exist"

proc valueAt*(fn: SsaFn, n: NodeId): ValueId =
  ## THE FRONT DOOR: what value does this node name?
  ##
  ## The whole point of keeping a node index. A consumer — an emitter, the
  ## ownership pass — is holding a node and wants to know which buffer it is
  ## looking at, without knowing anything about places or versions.
  if n.isSet and n in fn.byNode: fn.byNode[n] else: NoValue
