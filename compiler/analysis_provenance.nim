# compiler/analysis_provenance.nim
#
# DOES A CALL'S RESULT ALIAS ANYTHING THE CALLER STILL HOLDS?
#
# `lowering_seqcopy` decides which `Seq` bindings must be real copies on the
# two backends whose container is a header. Its rule was "everything except a
# fresh list literal", and the file says why: "a call may hand back its own
# argument". That is true, and it is also true far less often than always —
#
#     fn sweep({ladder: Seq[int], ...}) -> Filled    # builds a NEW ladder
#     fn wrap({xs: Seq[int]}) -> Pair                # hands xs straight back
#
# — and the difference is worth four ladder copies per order in
# `benches/apps/matching_engine.tuck`, of which two are pure waste.
#
# TWO ATTEMPTS TO SHORTCUT THIS FAILED, WHICH IS WHY IT IS A PASS. Exempting
# call results outright, and exempting record bindings from calls, were both
# tried and both silently produced 106 instead of 17 on the aliasing
# assertion in `value_semantics` — on D and Odin only, because Nim's `seq`
# has real value semantics and reports green either way. The question is not
# answerable syntactically; it needs the callee's body.
#
# WHAT MAKES IT CHEAP HERE. The same thing that makes last-use analysis cheap
# (see analysis_liveness.nim): Tuck has no aliasing, so a value's provenance
# is decided by where it came from and nothing else can have captured it on
# the way. Fns are top-level, the only escape is `return`, and after
# `genSendHelper` copies its payload a send cannot smuggle a buffer out
# either. So one walk over one body answers it.
#
# THE LATTICE, and it only ever moves one way:
#
#     oFresh  <  oAliased  <  oUnknown
#
# Anything the walk does not understand answers `oUnknown`, which the
# consumer reads exactly as `oAliased` — copy, as it always did. A wrong
# answer in that direction costs an allocation; the other direction is the
# aliasing bug this whole file exists to avoid, so every join takes the max.
#
# SCOPE, deliberately: a call to a fn this module does not declare is
# `oUnknown`. The driver marks each module inside the load loop, so a
# whole-program summary would need a pre-pass over every module first. That
# is worth doing and is not done here — cross-module calls keep copying, the
# same as before this file existed.
import ast, tables, sets, os
import resolution
import ast_query

const MaxRounds = 8
  ## Fixpoint bound. Bodies are small and the lattice has three levels, so
  ## this settles in two or three rounds; the cap is a guard against a shape
  ## the walk mishandles, not a tuning knob. Anything still moving when it
  ## runs out is forced to `oUnknown`.

type
  Origin* = enum
    oFresh      ## allocated in this body, or built only out of fresh things
    oAliased    ## may alias a parameter, so the caller may still hold it
    oUnknown    ## not determined; read exactly as oAliased

  Cell* = object
    origin*: Origin
    token*: NodeId  ## WHICH allocation this is. Two fields of one returned
                    ## record can both be fresh and still be the SAME buffer
                    ## (`return {a: a, b: a}`), which `oFresh` alone cannot
                    ## tell apart from two distinct ones. Only meaningful
                    ## when origin is oFresh.

  Prov* = object
    whole*: Cell                    ## the value itself — and the answer for
                                    ## any field not named below, so the walk
                                    ## never has to enumerate a type's fields
    fields*: Table[string, Cell]

var summaries: Table[string, Prov]
  ## Per fn NAME, for the module currently being marked. Cleared by
  ## `buildProvenance`, because the backends each lower their own deep copy
  ## and a summary computed against one tree must not be read against
  ## another.

proc noToken(): NodeId = NodeId(0)

proc unknownCell(): Cell = Cell(origin: oUnknown, token: noToken())
proc aliasedCell(): Cell = Cell(origin: oAliased, token: noToken())

proc unknownProv(): Prov = Prov(whole: unknownCell())

proc cellFor*(p: Prov, field: string): Cell =
  ## The cell for a named field, falling back to the value as a whole. The
  ## fallback is what lets a record whose shape the walk never resolved still
  ## answer every question the consumer asks.
  if field.len > 0 and field in p.fields: p.fields[field] else: p.whole

proc join(a, b: Cell): Cell =
  ## Merge two paths to the same value. Takes the MAX of the lattice, so a
  ## value that is fresh on one branch and aliased on another is aliased.
  if a.origin == oFresh and b.origin == oFresh:
    # Both fresh. If they are the same allocation the token survives; if not,
    # the merged value is still fresh but WHICH allocation it is is no longer
    # knowable, and a token-less fresh cell is never reported exclusive.
    if a.token == b.token: a else: Cell(origin: oFresh, token: noToken())
  else:
    Cell(origin: max(a.origin, b.origin), token: noToken())

proc joinProv(a, b: Prov): Prov =
  result.whole = join(a.whole, b.whole)
  for k in a.fields.keys:
    result.fields[k] = join(cellFor(a, k), cellFor(b, k))
  for k in b.fields.keys:
    if k notin result.fields:
      result.fields[k] = join(cellFor(a, k), cellFor(b, k))

proc isSeqTyped(t: Type): bool =
  ## SEQ ONLY, and the narrowness is load-bearing rather than an omission.
  ##
  ## `str` also owns heap, and it is deliberately not here. `afterBinding`
  ## below reasons "this slot was not exclusive, so the binding copied it, so
  ## it is fresh now" — and the copy pass this feeds only ever copies `Seq`.
  ## A `str` cell would be a claim with nothing behind it. It is also not
  ## needed: `str` is immutable in both D and Odin, so sharing its buffer
  ## cannot be observed (the same reason `copyableContainer` excludes it from
  ## the send copy).
  ##
  ## Deliberately NOT codegen_common's `ownsHeap`: that lives downstream of
  ## this file and importing it would close a cycle.
  seqElem(t) != nil

# --- the walk ---------------------------------------------------------------

type Ctx = object
  res: Resolution
  m: Module
  params: HashSet[string]   ## names that arrived from the caller
  locals: Table[string, Prov]

proc provOf(c: var Ctx, e: Expr): Prov

proc provOfCall(c: var Ctx, e: Expr): Prov =
  ## A call. Three shapes reach here and only the first is interesting.
  ##
  ## A RECORD CONSTRUCTION — `{a: x, b: y} Pair` — parses as a call over a
  ## struct payload, the same as any postfix application, so it is told apart
  ## by its argument rather than by its callee: one exkStruct argument and
  ## nothing else.
  if e.args.len == 1 and e.args[0] != nil and e.args[0].kind == exkStruct:
    var p = Prov(whole: Cell(origin: oFresh, token: noToken()))
    for f in e.args[0].fields:
      # HEAP FIELDS ONLY. An `int` field can neither be copied nor aliased,
      # so tracking one adds a cell that can only collide: `ask` and
      # `bestAsk` came out of `sweep` sharing a token and made each other
      # look shared, which is the opposite of what the token is for.
      if isSeqTyped(c.res.typeFor(f.value)):
        p.fields[f.name] = provOf(c, f.value).whole
    return p

  if e.callee == nil or e.callee.kind != exkVar: return unknownProv()
  let name = e.callee.name
  if name notin summaries: return unknownProv()   # imported, extern, or a
                                                  # shape allFns never yielded
  var p = summaries[name]
  # A FRESH RESULT IS THIS CALL'S OWN ALLOCATION. The callee's token names a
  # node inside the callee and means nothing out here; every call site is a
  # distinct allocation, so the site's own id is the identity.
  ensureId(e)
  if p.whole.origin == oFresh: p.whole.token = e.id
  for k, v in p.fields:
    if v.origin == oFresh:
      # Distinct fields of one returned record need distinct tokens, and the
      # callee already proved whether they share one. Re-key onto this call
      # so two different calls never collide, keeping the callee's own
      # sharing: same token there stays same token here.
      p.fields[k] = Cell(origin: oFresh,
                         token: NodeId(uint32(e.id) xor uint32(v.token)))
  p

proc provOf(c: var Ctx, e: Expr): Prov =
  ## Where did this expression's value come from?
  if e == nil: return unknownProv()
  case e.kind
  of exkList:
    # A fresh literal owns its storage outright — the one exemption the copy
    # pass has always had, now with an identity attached.
    ensureId(e)
    Prov(whole: Cell(origin: oFresh, token: e.id))
  of exkVar:
    if e.name in c.params: Prov(whole: aliasedCell())
    elif e.name in c.locals: c.locals[e.name]
    else: unknownProv()
  of exkStruct:
    var p = Prov(whole: Cell(origin: oFresh, token: noToken()))
    for f in e.fields:
      if isSeqTyped(c.res.typeFor(f.value)):
        p.fields[f.name] = provOf(c, f.value).whole
    p
  of exkCall: provOfCall(c, e)
  of exkField:
    # `b.items` reaches into whatever `b` is, so it is exactly as aliased.
    if e.receiver == nil: unknownProv()
    else: Prov(whole: cellFor(provOf(c, e.receiver), e.fieldName))
  of exkBracket:
    # An element of a container aliases the container it was read out of.
    if e.brReceiver == nil: unknownProv()
    else: Prov(whole: provOf(c, e.brReceiver).whole)
  of exkBinary:
    # Concatenation and friends build a NEW value; none of the binary
    # operators hands back an operand.
    if isSeqTyped(c.res.typeFor(e)):
      ensureId(e)
      Prov(whole: Cell(origin: oFresh, token: e.id))
    else: unknownProv()
  of exkIf: joinProv(provOf(c, e.thenBranch), provOf(c, e.elseBranch))
  of exkMatch:
    var p = unknownProv()
    var first = true
    for arm in e.arms:
      let a = provOf(c, arm.body)
      p = if first: a else: joinProv(p, a)
      first = false
    if first: unknownProv() else: p
  of exkBlock:
    # A block's value is its last statement's.
    if e.stmts.len == 0: unknownProv() else: provOf(c, e.stmts[^1])
  else: unknownProv()

proc mixToken(id: NodeId, field: string): NodeId =
  ## A distinct identity per copied field. The copies really are distinct
  ## allocations — one `tuckSeqCopy` each — so they must not look shared.
  ## A collision would make two distinct buffers read as one, which costs a
  ## copy and never grants a wrong exemption, so this fails in the safe
  ## direction.
  var h = uint32(id) * 0x9E3779B1'u32
  for ch in field: h = (h xor uint32(ord(ch))) * 16777619'u32
  NodeId(h)

proc afterBinding(e: Expr, v: Prov): Prov =
  ## What the NAME holds once THIS pass has done its work at this binding.
  ##
  ## The copy pass and the provenance are mutually dependent, and leaving the
  ## dependency out is what made the first version useless in practice: a slot
  ## that is not already exclusively owned gets a defensive copy right here,
  ## and a copy is a fresh allocation. Without this,
  ##
  ##     fn seed({xs: Seq[int]}) -> Box:
  ##       var b = {items: xs, n: 0} Box    # copied at this binding
  ##       return b
  ##
  ## reads as "returns its argument" — because the construction does — and
  ## every caller pays a second copy for a value `seed` had already made
  ## private. That is exactly the shape `sweep` has in the matching engine.
  ##
  ## There is no circularity: whether a slot is copied depends on the value
  ## arriving, and what the name then holds depends on the copy.
  result = v
  ensureId(e)
  if v.whole.origin != oFresh:
    result.whole = Cell(origin: oFresh, token: e.id)
  for k, cell in v.fields:
    if cell.origin != oFresh:
      result.fields[k] = Cell(origin: oFresh, token: mixToken(e.id, k))

proc noteAssignments(c: var Ctx, e: Expr) =
  ## Record what each local may hold. FLOW-INSENSITIVE on purpose: every
  ## value a name is ever given is joined into one answer, so a name that is
  ## fresh on one line and aliased on another reads as aliased everywhere.
  ## That is the safe direction, and it makes loops and branches need no
  ## special handling at all.
  if e == nil: return
  if e.kind == exkAssign and e.target != nil and e.target.kind == exkVar:
    let v = afterBinding(e.assignVal, provOf(c, e.assignVal))
    let n = e.target.name
    c.locals[n] = if n in c.locals: joinProv(c.locals[n], v) else: v
  for ch in e.children: noteAssignments(c, ch)

proc collectReturns(c: var Ctx, e: Expr, acc: var Prov, any: var bool) =
  if e == nil: return
  if e.kind == exkReturn:
    let p = provOf(c, e.returnVal)
    acc = if any: joinProv(acc, p) else: p
    any = true
  for ch in e.children: collectReturns(c, ch, acc, any)

proc summarize(res: Resolution, m: Module, d: Decl): Prov =
  ## One fn's answer. A fn with no reachable `return` is `oUnknown`: it may
  ## produce its value by a route this walk does not model, and guessing
  ## fresh there is the one guess that could be wrong.
  if d.fnBody == nil or d.isExtern or d.isPending or d.isDecision:
    return unknownProv()
  var c = Ctx(res: res, m: m)
  for p in d.fnParams: c.params.incl(p.name)
  # Locals first, so a `return` that names one has something to read. Repeated
  # because an assignment may name a local assigned further down.
  for _ in 0 ..< 2: noteAssignments(c, d.fnBody)
  var acc = unknownProv()
  var any = false
  collectReturns(c, d.fnBody, acc, any)
  if any: acc else: unknownProv()

proc buildProvenance*(res: Resolution, m: Module) =
  ## Summarize every fn this module declares, to a fixpoint.
  ##
  ## Every fn starts at `oFresh` — the optimistic end of the lattice — and
  ## each round can only move one further along it, so the iteration is
  ## monotone and settles. Starting pessimistic would never recover: a
  ## recursive fn would read its own unfinished summary as `oUnknown` and
  ## stay there.
  summaries.clear()
  # A NAME MUST IDENTIFY ONE BODY. `allFns` yields object and actor members
  # as well as top-level fns, and a member keeps its bare name here while the
  # emitted symbol is qualified — so a member `push` and a top-level `push`
  # would land in the same slot and a call to one would read the other's
  # summary. That is the one way this table could hand out an answer that is
  # too fresh, so a shared name is answered `oUnknown` outright.
  var seen, duplicated: HashSet[string]
  for d in m.allFns():
    if d.name in seen: duplicated.incl(d.name) else: seen.incl(d.name)
  for d in m.allFns():
    summaries[d.name] =
      if d.name in duplicated: unknownProv()
      else: Prov(whole: Cell(origin: oFresh, token: noToken()))
  for round in 0 ..< MaxRounds:
    var changed = false
    for d in m.allFns():
      if d.name in duplicated: continue
      let before = summaries[d.name]
      let after = summarize(res, m, d)
      if after.whole != before.whole or after.fields != before.fields:
        summaries[d.name] = after
        changed = true
    if not changed:
      when not defined(release):
        if getEnv("TUCK_DEBUG_PROV").len > 0:
          for n, pr in summaries:
            var fs = ""
            for k, v in pr.fields: fs.add(" " & k & "=" & $v.origin & "/" & $uint32(v.token))
            echo "PROV ", n, " whole=", pr.whole.origin, "/", uint32(pr.whole.token), fs
      return
  when not defined(release):
    if getEnv("TUCK_DEBUG_PROV").len > 0:
      for n, pr in summaries:
        var fs = ""
        for k, v in pr.fields: fs.add(" " & k & "=" & $v.origin & "/" & $uint32(v.token))
        echo "PROV ", n, " whole=", pr.whole.origin, "/", uint32(pr.whole.token), fs
  # Did not settle. Something in the walk is oscillating rather than rising,
  # which is a bug in this file — answer `oUnknown` for everything rather
  # than ship whichever half-state the last round happened to leave.
  for d in m.allFns(): summaries[d.name] = unknownProv()

# --- what the copy pass asks -------------------------------------------------

proc exclusivelyOwned*(res: Resolution, m: Module, e: Expr,
                       field = ""): bool =
  ## May this bound value (or its named field) skip its defensive copy?
  ##
  ## True only when the value is a CALL whose summary proves the slot is a
  ## fresh allocation that nothing else reaches: not a parameter of the
  ## callee, and not the same buffer as another field of the same result.
  ## Everything else — a name, a field read, an imported call, a shape the
  ## walk did not model — answers false and copies exactly as before.
  if e == nil or e.kind != exkCall: return false
  var c = Ctx(res: res, m: m)
  let p = provOfCall(c, e)
  if field.len == 0:
    # A bare Seq. It cannot alias itself, so being fresh is the whole test.
    return p.whole.origin == oFresh
  # A FIELD MUST BE NAMED. `cellFor`'s fallback to the value as a whole is
  # right when merging two paths and wrong here: a record whose Seq field the
  # walk never saw would inherit the construction's own `oFresh` and skip a
  # copy for a slot nothing ever looked at. An unnamed field is unknown, and
  # unknown copies.
  if field notin p.fields: return false
  let cell = p.fields[field]
  if cell.origin != oFresh: return false
  # A FIELD is exclusive when nothing else in this same result can be the
  # same buffer. Two fields CAN be: `return {a: xs, b: xs}` is one allocation
  # under two names, and `oFresh` alone cannot tell that from two.
  var freshFields = 0
  for _, v in p.fields:
    if v.origin == oFresh: inc freshFields
  if cell.token == noToken():
    # The join could not pin down WHICH allocation this is — it was fresh on
    # both paths but a different one on each. Safe only when there is nothing
    # else here it could have collided with. This is `sweep`: one heap field,
    # fresh by two different routes.
    return freshFields == 1
  for k, v in p.fields:
    # A token-less neighbour is an unknown allocation, so it could be this
    # one; a matching token says outright that it is.
    if k != field and v.origin == oFresh and
       (v.token == cell.token or v.token == noToken()):
      return false
  true
