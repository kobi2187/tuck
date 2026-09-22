# compiler/analysis_ssa.nim
#
# A VALUE MIRROR OF THE TREE. Stage A of thoughts/ssa-mirror-design.md.
#
# WHY. The ownership decision — may this value move rather than copy, and who
# frees it — is made in syntax-directed emitters, and every analysis that
# feeds them has to predict what they will do. Six bugs came out of that in
# one week: four syntactic positions with one missing, two decisions welded
# into one flag, a second scan that had to agree with the first, an analysis
# modelling the emitter's fast paths, two predicates kept in step by hand,
# and a syntactic `targetName` threaded into an ownership question.
#
# In SSA a value has ONE definition and a known set of uses, so "is this the
# last use", "who owns this" and "has this been consumed" are properties of
# the VALUE rather than of the position it is written at. There is no
# position to miss because positions stop being the unit.
#
# WHAT THIS IS NOT. Not an IR we emit from. We transpile, the backends do the
# real optimisation, and a second tree to keep correct is exactly what the
# ownership plan ruled against. This is a SIDE STRUCTURE the passes consult
# and the emitters read stamps from — the same relationship `Resolution`
# already has to the AST, and keyed the same way, by `NodeId`.
#
# WHY IT IS CHEAP HERE, and why this is not a textbook SSA construction:
#
#   NO DOMINANCE COMPUTATION. Tuck's control flow is entirely structured —
#   block, if, match, for, while, break, continue, return, raise, and nothing
#   else. `analysis_liveness` already exploits this to compute exact liveness
#   with a backward tree walk. Phi nodes belong at exactly two places, the
#   join after an if/match and a loop head, and both are syntactically
#   obvious. A CFG would add a representation to keep in sync for no extra
#   precision.
#
#   A NAME IS A VALUE. No nil, no refs, and `let b = a` copies. The alias
#   analysis that dominates SSA-based ownership work elsewhere is not needed.
#
# GRANULARITY IS THE ACCESS PATH, not the bare name — `b`, `b.ask`,
# `b.inner.xs`. A record's fields are separate buffers and the ownership
# question is asked per field, so a name-granular mirror would answer the
# wrong question. It is also what lets this reproduce `analysis_liveness`,
# which is path-granular for the same reason.
#
# STAGE A IS PROOF-ONLY. Nothing consults this yet. It earns the right to
# replace anything by reproducing the existing liveness answer EXACTLY across
# the corpus and both applications; see `ssaSelfCheck` and the `ssa` suite.
import ast, tables, sets, strutils, os
import resolution
import ast_ops

type
  ValueId* = distinct int32

  DefKind* = enum
    ## Where a version came from. This is the field Stage B reads to answer
    ## ownership, which is why `dfCall` and `dfConstruct` are told apart from
    ## `dfProject`: the first two may have allocated, the third never did.
    dfEntry      ## live on entry and not otherwise modelled — a parameter,
                 ## an actor field, a const, a name from another scope
    dfLiteral    ## a list or scalar literal: this body's own storage
    dfConstruct  ## a record construction
    dfCall       ## the result of a call
    dfProject    ## read out of another value: `b.ask` given `b`
    dfPhi        ## a join of two or more versions
    dfOpaque     ## a shape the builder does not model — always the safe
                 ## answer, and never mistaken for one of the above

  Def* = object
    kind*: DefKind
    at*: NodeId            ## the expression that produced it; 0 for phi/entry
    src*: Expr
      ## ...and that expression itself, for the consumer that needs to ask a
      ## question about it rather than merely identify it. Stage B asks
      ## `analysis_provenance` whether a `dfCall`'s callee builds its result
      ## or hands back an argument, which no NodeId can answer. Holding an
      ## AST pointer is what a MIRROR is for; it does not own the tree.
    inputs*: seq[ValueId]  ## phi operands, or the base of a projection

  Use* = object
    at*: NodeId
    region*: string
      ## Where in the control flow this read sits: a '/'-joined chain of
      ## `L<id>` for a loop and `A<id>:<arm>` for one arm of an if or match,
      ## outermost first. Two facts come out of it, and `finalUses` needs
      ## both — whether a read REPEATS (a loop the definition is outside of)
      ## and whether two reads can both happen (arms of one branch cannot).

  Value* = object
    place*: string         ## the access path this version belongs to
    version*: int
    def*: Def
    defRegion*: string     ## the loop chain the DEFINITION sits in
    uses*: seq[Use]        ## every site that READS this version, in order

  SsaFn* = object
    name*: string
    values*: seq[Value]
    terminal*: HashSet[string]
      ## Regions that ALWAYS exit the body — an `if` arm ending in `return`.
      ## Nothing outside such a region can follow a read inside it, which is
      ## the other half of "can these two reads both happen" and is invisible
      ## to the arm structure alone.
    deferred*: HashSet[string]
      ## Root names a `defer` body reads. A defer runs at SCOPE EXIT, after
      ## the apparent last use of everything it touches, so its reads are
      ## live throughout and nothing it names can have a final read inside
      ## the body. The mirror records the read where it is WRITTEN, which is
      ## early — so the place has to be named here instead, exactly as
      ## `analysis_liveness` kept a `skip` set for the same reason.
    readAt*: Table[NodeId, ValueId]
      ## which version each read site read. The inverse of `uses`, kept
      ## because the emitters ask by node and the passes ask by value.

  Builder = object
    res: Resolution
    fn: SsaFn
    cur: Table[string, ValueId]    ## place -> its current version
    breaks: seq[Table[string, ValueId]]   ## maps captured at each `break`
    conts: seq[Table[string, ValueId]]    ## ...and at each `continue`
    inLoop: bool
    region: string                 ## the control-flow chain being walked
    regionSeq: int                 ## ids for the branches and loops here
    entryVals: Table[string, ValueId]
      ## Places that arrived from OUTSIDE this body — parameters, actor
      ## fields, consts, callee names. Deliberately NOT in `cur`: `cur` is
      ## branch-scoped and gets saved and restored around every arm, so an
      ## entry value materialised inside one arm read as "defined on this
      ## path and not the other" and the join manufactured a phi over two
      ## freshly-invented versions of the same unchanging thing. `exit` in
      ## examples/38-division ended up with five.

const NoValue* = ValueId(-1)

proc `==`*(a, b: ValueId): bool {.borrow.}
proc `$`*(v: ValueId): string = "%" & $int32(v)

proc isSet*(v: ValueId): bool = int32(v) >= 0

# --- places -----------------------------------------------------------------

proc pathOf*(e: Expr): string =
  ## `b.ask` for a field chain rooted at a name, `b` for a bare name, "" for
  ## anything else — an index, a call result, a literal. "" means the walk
  ## could not NAME this location, which is a different thing from it not
  ## having one, and the caller falls back to the whole root.
  ##
  ## Deliberately identical to analysis_liveness.pathOf. The two must agree
  ## for the differential in `ssaSelfCheck` to mean anything, and when the
  ## mirror replaces that pass this is the definition that survives.
  if e == nil: return ""
  case e.kind
  of exkVar: e.name
  of exkField:
    let base = pathOf(e.receiver)
    if base.len == 0: "" else: base & "." & e.fieldName
  else: ""

proc rootOf*(path: string): string =
  let i = path.find('.')
  if i < 0: path else: path[0 ..< i]

# --- construction -----------------------------------------------------------

proc addValue(b: var Builder, place: string, def: Def,
              region = ""): ValueId =
  result = ValueId(b.fn.values.len.int32)
  var version = 0
  for v in b.fn.values:
    if v.place == place: inc version
  b.fn.values.add Value(place: place, version: version, def: def,
                        defRegion: (if region == "\0": ""
                                    elif region.len > 0: region
                                    else: b.region))

proc defineAt(b: var Builder, place: string, def: Def): ValueId {.discardable.} =
  ## A new version of `place`, and the death of everything UNDER it.
  ##
  ## `b = ...` replaces the whole record, so the versions of `b.ask` and
  ## `b.bid` that were current no longer describe anything. Dropping them
  ## rather than versioning them is what keeps a stale field version from
  ## being read after its record was overwritten.
  if place.len == 0: return NoValue
  result = b.addValue(place, def)
  var dead: seq[string]
  for p in b.cur.keys:
    if p.len > place.len and p.startsWith(place & "."): dead.add(p)
  for p in dead: b.cur.del(p)
  b.cur[place] = result

proc valueOf(b: var Builder, place: string): ValueId =
  ## The current version of `place`, materialising an entry value the first
  ## time a place is read without having been defined here — a parameter, an
  ## actor field, a const, a name from an enclosing scope.
  ##
  ## AN ENTRY VALUE IS DEFINED AT ENTRY, wherever it is first mentioned. It
  ## is materialised lazily, so it was being given the region it was first
  ## READ in — and a name first read inside a loop then looked as though the
  ## loop head had defined it, making its last read in the body final when
  ## in truth it is read again every iteration. `push` in
  ##
  ##     for i < n:
  ##       out = {items: out, value: 0} push
  ##
  ## is the smallest case: the callee is a name like any other, it is first
  ## seen inside the loop, and the mirror called its one read final.
  if place in b.cur: return b.cur[place]
  if place in b.entryVals: return b.entryVals[place]
  let root = rootOf(place)
  if root != place and (root in b.cur or root in b.entryVals):
    # A projection belongs where its BASE is, for the same reason.
    let base = if root in b.cur: b.cur[root] else: b.entryVals[root]
    result = b.addValue(place, Def(kind: dfProject, inputs: @[base]),
                        b.fn.values[int32(base)].defRegion)
  else:
    result = b.addValue(place, Def(kind: dfEntry), "\0")
  b.entryVals[place] = result

proc noteRead(b: var Builder, place: string, at: NodeId) =
  let v = b.valueOf(place)
  b.fn.values[int32(v)].uses.add(Use(at: at, region: b.region))
  b.fn.readAt[at] = v

proc defKindOf(e: Expr): DefKind =
  if e == nil: return dfOpaque
  case e.kind
  of exkLit, exkList: dfLiteral
  of exkStruct: dfConstruct
  of exkCall, exkChain: dfCall
  of exkField, exkBracket: dfProject
  else: dfOpaque

proc walk(b: var Builder, e: Expr)
proc walkLoop(b: var Builder, cond, body: Expr)

proc deferRoots(e: Expr, acc: var HashSet[string]) =
  ## The ROOT names a `defer` body reads — and only those. Deriving them from
  ## what `readAt` gained while walking the defer was tried and is wrong: it
  ## sweeps in every name the body had already read, and cost three final
  ## uses the old pass proves.
  if e == nil: return
  if e.kind in {exkVar, exkField}:
    let p = pathOf(e)
    if p.len > 0:
      acc.incl(rootOf(p))
      return
  if e.kind == exkAssign:
    deferRoots(e.assignVal, acc)
    if e.target != nil and e.target.kind != exkVar: deferRoots(e.target, acc)
    return
  for ch in e.children: deferRoots(ch, acc)

proc alwaysExits(e: Expr): bool =
  ## Does every path through this leave the body? Syntactic and deliberately
  ## incomplete — an unrecognised shape answers false, which costs precision
  ## and never grants a wrong move.
  if e == nil: return false
  case e.kind
  of exkReturn, exkRaise: true
  of exkBlock: e.stmts.len > 0 and alwaysExits(e.stmts[^1])
  of exkIf: alwaysExits(e.thenBranch) and alwaysExits(e.elseBranch)
  of exkMatch:
    if e.arms.len == 0: return false
    for arm in e.arms:
      if not alwaysExits(arm.body): return false
    true
  else: false


proc reads(b: var Builder, e: Expr) =
  ## Every place this expression READS, in evaluation order.
  ##
  ## Mirrors analysis_liveness.uses exactly, including its two refusals: an
  ## assignment to a plain name does not read that name, and a field chain
  ## the walk cannot name falls through so the receiver is read wholesale.
  if e == nil: return
  if e.kind == exkVar and e.name.len > 0:
    ensureId(e)
    b.noteRead(e.name, e.id)
    return
  if e.kind == exkField:
    let p = pathOf(e)
    if p.len > 0:
      ensureId(e)
      b.noteRead(p, e.id)
      return
  if e.kind == exkAssign:
    b.reads(e.assignVal)
    # `x[i] = v` and `x.f = v` READ x to find where to store; `x = v` does not.
    if e.target != nil and e.target.kind != exkVar: b.reads(e.target)
    return
  for ch in e.children: b.reads(ch)

proc definedPlaces(e: Expr, acc: var HashSet[string]) =
  ## Which places a subtree assigns to. A loop head needs this up front: a
  ## place the body writes is a place whose value at the head is a join of
  ## the entry version and whatever the previous iteration left.
  if e == nil: return
  if e.kind == exkAssign and e.target != nil:
    let p = pathOf(e.target)
    if p.len > 0: acc.incl(p)
  for ch in e.children: definedPlaces(ch, acc)

proc joinMaps(b: var Builder, maps: seq[Table[string, ValueId]],
              places: HashSet[string]) =
  ## Merge several control-flow paths. A place the paths disagree about gets
  ## a phi; one they agree about keeps its single version, which is what
  ## keeps the mirror from filling with phis that say nothing.
  for p in places:
    var seen: seq[ValueId]
    var missing = false
    for m in maps:
      if p in m:
        if m[p] notin seen: seen.add(m[p])
      else:
        missing = true
    if seen.len == 0: continue
    if missing:
      # Defined on some paths and not others: the entry version is the other
      # operand, and materialising it here is what makes the phi total.
      let entry = b.valueOf(p)
      if entry notin seen: seen.add(entry)
    if seen.len == 1:
      b.cur[p] = seen[0]
    else:
      b.cur[p] = b.addValue(p, Def(kind: dfPhi, inputs: seen))

proc allPlaces(maps: seq[Table[string, ValueId]]): HashSet[string] =
  for m in maps:
    for p in m.keys: result.incl(p)

proc walkLoop(b: var Builder, cond, body: Expr) =
  ## A loop head is a phi for every place the body writes: on the first
  ## iteration the value is what flowed in, on every later one it is what the
  ## previous iteration left. Both operands are known without a fixpoint
  ## because the body is one syntactic region — which is the whole reason
  ## this needs no dominance frontier.
  var written: HashSet[string]
  definedPlaces(body, written)
  if cond != nil: definedPlaces(cond, written)

  let savedBreaks = b.breaks
  let savedConts = b.conts
  let savedInLoop = b.inLoop
  let savedRegion = b.region
  inc b.regionSeq
  b.region = (if savedRegion.len == 0: "" else: savedRegion & "/") &
             "L" & $b.regionSeq

  # THE HEAD PHI BELONGS TO THE LOOP, and creating it before entering the
  # region gave it the one outside. That is not cosmetic: `finalUses` reads
  # a value as repeating when its reads sit in a loop its DEFINITION does
  # not, so every loop-carried value looked as though it were read again
  # forever and none of its reads could be final. `zeroed`'s `out` — the
  # plainest accumulate-in-a-loop there is — was exactly that.
  var headPhi: Table[string, ValueId]
  for p in written:
    let entry = b.valueOf(p)
    let phi = b.addValue(p, Def(kind: dfPhi, inputs: @[entry]))
    headPhi[p] = phi
    b.cur[p] = phi

  if cond != nil: b.reads(cond)
  b.breaks = @[]
  b.conts = @[]
  b.inLoop = true
  b.walk(body)
  b.region = savedRegion
  let bodyExit = b.cur
  let backEdges = b.conts & @[bodyExit]
  let breakMaps = b.breaks
  b.breaks = savedBreaks
  b.conts = savedConts
  b.inLoop = savedInLoop

  # Close the head phis with what flows back round.
  for p, phi in headPhi:
    for m in backEdges:
      if p in m and m[p] != phi and m[p] notin b.fn.values[int32(phi)].def.inputs:
        b.fn.values[int32(phi)].def.inputs.add(m[p])

  # The loop EXITS through the head (condition false) and through every
  # `break`. A `for` has no condition to fail, but a `break` still reaches
  # here, so both are joined the same way.
  # THE VALUE ON THE WAY OUT IS THE HEAD PHI, not what the body last left.
  # A loop may run zero times, so after it a name holds "whatever flowed in,
  # or whatever the last iteration produced" — which is precisely what the
  # head phi already says. Taking the body's exit version instead claims the
  # body definitely ran.
  #
  # NOT YET DISCRIMINATED BY ANY ASSERTION, and worth saying rather than
  # implying otherwise. Reverting this to the body's version was tried and
  # the suite stayed green: the subset rule in `finalUses` already answers
  # every last-use question on this corpus either way, and nothing else
  # consults the mirror yet, so no behavioural test can reach it. It matters
  # for Stage B, where the value read after a loop decides ownership and a
  # zero-trip loop would attribute the body's allocation to a path that
  # never allocated. Stage B's assertions are where this gets teeth.
  for p, phi in headPhi: b.cur[p] = phi
  var exits = @[b.cur] & breakMaps
  if exits.len > 1:
    b.joinMaps(exits, allPlaces(exits))

proc walkAssign(b: var Builder, e: Expr) =
  b.reads(e.assignVal)
  if e.target != nil and e.target.kind != exkVar: b.reads(e.target)
  let p = pathOf(e.target)
  if p.len > 0:
    ensureId(e.assignVal)
    let at = if e.assignVal != nil: e.assignVal.id else: NodeId(0)
    b.defineAt(p, Def(kind: defKindOf(e.assignVal), at: at, src: e.assignVal))
    return
  # THE TARGET HAS NO NAME. Two shapes reach here and they are not the same:
  #
  #   xs[i] = v    the ELEMENT cannot be named, but the container changed, so
  #                its version has to move with it.
  #   R.W = true   a register field. Nothing in this body owns it and there
  #                is no place to version — `R` is a memory-mapped address,
  #                not a value.
  #
  # Reading `brReceiver` off the second crashed the compiler outright:
  # `field 'brReceiver' is not accessible for type 'Expr' using 'kind =
  # exkField'`. No example assigns a register field with `=` — examples/20
  # uses the chain form throughout — so the corpus sweep never reached it and
  # `known_bugs`' register assertion did.
  if e.target == nil or e.target.kind != exkBracket: return
  let r = pathOf(e.target.brReceiver)
  if r.len > 0: b.defineAt(r, Def(kind: dfOpaque))

proc enterArm(b: var Builder, pre, armId, k: string, body: Expr) =
  b.region = pre & armId & k
  if alwaysExits(body): b.fn.terminal.incl(b.region)

proc walkIf(b: var Builder, e: Expr) =
  b.reads(e.cond)
  let entry = b.cur
  let saved = b.region
  inc b.regionSeq
  let armId = "A" & $b.regionSeq & ":"
  let pre = if saved.len == 0: "" else: saved & "/"
  b.enterArm(pre, armId, "0", e.thenBranch)
  b.walk(e.thenBranch)
  let thenMap = b.cur
  b.cur = entry
  b.enterArm(pre, armId, "1", e.elseBranch)
  b.walk(e.elseBranch)
  let elseMap = b.cur
  b.cur = entry
  b.region = saved
  b.joinMaps(@[thenMap, elseMap], allPlaces(@[thenMap, elseMap]))

proc walkMatch(b: var Builder, e: Expr) =
  b.reads(e.subject)
  let entry = b.cur
  let saved = b.region
  inc b.regionSeq
  let armId = "A" & $b.regionSeq & ":"
  let pre = if saved.len == 0: "" else: saved & "/"
  var maps: seq[Table[string, ValueId]]
  for k, arm in e.arms:
    b.cur = entry
    b.enterArm(pre, armId, $k, arm.body)
    if arm.guard != nil: b.reads(arm.guard)
    b.walk(arm.body)
    maps.add(b.cur)
  b.cur = entry
  b.region = saved
  if maps.len > 0: b.joinMaps(maps, allPlaces(maps))

proc walk(b: var Builder, e: Expr) =
  ## Forward over the structured tree, versioning as it goes. FLAT on
  ## purpose, per this tree's rule for dispatches over an enum: the arms
  ## delegate, so a new ExprKind produces a compile error here rather than
  ## being swallowed by an `else` that quietly builds a mirror over a
  ## construct nobody taught it.
  if e == nil: return
  case e.kind
  of exkBlock:
    for s in e.stmts: b.walk(s)
  of exkAssign: b.walkAssign(e)
  of exkIf: b.walkIf(e)
  of exkMatch: b.walkMatch(e)
  of exkWhile: b.walkLoop(e.whileCond, e.whileBody)
  of exkFor:
    b.reads(e.iterable)
    b.walkLoop(nil, e.body)
  of exkBreak:
    if b.inLoop: b.breaks.add(b.cur)
  of exkContinue:
    if b.inLoop: b.conts.add(b.cur)
  of exkDefer:
    # Its reads are recorded so the values are seen to escape, and the ROOTS
    # are named so nothing it touches can have a final read inside the body.
    deferRoots(e.deferBody, b.fn.deferred)
    b.reads(e.deferBody)
  else:
    b.reads(e)

proc buildFn*(res: Resolution, d: Decl): SsaFn =
  ## One body's mirror. Parameters arrive as `dfEntry`, which is precisely
  ## what Stage B needs to refuse to move them: on D and Odin a container
  ## parameter aliases the caller's buffer, and `dfEntry` says "not mine".
  var b = Builder(res: res)
  b.fn.name = d.name
  var body: Expr
  case d.kind
  of dkFn: body = d.fnBody
  of dkTask: body = d.taskBody
  else: return b.fn
  if body == nil: return b.fn
  if d.kind == dkFn:
    for p in d.fnParams:
      b.entryVals[p.name] = b.addValue(p.name, Def(kind: dfEntry))
  b.walk(body)
  b.fn

# --- the proof --------------------------------------------------------------

proc defErrors(fn: SsaFn, v: Value): seq[string] =
  case v.def.kind
  of dfPhi:
    if v.def.inputs.len < 1:
      result.add(fn.name & ": phi for " & v.place & " has no operands")
    for inp in v.def.inputs:
      if int32(inp) < 0 or int32(inp) >= fn.values.len.int32:
        result.add(fn.name & ": phi for " & v.place & " names " & $inp)
      elif fn.values[int32(inp)].place != v.place:
        result.add(fn.name & ": phi for " & v.place & " takes " &
                   fn.values[int32(inp)].place)
  of dfProject:
    for inp in v.def.inputs:
      if int32(inp) < 0 or int32(inp) >= fn.values.len.int32:
        result.add(fn.name & ": projection of " & v.place & " names " & $inp)
  else: discard

proc useErrors(fn: SsaFn, v: Value): seq[string] =
  var seenUse: HashSet[NodeId]
  for u in v.uses:
    if u.at in seenUse:
      result.add(fn.name & ": " & v.place & " records node " &
                 $uint32(u.at) & " twice")
    seenUse.incl(u.at)

proc readErrors(fn: SsaFn): seq[string] =
  for node, v in fn.readAt:
    if int32(v) < 0 or int32(v) >= fn.values.len.int32:
      result.add(fn.name & ": read at " & $uint32(node) & " names " & $v)
      continue
    var found = false
    for u in fn.values[int32(v)].uses:
      if u.at == node: found = true
    if not found:
      result.add(fn.name & ": read at " & $uint32(node) & " is not in " &
                 fn.values[int32(v)].place & "'s use list")

proc structuralErrors*(fn: SsaFn): seq[string] =
  ## Stage A.1. Invariants that must hold of any mirror, whatever the source
  ## said. These are checked across the whole corpus by the `ssa` suite, and
  ## they are what makes "the mirror was built" a claim rather than a hope.
  for i, v in fn.values:
    if v.place.len == 0:
      result.add(fn.name & ": value " & $i & " has no place")
    if v.version < 0:
      result.add(fn.name & ": " & v.place & " has version " & $v.version)
    result.add(defErrors(fn, v))
    result.add(useErrors(fn, v))
  result.add(readErrors(fn))

proc loopsOf(region: string): seq[string] =
  for c in region.split('/'):
    if c.len > 0 and c[0] == 'L': result.add c

proc under(region, prefix: string): bool =
  region == prefix or region.startsWith(prefix & "/")

proc disjoint(a, b: string, terminal: HashSet[string]): bool =
  ## Can a read in `b` follow a read in `a` on one run? Two ways it cannot.
  ##
  ## SIBLING ARMS of one branch never both execute. Everything else about
  ## the arm structure is conservatively "yes, both".
  let ca = a.split('/')
  let cb = b.split('/')
  var i = 0
  while i < ca.len and i < cb.len:
    if ca[i] != cb[i]:
      if ca[i].len > 0 and cb[i].len > 0 and ca[i][0] == 'A' and cb[i][0] == 'A':
        return ca[i].split(':')[0] == cb[i].split(':')[0]
      break
    inc i
  # AN ARM THAT ALWAYS RETURNS is not followed by the code after its branch,
  # and that code is not in a sibling arm — it is at the enclosing level, so
  # the rule above cannot see it:
  #
  #     if kind == 0:
  #       return {sl: sl, ...} digAt      # this read of sl IS final
  #     return {sl: sl, ...} placeAt      # ...and so is this one
  var pre = ""
  for c in ca:
    pre = if pre.len == 0: c else: pre & "/" & c
    if pre in terminal and not under(b, pre): return true
  false

proc finalUses*(fn: SsaFn): HashSet[NodeId] =
  ## Stage A.2. Which read sites are a version's FINAL one — the question the
  ## whole mirror exists to answer, derived from its structure alone.
  ##
  ## A version has ONE definition, so this is nearly a lookup over its use
  ## list. Two things stop it being one, and both are read off the region:
  ##
  ##   REPETITION. A read inside a loop the definition sits outside of
  ##   happens again next time round, so it is never final. A value defined
  ##   at a loop HEAD — a phi — is a fresh version each iteration, so its
  ##   reads in the body carry the same loop chain as its definition and ARE
  ##   final. That distinction is what the old counting pass could not make
  ##   and what `analysis_liveness` buys with a backward fixpoint; here it
  ##   falls out of where the phi was placed.
  ##
  ##   BRANCHING. "Last in program order" is wrong the moment control flow
  ##   splits: a value read in all four arms of a `match` has FOUR final
  ##   reads, because on whichever path runs, that read is the last one.
  ##   Measured before this was written — `world_server`'s `toShard` is
  ##   exactly that shape and the order-only rule found one final read where
  ##   there are four.
  ##
  ## So a read is final when no LATER read of the same version can follow it,
  ## and a read in a sibling arm cannot.
  for v in fn.values:
    if v.uses.len == 0: continue
    if rootOf(v.place) in fn.deferred: continue
    let defLoops = loopsOf(v.defRegion)
    for i, u in v.uses:
      # REPEATS iff the read sits inside a loop the definition does not. A
      # SUBSET test and not equality: a loop-carried value read AFTER the
      # loop has fewer loops than its definition, and does not repeat — it
      # is the commonest shape there is (`for ...: acc = ...` then
      # `return acc`) and equality refused every one of them.
      var repeats = false
      for l in loopsOf(u.region):
        if l notin defLoops: repeats = true
      if repeats: continue
      var followed = false
      for j in i + 1 ..< v.uses.len:
        if not disjoint(u.region, v.uses[j].region, fn.terminal):
          followed = true
      if not followed: result.incl(u.at)

proc deferExempt*(fn: SsaFn): bool =
  ## THE ONE PLACE THE MIRROR IS ALLOWED TO PROVE LESS, and it proves less by
  ## being right.
  ##
  ## `analysis_liveness` keeps a skip set of the PATHS a `defer` reads, so
  ## for `defer: finish sock.value` it holds `sock.value`. Its root rule then
  ## asks whether `sock` itself is dead, finds `sock` is not in the skip set,
  ## and stamps it — although the defer reads `sock` at scope exit, through
  ## that very field. Moving `sock` there would hand the defer freed memory.
  ##
  ## Inert today: `serve` is the only body in the corpus with the shape,
  ## `sock` is a local rather than a parameter, and nothing consumes a local's
  ## stamp. Recorded rather than reproduced, because reproducing a hole to
  ## make a differential green is how a hole becomes permanent.
  fn.deferred.len > 0

proc livenessDiff*(reference: HashSet[NodeId], fn: SsaFn):
    tuple[agree, onlyMirror, onlyPass: int] =
  ## The differential the design document asks for, as a MEASUREMENT rather
  ## than an assertion — because writing it turned up that "identical" was
  ## the wrong bar. See thoughts/ssa-mirror-design.md.
  let mine = finalUses(fn)
  var theirs: HashSet[NodeId]
  for v in fn.values:
    for u in v.uses:
      if u.at in reference: theirs.incl(u.at)
  for n in mine:
    if n in theirs: inc result.agree else: inc result.onlyMirror
  for n in theirs:
    if n notin mine: inc result.onlyPass

proc dump*(fn: SsaFn): string =
  result = "SSA " & fn.name & "\n"
  for i, v in fn.values:
    result.add("  %" & $i & " " & v.place & "." & $v.version & " = " &
               $v.def.kind)
    if v.def.inputs.len > 0:
      var ins: seq[string]
      for inp in v.def.inputs: ins.add($inp)
      result.add("(" & ins.join(", ") & ")")
    result.add("  uses=" & $v.uses.len & "\n")

proc markLivenessSsa*(res: Resolution, m: Module) =
  ## Stamp every final read in every body this module declares — the job
  ## `analysis_liveness` did with a backward walk and a loop fixpoint over
  ## access paths, now read off the mirror.
  ##
  ## SAME SCOPE, deliberately: `m.decls` and not `m.allFns()`, so an actor
  ## handler is still not visited. A handler's locals are actor FIELDS, which
  ## outlive the body, and an intra-body answer about one is simply wrong.
  ##
  ## The mirror is strictly more precise inside a loop — a loop-head phi is a
  ## fresh version each iteration, so `out = {items: out, ...} push` has a
  ## final read of `out` at the push, which a pass reasoning about the NAME
  ## `out` cannot say. `assertSsaWellFormed` checks the other direction:
  ## nothing the old pass proves may be lost.
  for d in m.decls:
    if d == nil or d.kind notin {dkFn, dkTask}: continue
    let fn = buildFn(res, d)
    for n in finalUses(fn): markLastUseId(res, n)

proc buildModuleSsa*(res: Resolution, m: Module): seq[SsaFn] =
  for d in m.decls:
    if d == nil or d.kind notin {dkFn, dkTask}: continue
    let fn = buildFn(res, d)
    if fn.values.len == 0: continue
    result.add(fn)
  when not defined(release):
    if getEnv("TUCK_DEBUG_SSA") notin ["", "diff"]:
      for fn in result: echo dump(fn)
