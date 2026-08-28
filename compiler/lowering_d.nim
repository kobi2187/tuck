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
import ast, options, sets
import resolution
import ast_query

proc seqElemT(t: Type): Type =
  ## The element type of a `Seq[T]`, or nil. Local copy of the emitter's
  ## predicate: this pass sits BELOW codegen_d in the dependency order, so
  ## it cannot import from it.
  if t != nil and t.kind == tkApp and t.base != nil and
     t.base.kind == tkNamed and t.base.name == "Seq" and t.args.len == 1:
    t.args[0]
  else: nil

proc isSeqValued(e: Expr): bool =
  e != nil and seqElemT(semLayer.typeFor(e)) != nil

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

proc needsDup*(e: Expr): bool =
  ## Did this backend's lowering mark this expression as needing a copy?
  e != nil and e.id.isSet and e.id in dupSites

proc markSeqCopies(e: Expr) =
  ## Mark every Seq-valued expression whose VALUE is being bound to a name,
  ## so the emitter copies rather than aliases.
  if e == nil: return
  case e.kind
  of exkAssign:
    if e.assignVal != nil and e.assignVal.kind != exkList and
       isSeqValued(e.assignVal):
      ensureId(e.assignVal)
      dupSites.incl(e.assignVal.id)
    markSeqCopies(e.target)
    markSeqCopies(e.assignVal)
  of exkBlock:
    for s in e.stmts: markSeqCopies(s)
  of exkIf:
    markSeqCopies(e.cond)
    markSeqCopies(e.thenBranch)
    markSeqCopies(e.elseBranch)
  of exkFor:
    markSeqCopies(e.iterable)
    markSeqCopies(e.body)
  of exkWhile:
    markSeqCopies(e.whileCond)
    markSeqCopies(e.whileBody)
  of exkMatch:
    markSeqCopies(e.subject)
    for arm in e.arms: markSeqCopies(arm.body)
  of exkCall:
    for a in e.args: markSeqCopies(a)
  of exkReturn: markSeqCopies(e.returnVal)
  else: discard

proc lowerModuleD*(m: Module) =
  ## The D backend's own lowering. Runs AFTER lowerModule, on this backend's
  ## private copy of the tree.
  for fn in m.allFns():
    markSeqCopies(fn.fnBody)
  for d in m.decls(dkTask):
    markSeqCopies(d.taskBody)
  for d in m.decls(dkExpr):
    markSeqCopies(d.expr)
