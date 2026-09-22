# compiler/analysis_ownership.nim
#
# WHO FREES A HEAP VALUE — decided once, for every backend.
#
# This is a fact about TUCK CODE, not about any one target: a buffer this
# body allocated, that nothing outside the body can still reach, is dead at
# the end of the body. Nim's ARC and D's GC act on that for free; Odin has
# neither, so it is the backend that must print the `delete`. The DECISION is
# the same for all three, so it belongs here rather than inside an emitter —
# the rule `lowering_seqcopy.nim` already states for the copy decision:
#
#   Anything the emitter decides, it decides while building a string, so the
#   decision cannot be inspected, tested, or reused — which is how three
#   backends each grew their own copy of the same reasoning.
#
# ---------------------------------------------------------------------------
# THE ALGORITHM, IN SIX STEPS
# ---------------------------------------------------------------------------
#
# Worked against the shape that motivated it, `world_server`'s `relight`:
#
#     fn relight({sl: Slice, c: int, cols: int}) -> Slice:
#       let a = {height: sl.height, lum: sl.lum, light: sl.light, ...} Flood
#       let r = {f: a, ...} pass
#       let b = {f: r, ...} pass
#       return {height: sl.height, lum: sl.lum, light: b.light, ...} Slice
#
# Twelve arrays are allocated here; one is returned.
#
#   STEP 1  Collect every local: what it was declared with, and how many
#           times it is assigned. A name assigned more than once has no
#           single allocation to talk about, so steps 2-4 skip it and step 5
#           handles it instead.
#
#   STEP 2  OWNERSHIP, per slot. A "slot" is the value itself for a bare
#           `Seq`, or one named field for a record. This body owns a slot
#           when it got a buffer nobody else holds, by either of two routes:
#             * the value is a fresh literal, or a call whose result is
#               `exclusivelyOwned` — the callee built it and kept nothing;
#             * a defensive copy was emitted at the binding. Note this reads
#               backwards: `exclusivelyOwned` being FALSE is *why*
#               `markSeqCopies` marked the site, so a copy exists and the
#               copy is ours.
#           For `a`, `r` and `b` that is all three fields each — nine
#           buffers, all owned here.
#
#   STEP 3  ESCAPE, per slot. A slot escapes if it can still be reached after
#           the body returns: it is returned, sent, stored through another
#           name, or handed to a twin that will free it. PER SLOT is the
#           whole precision of this pass: `b.light` is returned and
#           `b.height` and `b.lum` are not, so asking about `b` as a whole
#           calls all three live and frees nothing.
#
#   STEP 4  Owned and not escaping => FREE AT SCOPE EXIT. `b.height` and
#           `b.lum`. The backend emits this as a `defer`, which needs no
#           position: decided once at the declaration, run on every path out.
#
#   STEP 5  A local OVERWRITTEN IN A LOOP needs a free the other side of the
#           assignment, because a scope-exit free fires once and the leak is
#           one buffer per iteration:
#
#               for i < n:
#                 let ns = {xs: xs} bump
#                 xs = ns              # the previous xs dies HERE
#
#           Allowed only when every value ever assigned to the name is a
#           fresh buffer (so the new value can never BE the old one), the
#           name never escapes, and it is a local rather than a parameter
#           whose first value belongs to the caller.
#
#   STEP 6  A fn with a MOVED twin hands its first parameter over to be
#           consumed. The twin frees each parameter slot the result does not
#           hand back — asked PER SLOT, because a result that returns one
#           field unchanged used to keep every other field alive with it.
#
# ---------------------------------------------------------------------------
# WHERE THIS RUNS, AND WHY IT IS NOT EARLIER
# ---------------------------------------------------------------------------
#
# The DECISION is backend-neutral, which is why it lives here. The moment it
# runs is not: this must run AFTER `lowerModule` and `markSeqCopiesIn`, on a
# backend's own copy of the tree.
#
# That is measured, not assumed. Running it straight after `mangleProgram`,
# before any backend's deepCopy, claims MORE than running it at emit time —
# and the extra is a double free. On `world_server`'s `relight`:
#
#     pre-clone   a -> [height, lum, light]    r -> [height, lum, light]
#     after       a -> nothing                 r -> nothing
#
# `a` and `r` are handed to `pass`, and `pass`'s twin frees all three slots of
# what it consumes. Freeing them at scope exit as well is freeing them twice.
# Before lowering, the twin-call rewrite has not happened, so they do not look
# consumed yet — step 3's `isMovedArg` has nothing to see.
#
# So two of this pass's inputs are established by lowering: WHICH CALL SITES
# BECAME TWIN CALLS, and which bindings copy. Until those move earlier, this
# cannot.
#
# AND THAT IS EXACTLY WHAT STAGE C IS. `thoughts/ssa-mirror-design.md` wants
# the copy decision read off the SSA mirror, which is built before lowering;
# once it is, this pass stops needing post-lowering marks and can run once,
# before the clone, for every backend at the same time. The architectural
# instinct and the memory work converge on the same change.
#
# ---------------------------------------------------------------------------
# WHY EACH "NO" IS THE SAFE ANSWER
# ---------------------------------------------------------------------------
#
# Every question here fails towards NOT freeing. A slot this pass declines to
# claim is a leak — which is where the Odin backend already was, so nothing
# regresses. A slot it claims wrongly is a double free or a use-after-free,
# which is silent and far worse. So anything unmodelled answers "someone else
# owns it" and "it escapes", and the shapes that are understood are listed
# rather than inferred.
import ast, tables, sets, os
import resolution
import ast_query
import twin_shape
from analysis_ssa import rootOf, pathOf
from analysis_provenance import exclusivelyOwned, slotIsFresh, consumedSlotsSsa
from lowering_seqcopy import needsDup, recordDupFields


type
  Slot* = string
    ## "" is the value itself (a bare `Seq`); anything else is a field name.

  FreeKind* = enum
    ## WHERE a buffer is released. One value may carry at most one of these,
    ## and that "at most one" is the double-free invariant made structural
    ## rather than hoped for — see `checkInvariants`.
    fkScopeExit    ## a `defer` at the declaration: every path out of the block
    fkOverwrite    ## immediately before the assignment that replaces it
    fkTwinParam    ## the MOVED twin consuming its first parameter

  FreeSite* = object
    local*: string
    slot*: Slot
    kind*: FreeKind

  Ownership* = object
    ## What one function body owns, and where each of those buffers dies.
    freeAtScopeExit*: Table[string, seq[Slot]]
      ## local -> the slots to free when the block ends (step 4)
    freeBeforeOverwrite*: HashSet[string]
      ## locals whose OLD value dies at each reassignment (step 5)
    twinFreesParam*: seq[Slot]
      ## the slots the MOVED twin frees of the parameter it consumes (step 6)
    freed*: seq[FreeSite]
      ## EVERY release this pass decided, in one list.
      ##
      ## The three fields above are what each emitter reads; this is what the
      ## pass can be CHECKED against. Correctness of a free used to be
      ## established by reading the emitter and running valgrind afterwards —
      ## a shipped use-after-free got through that (docs/ownership-and-ssa.md,
      ## M7). Recording the decision where it is made lets the invariants be
      ## asserted at the moment of deciding, on every build.

  Scan = object
    ## Just enough context to answer a question about one body.
    res: Resolution
    m: Module
    body: Expr
    copiedOut: HashSet[NodeId]
      ## bindings that copied every heap slot out of their right-hand side —
      ## see `findCopiedOut`

let Enabled = getEnv("TUCK_NO_SEQ_FREE").len == 0
  ## ON. `TUCK_NO_SEQ_FREE=1` turns the whole pass off, for bisecting a
  ## suspected bad free against the leak it would otherwise replace.

let Debug = not defined(release) and getEnv("TUCK_DEBUG_SEQ").len > 0

# --- shared vocabulary -----------------------------------------------------

proc holdsHeap(s: Scan, t: Type): bool =
  ## Can a value of this type be carrying a heap buffer at all? A scalar
  ## cannot, and asking about one only ever produces a false alarm.
  if t == nil: return false
  seqElem(t) != nil or seqFieldNames(s.res, s.m, t).len > 0

proc slotsOf(s: Scan, t: Type): seq[Slot] =
  ## The slots a value of this type has: one unnamed slot for a bare `Seq`,
  ## otherwise its Seq-typed field names.
  if seqElem(t) != nil: @[""] else: seqFieldNames(s.res, s.m, t)

# --- STEP 1: the locals ----------------------------------------------------

proc collectLocals(body: Expr, timesAssigned: var CountTable[string],
                   declaredWith: var Table[string, Expr]) =
  ## Every name this body assigns, how often, and the value it was DECLARED
  ## with. The count is what tells step 4's question from step 5's.
  var stack = @[body]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil: continue
    for ch in n.children: stack.add(ch)
    if n.kind != exkAssign or n.target == nil or n.target.kind != exkVar:
      continue
    timesAssigned.inc(n.target.name)
    if n.isDecl: declaredWith[n.target.name] = n.assignVal

proc findCopiedOut(s: Scan): HashSet[NodeId] =
  ## Right-hand sides whose every heap slot was COPIED into the name being
  ## bound. Recorded because such a binding does not let its source escape:
  ## the new name holds copies, so whatever they were built from is dead.
  ##
  ##     let r = {f: a, ...} pass     # `pass` hands a's buffers back, which
  ##                                  # is why the binding copies them — so
  ##                                  # `a`'s originals die here
  ##     xs = ns                      # emits xs = copy(ns); `ns` dies here
  ##
  ## The copy marks are the whole witness. Nothing about the callee has to be
  ## proved separately.
  var stack = @[s.body]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil: continue
    for ch in n.children: stack.add(ch)
    if n.kind != exkAssign or n.assignVal == nil: continue
    let v = n.assignVal
    let t = s.res.typeFor(v)
    if seqElem(t) != nil:
      if needsDup(s.res, v): result.incl(v.id)
    elif v.kind in {exkCall, exkChain}:
      let want = seqFieldNames(s.res, s.m, t)
      if want.len == 0: continue
      let copied = recordDupFields(s.res, v)
      var everySlot = want.len > 0
      for f in want:
        if f notin copied: everySlot = false
      if everySlot: result.incl(v.id)

# --- STEP 2: ownership -----------------------------------------------------

proc ownsSlot(s: Scan, val: Expr, slot: Slot): bool =
  ## Did this binding hand the name a buffer nobody else holds?
  ##
  ## TWO ROUTES, and the second reads backwards until you have been bitten by
  ## it. `exclusivelyOwned` TRUE means the callee built the buffer and kept
  ## nothing, so no copy was needed. `exclusivelyOwned` FALSE is not "someone
  ## else owns it" — it is precisely why `markSeqCopies` marked the site, so
  ## a copy was emitted and the copy is ours. Reading only the first route
  ## made every field of `relight`'s three intermediates look unowned while
  ## the emitted code copies all nine.
  if slot.len == 0:
    val.kind == exkList or
    needsDup(s.res, val) or
    exclusivelyOwned(s.res, s.m, val, "")
  else:
    slot in recordDupFields(s.res, val) or
    exclusivelyOwned(s.res, s.m, val, slot)

# --- STEP 3: escape --------------------------------------------------------

type Mention = enum
  mNotOurs    ## this node is not a mention of the local
  mAccounted  ## a mention already answered; do NOT descend into it
  mEscapes    ## the slot leaves the body here

proc mentionOf(s: Scan, n: Expr, name: string, slot: Slot,
               sealed: bool): Mention =
  ## What one node says about the local we are following.
  ##
  ## A FIELD READ IS NOT A WHOLE-RECORD READ. `b.light` carries the bare `b`
  ## as its receiver, so descending into it re-reads the name and every slot
  ## of `b` looks live. `mAccounted` is what stops that descent, and getting
  ## it wrong is invisible: every local simply reads as escaping, with no
  ## wrong answer anywhere to point at.
  if n.kind == exkField and rootOf(pathOf(n)) == name:
    let wanted = if slot.len == 0: name else: name & "." & slot
    if sealed and (slot.len == 0 or pathOf(n) == wanted): return mEscapes
    return mAccounted
  if n.kind == exkVar and n.name == name:
    # A bare mention takes every slot with it.
    if sealed: return mEscapes
    # A MOVED ARGUMENT IS GONE, unconditionally. This was once relaxed to
    # "gone only if the callee's twin really frees it", and the predicate
    # answering that was a second copy of the twin's own rule (step 6). The
    # rule went per slot, the copy did not, and the result was a double free
    # that segfaulted. Two predicates for one fact, again.
    if n.id.isSet and isMovedArg(s.res, n): return mEscapes
  mNotOurs

proc sealsContents(s: Scan, n: Expr, alreadySealed: bool): bool =
  ## Does this node put whatever is inside it beyond the body's reach?
  ##
  ## WHAT THE DESTINATION CAN HOLD is the test, never the node kind: a
  ## `return` of an int cannot be carrying our buffer away, and
  ## `acc = acc + s.len` is exactly that shape.
  if alreadySealed or n.kind == exkSend: return true
  if n.kind in {exkReturn, exkRaise}:
    return n.returnVal == nil or s.holdsHeap(s.res.typeFor(n.returnVal))
  if n.kind == exkCall:
    # ...unless the binding around it copied every slot out, in which case
    # what went in is dead rather than captured. See `findCopiedOut`.
    if n.id.isSet and n.id in s.copiedOut: return false
    return s.holdsHeap(s.res.typeFor(n))
  false

proc slotEscapes(s: Scan, name: string, slot: Slot): bool =
  ## Can this slot still be reached once the body has returned?
  ##
  ## One walk, carrying a `sealed` flag that says "everything below here is
  ## on its way out of the body".
  if s.body == nil: return false
  var stack = @[(s.body, false)]
  while stack.len > 0:
    let (n, sealed) = stack.pop()
    if n == nil: continue
    case s.mentionOf(n, name, slot, sealed)
    of mEscapes: return true
    of mAccounted: continue
    of mNotOurs: discard
    let seals = s.sealsContents(n, sealed)
    if n.kind == exkAssign:
      # Binding to ANOTHER name normally seals the right-hand side — the
      # value is now reachable through a name this walk is not following.
      # Not when the binding copied every slot out of it.
      let toAnotherName = n.target != nil and pathOf(n.target) != name
      let copiesOut = n.assignVal != nil and n.assignVal.id.isSet and
                      n.assignVal.id in s.copiedOut
      stack.add((n.assignVal,
                 if toAnotherName and not copiesOut:
                   s.holdsHeap(s.res.typeFor(n.target))
                 else: seals))
      stack.add((n.target, seals))
      continue
    for ch in n.children: stack.add((ch, seals))
  false

# --- STEP 4: what dies at scope exit ---------------------------------------

proc diesAtScopeExit(s: Scan, name: string, val: Expr,
                     timesAssigned: CountTable[string]): seq[Slot] =
  ## The slots of this local that this body owns and never lets go.
  ##
  ## ASSIGNED EXACTLY ONCE is what makes the answer need no further analysis:
  ## one version, no reassignment, so the name and the allocation are the
  ## same thing for the whole scope. A name assigned more than once is step
  ## 5's business.
  if timesAssigned[name] != 1 or val == nil: return
  let t = s.res.typeFor(val)
  if not s.holdsHeap(t): return
  for slot in s.slotsOf(t):
    if s.ownsSlot(val, slot) and not s.slotEscapes(name, slot):
      result.add(slot)

# --- STEP 5: what dies at an overwrite -------------------------------------

proc valuesAssignedTo(body: Expr, name: string): seq[Expr] =
  var stack = @[body]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil: continue
    for ch in n.children: stack.add(ch)
    if n.kind == exkAssign and n.target != nil and
       n.target.kind == exkVar and n.target.name == name:
      result.add(n.assignVal)

proc isFreshBuffer(s: Scan, v: Expr): bool =
  ## Does this value hand the name a buffer nothing else holds? Needed
  ## because `x = <something that may be x>` would free what it is about to
  ## read.
  if v == nil: return false
  v.kind == exkList or
  needsDup(s.res, v) or
  (v.id.isSet and v.id in s.copiedOut) or
  exclusivelyOwned(s.res, s.m, v, "")

proc diesAtOverwrite(s: Scan, d: Decl,
                     timesAssigned: CountTable[string]): HashSet[string] =
  ## Locals overwritten in a loop, whose OLD value dies at the overwrite.
  ##
  ## A scope-exit free cannot reach this: it fires once, and the leak is one
  ## buffer per iteration.
  ##
  ## THREE CONDITIONS, each a use-after-free if it is wrong:
  ##   * every value ever assigned is fresh, so the new one is never the old;
  ##   * the name never escapes, so nobody else holds an earlier value;
  ##   * it is a local, not a parameter — a parameter's first value belongs
  ##     to the caller, and only the twin may free that.
  var params: HashSet[string]
  for p in d.fnParams: params.incl(p.name)
  for name, count in timesAssigned:
    if count < 2 or name in params: continue
    let values = valuesAssignedTo(s.body, name)
    if values.len == 0: continue
    # Bare `Seq` only for now: a record overwritten in a loop needs the old
    # value's slots compared field by field, which nothing asks for yet.
    if seqElem(s.res.typeFor(values[0])) == nil: continue
    var allFresh = true
    for v in values:
      if not s.isFreshBuffer(v): allFresh = false
    if allFresh and not s.slotEscapes(name, ""): result.incl(name)

# --- STEP 6: the twin's parameter ------------------------------------------

proc threadingTwinFrees(s: Scan, d: Decl, paramSlots: seq[Slot],
                        handedOn: HashSet[string]): seq[Slot] =
  ## A THREADING fn: parameter and result are the same record, so the field
  ## names correspond and each slot can be asked about on its own.
  ##
  ## A result slot that is a FRESH allocation cannot be the parameter's, so
  ## the parameter's is dead and the twin is the last place that can free it.
  ## A result slot that is not fresh may well BE the parameter's, so it stays.
  ##
  ## This used to be all-or-nothing, and that was most of issue #82:
  ## `relight` returns `sl.height` and `sl.lum` unchanged, and those two kept
  ## `sl.light` alive with them.
  for f in paramSlots:
    if f notin handedOn and slotIsFresh(s.res, s.m, d.name, f): result.add(f)

proc wholesaleTwinFrees(s: Scan, d: Decl, paramSlots, resultSlots: seq[Slot],
                        handedOn: HashSet[string]): seq[Slot] =
  ## NOT a threading fn: all-or-nothing, which is all that can be said when
  ## the result's slots have no name-wise correspondence with the parameter's.
  ##
  ## Ask of the RESULT whether anything it hands back could be the
  ## parameter's. If nothing is, every parameter slot is free to go.
  var mayFree = true
  if resultSlots.len == 0:
    mayFree = slotIsFresh(s.res, s.m, d.name, "")
  else:
    for f in resultSlots:
      if not slotIsFresh(s.res, s.m, d.name, f): mayFree = false
  if not mayFree: return
  # THE PARAMETER'S OWN SHAPE decides what to name, not the result's. A fn
  # taking a record and returning a bare `Seq` has record slots to free, and
  # reading this off the result instead silently freed nothing — worth 1.6 GB
  # on matching_engine, caught by re-measuring after a refactor.
  if paramSlots.len == 0: return @[""]
  for f in paramSlots:
    if f notin handedOn: result.add(f)

proc twinFreedSlots(s: Scan, d: Decl): seq[Slot] =
  ## Which slots of the consumed parameter this fn's MOVED twin frees.
  if d.fnParams.len == 0 or d.fnReturnType == nil: return
  let paramSlots = movedCopyFields(s.res, s.m, d.fnParams[0].typ)
  let resultSlots = movedCopyFields(s.res, s.m, d.fnReturnType)
  # A slot handed on to ANOTHER twin is that twin's to free; freeing it here
  # too segfaults under TUCK_TRACK.
  let handedOn = consumedSlotsSsa(s.res, s.m, d)
  if "" in handedOn: return

  if paramSlots.len > 0 and resultSlots.len > 0 and
     sameTypeName(d.fnParams[0].typ, d.fnReturnType):
    s.threadingTwinFrees(d, paramSlots, handedOn)
  else:
    s.wholesaleTwinFrees(d, paramSlots, resultSlots, handedOn)

# --- the pass ---------------------------------------------------------------

proc checkInvariants*(o: Ownership, d: Decl) =
  ## What must be true of any answer this pass gives. Cheap, and run on every
  ## build rather than behind a flag: each of these was a real bug first.
  var seen: HashSet[string]
  for f in o.freed:
    # ONE RELEASE PER SLOT. A slot freed twice is a double free, and that is
    # not hypothetical: `b` freed at scope exit AND by the twin consuming it
    # segfaulted `value_semantics`. Here it is a duplicate key.
    let key = f.local & "\x00" & f.slot
    doAssert key notin seen,
      "ownership: " & d.name & " frees " & f.local &
      (if f.slot.len > 0: "." & f.slot else: "") & " more than once"
    seen.incl(key)

  # THE TWO LOCAL RULES ARE MUTUALLY EXCLUSIVE. Step 4 needs the name assigned
  # exactly once; step 5 needs it assigned more than once. A name in both
  # means one of those counts is wrong, and the emitted code would free the
  # same buffer at the overwrite and again at the end.
  for name in o.freeBeforeOverwrite:
    doAssert name notin o.freeAtScopeExit,
      "ownership: " & d.name & " frees " & name &
      " both at an overwrite and at scope exit"

  # A SLOT IS NAMED ONCE PER LOCAL. `@["xs", "xs"]` would emit two deletes.
  for name, slots in o.freeAtScopeExit:
    var once: HashSet[Slot]
    for sl in slots:
      doAssert sl notin once,
        "ownership: " & d.name & " lists " & name & "." & sl & " twice"
      once.incl(sl)

proc ownershipOf*(res: Resolution, m: Module, d: Decl): Ownership =
  ## Run all six steps over one function body.
  if not Enabled or d.fnBody == nil: return
  var s = Scan(res: res, m: m, body: d.fnBody)
  s.copiedOut = s.findCopiedOut()

  var timesAssigned: CountTable[string]
  var declaredWith: Table[string, Expr]
  collectLocals(d.fnBody, timesAssigned, declaredWith)      # step 1

  for name, val in declaredWith:                            # steps 2-4
    let slots = s.diesAtScopeExit(name, val, timesAssigned)
    if slots.len > 0: result.freeAtScopeExit[name] = slots

  result.freeBeforeOverwrite = s.diesAtOverwrite(d, timesAssigned)  # step 5
  result.twinFreesParam = s.twinFreedSlots(d)                       # step 6

  # Every decision above, gathered once so it can be checked as a whole.
  for name, slots in result.freeAtScopeExit:
    for sl in slots:
      result.freed.add FreeSite(local: name, slot: sl, kind: fkScopeExit)
  for name in result.freeBeforeOverwrite:
    result.freed.add FreeSite(local: name, slot: "", kind: fkOverwrite)
  let movedParam = if d.fnParams.len > 0: d.fnParams[0].name else: ""
  for sl in result.twinFreesParam:
    result.freed.add FreeSite(local: movedParam, slot: sl, kind: fkTwinParam)
  checkInvariants(result, d)

  when not defined(release):
    if Debug:
      for name, slots in result.freeAtScopeExit:
        echo "OWN ", d.name, ".", name, " dies-at-exit=", slots
      for name in result.freeBeforeOverwrite:
        echo "OWN ", d.name, ".", name, " dies-at-overwrite"
      if result.twinFreesParam.len > 0:
        echo "OWN ", d.name, " twin-frees-param=", result.twinFreesParam
