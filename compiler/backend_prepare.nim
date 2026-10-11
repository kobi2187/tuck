# compiler/backend_prepare.nim
#
# GETTING A TREE READY FOR ONE BACKEND — the stage between checking and
# emitting, in one place.
#
# Seven steps, always the same seven, always in this order:
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
#   4. NUMBER what lowering minted (`fillIds`), so nothing it built drops out
#      of the semantic layer.
#   5. MARK THE TWIN CALLS (the aliasing backends): which calls reach a
#      threaded fn's MOVED twin, and which assignments thread through one
#      (`twin_calls`, ROADMAP M3.5). Keyed by the ids step 4 filled.
#   6. ASSERT EVERY CALL COMPLETE (`call_args`): each payload call has a
#      value for every param its callee declares. The checker's own rule,
#      asked again after the passes that build calls, which run after it.
#   7. MAKE THE DECISIONS NODES. An append assigned back over its own
#      argument becomes `exkAppend` (`ownership_nodes`), which every emitter
#      prints as its host's growth in place. Then the ownership rules write
#      the program's ownership into the tree (`ownership_write`): the bindings
#      that name temporaries, each copy value semantics needs (`exkCopy`,
#      rules S and G), the drops at scope end, at an overwrite and of consumed
#      parameters (`exkDrop` in a `deferReleases` defer, `dropsOld`, rules D
#      and P), and the resets after a move on some paths (`exkReset`, rule M).
#      Rule V (`ownership_check`, TUCK_DEBUG_OWN=verify) then checks it.
#
# ONE TREE, THREE PRINTERS. Every step but 2 takes no backend
# (`prepareCommon`): a copy, a drop or a reset is the same fact on all three
# targets, and only how it prints differs. Odin frees by hand, so it prints
# all of them. D's slices alias, so it prints the copies; its collector frees,
# so a drop or a reset prints as nothing, and a `str` is immutable there, so
# its copy is itself. Nim's assignment copies and ARC frees, so a copy prints
# as its value and a drop or a reset as nothing; its `sink` parameters are
# rule P's answer (`Decl.ownedParams`), as the twins' copying wrappers are on
# Odin and D. Step 2 and Nim's construction field order are the only steps
# that know which backend they run for.
#
# WHY NOT BEFORE THE CLONE (ROADMAP M3.1 as first written). Two of
# ownership's inputs are made by lowering, so it cannot precede lowering —
# and it need not: `lowerModule` takes no backend, and a build targets one
# backend, so "once per build, before emission" is the whole of what "once,
# for every backend" was asking for.
#
# WHY THIS IS A MODULE. It was written out longhand FOUR TIMES in `tuck.nim`
# — once per backend, plus once more for the stage-dump path — and the four
# copies had already drifted: two carried a `verifyStages` check the others
# did not. That is the same shape as every other bug found in this compiler
# lately (one decision, several copies, kept in step by hand), and the
# remedy is always the same:
# a decision that lives in one place can be inspected, tested and reused.
#
# WHAT IS NOT HERE: emitting. Each backend prints differently and that is the
# point of having three; `prepare` ends where the printing starts.
import tables, times, os, strutils
import ast
import modules
import resolution
import lowering
import lowering_field_order
import lowering_with
import twin_calls
import call_args
import ownership_nodes
import ownership_check
import ownership_write
import ownership_rules
import ownership_dump
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
  ## The backend's name as `impl:` blocks spell it (`nim`, `odin`, `d`), which
  ## is what `rebaseImplPaths` matches an extern's impl entries against.
  case b
  of bkNim: "nim"
  of bkOdin: "odin"
  of bkDlang: "d"

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
  ## Rewrites every extern fn's `impl: <backend>` module path in `lm` from
  ## source-relative to relative to `outDir`, so the emitted import still finds
  ## the shim wherever the output lands. Only the current backend's entries move.
  let srcDir = parentDir(absolutePath(lm.path))
  for d in lm.m.decls:
    if d == nil or d.kind != dkExtern: continue
    for mem in d.mixinMembers:
      if mem.kind != dkFn or not mem.isExtern: continue
      for i in 0 ..< mem.externImpl.len:
        if mem.externImpl[i].backend != backend: continue
        mem.externImpl[i].module =
          rebasedImplModule(mem.externImpl[i].module, srcDir, outDir)

var preparedOnce = false
  ## ONE BACKEND PER PROCESS. Steps 5 and 7 record decisions in
  ## tables keyed by node id, and node ids survive the clone — so a second
  ## backend prepared in the same process would read the first one's
  ## decisions as its own. Every path in tuck.nim prepares exactly one.

proc prepareCommon(prog: seq[LoadedModule], semLayer: Resolution): BackendTree =
  ## Steps 1 and 3-7: the program every backend prints, lowered and with its
  ## ownership written in as nodes. It takes no backend: a copy, a drop, a
  ## reset or a named temporary is the same fact on all three, and each
  ## emitter decides how to print it (Odin frees by hand; Nim's ARC and D's
  ## collector print a drop or a reset as nothing).
  for lm in prog:                                                   # 1. clone
    result.mods.add LoadedModule(name: lm.name, path: lm.path,
                                 m: deepCopy(lm.m))
  for lm in result.mods[0 ..< result.mods.high]:
    result.real[lm.name] = lm.m
  let t0 = vBegin(psLowering)
  for lm in result.mods:
    let ts = epochTime()
    lowerModule(semLayer, lm.m, result.real)                         # 3. lower
    lowerWith(semLayer, lm.m)            #    `with` -> the construction it means
    # 4. NUMBER WHAT LOWERING MINTED. Lowering builds nodes (tail returns,
    # hoisted temporaries, desugared assignments) without ids; a node
    # without one drops out of the semantic layer. Existing ids are kept —
    # they are what makes the checker's facts reachable from this copy.
    fillIds(lm.m)
    markTwinCalls(semLayer, lm.m)                                  # 5. twins
    # 6. EVERY CALL IS COMPLETE. The checker rejects a payload missing a
    # param, but it runs before lowering, and lowering builds and rewrites
    # calls. Asserted here, after the last pass that can, so no emitter is
    # ever handed a call with a hole to fill in its own way.
    assertCallsComplete(semLayer, lm.m, result.real)
    typeResolvedCalls(semLayer, lm.m)          # a resolved call has a type
    dumpUses(semLayer, lm.m)                   # TUCK_DEBUG_OWN=uses (rule U)
    # 7. DECISIONS BECOME NODES. Last, because every pass above reads the
    # statements they replace; an emitter then prints the node instead of
    # re-deciding from a predicate.
    materializeAppends(semLayer, lm.m)
    dumpParams(semLayer, lm.m)                 # TUCK_DEBUG_OWN=params (P)
    dumpDrops(semLayer, lm.m)                  # TUCK_DEBUG_OWN=drops (D, M)
    writeRules(semLayer, lm.m)                 # copies, drops, resets (S-M)
    dumpCopies(lm.m)                           # TUCK_DEBUG_OWN=copies (S)
    verifyTree(semLayer, lm.m)                 # TUCK_DEBUG_OWN=verify (V)
    vSub(lm.name, ts)
  vEnd(psLowering, t0)

proc prepare*(prog: seq[LoadedModule], backend: Backend,
              semLayer: Resolution, outDir: string): BackendTree =
  ## Steps 1-7, for one backend. The checked program goes in; a private,
  ## lowered copy with its ownership written in comes out. Everything but
  ## step 2 is the same for every backend (`prepareCommon`).
  doAssert not preparedOnce,
    "backend_prepare: a second backend prepared in one process would read " &
    "the first one's twin decisions (keyed by node id)"
  preparedOnce = true
  result = prepareCommon(prog, semLayer)
  for lm in result.mods:                                           # 2. rebase
    rebaseImplPaths(lm, backend.name, outDir)
    if backend == bkNim:
      orderConstructionFields(semLayer, lm.m)       #    a moved field goes last

proc modules*(t: BackendTree): seq[Module] =
  ## The bare modules, for the stage assertions that take a `seq[Module]`.
  for lm in t.mods: result.add lm.m
