# compiler/lowering_d.nim
#
# STAGE 7b — the D backend's OWN lowering pass.
#
# `lowerModule` (lowering.nim) makes the tree boring in ways every backend
# wants. This pass makes it boring in ways only D wants, and it runs on the
# deepCopy tuck.nim already hands each backend — so a rewrite here cannot be
# seen by the Nim or Odin output.
#
# WHY A SEPARATE PASS RATHER THAN DECISIONS INSIDE THE EMITTER. Anything the
# emitter decides, it decides while building a string, which means the
# decision cannot be inspected, tested, or reused — and three backends each
# grew their own copy of the same reasoning that way. A pass rewrites TREE to
# TREE: `tuck p --ast` can show the result, a test can assert on it, and the
# emitter that follows is left doing nothing but printing.
#
# WHAT BELONGS HERE, precisely: rewrites that exist because D's semantics
# differ from Tuck's. Not "D spells it differently" — that is the emitter's
# job and stays there (`~` for concat, `foreach` for a range). The test is
# whether leaving the tree alone would produce D that MEANS something else.
#
# What does NOT belong here: anything derived from checker facts, which every
# backend needs identically. That is lowering.nim's job, and moving it here
# would just re-create the duplication this pass exists to end.
import ast, options, sets, tables
import resolution
import ast_query
import lowering  # getFieldsForType

proc isSeqValued(e: Expr): bool =
  e != nil and seqElem(semLayer.typeFor(e)) != nil

proc seqFieldNames(m: Module, t: Type): seq[string] =
  ## Names of `t`'s fields whose own type is `Seq[T]` — a D struct copies by
  ## value field-for-field, but a `T[]` field's copy is only the slice
  ## HEADER, so any Seq field aliases across the copy exactly the way a bare
  ## Seq assignment does. "" (never nil) when `t` is not a record at all.
  for f in getFieldsForType(m, t):
    if seqElem(f.typ) != nil: result.add(f.name)

# `.dup` — the one place D's semantics genuinely differ from Tuck's.
#
# A Tuck `Seq` assignment COPIES (the Nim backend gets this from Nim's own
# seq value semantics). A D dynamic-array assignment ALIASES: `b = a` makes
# both names view one buffer, so `b[0] = 50` writes `a[0]` too. Verified
# divergent before this existed.
#
# A fresh list literal owns its storage and needs no copy; everything else
# does, including a call result, since a call may hand back its own argument.
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

proc needsDup*(e: Expr): bool =
  ## Did this backend's lowering mark this expression as needing a bare
  ## `.dup` (a Seq-valued expression copied by name)?
  e != nil and e.id.isSet and e.id in dupSites

proc recordDupFields*(e: Expr): seq[string] =
  ## The Seq-typed field names this backend's lowering marked for a
  ## per-field dup, or "" if `e` was not marked this way.
  if e != nil and e.id.isSet and e.id in recordDupSites: recordDupSites[e.id]
  else: @[]

proc markSeqCopies(m: Module, e: Expr) =
  ## Mark every Seq-valued OR Seq-field-holding expression whose VALUE is
  ## being bound to a name, so the emitter copies rather than aliases.
  if e == nil: return
  case e.kind
  of exkAssign:
    if e.assignVal != nil and e.assignVal.kind != exkList:
      if isSeqValued(e.assignVal):
        ensureId(e.assignVal)
        dupSites.incl(e.assignVal.id)
      else:
        # `{fields} TypeName` (a record construction) parses as an exkCall
        # over an exkStruct payload, same as any other postfix application —
        # there is no "this is a fresh literal" node kind to exempt the way
        # exkList exempts a fresh Seq literal above. A construction call's
        # own Seq fields are already fresh too, so marking it costs one
        # redundant `.dup` rather than a wrong one — correctness over the
        # extra allocation.
        let fields = seqFieldNames(m, semLayer.typeFor(e.assignVal))
        if fields.len > 0:
          ensureId(e.assignVal)
          recordDupSites[e.assignVal.id] = fields
    markSeqCopies(m, e.target)
    markSeqCopies(m, e.assignVal)
  of exkBlock:
    for s in e.stmts: markSeqCopies(m, s)
  of exkIf:
    markSeqCopies(m, e.cond)
    markSeqCopies(m, e.thenBranch)
    markSeqCopies(m, e.elseBranch)
  of exkFor:
    markSeqCopies(m, e.iterable)
    markSeqCopies(m, e.body)
  of exkWhile:
    markSeqCopies(m, e.whileCond)
    markSeqCopies(m, e.whileBody)
  of exkMatch:
    markSeqCopies(m, e.subject)
    for arm in e.arms: markSeqCopies(m, arm.body)
  of exkCall:
    for a in e.args: markSeqCopies(m, a)
  of exkReturn: markSeqCopies(m, e.returnVal)
  else: discard

proc lowerModuleD*(m: Module) =
  ## The D backend's own lowering. Runs AFTER lowerModule, on this backend's
  ## private copy of the tree.
  for fn in m.allFns():
    markSeqCopies(m, fn.fnBody)
  for d in m.decls(dkTask):
    markSeqCopies(m, d.taskBody)
  for d in m.decls(dkExpr):
    markSeqCopies(m, d.expr)
