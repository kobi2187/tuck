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
#
# WHAT USED TO LIVE HERE: the Seq-copy analysis. Odin turned out to alias
# exactly as D does, so the reasoning moved to lowering_seqcopy.nim and both
# backends share it; only the repair each prints is its own.
import ast
import resolution
import lowering_seqcopy

proc lowerModuleD*(res: Resolution, m: Module) =
  ## The D backend's own lowering. Runs AFTER lowerModule, on this backend's
  ## private copy of the tree.
  markSeqCopiesIn(res, m)

