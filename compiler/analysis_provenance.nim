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
import ast, tables, sets, os, strutils, sequtils
import resolution
import ast_query
from lowering import getFieldsForType
import twin_shape
import ssa_ir, ssa_cache

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
    src*: string    ## For oAliased: the PARAMETER this is, directly — the
    srcField*: string ## param itself ("") or one of its fields. "" in `src`
                    ## when it is anything less direct (an element, a
                    ## nested field, a join of two). A call site needs this
                    ## to know whether the callee's WRAPPER copied it.

  Prov* = object
    whole*: Cell                    ## the value itself — and the answer for
                                    ## any field not named below, so the walk
                                    ## never has to enumerate a type's fields
    fields*: Table[string, Cell]

var summaries: Table[string, Prov]
  ## Keyed by MODULE and fn name, not fn name alone.
  ##
  ## It used to be cleared per module, which was right while the only
  ## consumer ran during marking — `markSeqCopiesIn` builds and reads it in
  ## the same call. Stage 3 reads it at EMIT time, and the driver marks every
  ## module before emitting any, so a bare-name table would by then hold only
  ## the last module's answers and quietly hand them to every other module.
  ## Keying by module removes the phase dependency rather than documenting
  ## it.

proc keyOf(m: Module, name: string): string =
  ## A module is identified by its PATH — `Module` has no name field.
  m.path.join(".") & "\0" & name

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
  elif a.origin == oAliased and b.origin == oAliased and
       a.src == b.src and a.srcField == b.srcField:
    a                        # the same parameter slot on both paths
  else:
    Cell(origin: max(a.origin, b.origin), token: noToken())

proc fieldOf(whole: Cell, field: string): Cell =
  ## A field read out of a value that has no cell for that field. A direct
  ## parameter stays direct one level down (`p.ladder`); anything deeper is
  ## no longer a slot a wrapper copies.
  result = whole
  if whole.origin == oAliased and whole.src.len > 0:
    if whole.srcField.len == 0: result.srcField = field
    else: result.src = ""

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
  moved: string             ## the param a MOVED twin takes destructively
  final: HashSet[NodeId]    ## this body's last reads (the lowered graph),
                            ## for `movedTransfer`; only filled in a twin
  locals: Table[string, Prov]

proc provOf(c: var Ctx, e: Expr): Prov

proc maybeMovedParam(res: Resolution, m: Module, d: Decl): string
proc mixToken(id: NodeId, field: string): NodeId

proc throughWrapper(c: var Ctx, e: Expr, p: var Prov) =
  ## A callee that threads its first parameter has a MOVED twin, and a call
  ## reaches one of two procs:
  ##
  ##   the WRAPPER, which copies that parameter's Seq slots (`xs =
  ##     tuckSeqCopy(xs)`, or each Seq field) and then calls the twin — so a
  ##     result slot that IS the parameter is the wrapper's fresh copy;
  ##   the TWIN, when the argument is a moved one — so the same slot is the
  ##     caller's own argument, handed straight back.
  ##
  ## Which one is not known yet here (the moved-argument stamps are made FROM
  ## this analysis), so the answer covers both: fresh, joined with what the
  ## argument itself is. A fresh argument gives a fresh result — no second
  ## copy of a buffer the wrapper already made private, which is #77. An
  ## aliased one stays aliased: inside a twin, the argument may be that
  ## twin's own moved parameter, and calling the result fresh there would let
  ## it free what it returns.
  ##
  ## Every other slot's `src` names a parameter OF THE CALLEE, which means
  ## nothing on this side of the call; it is cleared.
  let callee = c.m.findFn(e.callee.name)
  let moved = maybeMovedParam(c.res, c.m, callee)
  var copied: seq[string]
  var bare = false
  if moved.len > 0 and e.args.len > 0:
    for prm in callee.fnParams:
      if prm.name == moved:
        copied = movedCopyFields(c.res, c.m, prm.typ)
        bare = copied.len == 0
  proc rewrite(c: var Ctx, cell: Cell, key: string): Cell =
    result = cell
    if cell.origin == oAliased and cell.src.len > 0 and cell.src == moved and
       ((cell.srcField.len == 0 and bare) or cell.srcField in copied):
      let fresh = Cell(origin: oFresh,
                       token: mixToken(e.id, "\0wrapper:" & cell.srcField))
      let arg = provOf(c, e.args[0])
      let given = if cell.srcField.len == 0: arg.whole
                  elif cell.srcField in arg.fields: arg.fields[cell.srcField]
                  else: fieldOf(arg.whole, cell.srcField)
      result = join(fresh, given)
    else:
      result.src = ""
      result.srcField = ""
  p.whole = rewrite(c, p.whole, "")
  for k in toSeq(p.fields.keys):
    p.fields[k] = rewrite(c, p.fields[k], k)

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
  let key = keyOf(c.m, name)
  if key notin summaries: return unknownProv()   # imported, extern, or a
                                                 # shape allFns never yielded
  var p = summaries[key]
  # A FRESH RESULT IS THIS CALL'S OWN ALLOCATION. The callee's token names a
  # node inside the callee and means nothing out here; every call site is a
  # distinct allocation, so the site's own id is the identity.
  ensureId(e)
  c.throughWrapper(e, p)
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
    if e.name in c.params: Prov(whole: Cell(origin: oAliased, src: e.name))
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
    else:
      let base = provOf(c, e.receiver)
      if e.fieldName in base.fields: Prov(whole: base.fields[e.fieldName])
      else: Prov(whole: fieldOf(base.whole, e.fieldName))
  of exkBracket:
    # An element of a container aliases the container it was read out of —
    # but it is NOT that container's slot: a wrapper's copy is shallow, so an
    # element of a copied Seq[Seq[T]] is still the caller's inner buffer.
    if e.brReceiver == nil: unknownProv()
    else:
      var cell = provOf(c, e.brReceiver).whole
      cell.src = ""
      Prov(whole: cell)
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

proc maybeMovedParam(res: Resolution, m: Module, d: Decl): string =
  ## The parameter a MOVED twin takes destructively, or "".
  ##
  ## ONE PREDICATE NOW, shared with codegen through `twin_shape`. This used
  ## to be a second, wider copy of `movedFnParam` kept in step by hand — the
  ## analysis could not call codegen's, because codegen sits downstream of
  ## every analysis. It was not kept in step: codegen learned the WRAPPED
  ## shape and this did not, and for every fn of that shape `rootedAtMoved`
  ## could not fire and the twin emitted `defer delete` over the buffer it
  ## was handing back. See twin_shape.nim's header for the whole account.
  ##
  ## It is also no longer wider. Wider was a hedge against drift, and with
  ## one definition there is nothing to drift: a fn codegen does not twin is
  ## a fn whose parameter nothing takes destructively.
  movedFnParam(res, m, d)

proc rootedAtMoved(c: Ctx, e: Expr): bool =
  ## Is this value read THROUGH the moved parameter? `s.ladder` inside a twin
  ## whose moved param is `s` is the caller's buffer, not a copy of it.
  if c.moved.len == 0 or e == nil: return false
  var cur = e
  while cur != nil and cur.kind in {exkField, exkBracket}:
    cur = if cur.kind == exkField: cur.receiver else: cur.brReceiver
  cur != nil and cur.kind == exkVar and cur.name == c.moved

proc mixToken(id: NodeId, field: string): NodeId =
  ## A distinct identity per copied field. The copies really are distinct
  ## allocations — one `tuckSeqCopy` each — so they must not look shared.
  ## A collision would make two distinct buffers read as one, which costs a
  ## copy and never grants a wrong exemption, so this fails in the safe
  ## direction.
  var h = uint32(id) * 0x9E3779B1'u32
  for ch in field: h = (h xor uint32(ord(ch))) * 16777619'u32
  NodeId(h)

proc movedTransfer(c: Ctx, e: Expr): tuple[takes: bool, slot: string]

proc afterBinding(c: Ctx, e: Expr, v: Prov): Prov =
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
  ##
  ## NO EXCEPTION INSIDE A MOVED TWIN any more. The emitters used to skip
  ## the copy for a read through the moved parameter, and this mirrored it;
  ## that skip broke value semantics (`var t = xs; t[0] = 99; return xs`
  ## returned 99) and made Odin free one buffer twice. The binding copies
  ## like any other, so it IS fresh.
  result = v
  # ...except a binding that TAKES the moved parameter's buffer at its last
  # read: that is the parameter's buffer, uncopied, and saying so is what
  # stops the twin freeing what it returns.
  if c.movedTransfer(e).takes: return result
  # A VALUE BUILT OUT OF THE TARGET IS MUTATED IN PLACE, not copied:
  #
  #   xs = {items: xs, value: v} push   ->  append(&xs, v)
  #   s  = s + t                        ->  s.add(t) / s ~= t
  #   x  = f(x, ...)                    ->  x = f_moved(x, ...)
  #
  # so for those the claim below — "it was not exclusive, therefore the
  # binding copied it, therefore it is fresh now" — has nothing behind it.
  # Refusing the claim for them was tried and MEASURED: it is unnecessary,
  # and it cost the matching engine 1.6 GB against 10 MB.
  #
  # Unnecessary because `noteAssignments` is flow-INsensitive and joins every
  # value a name is ever given. An in-place mutation of `x` keeps whatever
  # `x` already was, and that earlier value is already in the join: fresh
  # stays fresh, aliased stays aliased, without a rule here. The one shape
  # that would escape the join is a PARAMETER mutated in place, which has no
  # earlier binding to join with — and Tuck parameters are immutable, so it
  # cannot be written.
  ensureId(e)
  if v.whole.origin != oFresh:
    result.whole = Cell(origin: oFresh, token: e.id)
  for k, cell in v.fields:
    if cell.origin != oFresh:
      result.fields[k] = Cell(origin: oFresh, token: mixToken(e.id, k))

proc movedTransfer(c: Ctx, e: Expr): tuple[takes: bool, slot: string] =
  ## Does binding `e` TAKE the moved parameter's buffer rather than read it?
  ##
  ## Inside a twin the moved parameter belongs to the call. A binding that
  ## reads it — the parameter itself, or one of its fields — at its LAST
  ## read hands the buffer over: nothing reads the parameter afterwards, so
  ## no copy is needed and none can be observed. `var out = xs` in `grow`
  ## is the move path, and copying there made a 2M-append loop quadratic.
  ##
  ## A read that is NOT the last one must copy like any other binding. The
  ## emitters used to skip the copy for every read through the moved
  ## parameter, and `var t = xs; t[0] = 99; return xs` returned 99.
  ##
  ## Answered from the SAME predicate by provenance (what the binding then
  ## holds), the copy pass (whether to copy), and — through the copy pass's
  ## record — the ownership pass (the twin must not free a slot it gave to
  ## a local). Three consumers, one answer.
  if c.moved.len == 0 or e == nil or not e.id.isSet or e.id notin c.final:
    return
  case e.kind
  of exkVar:
    if e.name == c.moved: result = (true, "")
  of exkField:
    if e.receiver != nil and e.receiver.kind == exkVar and
       e.receiver.name == c.moved:
      result = (true, e.fieldName)
  else: discard

proc noteAssignments(c: var Ctx, e: Expr) =
  ## Record what each local may hold. FLOW-INSENSITIVE on purpose: every
  ## value a name is ever given is joined into one answer, so a name that is
  ## fresh on one line and aliased on another reads as aliased everywhere.
  ## That is the safe direction, and it makes loops and branches need no
  ## special handling at all.
  if e == nil: return
  if e.kind == exkAssign and e.target != nil and e.target.kind == exkVar:
    let v = afterBinding(c, e.assignVal, provOf(c, e.assignVal))
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
  var c = Ctx(res: res, m: m, moved: maybeMovedParam(res, m, d))
  if c.moved.len > 0: c.final = ssaOf(res, d, ssLowered).final
  for p in d.fnParams: c.params.incl(p.name)
  # Locals first, so a `return` that names one has something to read. Repeated
  # because an assignment may name a local assigned further down.
  for _ in 0 ..< 2: noteAssignments(c, d.fnBody)
  var acc = unknownProv()
  var any = false
  collectReturns(c, d.fnBody, acc, any)
  if any: acc else: unknownProv()

# --- which arguments may be handed on destructively --------------------------
#
# EV-15. A fn that threads a container gets a MOVED twin, and the call site
# reaches it when the old value is provably dead. Three shapes can prove it,
# and only the first was ever syntactic:
#
#     x = f(x, ...)          the result overwrites its own argument
#     let y = f(b.ask, ...)  a field nothing reads again
#     let r = f(a, ...)      a LOCAL nothing reads again      <- this pass
#
# The third is the shape a chain of threading calls actually takes, and it
# was the whole of `world_server`'s cost: 191 ms on Nim against 2.9 s on Odin
# and 54 s on D, because `let r = {f: a, ...} pass` copied a container its
# caller was finished with and then abandoned the copy.
#
# WHY LIVENESS IS NOT ENOUGH, which is the part that took a use-after-free to
# learn on the other side of this file. Liveness says nobody in THIS body
# reads the value again. On Nim that settles it: `sink` hands the rest to
# ARC. On D and Odin a container parameter ALIASES the caller's buffer, so
#
#     fn g({xs: Seq[int]}) -> int:      # NOT a twin: g does not own xs
#       let r = {f: xs, ...} pass       # last use of xs...
#       return r.relit                  # ...but pass_moved would free it
#
# would free the CALLER's buffer. So the value must also be one this body
# owns, and provenance is exactly the thing that knows: `oFresh` means this
# body allocated it. A parameter is owned only inside the twin that took it
# destructively — and there `slotsMovedAway` already stops the twin freeing
# what it has handed on, which is the same fact read from the other end.

proc seqFieldsOfType(c: Ctx, t: Type): seq[string] =
  for f in getFieldsForType(c.res, c.m, t):
    if seqElem(f.typ) != nil: result.add(f.name)

proc ownedForMove(c: Ctx, p: Prov, t: Type): bool =
  ## Is EVERY heap slot the twin would free one this body allocated?
  ##
  ## All of them, not just the one being read: the twin frees the whole
  ## parameter, so a record with one borrowed field is not movable however
  ## fresh the others are.
  if t == nil: return false
  if seqElem(t) != nil: return p.whole.origin == oFresh
  let fs = seqFieldsOfType(c, t)
  if fs.len == 0: return false     # not a container, or a shape not resolved
  for f in fs:
    if f notin p.fields: return false
    if p.fields[f].origin != oFresh: return false
  true

proc provOfRoot(c: var Ctx, root: string): Prov =
  if root in c.locals: c.locals[root] else: unknownProv()

proc threadsFirstArg(res: Resolution, m: Module, e: Expr): bool =
  ## Is this a call that might take its first argument destructively?
  e != nil and e.kind == exkCall and e.callee != nil and
    e.callee.kind == exkVar and e.args.len >= 1 and e.args[0] != nil and
    maybeMovedParam(res, m, m.findFn(e.callee.name)) != ""

# --- the same question, asked of the value mirror -----------------------------
#
# Stage B of thoughts/ssa-mirror-design.md. Everything above this line decides
# ownership by walking the tree twice: a seed pass that asks provenance about
# each NAME a call site reads, then a grow pass that spreads the answer along
# assignments to a fixpoint, with `valueIsOwned` re-deriving the call shape at
# every step. Three walks that have to agree about what a name holds.
#
# On the mirror there are no names to spread anything along. Each VERSION has
# one definition, so ownership is a property read straight off it, and the
# only iteration left is the one the phi structure genuinely needs — a loop
# head's operand comes from the bottom of the loop.
#
# WHAT IS NOT MOVED HERE, deliberately. Whether a record BINDING copies its
# Seq fields still comes from `afterBinding`, which models what the emitter
# does. That is item 4 on the list and it is Stage C's to remove; pulling it
# forward would mean changing the ownership ANSWER in the same step as
# changing where the answer comes from, and then a difference between the two
# could not be attributed. So this keeps provenance's field lattice exactly
# and replaces only the structure around it.

proc ssaOwnSeed(c: var Ctx, fn: SsaFn, v: Value): bool =
  ## What this definition says on its own, before anything flows into it.
  case v.def.kind
  of dkEntry:
    # A parameter is the caller's buffer on D and Odin. The ONE exception is
    # the parameter a MOVED twin took destructively, which the caller has
    # already given away.
    v.place == c.moved
  of dkLiteral:
    true
  of dkConstruct, dkCall:
    ownedForMove(c, provOfRoot(c, v.place), c.res.typeFor(v.def.src))
  else:
    false

proc ssaFieldIsOurs(c: var Ctx, place: string): bool =
  ## For `b.ask`: is that SLOT one this body allocated? A narrower question
  ## than whether `b` is ours, and the reason the old code needed
  ## `slotIsOwned` on the side.
  let root = rootOf(place)
  if root == place: return true
  if root == c.moved: return true
  cellFor(provOfRoot(c, root), place[root.len + 1 .. ^1]).origin == oFresh

proc ssaFlowsOwn(c: var Ctx, m: Module, fn: SsaFn, v: Value,
                 own: seq[bool]): bool =
  ## What flows INTO this version from the ones it was built out of.
  case v.def.kind
  of dkProject:
    v.def.inputs.len > 0 and own[int32(v.def.inputs[0])] and
      ssaFieldIsOurs(c, v.place)
  of dkPhi:
    # A join is ours only if it is ours on EVERY path.
    if v.def.inputs.len == 0: return false
    for inp in v.def.inputs:
      if not own[int32(inp)]: return false
    true
  of dkCall:
    # A twin hands back either a buffer it allocated or the one it was
    # given, so the result is ours when the argument we gave it was.
    #
    # NOT EXERCISED BY THE CORPUS, and said rather than implied: disabling
    # this rule changes no stamp on any example, either application, the
    # Savina ports or the stdlib, because `afterBinding` already calls such
    # a binding fresh. It is kept because that reason is item 4 on
    # thoughts/ssa-mirror-design.md's list — a claim about what the emitter
    # does — and when Stage C removes it this rule is what carries the fact.
    let src = v.def.src
    if not threadsFirstArg(c.res, m, src): return false
    if src.args[0].id notin fn.byNode: return false
    own[int32(fn.byNode[src.args[0].id])]
  else: false

proc ssaOwnership(c: var Ctx, m: Module, fn: SsaFn): seq[bool] =
  ## One answer per version, to a fixpoint. Monotone: a value only ever
  ## becomes owned, so it settles in as many rounds as the longest chain.
  result = newSeq[bool](fn.values.len)
  for i, v in fn.values: result[i] = ssaOwnSeed(c, fn, v)
  for _ in 0 ..< MaxRounds:
    var changed = false
    for i, v in fn.values:
      if result[i]: continue
      if ssaFlowsOwn(c, m, fn, v, result):
        result[i] = true
        changed = true
    if not changed: return

proc threadSites(res: Resolution, m: Module, body: Expr): seq[Expr] =
  ## Every first argument of a threading call in this body.
  var stack = @[body]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil: continue
    for ch in n.children: stack.add(ch)
    if not threadsFirstArg(res, m, n): continue
    if n.args[0].kind notin {exkVar, exkField}: continue
    ensureId(n.args[0])
    result.add(n.args[0])

proc debugOwn(d: Decl, c: Ctx, fn: SsaFn, own: seq[bool]) =
  when not defined(release):
    if getEnv("TUCK_DEBUG_MOVE") in ["", "diff"]: return
    var owned: seq[string]
    for i, v in fn.values:
      if own[i]: owned.add(v.place & "." & $v.version)
    echo "MOVE ", d.name, " moved=", c.moved, " owned=[ ", owned.join(" "), " ]"

proc moveFactsSsa*(res: Resolution, m: Module, d: Decl):
    tuple[sites: HashSet[NodeId], consumed: HashSet[string]] =
  ## Both halves of the same fact, from one look at the mirror: which
  ## arguments this body may hand on, and which slots of its OWN moved
  ## parameter it has therefore handed away.
  ##
  ## They were two independent tree walks — `markMovableArgs` deciding to
  ## hand a slot on, and `slotsMovedAway` re-scanning to find out whether one
  ## had been — with nothing making them agree. They did not, once, and the
  ## result was a double free that segfaulted under `TUCK_TRACK`. That is
  ## item 3 on thoughts/ssa-mirror-design.md's list, and one walk is the
  ## whole of the answer to it: the site that consumes a value is recorded
  ## ON the value.
  ##
  ## `consumed` is also NARROWER than the scan it replaces, and correctly so.
  ## The old one recorded a slot whenever the callee merely HAD a twin,
  ## whether or not the call site reached it. An unstamped site calls the
  ## wrapper, which copies our slot and hands the COPY to the twin — so the
  ## twin frees the copy and ours is still ours to free.
  if d.fnBody == nil or d.isExtern or d.isPending or d.isDecision: return
  var c = Ctx(res: res, m: m, moved: maybeMovedParam(res, m, d))
  for p in d.fnParams: c.params.incl(p.name)
  for _ in 0 ..< 2: noteAssignments(c, d.fnBody)
  let g = ssaOf(res, d, ssLowered)
  template fn: untyped = g.fn
  if fn.values.len == 0: return
  let own = ssaOwnership(c, m, fn)
  template final: untyped = g.final
  debugOwn(d, c, fn, own)
  for a in threadSites(res, m, d.fnBody):
    if a.id notin final or a.id notin fn.byNode: continue
    let v = fn.byNode[a.id]
    if not own[int32(v)]: continue
    result.sites.incl(a.id)
    # ...and if what went was a slot of OUR moved parameter, it is no longer
    # ours to free.
    let place = fn.values[int32(v)].place
    if c.moved.len == 0 or rootOf(place) != c.moved: continue
    result.consumed.incl(if place == c.moved: "" else: place[c.moved.len + 1 .. ^1])

proc consumedSlotsSsa*(res: Resolution, m: Module, d: Decl): HashSet[string] =
  moveFactsSsa(res, m, d).consumed

proc movableArgsSsa*(res: Resolution, m: Module, d: Decl): HashSet[NodeId] =
  ## Which arguments this body may hand on destructively — the mirror's
  ## answer to exactly what `markMovableArgs` decides above.
  if d.fnBody == nil or d.isExtern or d.isPending or d.isDecision: return
  var c = Ctx(res: res, m: m, moved: maybeMovedParam(res, m, d))
  for p in d.fnParams: c.params.incl(p.name)
  for _ in 0 ..< 2: noteAssignments(c, d.fnBody)
  let g = ssaOf(res, d, ssLowered)
  template fn: untyped = g.fn
  if fn.values.len == 0: return
  let own = ssaOwnership(c, m, fn)
  template final: untyped = g.final
  debugOwn(d, c, fn, own)
  for a in threadSites(res, m, d.fnBody):
    if a.id notin final or a.id notin fn.byNode: continue
    if own[int32(fn.byNode[a.id])]: result.incl(a.id)

proc markMovableArgs(res: Resolution, m: Module, d: Decl) =
  ## Stamp the first argument of every threading call this body may give away.
  ##
  ## THIS USED TO BE THREE WALKS. A seed pass asking provenance about every
  ## NAME a call site read, a grow pass spreading the answer along
  ## assignments to a fixpoint, and `valueIsOwned` re-deriving the call shape
  ## inside it — three traversals that had to agree about what a name holds,
  ## which is item 6 on thoughts/ssa-mirror-design.md's list. On the mirror
  ## there are no names to spread anything along: each version has one
  ## definition and ownership is read off it.
  ##
  ## Switched only after the two answers were compared across the corpus,
  ## both applications, the Savina ports and the stdlib: 24 stamps, zero
  ## difference either way, with the comparison itself sabotage-verified.
  for site in movableArgsSsa(res, m, d):
    markMovedArgId(res, site)

proc oldStampsIn(res: Resolution, d: Decl): HashSet[NodeId] =
  var stack = @[d.fnBody]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil: continue
    for ch in n.children: stack.add(ch)
    if n.kind in {exkVar, exkField} and n.id.isSet and isMovedArg(res, n):
      result.incl(n.id)

proc moveDiffReport(res: Resolution, m: Module) =
  ## The Stage B differential, kept as a MEASUREMENT after the switch.
  ##
  ## It compared the mirror's answer against the three-walk implementation it
  ## replaced — 24 stamps, zero difference — and it stays because the same
  ## comparison is what Stage C will need when the emitter-prediction in
  ## `afterBinding` comes out and the answer is allowed to change.
  when not defined(release):
    if getEnv("TUCK_DEBUG_MOVE") != "diff": return
    var agree, onlyMirror, onlyOld = 0
    for d in m.allFns():
      let mine = movableArgsSsa(res, m, d)
      let theirs = oldStampsIn(res, d)
      agree += (mine * theirs).len
      onlyMirror += (mine - theirs).len
      onlyOld += (theirs - mine).len
      if (mine - theirs).len > 0 or (theirs - mine).len > 0:
        echo "MOVEDIFF ", d.name, " agree=", (mine * theirs).len,
             " onlyMirror=", (mine - theirs).len,
             " onlyOld=", (theirs - mine).len
    echo "MOVETOTAL ", m.path.join("."), " agree=", agree,
         " onlyMirror=", onlyMirror, " onlyOld=", onlyOld

proc markAllMovableArgs(res: Resolution, m: Module) =
  for d in m.allFns(): markMovableArgs(res, m, d)
  moveDiffReport(res, m)

proc buildProvenance*(res: Resolution, m: Module) =
  ## Summarize every fn this module declares, to a fixpoint.
  ##
  ## Every fn starts at `oFresh` — the optimistic end of the lattice — and
  ## each round can only move one further along it, so the iteration is
  ## monotone and settles. Starting pessimistic would never recover: a
  ## recursive fn would read its own unfinished summary as `oUnknown` and
  ## stay there.
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
    summaries[keyOf(m, d.name)] =
      if d.name in duplicated: unknownProv()
      else: Prov(whole: Cell(origin: oFresh, token: noToken()))
  for round in 0 ..< MaxRounds:
    var changed = false
    for d in m.allFns():
      if d.name in duplicated: continue
      let before = summaries[keyOf(m, d.name)]
      let after = summarize(res, m, d)
      if after.whole != before.whole or after.fields != before.fields:
        summaries[keyOf(m, d.name)] = after
        changed = true
    if not changed:
      when not defined(release):
        if getEnv("TUCK_DEBUG_PROV").len > 0:
          for n, pr in summaries:
            var fs = ""
            for k, v in pr.fields: fs.add(" " & k & "=" & $v.origin & "/" & $uint32(v.token))
            echo "PROV ", n, " whole=", pr.whole.origin, "/", uint32(pr.whole.token), fs
      markAllMovableArgs(res, m)
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
  for d in m.allFns(): summaries[keyOf(m, d.name)] = unknownProv()

# --- what the copy pass asks -------------------------------------------------

proc slotIsFresh*(res: Resolution, m: Module, fnName, field: string): bool =
  ## Does this fn's RETURN carry a freshly allocated value in that slot — as
  ## opposed to one of its own arguments?
  ##
  ## Stage 3 asks this before letting a MOVED twin free its parameter at
  ## exit. `oAliased` there means the returned slot may BE the parameter's
  ## buffer (`takeLevel` returns the very ladder it was handed), and freeing
  ## it would free the value the caller is about to bind. Anything the walk
  ## did not resolve answers false, which leaks — the safe direction.
  let key = keyOf(m, fnName)
  if key notin summaries: return false
  let p = summaries[key]
  if field.len == 0: return p.whole.origin == oFresh
  field in p.fields and p.fields[field].origin == oFresh

type ProvCtx* = object
  ## One body's context for asking about a value inside it: its parameters,
  ## its moved parameter if it is a twin, and what each local may hold.
  ##
  ## A call's result can depend on its ARGUMENT (see `throughWrapper`), and
  ## what an argument is only has an answer inside the body that contains
  ## the call. Asked without this, every argument read as unknown.
  c: Ctx

proc provCtxFor*(res: Resolution, m: Module, d: Decl): ProvCtx =
  ## The context for the body of `d` — or an empty one for a top-level
  ## statement, which has no parameters and no locals to know about.
  result.c = Ctx(res: res, m: m)
  if d == nil: return
  let body = case d.kind
             of dkFn: d.fnBody
             of dkTask: d.taskBody
             else: nil
  if body == nil: return
  if d.kind == dkFn:
    result.c.moved = maybeMovedParam(res, m, d)
    if result.c.moved.len > 0:
      result.c.final = ssaOf(res, d, ssLowered).final
    for p in d.fnParams: result.c.params.incl(p.name)
  else:
    for p in d.taskParams: result.c.params.incl(p.name)
  for _ in 0 ..< 2: noteAssignments(result.c, body)

proc takesMovedParam*(pc: ProvCtx, e: Expr): tuple[takes: bool, slot: string] =
  ## `movedTransfer`, for the copy pass. `slot` is "" for the parameter
  ## itself, else the field taken.
  pc.c.movedTransfer(e)

proc exclusivelyOwned*(pc: var ProvCtx, e: Expr, field = ""): bool =
  ## May this bound value (or its named field) skip its defensive copy?
  ##
  ## True only when the value is a CALL whose summary proves the slot is a
  ## fresh allocation that nothing else reaches: not a parameter of the
  ## callee, and not the same buffer as another field of the same result.
  ## Everything else — a name, a field read, an imported call, a shape the
  ## walk did not model — answers false and copies exactly as before.
  ##
  ## ASKED ONCE, by `lowering_seqcopy`, which records the answer beside its
  ## copy marks; the ownership pass reads that record rather than asking
  ## again, so the copy decision and the free decision cannot disagree.
  if e == nil or e.kind != exkCall: return false
  let p = provOfCall(pc.c, e)
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
