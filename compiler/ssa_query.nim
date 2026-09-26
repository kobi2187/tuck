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
import tables, sets, strutils, algorithm
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

# --- last use --------------------------------------------------------------
#
# ONE QUESTION, asked by following the buffer: after this read, can control
# reach another read of the SAME BUFFER?
#
# The buffer does not keep one SSA name. At a join it becomes the phi — but
# only along the edge that carries it; on the other edges the phi is some
# other buffer. Round a loop it comes back as the head phi only if nothing
# on that path replaced it. So the walk carries the buffer's CURRENT NAME
# with it and re-derives it at every block boundary:
#
#   entering a block that has a phi for the place:
#       the phi's operand for THIS edge is our name -> the phi is our name now
#       it is anything else                         -> the buffer ends here
#   entering any other block:                       -> same name
#   entering the block that DEFINES our name, not as a phi:
#       the definition runs again and makes a new buffer -> ends here
#       (except a field of a named root: `b.lo` of an unchanged `b` is the
#       same field every time; `items[i]` or a `for` element is not)
#
# Any read of the current name on the way means the read was not the last.
#
# This replaced five separate rules — "a read in a loop repeats", "unless the
# definition is in the loop too", "unless the phi carries itself", "reads in
# a phi's own block are the next turn's", "and follow reads through joins".
# Each was right for the shapes it was written against, and `keep` in the
# generics suite was the shape between them: `out` carried round a loop, read
# only on the path that replaces it. Following the buffer answers all six.

type Holder = tuple[blk: BlockId, v, root: ValueId]
  ## Where the walk is, the buffer's current name, and — for a field — the
  ## current name of the record it is a field of (NoValue once that record
  ## is gone, or when the name is not a field).

proc phiIndex(fn: SsaFn): Table[(int32, Place), ValueId] =
  ## The live phi, if any, for each (block, place).
  for v in fn.values:
    if v.def.kind == dkPhi and v.def.inputs.len > 0:
      result[(int32(v.blk), v.place)] = v.id

proc isField(fn: SsaFn, v: ValueId): bool =
  let d = fn.values[int32(v)].def
  d.kind == dkProject and d.inputs.len > 0

proc across(fn: SsaFn, phis: Table[(int32, Place), ValueId],
            src, dst: BlockId, v: ValueId): ValueId =
  ## `v` leaving `src` for `dst` through the joins only: the phi it becomes,
  ## itself if there is no phi for its place, NoValue if the phi there takes
  ## something else on this edge.
  let key = (int32(dst), fn.values[int32(v)].place)
  if key notin phis: return v
  let phi = fn.values[int32(phis[key])]
  let preds = fn.blocks[int32(dst)].preds
  doAssert preds.len == phi.def.inputs.len,
    "ssa_query: phi " & $phi.id & " has " & $phi.def.inputs.len &
    " operands for " & $preds.len & " predecessors"
  for k, p in preds:
    if p == src and phi.def.inputs[k] == v: return phi.id
  NoValue

proc carry(fn: SsaFn, phis: Table[(int32, Place), ValueId],
           h: Holder, dst: BlockId): Holder =
  ## The buffer named `h.v` leaving `h.blk` for `dst`: what it is called
  ## there, with NoValue in `v` if it does not get there.
  result = (dst, fn.across(phis, h.blk, dst, h.v), NoValue)
  if not result.v.isSet: return
  if h.root.isSet:
    result.root = fn.across(phis, h.blk, dst, h.root)
    # The record itself is replaced here: a new record, new fields.
    let r = fn.values[int32(h.root)]
    if dst == r.blk and r.def.kind != dkPhi: result.root = NoValue
  let val = fn.values[int32(result.v)]
  if dst != val.blk or val.def.kind == dkPhi or result.v != h.v: return
  # RE-ENTERING THE DEFINITION. It runs again. For a call, a literal, a
  # construction, an element (`items[i]`, a `for` binding) that is a new
  # buffer. For a field it is the SAME buffer exactly when the record it is
  # read out of is still the same record — which the walk has been carrying.
  if fn.isField(result.v) and result.root.isSet and
     result.root == val.def.inputs[0]:
    return
  result.v = NoValue

proc readAgain(fn: SsaFn, succ: seq[seq[BlockId]],
               phis: Table[(int32, Place), ValueId],
               v: ValueId, start: BlockId): bool =
  ## Leaving `start` with the buffer named `v`, is it ever read again?
  let root = if fn.isField(v): fn.values[int32(v)].def.inputs[0] else: NoValue
  var seen: HashSet[Holder]
  var stack: seq[Holder]
  for s in succ[int32(start)]:
    let n = fn.carry(phis, (start, v, root), s)
    if n.v.isSet: stack.add n
  while stack.len > 0:
    let h = stack.pop()
    if h in seen: continue
    seen.incl h
    for u in fn.values[int32(h.v)].uses:
      if u.blk == h.blk: return true
    for s in succ[int32(h.blk)]:
      let n = fn.carry(phis, h, s)
      if n.v.isSet: stack.add n
  false

proc laterInBlock(v: Value, i: int): bool =
  ## Another read of the same value further down the same block. Uses are
  ## recorded in walk order, which within one block is program order.
  for j in i + 1 ..< v.uses.len:
    if v.uses[j].blk == v.uses[i].blk: return true
  false

proc finalUses*(fn: SsaFn): HashSet[NodeId] =
  ## The reads after which the buffer they read is never read again.
  ##
  ## Sibling arms need no rule: neither reaches the other. A `defer` does: it
  ## runs at scope exit, after every read the graph can see, so a root it
  ## names has no final read at all.
  let succ = fn.successors()
  let phis = fn.phiIndex()
  for v in fn.values:
    if v.uses.len == 0: continue
    if rootOf(v.place) in fn.deferredRoots: continue
    for i, u in v.uses:
      if v.laterInBlock(i): continue
      if fn.readAgain(succ, phis, v.id, u.blk): continue
      result.incl u.at

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
  if v.def.inputs.len > 1 and
     v.def.inputs.len != fn.blocks[int32(v.blk)].preds.len:
    result.add $v.id & " (" & v.place & ") has " & $v.def.inputs.len &
               " operands for " & $fn.blocks[int32(v.blk)].preds.len &
               " predecessors"
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

proc isTombstone(v: Value): bool =
  ## A phi `tryRemoveTrivialPhi` removed: no operands, no uses.
  v.def.kind == dkPhi and v.def.inputs.len == 0

proc useErrors(fn: SsaFn, v: Value): seq[string] =
  # THE FRONT DOOR AGREES WITH THE USE LISTS. A consumer asks `byNode` which
  # value a read saw; `finalUses` answers from the value's own `uses`. If
  # they disagree, the move decision and the read it is about describe two
  # different buffers. `let a = s` once overwrote the read of `s` with `a`.
  for u in v.uses:
    if not u.blk.isSet or int32(u.blk) >= fn.blocks.len:
      result.add $v.id & " (" & v.place & ") is read in a bogus block"
    if u.at notin fn.byNode:
      result.add $v.id & " (" & v.place & ") has a read the front door " &
                 "does not index"
    elif fn.byNode[u.at] != v.id:
      result.add $v.id & " (" & v.place & ") has a read the front door " &
                 "attributes to " & $fn.byNode[u.at]

proc inputErrors(fn: SsaFn, v: Value): seq[string] =
  # NOTHING POINTS AT A REMOVED PHI. Removal reroutes every reference; a
  # projection once kept its input on the tombstone (`f.test` of a parked
  # `f`), so ownership read a value that no longer existed.
  for op in v.def.inputs:
    if not op.isSet or int32(op) >= fn.values.len: continue  # phiErrors says
    if fn.values[int32(op)].isTombstone:
      result.add $v.id & " (" & v.place & ") takes input from removed phi " &
                 $op

proc structuralErrors*(fn: SsaFn): seq[string] =
  ## What must be true of any graph this builder produces. Checked under
  ## `--verify-stages`, and each line here is a bug that happened.
  result = blockErrors(fn)
  for v in fn.values:
    if v.isTombstone:
      if v.uses.len > 0:
        result.add $v.id & " (" & v.place & ") is a removed phi still read"
      continue
    result.add useErrors(fn, v)
    result.add inputErrors(fn, v)
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

# --- rendering --------------------------------------------------------------

proc defText(fn: SsaFn, v: Value): string =
  result = ($v.def.kind)[2 .. ^1].toLowerAscii
  if v.def.inputs.len > 0:
    var ins: seq[string]
    for i in v.def.inputs: ins.add $i
    result.add "(" & ins.join(", ") & ")"

proc render*(fn: SsaFn): string =
  ## The graph as a reader wants it, and as the goldens pin it: every block
  ## with its predecessors, every live value with where it came from, and
  ## every read by source position with the FINAL verdict beside it.
  ##
  ## Stable on purpose. No NodeIds (they depend on how much of the program
  ## was parsed first) and no removed phis (a tombstone is a construction
  ## detail); value and block numbers stay, because a phi's operands are
  ## meaningless without them.
  let final = fn.finalUses()
  result = "fn " & fn.name & "\n"
  for b in fn.blocks:
    var ps: seq[string]
    for p in b.preds: ps.add $p
    result.add "  " & $b.id & " " & b.label &
               (if ps.len > 0: " <- " & ps.join(" ") else: "") &
               (if b.exits: "  [exits]" else: "") & "\n"
  for v in fn.values:
    if v.def.kind == dkPhi and v.def.inputs.len == 0: continue  # removed
    var reads: seq[string]
    for u in v.uses:
      reads.add $u.line & ":" & $u.col & (if u.at in final: " FINAL" else: "")
    result.add "  " & alignLeft($v.id, 4) & " " &
               alignLeft(v.place & "." & $v.version, 14) & " = " &
               alignLeft(fn.defText(v), 18) & " in " & $v.blk
    if reads.len > 0: result.add "  reads " & reads.join(", ")
    result.add "\n"
  if fn.deferredRoots.len > 0:
    var roots: seq[string]
    for r in fn.deferredRoots: roots.add r
    roots.sort()
    result.add "  deferred: " & roots.join(" ") & "\n"
