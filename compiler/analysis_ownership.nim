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
#           calls all three live and frees nothing. Asked of the SSA graph's
#           uses (`ownership_escape`), not by walking the body per slot.
#
#   STEP 4  Owned and not escaping => FREE AT SCOPE EXIT. `b.height` and
#           `b.lum`. The backend emits this as a `defer`, which needs no
#           position: decided once at the declaration, run on every path out.
#           A `str` is a value with one slot, owned when one of the
#           backend's allocating runtime procs made it (`ownership_str`).
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
# BECAME TWIN CALLS, and which bindings copy. It runs as step 6 of
# `backend_prepare`, after both — once per build, before any emitter, which
# is all "before the clone" was asking for (ROADMAP M3.1).
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
import ast, tables, sets, os, strutils
import resolution
import ast_query
import twin_shape
import buffer_check
import ownership_str
import ownership_escape
from analysis_provenance import slotIsFresh, consumedSlotsSsa
from lowering_seqcopy import needsDup, recordDupFields, decidedExclusive,
                             transferredSlots


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
    ix: BodyIndex
      ## the body's uses and ancestors, for the escape question (step 3)
    heapRule, strRule: SealRule
      ## what exempts a node from carrying a heap slot / a `str` out
    strProcs: seq[string]
      ## the backend's runtime procs that return a `str` the caller owns;
      ## empty where the runtime frees its own (Nim, D)

let Enabled = getEnv("TUCK_NO_SEQ_FREE").len == 0
  ## ON. `TUCK_NO_SEQ_FREE=1` turns the whole pass off, for bisecting a
  ## suspected bad free against the leak it would otherwise replace.

let Debug = not defined(release) and getEnv("TUCK_DEBUG_SEQ").len > 0

# --- shared vocabulary -----------------------------------------------------

proc holdsHeap(s: Scan, t: Type): bool = holdsHeapSlots(s.res, s.m, t)

proc isStr(t: Type): bool = t != nil and t.kind == tkNamed and t.name == "str"

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

proc takesNothingOf(s: Scan, v: Expr): bool =
  ## Is every heap slot this binding holds either copied or exclusive?
  let t = s.res.typeFor(v)
  if seqElem(t) != nil:
    return needsDup(s.res, v) or decidedExclusive(v, "")
  if v.kind notin {exkCall, exkChain}: return false
  let want = seqFieldNames(s.res, s.m, t)
  if want.len == 0: return false
  let copied = recordDupFields(s.res, v)
  for f in want:
    if f notin copied and not decidedExclusive(v, f): return false
  true

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
  ## The copy marks are the whole witness — both halves of them: a slot the
  ## binding COPIED, and a slot it left alone because the value was already
  ## the binder's (`decidedExclusive`). Either way the name holds nothing the
  ## right-hand side was built from. Tuck has no aliasing channel but a
  ## call's result, so a result whose every heap slot is one or the other
  ## captured nothing of its arguments. (A MOVED argument did go into it —
  ## and the escape question treats a moved argument as gone before this is
  ## asked.)
  ##
  ## Counting only the copied half made the #77 fix leak the other way: once
  ## `bump`'s result stopped being copied, `xs` looked captured by it and
  ## lost its free at the overwrite.
  var stack = @[s.body]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil: continue
    for ch in n.children: stack.add(ch)
    if n.kind != exkAssign or n.assignVal == nil: continue
    if s.takesNothingOf(n.assignVal): result.incl(n.assignVal.id)

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
    decidedExclusive(val, "")
  else:
    slot in recordDupFields(s.res, val) or
    decidedExclusive(val, slot)

# --- STEP 3: escape --------------------------------------------------------
#
# `ownership_escape.escapes`, over the body's SSA uses. It was a walk of the
# whole body per local per slot, with a second walk and a second copy of the
# rules for `str`; see that module's header for the rules themselves.

proc slotEscapes(s: Scan, name: string, slot: Slot): bool =
  s.ix.escapes(s.heapRule, name, slot)

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
  if isStr(t):
    # ONE SLOT, owned when an allocating runtime proc made it. Nothing else
    # about a `str` differs from a `Seq`.
    if ownedStrCall(s.res, s.strProcs, val) and
       not s.ix.escapes(s.strRule, name, ""):
      result.add("")
    return
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
  decidedExclusive(v, "")

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

proc assignedValues(s: Scan): seq[Expr] =
  ## Every right-hand side in the body.
  var stack = @[s.body]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil: continue
    for ch in n.children: stack.add ch
    if n.kind == exkAssign and n.assignVal != nil: result.add n.assignVal

proc twinFreedSlots(s: Scan, d: Decl): seq[Slot] =
  ## Which slots of the consumed parameter this fn's MOVED twin frees.
  if d.fnParams.len == 0 or d.fnReturnType == nil: return
  let paramSlots = movedCopyFields(s.res, s.m, d.fnParams[0].typ)
  let resultSlots = movedCopyFields(s.res, s.m, d.fnReturnType)
  # A slot handed on to ANOTHER twin is that twin's to free; freeing it here
  # too segfaults under TUCK_TRACK. So is a slot a LOCAL took at the
  # parameter's last read (`lowering_seqcopy.transferredSlots`): the local
  # owns it now, and the ownership rules above decide its free.
  var handedOn = consumedSlotsSsa(s.res, s.m, d)
  for v in s.assignedValues():
    for slot in transferredSlots(v): handedOn.incl slot
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

proc gatherFreed(o: var Ownership, d: Decl) =
  ## Every decision the six steps made, as one list, so it can be checked as
  ## a whole rather than one table at a time.
  for name, slots in o.freeAtScopeExit:
    for sl in slots:
      o.freed.add FreeSite(local: name, slot: sl, kind: fkScopeExit)
  for name in o.freeBeforeOverwrite:
    o.freed.add FreeSite(local: name, slot: "", kind: fkOverwrite)
  let movedParam = if d.fnParams.len > 0: d.fnParams[0].name else: ""
  for sl in o.twinFreesParam:
    o.freed.add FreeSite(local: movedParam, slot: sl, kind: fkTwinParam)

proc debugEcho(o: Ownership, d: Decl) =
  ## `TUCK_DEBUG_OWN`: the decisions, one line each.
  for name, slots in o.freeAtScopeExit:
    echo "OWN ", d.name, ".", name, " dies-at-exit=", slots
  for name in o.freeBeforeOverwrite:
    echo "OWN ", d.name, ".", name, " dies-at-overwrite"
  if o.twinFreesParam.len > 0:
    echo "OWN ", d.name, " twin-frees-param=", o.twinFreesParam

proc checkBuffers(s: Scan, d: Decl, o: Ownership) =
  ## buffer_check over this body's decisions: no buffer released twice, and
  ## none released at exit that the body returns.
  var sites: seq[tuple[local, slot: string, atExit: bool]]
  for f in o.freed:
    sites.add (f.local, f.slot, f.kind in {fkScopeExit, fkTwinParam})
  var returnSlots: seq[string]
  let rt = d.fnReturnType
  if rt != nil:
    if seqElem(rt) != nil or (rt.kind == tkNamed and rt.name == "str"):
      returnSlots = @[""]
    else: returnSlots = seqFieldNames(s.res, s.m, rt)
  let bad = bufferErrors(s.res, d, sites, returnSlots)
  doAssert bad.len == 0,
    "ownership: " & d.name & " — " & bad[0 .. min(2, bad.high)].join("; ")

proc ownershipOf*(res: Resolution, m: Module, d: Decl,
                  strProcs: seq[string] = @[]): Ownership =
  ## Run all six steps over one function body. `strProcs` is the backend's
  ## list of runtime calls returning a caller-owned `str` (step 4).
  if not Enabled or d.fnBody == nil: return
  var s = Scan(res: res, m: m, body: d.fnBody, strProcs: strProcs)
  s.copiedOut = s.findCopiedOut()
  s.ix = indexBody(res, m, d)
  s.heapRule = SealRule(carried: cHeapSlots, exemptCalls: s.copiedOut,
                        exemptBindings: s.copiedOut)
  s.strRule = strRule(res, strProcs, d.fnBody)

  var timesAssigned: CountTable[string]
  var declaredWith: Table[string, Expr]
  collectLocals(d.fnBody, timesAssigned, declaredWith)      # step 1

  for name, val in declaredWith:                            # steps 2-4
    let slots = s.diesAtScopeExit(name, val, timesAssigned)
    if slots.len > 0: result.freeAtScopeExit[name] = slots

  result.freeBeforeOverwrite = s.diesAtOverwrite(d, timesAssigned)  # step 5
  result.twinFreesParam = s.twinFreedSlots(d)                       # step 6

  result.gatherFreed(d)
  checkInvariants(result, d)
  s.checkBuffers(d, result)
  when not defined(release):
    if Debug: result.debugEcho(d)


# --- the pass ----------------------------------------------------------------
#
# DECIDED ONCE, BEFORE EMISSION, AND READ. `ownershipOf` used to be called by
# the Odin emitter as it printed each fn — twice per fn, once for the body's
# frees and once for the twin's — which made the decision a side effect of
# printing. `backend_prepare` now runs `decideOwnership` as a step of its
# own, after lowering and the copy marks it depends on, and the emitter asks
# `ownershipFor`. The decision is inspectable before any text exists, and
# the assertions in `ownershipOf` (checkInvariants, buffer_check) run at a
# named stage rather than whenever emission reaches a fn.

var decided: Table[NodeId, Ownership]

proc decideOwnership*(res: Resolution, m: Module, strProcs: seq[string]) =
  ## Every fn body's ownership, recorded by the fn's declaration id.
  for d in m.allFns():
    if d == nil or d.fnBody == nil: continue
    doAssert d.id.isSet, "ownership: fn " & d.name & " has no id"
    decided[d.id] = ownershipOf(res, m, d, strProcs)

proc ownershipFor*(d: Decl): Ownership =
  ## The decision `decideOwnership` recorded for this fn. Asserted present:
  ## a fn the pass never saw would otherwise be emitted with no frees at
  ## all, which reads exactly like a fn that needs none.
  if d.fnBody == nil or not Enabled: return
  doAssert d.id in decided,
    "ownership: no decision for " & d.name & " — backend_prepare runs " &
    "decideOwnership before emission, and this fn was not in allFns()"
  decided[d.id]
