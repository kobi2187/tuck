# compiler/ssa_build.nim
#
# SSA CONSTRUCTION, after Braun, Buchwald, Hack, Leißa, Mallon & Zwinkau,
# "Simple and Efficient Construction of SSA Form" (CC 2013).
#
# ---------------------------------------------------------------------------
# WHY THIS ALGORITHM AND NOT THE TEXTBOOK ONE
# ---------------------------------------------------------------------------
#
# The classic construction is Cytron, Ferrante, Rosen, Wegman & Zadeck (1991):
# build a CFG, compute the dominator tree, compute DOMINANCE FRONTIERS, place
# a phi for v at the frontier of every block defining v, then rename in a
# dominator-tree walk with a stack per variable. It is what every compiler
# textbook means by "SSA construction", and it needs two structures Tuck does
# not have and would have to invent: an explicit CFG and a dominator tree.
#
# Braun et al. builds SSA DIRECTLY, with neither. Three operations —
# `writeVariable`, `readVariable`, and a phi that removes itself when it turns
# out trivial — plus one flag per block, `sealed`, for "are all predecessors
# known yet". Loops need nothing else: a loop head is unsealed while its body
# is being built, its phis are parked, and sealing fills them in once the back
# edge exists.
#
# IT FITS TUCK FOR A SPECIFIC REASON. Dominance frontiers earn their keep on
# IRREDUCIBLE control flow — arbitrary `goto`, computed jumps. Tuck has none:
# no labels, by ruling (ROADMAP), so every join in the language is a
# SYNTACTIC join and the CFG a structured walk produces is always reducible.
# Paying for dominance here would buy nothing.
#
# ---------------------------------------------------------------------------
# WHAT THE PREVIOUS BUILDER GOT WRONG BY NOT KNOWING THIS
# ---------------------------------------------------------------------------
#
# `analysis_ssa.nim` is a partial reimplementation of this paper that nobody
# noticed was one: its `cur` is `currentDef`, `valueOf` is `readVariable`,
# `joinMaps` is phi insertion. What it lacks is SEALING and TRIVIAL-PHI
# REMOVAL — and every one of the six builder bugs that Stage A cost was in
# exactly that gap:
#
#   * the loop-head phi took the wrong region — sealing decides this;
#   * entry values materialised inside one arm spawned phantom phis, and
#     `exit` in examples/38-division ended with FIVE versions of an unchanging
#     value — that is precisely a missing `tryRemoveTrivialPhi`;
#   * "does this read repeat" needed a subset test on loop chains — with real
#     blocks it is reachability, not string surgery.
#
# Each was found by differential testing and fixed by hand. The algorithm
# handles all three by construction.
#
# ---------------------------------------------------------------------------
# THE TUCK-SPECIFIC PART
# ---------------------------------------------------------------------------
#
# Braun versions "variables". This versions PLACES — `b`, `b.ask`, `b.bid` —
# because Tuck's ownership question is per field. Two consequences:
#
#   * a write to a root KILLS every path under it (`b = ...` invalidates the
#     live version of `b.ask`), handled in `writeVariable`;
#   * a read of `b.ask` with no definition in this body is not an entry value
#     of `b.ask` but a PROJECTION of whatever `b` currently is, so that the
#     two stay related when `b` is reassigned.
import ast, tables, sets, strutils
import resolution
import ssa_ir

type
  Builder = object
    res: Resolution
    fn: SsaFn
    cur: Table[Place, Table[BlockId, ValueId]]
      ## Braun's `currentDef`: place -> block -> the value live there
    here: BlockId               ## the block being filled
    loopHeads: seq[BlockId]     ## for `continue`
    loopExits: seq[BlockId]     ## for `break`

# --- blocks -----------------------------------------------------------------

proc newBlock(b: var Builder, label: string, sealed = true): BlockId =
  result = BlockId(b.fn.blocks.len.int32)
  b.fn.blocks.add Block(id: result, label: label, sealed: sealed)

proc addPred(b: var Builder, blk, pred: BlockId) =
  if pred.isSet and pred notin b.fn.blocks[int32(blk)].preds:
    b.fn.blocks[int32(blk)].preds.add pred

proc exitsAlready(b: Builder, blk: BlockId): bool =
  blk.isSet and b.fn.blocks[int32(blk)].exits

# --- values -----------------------------------------------------------------

proc newValue(b: var Builder, place: Place, def: Def, blk: BlockId): ValueId =
  result = ValueId(b.fn.values.len.int32)
  var version = 0
  for v in b.fn.values:
    if v.place == place: inc version
  b.fn.values.add Value(id: result, place: place, version: version,
                        def: def, blk: blk, freedBy: fkNotFreed)

proc writeVariable(b: var Builder, place: Place, blk: BlockId, v: ValueId) =
  ## Braun's `writeVariable`, plus Tuck's kill rule.
  if place.len == 0: return
  if place notin b.cur: b.cur[place] = initTable[BlockId, ValueId]()
  b.cur[place][blk] = v

proc killUnder(b: var Builder, root: Place, blk: BlockId) =
  ## `b = ...` replaces the whole record, so the live versions of `b.ask` and
  ## `b.bid` describe nothing. Dropping them is what stops a stale field
  ## version being read after its record was overwritten.
  var dead: seq[Place]
  for p in b.cur.keys:
    if p != root and p.isUnder(root): dead.add p
  for p in dead: b.cur[p].del(blk)

proc readVariable(b: var Builder, place: Place, blk: BlockId): ValueId

proc addPhiOperands(b: var Builder, place: Place, phi: ValueId): ValueId

proc phiUsersOf(b: Builder, phi: ValueId): seq[ValueId] =
  ## Phis taking this one as an operand. They are the ones that may THEMSELVES
  ## have become trivial once it is gone, which is why removal recurses.
  for v in b.fn.values:
    if v.id == phi or v.def.kind != dkPhi: continue
    for op in v.def.inputs:
      if op == phi: result.add v.id; break

proc replaceEverywhere(b: var Builder, phi, same: ValueId,
                       users: seq[ValueId]) =
  ## Every reference to `phi` becomes a reference to `same`: phi operands,
  ## the node index, the current-definition map, and THE USES ALREADY
  ## RECORDED ON IT.
  ##
  ## That last one is easy to miss and was. A read taken while the block was
  ## unsealed landed on the parked phi; if sealing then proves the phi
  ## trivial, that read was really a read of `same` all along. Leaving the use
  ## behind strands it on a value nothing refers to — `levels` in `zeroed` had
  ## its one use on a removed phi while the entry value it collapsed to showed
  ## `uses=0`. Found by the differential against the old builder.
  for u in users:
    for i in 0 ..< b.fn.values[int32(u)].def.inputs.len:
      if b.fn.values[int32(u)].def.inputs[i] == phi:
        b.fn.values[int32(u)].def.inputs[i] = same
  for node, v in b.fn.byNode:
    if v == phi: b.fn.byNode[node] = same
  for p in b.cur.keys:
    for blk in b.cur[p].keys:
      if b.cur[p][blk] == phi: b.cur[p][blk] = same
  for u in b.fn.values[int32(phi)].uses:
    b.fn.values[int32(same)].uses.add u
  b.fn.values[int32(phi)].uses = @[]

proc tryRemoveTrivialPhi(b: var Builder, phi: ValueId): ValueId =
  ## Braun §3.1. A phi is trivial when its operands are all one value (self
  ## references aside); it then IS that value and should not exist.
  ##
  ## Leaving these in is not cosmetic. Every trivial phi is a version of
  ## something that never changed, and a consumer counting versions — "has
  ## this name held more than one buffer?" — reads it as a change that
  ## happened. `exit` in examples/38-division carried five.
  var same = NoValue
  for op in b.fn.values[int32(phi)].def.inputs:
    if op == same or op == phi: continue      # unique value, or self-reference
    if same != NoValue: return phi            # merges two values: not trivial
    same = op
  if same == NoValue:
    # Unreachable, or defined in the entry block with nothing before it.
    same = b.newValue(b.fn.values[int32(phi)].place,
                      Def(kind: dkUndef), b.fn.values[int32(phi)].blk)

  let users = b.phiUsersOf(phi)
  b.replaceEverywhere(phi, same, users)
  b.fn.values[int32(phi)].def.inputs = @[]    # detach; the slot stays for ids
  for u in users:
    discard b.tryRemoveTrivialPhi(u)
  same

proc addPhiOperands(b: var Builder, place: Place, phi: ValueId): ValueId =
  ## One operand per predecessor, read at that predecessor.
  let blk = b.fn.values[int32(phi)].blk
  for pred in b.fn.blocks[int32(blk)].preds:
    let op = b.readVariable(place, pred)
    if op.isSet: b.fn.values[int32(phi)].def.inputs.add op
  b.tryRemoveTrivialPhi(phi)

proc readVariableRecursive(b: var Builder, place: Place,
                           blk: BlockId): ValueId =
  ## Braun §2.1 and §2.2.
  if not b.fn.blocks[int32(blk)].sealed:
    # THE LOOP CASE, and the whole reason sealing exists. The back edge does
    # not exist yet, so the operands cannot be known; park an empty phi and
    # fill it in at `sealBlock`.
    result = b.newValue(place, Def(kind: dkPhi), blk)
    if blk notin b.fn.incompletePhis:
      b.fn.incompletePhis[blk] = initTable[Place, ValueId]()
    b.fn.incompletePhis[blk][place] = result
  elif b.fn.blocks[int32(blk)].preds.len == 1:
    # The common case: one predecessor, so no phi is needed at all.
    result = b.readVariable(place, b.fn.blocks[int32(blk)].preds[0])
  elif b.fn.blocks[int32(blk)].preds.len == 0:
    # The entry block. A place read before it is written arrived from outside
    # the body: a parameter, an actor field, a const, a callee's name.
    result = b.newValue(place, Def(kind: dkEntry), blk)
  else:
    # Write the phi BEFORE filling it, to break cycles: an operand that reads
    # its way back here finds the phi rather than recursing forever.
    result = b.newValue(place, Def(kind: dkPhi), blk)
    b.writeVariable(place, blk, result)
    result = b.addPhiOperands(place, result)
  b.writeVariable(place, blk, result)

proc readVariable(b: var Builder, place: Place, blk: BlockId): ValueId =
  if place.len == 0: return NoValue
  if place in b.cur and blk in b.cur[place]:
    return b.cur[place][blk]                  # local value numbering
  b.readVariableRecursive(place, blk)

proc sealBlock(b: var Builder, blk: BlockId) =
  ## All predecessors are known now. Fill the parked phis and mark it.
  if b.fn.blocks[int32(blk)].sealed: return
  if blk in b.fn.incompletePhis:
    var parked: seq[(Place, ValueId)]
    for place, phi in b.fn.incompletePhis[blk]: parked.add (place, phi)
    b.fn.blocks[int32(blk)].sealed = true     # so operand reads do not re-park
    for (place, phi) in parked:
      discard b.addPhiOperands(place, phi)
    b.fn.incompletePhis.del(blk)
  b.fn.blocks[int32(blk)].sealed = true

# --- walking the tree -------------------------------------------------------

proc defKindOf(e: Expr): DefKind =
  if e == nil: return dkOpaque
  case e.kind
  of exkLit, exkList: dkLiteral
  of exkStruct: dkConstruct
  of exkCall, exkChain: dkCall
  of exkField, exkBracket: dkProject
  of exkVar: dkAlias
  else: dkOpaque

proc walk(b: var Builder, e: Expr)

proc noteRead(b: var Builder, e: Expr) =
  ## A read of a nameable place records itself on the value it read.
  let place = pathOf(e)
  if place.len == 0: return
  let v = b.readVariable(place, b.here)
  if not v.isSet: return
  ensureId(e)
  b.fn.values[int32(v)].uses.add Use(at: e.id, blk: b.here)
  b.fn.byNode[e.id] = v

proc reads(b: var Builder, e: Expr) =
  ## Every read inside an expression. A field chain is recorded at its
  ## deepest nameable path and not descended into — `b.ask` is a read of
  ## `b.ask`, not of `b`.
  if e == nil: return
  if e.kind in {exkVar, exkField} and pathOf(e).len > 0:
    b.noteRead(e)
    return
  for ch in e.children: b.reads(ch)

proc defineTo(b: var Builder, target, value: Expr) =
  let place = pathOf(target)
  if place.len == 0:
    b.reads(target)          # an index or a register: no place to version
    return
  var def = Def(kind: defKindOf(value), src: value)
  if value != nil:
    ensureId(value)
    def.at = value.id
  let v = b.newValue(place, def, b.here)
  b.killUnder(place, b.here)
  b.writeVariable(place, b.here, v)
  if def.at.isSet: b.fn.byNode[def.at] = v

proc walkIf(b: var Builder, e: Expr) =
  b.reads(e.cond)
  let entry = b.here
  let thenB = b.newBlock("then")
  b.addPred(thenB, entry)
  b.sealBlock(thenB)
  b.here = thenB
  b.walk(e.thenBranch)
  let thenExit = b.here
  let thenLeaves = b.exitsAlready(thenExit)

  var elseExit = entry
  var elseLeaves = false
  if e.elseBranch != nil:
    let elseB = b.newBlock("else")
    b.addPred(elseB, entry)
    b.sealBlock(elseB)
    b.here = elseB
    b.walk(e.elseBranch)
    elseExit = b.here
    elseLeaves = b.exitsAlready(elseExit)

  let join = b.newBlock("join")
  if not thenLeaves: b.addPred(join, thenExit)
  if not elseLeaves: b.addPred(join, elseExit)
  b.sealBlock(join)
  b.fn.blocks[int32(join)].exits = thenLeaves and elseLeaves and
                                   e.elseBranch != nil
  b.here = join

proc walkMatch(b: var Builder, e: Expr) =
  b.reads(e.subject)
  let entry = b.here
  var armExits: seq[BlockId]
  var allLeave = e.arms.len > 0
  for i, arm in e.arms:
    let ab = b.newBlock("arm" & $i)
    b.addPred(ab, entry)
    b.sealBlock(ab)
    b.here = ab
    b.walk(arm.body)
    if b.exitsAlready(b.here): continue
    allLeave = false
    armExits.add b.here
  let join = b.newBlock("join")
  # A match need not be exhaustive at this level, so the subject block is
  # still a predecessor unless every arm leaves.
  if not allLeave: b.addPred(join, entry)
  for x in armExits: b.addPred(join, x)
  b.sealBlock(join)
  b.fn.blocks[int32(join)].exits = allLeave
  b.here = join

proc walkLoop(b: var Builder, cond, body: Expr) =
  let entry = b.here
  # THE HEAD IS UNSEALED. Its second predecessor is the latch at the bottom of
  # the body, which does not exist yet. Everything the body reads from the
  # head parks an incomplete phi; sealing after the body fills them in.
  let head = b.newBlock("loop.head", sealed = false)
  b.addPred(head, entry)
  let exit = b.newBlock("loop.exit")
  b.addPred(exit, head)

  b.here = head
  if cond != nil: b.reads(cond)

  let bodyB = b.newBlock("loop.body")
  b.addPred(bodyB, head)
  b.sealBlock(bodyB)
  b.loopHeads.add head
  b.loopExits.add exit
  b.here = bodyB
  b.walk(body)
  let latch = b.here
  discard b.loopHeads.pop()
  discard b.loopExits.pop()

  if not b.exitsAlready(latch): b.addPred(head, latch)
  b.sealBlock(head)                       # the back edge exists now
  b.sealBlock(exit)
  b.here = exit

proc walk(b: var Builder, e: Expr) =
  if e == nil: return
  case e.kind
  of exkBlock:
    for s in e.stmts: b.walk(s)
  of exkAssign:
    b.reads(e.assignVal)
    b.defineTo(e.target, e.assignVal)
  of exkIf: b.walkIf(e)
  of exkMatch: b.walkMatch(e)
  of exkWhile: b.walkLoop(e.whileCond, e.whileBody)
  of exkFor:
    b.reads(e.iterable)
    b.walkLoop(nil, e.body)
  of exkReturn, exkRaise:
    b.reads(e)
    b.fn.blocks[int32(b.here)].exits = true
  of exkBreak:
    if b.loopExits.len > 0: b.addPred(b.loopExits[^1], b.here)
    b.fn.blocks[int32(b.here)].exits = true
  of exkContinue:
    if b.loopHeads.len > 0: b.addPred(b.loopHeads[^1], b.here)
    b.fn.blocks[int32(b.here)].exits = true
  else:
    b.reads(e)

proc deferRoots(e: Expr, acc: var HashSet[string]) =
  ## A `defer` body's reads are live to the end of the scope, whatever the
  ## graph says about where they appear.
  if e == nil: return
  if e.kind == exkDefer:
    var stack = @[e]
    while stack.len > 0:
      let n = stack.pop()
      if n == nil: continue
      for ch in n.children: stack.add ch
      if n.kind in {exkVar, exkField}:
        let p = pathOf(n)
        if p.len > 0: acc.incl rootOf(p)
  for ch in e.children: deferRoots(ch, acc)

proc buildFn*(res: Resolution, d: Decl): SsaFn =
  ## The whole construction for one body.
  var b = Builder(res: res)
  b.fn.name = d.name
  b.fn.entry = b.newBlock("entry")
  b.here = b.fn.entry
  b.sealBlock(b.fn.entry)
  if d.fnBody != nil:
    b.walk(d.fnBody)
    deferRoots(d.fnBody, b.fn.deferredRoots)
  # Any block left unsealed is a construction bug, not a program property.
  for blk in b.fn.blocks:
    doAssert blk.sealed,
      "ssa_build: " & d.name & " left " & blk.label & " unsealed"
  b.fn

proc buildScope*(res: Resolution, name: string, body: Expr): SsaFn =
  ## SSA over an ARBITRARY region rather than a whole function.
  ##
  ## Possible because a block is a real thing with predecessors: the entry
  ## block has none, so every place the region reads without writing is a
  ## `dkEntry` value and the region stands alone. The previous mirror could
  ## not express this at all — its "scope" was a string prefix on a function's
  ## own walk.
  var b = Builder(res: res)
  b.fn.name = name
  b.fn.entry = b.newBlock("entry")
  b.here = b.fn.entry
  b.sealBlock(b.fn.entry)
  b.walk(body)
  deferRoots(body, b.fn.deferredRoots)
  b.fn

proc dump*(fn: SsaFn): string =
  ## For eyes, never parsed.
  result = "fn " & fn.name & "\n"
  for blk in fn.blocks:
    result.add "  " & $blk.id & " " & blk.label &
               " preds=" & $blk.preds.len &
               (if blk.exits: " exits" else: "") & "\n"
  for v in fn.values:
    if v.def.kind == dkPhi and v.def.inputs.len == 0: continue  # removed
    result.add "  " & $v.id & " " & v.place & "." & $v.version &
               " " & $v.def.kind & " in " & $v.blk &
               " uses=" & $v.uses.len & "\n"
