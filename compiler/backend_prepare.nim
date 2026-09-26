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
#      otherwise each have to understand. Then, on a backend whose runtime
#      hands the caller new `str` storage (Odin), NAME each nested one
#      (`lowering_strtemps`) — an unnamed temporary has no owner to free it.
#   4. MARK THE COPIES, for the backends whose native container ALIASES.
#      Odin's `[dynamic]T` and D's `T[]` both copy a header that still points
#      at the source buffer; Nim's `seq` has real value semantics and needs
#      none of it. The copy pass records both halves of its decision —
#      copied, or left alone because the value is already the binder's.
#   5. NUMBER what lowering minted (`fillIds`), so nothing it built drops out
#      of the semantic layer.
#   6. DECIDE OWNERSHIP (the aliasing backends): who frees each buffer, and
#      where. It reads steps 4 and 5, so it comes after them; the emitter
#      prints it, so it comes before any emitter. It used to run INSIDE the
#      Odin emitter, twice per fn — a decision made as a side effect of
#      printing.
#   7. MARK THE TWIN CALLS (the aliasing backends): which calls hand their
#      first argument to a threaded fn's MOVED twin, and which assignments
#      thread through one (`twin_calls`, ROADMAP M3.5). It reads the moved-
#      argument stamps step 4 made and keys by the ids step 5 filled. The
#      Odin and D emitters decided it while printing, each its own way.
#   8. ASSERT EVERY CALL COMPLETE (`call_args`): each payload call has a
#      value for every param its callee declares. The checker's own rule,
#      asked again after the passes that build calls, which run after it.
#      The emitters used to fill a hole three ways (`nil`, `{}`, a refusal).
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
import lowering_strtemps
import analysis_ownership
import twin_calls
import call_args
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

proc ownedStrProcs*(b: Backend): seq[string] =
  ## Runtime procs that hand back a `str` the CALLER now owns, on this
  ## backend. Only Odin has any: Nim's ARC and D's GC free their own.
  ## Runtime procs that hand back a `str` the CALLER now owns — Odin's
  ## `strings.clone`, `strings.concatenate`, `strings.join`, `fmt.aprint`.
  ##
  ## A LIST, and it lives here rather than as an attribute in `std/`, because
  ## "this returns freshly allocated storage" is a fact about the ODIN
  ## RUNTIME'S IMPLEMENTATION and not about Tuck. On Nim the same call is
  ## handled by ARC and on D by the GC; writing `[owned]` on `std/str.tuck`
  ## would state a backend's private business as a language-level claim.
  ##
  ## DELIBERATELY SHORT. Two str-returning runtime procs are NOT here and
  ## must not be added without reading them first:
  ##
  ##   splitLines  Odin's `strings.split_lines` hands back lines that SLICE
  ##               the input. The `[dynamic]string` is fresh; the strings in
  ##               it are not, and freeing one would cut into the caller's.
  ##   readFile    its buffer becomes a FIELD of the `FsContent` record it
  ##               returns, and a field is not a local — freeing it needs
  ##               the record's own ownership, which is issue #82's shape.
  ##
  ## Leaving a proc off this list LEAKS, which is where the backend already
  ## is. Putting one on it wrongly is a use-after-free. The asymmetry is why
  ## the list is short and each absence is written down.
  case b
  of bkOdin: @["toStr", "tuckConcat", "joinStr", "charAt"]
  of bkNim, bkDlang: @[]

var preparedOnce = false
  ## ONE BACKEND PER PROCESS. Steps 4, 6 and 7 record their decisions in
  ## tables keyed by node id, and node ids survive the clone — so a second
  ## backend prepared in the same process would read the first one's
  ## decisions as its own. Every path in tuck.nim prepares exactly one.

proc prepare*(prog: seq[LoadedModule], backend: Backend,
              semLayer: Resolution, outDir: string): BackendTree =
  ## Steps 1-8, for one backend. The checked program goes in; a private,
  ## lowered, marked copy comes out.
  doAssert not preparedOnce,
    "backend_prepare: a second backend prepared in one process would read " &
    "the first one's copy, ownership and twin decisions (keyed by node id)"
  preparedOnce = true
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
    lowerModule(semLayer, lm.m, result.real)                         # 3. lower
    hoistStrTemps(semLayer, lm.m, ownedStrProcs(backend))     #    str temps
    if backend.aliasesOnAssign:
      markSeqCopiesIn(semLayer, lm.m)                                # 4. marks
    # 5. NUMBER WHAT LOWERING MINTED. Lowering builds nodes (tail returns,
    # hoisted temporaries, desugared assignments) without ids; a node
    # without one drops out of the semantic layer. Existing ids are kept —
    # they are what makes the checker's facts reachable from this copy.
    fillIds(lm.m)
    # 6. OWNERSHIP, DECIDED. After the copy marks (it reads them) and after
    # every node has an id (it keys by them); before any emitter runs, so
    # the emitter prints a decision instead of making one. Only on the
    # backends whose containers alias — the same ones that get copy marks;
    # Odin prints the frees, D's collector does not need them but the
    # decision's assertions (buffer_check) still run over its tree.
    if backend.aliasesOnAssign:
      decideOwnership(semLayer, lm.m, ownedStrProcs(backend))
      markTwinCalls(semLayer, lm.m)                                # 7. twins
    # 8. EVERY CALL IS COMPLETE. The checker rejects a payload missing a
    # param, but it runs before lowering, and lowering builds and rewrites
    # calls. Asserted here, after the last pass that can, so no emitter is
    # ever handed a call with a hole to fill in its own way.
    assertCallsComplete(semLayer, lm.m, result.real)
    vSub(lm.name, ts)
  vEnd(psLowering, t0)

proc modules*(t: BackendTree): seq[Module] =
  ## The bare modules, for the stage assertions that take a `seq[Module]`.
  for lm in t.mods: result.add lm.m
