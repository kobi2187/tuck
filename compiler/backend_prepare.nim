# compiler/backend_prepare.nim
#
# GETTING A TREE READY FOR ONE BACKEND — the stage between checking and
# emitting, in one place.
#
# Four steps, always the same four, always in this order:
#
#   1. CLONE. Each backend lowers its own deepCopy, because lowering and the
#      emitters both mutate the tree in place. Sharing one would hand the
#      second backend whatever the first left behind. Node ids survive the
#      copy, which is what keeps the Resolution built during checking
#      reachable from either clone.
#   2. REBASE `impl:` paths. The author writes `impl: nim "./shim/x"`
#      relative to their OWN .tuck file, which is the only place they can see
#      it from; the emitted import has to be relative to the OUTPUT directory
#      instead, and `-o:` moves that around.
#   3. LOWER. `lowerModule` simplifies the constructs every backend would
#      otherwise each have to understand.
#   4. MARK THE COPIES, for the backends whose native container ALIASES.
#      Odin's `[dynamic]T` and D's `T[]` both copy a header that still points
#      at the source buffer; Nim's `seq` has real value semantics and needs
#      none of it.
#
# WHY THIS IS A MODULE. It was written out longhand FOUR TIMES in `tuck.nim`
# — once per backend, plus once more for the stage-dump path — and the four
# copies had already drifted: two carried a `verifyStages` check the others
# did not. That is the same shape as every other bug found in this compiler
# lately (one decision, several copies, kept in step by hand), and the
# remedy is the same one `lowering_seqcopy.nim` states for the copy decision:
# a decision that lives in one place can be inspected, tested and reused.
#
# WHAT IS NOT HERE: emitting. Each backend prints differently and that is the
# point of having three; `prepare` ends where the printing starts.
import tables, times, os, strutils
import ast
import modules
import resolution
import lowering
import lowering_seqcopy
import pipeline
import verbose

type
  Backend* = enum
    ## Which target this tree is being prepared for.
    ##
    ## Module level, not local to the driver's argument parser where it used
    ## to be: it is a fact about the compiler, and three modules now need to
    ## name it.
    bkNim, bkOdin, bkDlang

  BackendTree* = object
    ## One backend's private copy of the program, ready to emit.
    mods*: seq[LoadedModule]
      ## every module, dependency-first; the entry module is last
    real*: Table[string, Module]
      ## the imported modules by name — what an emitter looks a cross-module
      ## callee up in. Excludes the entry module, which is nobody's import.

proc name*(b: Backend): string =
  case b
  of bkNim: "nim"
  of bkOdin: "odin"
  of bkDlang: "d"

proc aliasesOnAssign*(b: Backend): bool =
  ## Does this target's native container share a buffer on assignment?
  ##
  ## Nim's `seq` copies, so it needs no repair. Odin and D both alias — Odin
  ## was assumed not to until a spike ran the same program on all three and
  ## got 1, 1 and 99. The analysis has nothing to do with either target, so
  ## `lowering_seqcopy` decides it once and each backend prints its own fix.
  b in {bkOdin, bkDlang}

proc rebasedImplModule(module, srcDir, outDir: string): string =
  ## Rewrite one `impl: <backend> "..."` module string from source-relative
  ## (what the author wrote, and the only frame of reference they have) to
  ## output-relative (what the emitted import needs), or return it unchanged
  ## if it isn't a path at all.
  ##
  ## Only ./ and ../ forms are paths. "std/strutils" and "core:strings" are
  ## module names in the backend's own namespace and pass through untouched —
  ## the same distinction Nim and Odin themselves draw.
  if not (module.startsWith("./") or module.startsWith("../")): return module
  let abs = normalizedPath(srcDir / module)
  result = relativePath(abs, outDir).replace('\\', '/')
  # KEEP AN EXPLICIT RELATIVE MARKER. `relativePath` returns a BARE name for
  # a sibling ("shim"), and Odin reads a bare import path as a COLLECTION
  # name (like "core:"), not a directory — it fails with "Path does not
  # exist". Nim accepts either, so ./ is right for both.
  #
  # Dropped once while moving this proc out of the driver, and caught by the
  # re-emit: `examples/34-ffi-cstring` went from `./shim/zlib_shim` to
  # `shim/zlib_shim`, which Nim tolerates and Odin does not. That diff is
  # exactly what tracking emitted output under `examples/` is for.
  if not (result.startsWith("./") or result.startsWith("../")):
    result = "./" & result

proc rebaseImplPaths(lm: LoadedModule, backend, outDir: string) =
  let srcDir = parentDir(absolutePath(lm.path))
  for d in lm.m.decls:
    if d == nil or d.kind != dkExtern: continue
    for mem in d.mixinMembers:
      if mem.kind != dkFn or not mem.isExtern: continue
      for i in 0 ..< mem.externImpl.len:
        if mem.externImpl[i].backend != backend: continue
        mem.externImpl[i].module =
          rebasedImplModule(mem.externImpl[i].module, srcDir, outDir)

proc prepare*(prog: seq[LoadedModule], backend: Backend,
              semLayer: Resolution, outDir: string): BackendTree =
  ## Steps 1-4, for one backend. The checked program goes in; a private,
  ## lowered, marked copy comes out.
  for lm in prog:                                                   # 1. clone
    result.mods.add LoadedModule(name: lm.name, path: lm.path,
                                 m: deepCopy(lm.m))
  for lm in result.mods[0 ..< result.mods.high]:
    result.real[lm.name] = lm.m
  for lm in result.mods:                                           # 2. rebase
    rebaseImplPaths(lm, backend.name, outDir)

  let t0 = vBegin(psLowering)
  for lm in result.mods:
    let ts = epochTime()
    lowerModule(semLayer, lm.m)                                      # 3. lower
    if backend.aliasesOnAssign:
      markSeqCopiesIn(semLayer, lm.m)                                # 4. marks
    vSub(lm.name, ts)
  vEnd(psLowering, t0)

proc modules*(t: BackendTree): seq[Module] =
  ## The bare modules, for the stage assertions that take a `seq[Module]`.
  for lm in t.mods: result.add lm.m
