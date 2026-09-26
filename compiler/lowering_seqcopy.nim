# compiler/lowering_seqcopy.nim
#
# WHICH COPIES OF A `Seq` MUST BE REAL COPIES — decided once, for the two
# backends whose native container ALIASES.
#
# Tuck's `Seq` assignment copies. Nim's `seq` gives that for free. D's `T[]`
# and Odin's `[dynamic]T` do not: both copy a header that still points at the
# source buffer, so `b = a` then `b[0] = 99` writes `a[0]` too — the exact
# aliasing bug value semantics exists to prevent, in the language whose
# central claim it is.
#
# This was a D-only pass. Spiking a record with a `Seq` field found Odin
# aliasing identically and silently: `nim = 1, d = 1, odin = 99`. The
# ANALYSIS — which expressions are Seq-valued, or records carrying Seq
# fields, being bound to a name — has nothing to do with either target, so it
# lives here once and each backend prints its own repair: D `.dup`, Odin a
# runtime copy.
#
# WHY A PASS RATHER THAN A DECISION INSIDE THE EMITTER. Anything the emitter
# decides, it decides while building a string, so the decision cannot be
# inspected, tested, or reused — which is how three backends each grew their
# own copy of the same reasoning. A pass marks the tree; `tuck p --ast` can
# show it, a test can assert on it, and the emitters stay printers.
import ast, options, sets, tables
import resolution
import ast_query
import lowering  # getFieldsForType
import twin_shape
export seqFieldNames
import analysis_provenance

proc isSeqValued(res: Resolution, e: Expr): bool =
  e != nil and seqElem(res.typeFor(e)) != nil

# `.dup` — the one place D's semantics genuinely differ from Tuck's.
#
# A Tuck `Seq` assignment COPIES (the Nim backend gets this from Nim's own
# seq value semantics). A D dynamic-array assignment ALIASES: `b = a` makes
# both names view one buffer, so `b[0] = 50` writes `a[0]` too. Verified
# divergent before this existed.
#
# A fresh list literal owns its storage and needs no copy. A CALL RESULT is
# asked about: `analysis_provenance` answers whether the callee built the
# value or merely handed back one of its own arguments, and only the first
# skips the copy. Everything else copies, as it always did.
#
# That question used to be answered "always copy" — the safe reading, and the
# expensive one: the matching engine paid four ladder copies per order where
# two were provably waste. It must NOT be answered syntactically. Exempting
# call results, and exempting record bindings from calls, were each tried and
# each returned 106 instead of 17 on this suite's own aliasing assertion, on
# D and Odin only.
var dupSites: HashSet[NodeId]
  ## Expressions the emitter must wrap in `.dup`, keyed by node id — the same
  ## side-table shape the checker's own Resolution uses.
  ##
  ## NOT `sourceName`: that field holds the name the USER wrote, for
  ## diagnostics, and `writtenName` reads it — borrowing it would corrupt
  ## error messages. And not the shared Resolution either: this is a D-only
  ## fact, so it lives with the D pass that decides it.
  ##
  ## Node ids survive the per-backend deepCopy (that is what makes the
  ## checker's tables reachable from a cloned tree), so a mark set here is
  ## still findable when the emitter walks this backend's copy. They are
  ## GLOBAL rather than per-module (ast.newNodeId counts once for the whole
  ## program), so this table accumulates across every module in the import
  ## closure and must NOT be cleared between them — tuck.nim lowers every
  ## module before emitting any of them.

var recordDupSites: Table[NodeId, seq[string]]
  ## Same idea as `dupSites`, for a RECORD-valued expression that has one or
  ## more Seq-typed fields: a D struct copies field-for-field, so the fields
  ## NAMED HERE are exactly the ones whose copy is only a slice header and
  ## needs `.dup` — the emitter reconstructs the record with those fields
  ## replaced rather than appending a bare `.dup` (a D struct has no `.dup`
  ## at all; only a slice does).

var exclusiveSites: Table[NodeId, seq[string]]
  ## The OTHER half of the copy decision: bindings left UNCOPIED because the
  ## value is already exclusively the binder's — "" for a bare `Seq`, else
  ## the field names. Recorded here, where the decision is made, so the
  ## ownership pass reads the decision instead of re-deriving it. Two
  ## derivations of one fact are two answers, and between a copy and a free
  ## the difference is a leak one way and a double free the other.

var transferSites: Table[NodeId, seq[string]]
  ## Bindings that TOOK a moved twin's parameter buffer at its last read
  ## (`analysis_provenance.movedTransfer`), and which slots of that
  ## parameter they took. The twin must not free those: the local owns them.

proc transferredSlots*(e: Expr): seq[string] =
  ## Slots of the moved parameter this binding took ("" = the whole value).
  if e != nil and e.id.isSet and e.id in transferSites: transferSites[e.id]
  else: @[]

proc needsDup*(res: Resolution, e: Expr): bool =
  ## Did this backend's lowering mark this expression as needing a bare
  ## `.dup` (a Seq-valued expression copied by name)?
  e != nil and e.id.isSet and e.id in dupSites

proc recordDupFields*(res: Resolution, e: Expr): seq[string] =
  ## The Seq-typed field names this backend's lowering marked for a
  ## per-field dup, or "" if `e` was not marked this way.
  if e != nil and e.id.isSet and e.id in recordDupSites: recordDupSites[e.id]
  else: @[]

proc decidedExclusive*(e: Expr, slot: string): bool =
  ## Did the copy decision leave this slot uncopied because the value is the
  ## binder's alone? ("" is the value itself.)
  e != nil and e.id.isSet and e.id in exclusiveSites and
    slot in exclusiveSites[e.id]

proc markBinding(res: Resolution, m: Module, pc: var ProvCtx, v: Expr) =
  ## One binding's copy decision, both halves recorded.
  if v == nil or v.kind == exkList: return
  ensureId(v)
  # A MOVED TWIN'S PARAMETER, taken at its last read: no copy, and the
  # binder owns what it took (the twin frees nothing of it).
  let (takes, slot) = pc.takesMovedParam(v)
  if takes:
    if isSeqValued(res, v):
      exclusiveSites[v.id] = @[""]
      transferSites[v.id] = @[slot]
    else:
      let fs = seqFieldNames(res, m, res.typeFor(v))
      exclusiveSites[v.id] = fs
      transferSites[v.id] = fs     # the whole record: every heap slot
    return
  if isSeqValued(res, v):
    if pc.exclusivelyOwned(v): exclusiveSites[v.id] = @[""]
    else: dupSites.incl(v.id)
    return
  # `{fields} TypeName` (a record construction) parses as an exkCall over an
  # exkStruct payload, same as any other postfix application — there is no
  # "this is a fresh literal" node kind to exempt the way exkList exempts a
  # fresh Seq literal above.
  #
  # PER FIELD, because the answer is per field: `sweep` returns a `Filled`
  # whose ladder it allocated, while `wrap` returns a `Pair` whose two fields
  # are both its argument. Asking about the record as a whole cannot tell
  # those apart, and the field that still aliases is the one that must keep
  # its copy.
  var need, mine: seq[string]
  for f in seqFieldNames(res, m, res.typeFor(v)):
    if pc.exclusivelyOwned(v, f): mine.add(f) else: need.add(f)
  if need.len > 0: recordDupSites[v.id] = need
  if mine.len > 0: exclusiveSites[v.id] = mine

proc markSeqCopies(res: Resolution, m: Module, pc: var ProvCtx, e: Expr) =
  ## Mark every Seq-valued OR Seq-field-holding expression whose VALUE is
  ## being bound to a name, so the emitter copies rather than aliases.
  ##
  ## EVERY node kind is walked. This listed seven and ended in `else:
  ## discard`, so an assignment inside any other construct was never asked
  ## about at all.
  var stack = @[e]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil: continue
    if n.kind == exkAssign: markBinding(res, m, pc, n.assignVal)
    for ch in n.children: stack.add ch

proc markSeqCopiesIn*(res: Resolution, m: Module) =
  ## Mark this module's copy sites. Runs AFTER lowerModule, on the backend's
  ## private copy of the tree — the marks are keyed by node id, which survives
  ## the per-backend deepCopy.
  ##
  ## The provenance summary is rebuilt HERE, against this backend's tree,
  ## because each backend lowers its own deep copy and a summary computed
  ## over one tree names nodes in that tree only.
  buildProvenance(res, m)
  for d in m.allDecls:
    # A fn's or task's params are what provenance tracks; any other body
    # (a select arm, an initialiser) has none.
    let owner = if d.kind in {dkFn, dkTask}: d else: nil
    for e in d.ownExprs:
      if e == nil: continue
      var pc = provCtxFor(res, m, owner)
      markSeqCopies(res, m, pc, e)
