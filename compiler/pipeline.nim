# compiler/pipeline.nim
#
# Names the pipeline's real stages, and a handful of assertions that check
# a tree genuinely carries what the next stage needs — rather than that
# being an informal comment on `checkOrDie`/tuck.nim and a re-derivation
# each backend does for itself when something looks wrong.
#
# The REAL, distinct stages, found by reading the driver rather than
# guessed: load, inject types, typecheck, verify effects, mangle, lower,
# emit. There is no "indexing" stage — compiler/decl_index.nim's DeclIndex
# is built lazily, per backend, on demand at codegen time; it gates
# nothing upstream of it. `lowering`/`emitting` are inherently per-backend
# once a build targets exactly one (see tuck.nim's Backend enum) — the
# enum names the stage, not which tree it ran on.
#
# Off by default: these walk the whole tree, and are diagnostic, not
# something every compile should pay for. `--verify-stages` turns them on.

import ast
import ast_query
import resolution
import strutils
import analysis_ssa
import analysis_liveness
import sets, os
import ssa_build
import ssa_query
import ssa_ir

type
  PipelineStage* = enum
    psLoad          ## loadOrDie/loadProgram: lex+parse+import-closure
    psInjectTypes   ## injectImportedTypes
    psResolveDeclRefs ## resolve_refs.resolveDeclRefs — bare actor/register/
                      ## registry/pool/mixin names become their own node
                      ## kind before typecheck ever sees them as exkVar
    psTypecheck     ## typecheckProgram
    psVerifyEffects ## verifyModuleEffects — after psTypecheck: typechecking
                    ## resets the shared semantic layer, so async call-site
                    ## marks made before that point would be wiped
    psMangle        ## mangleProgram — whole-program, once, before any
                    ## backend's deepCopy
    psLowering      ## lowerModule (+lowerModuleD for D) — per backend copy
    psEmitting      ## emitNim/emitOdin/emitD — per backend

proc requireOrder*(have, want: PipelineStage) =
  ## `ord()` on the enum IS the ordering check — ordering is exactly what
  ## the enum's declaration sequence already states, so there is no
  ## separate state-machine type to keep in sync with it.
  if ord(have) < ord(want):
    raise newException(ValueError,
      "pipeline: stage " & $want & " requires " & $have & " to have run first")

proc hasChainReceiver(e: Expr): bool =
  ## True when `e` is a resolved `.fn` call whose receiver is a `..` chain —
  ## the exact shape lowering.hoistChainCalls exists to rewrite away
  ## (compiler/lowering.nim). Purely structural: no semLayer lookup needed,
  ## `e.receiver.kind == exkChain` is enough on its own.
  e != nil and e.kind == exkField and e.receiver != nil and
    e.receiver.kind == exkChain

proc walkNoChainReceiver(e: Expr, bad: var seq[Expr]) =
  if e == nil: return
  if hasChainReceiver(e): bad.add(e)
  for c in e.children: walkNoChainReceiver(c, bad)

proc assertNoChainFedCalls*(mods: seq[Module]) =
  ## After psLowering: no `.fn` call may still have a `..` chain as its
  ## receiver. Before hoistChainCalls existed, this exact shape reached
  ## codegen as `startAudio(    self = loadEpisode(self, episode);\n)` —
  ## a statement spliced into an argument slot, valid in none of the three
  ## target languages. Once lowering has run, the shape cannot occur; this
  ## assertion says so instead of leaving it as a comment on the fix.
  var bad: seq[Expr]
  for m in mods:
    for fn in m.allFns(): walkNoChainReceiver(fn.fnBody, bad)
    for d in m.decls(dkTask): walkNoChainReceiver(d.taskBody, bad)
    for d in m.decls(dkExpr): walkNoChainReceiver(d.expr, bad)
  if bad.len > 0:
    raise newException(ValueError,
      "pipeline: " & $bad.len &
      " call(s) still have a chain receiver after lowering — " &
      "hoistChainCalls should have rewritten every one of these away")

proc walkAsyncConsistency(e: Expr, bad: var seq[Expr]) =
  if e == nil: return
  if semLayer.isAsync(e):
    let call = semLayer.call(e)
    let decl = if call != nil: semLayer.declFor(call) else: nil
    # A missing decl edge is a DIFFERENT, already-known gap (declFor is not
    # populated for every call shape — payload-application calls to an
    # extern are one, per TODO.md's callParamsFor/declForType notes) and not
    # what this assertion exists to catch. Only flag a REAL disagreement:
    # a decl edge that exists but does not declare [io].
    if decl != nil and emIo notin decl.fnEffects: bad.add(e)
  for c in e.children: walkAsyncConsistency(c, bad)

proc assertAsyncEffectsConsistent*(mods: seq[Module]) =
  ## After psVerifyEffects: every call site the effect pass marked async
  ## (semantics.nim's callEffects, matched by NAME against the caller's own
  ## `getDeclaredEffects`) that ALSO has a `declFor` edge (a DIFFERENT
  ## lookup, populated during typecheck's own call resolution) must agree —
  ## that declaration must genuinely declare [io]. The two mechanisms answer
  ## the same question two different ways when both are present; if they
  ## disagree, the documented ordering hazard on `checkOrDie` ("typechecking
  ## resets the semantic layer... async marks wiped before codegen reads
  ## them") has recurred.
  var bad: seq[Expr]
  for m in mods:
    for fn in m.allFns(): walkAsyncConsistency(fn.fnBody, bad)
    for d in m.decls(dkTask): walkAsyncConsistency(d.taskBody, bad)
    for d in m.decls(dkExpr): walkAsyncConsistency(d.expr, bad)
  if bad.len > 0:
    raise newException(ValueError,
      "pipeline: " & $bad.len &
      " call(s) marked async do not resolve to an [io] declaration — " &
      "the async mark and the call's own resolved declaration disagree")

proc walkNoMissingTypes(e: Expr, bad: var seq[Expr]) =
  if e == nil: return
  # Only a node the checker actually SYNTHESIZED a type for counts — most
  # nodes (declarations, patterns, statement-level constructs) never go
  # through `tc.synthesize` and have no recorded type at all (`typeFor`
  # returns nil), which is not evidence of anything. Only a type the
  # checker recorded AS `missing type` — its "I could not work this out"
  # sentinel — is the real signal: every OTHER gradual-typing marker
  # (`<typeparam>`, `<pending>`, `<emptyrec>`) means something legitimate,
  # not a gap, so this checks the exact name rather than reusing
  # ast_query's `hasMissingType` (which also treats a nil type as unknown —
  # right for a backend about to emit one, wrong for "was this even typed
  # at all").
  let t = semLayer.typeFor(e)
  if t != nil and hasMissingType(t): bad.add(e)
  for c in e.children: walkNoMissingTypes(c, bad)

proc assertNoMissingTypes*(mods: seq[Module]) =
  ## After psTypecheck: no expression may still carry the checker's own
  ## "I could not work this out" marker. Gradual typing has real, deliberate
  ## holes (a `pending:` stub, a generic's type param inside its own body) —
  ## none of those are `missing type`, they are their own distinct sentinels.
  ## A node that reaches here still tagged `missing type` means some checker
  ## path returned it instead of reporting — `synthBareVariant`'s old
  ## silent fallback was exactly this, caught only by hand after three
  ## unrelated bugs rode through it (discard, register-field reads, a
  ## sizeof argument) before each got its own dedicated fix. This turns
  ## that class of bug into an immediate, located failure instead of a
  ## silent pass-through to codegen.
  var bad: seq[Expr]
  for m in mods:
    for fn in m.allFns(): walkNoMissingTypes(fn.fnBody, bad)
    for d in m.decls(dkTask): walkNoMissingTypes(d.taskBody, bad)
    for d in m.decls(dkExpr): walkNoMissingTypes(d.expr, bad)
  if bad.len > 0:
    var lines: seq[string]
    for e in bad: lines.add($e.span.line & ":" & $e.span.col)
    raise newException(ValueError,
      "pipeline: " & $bad.len & " expression(s) still carry the checker's " &
      "missing type marker after typecheck (a checker gap, not a real error) " &
      "at " & lines.join(", "))

proc assertSsaWellFormed*(res: Resolution, mods: seq[Module]) =
  ## After psTypecheck, under `--verify-stages`: the value mirror
  ## (compiler/analysis_ssa.nim) must be structurally sound for every body in
  ## the program.
  ##
  ## Stage A of thoughts/ssa-mirror-design.md, and the reason it is a
  ## pipeline assertion rather than a unit test: the invariants are about
  ## SHAPES THE CORPUS CONTAINS, not about shapes I thought to write down. A
  ## phi whose operands belong to a different place, a read whose value was
  ## never defined, a use recorded twice — each is a builder bug that would
  ## silently produce a wrong ownership answer two stages later, and each is
  ## far cheaper to find here, over every example and both applications, than
  ## from a leak in emitted Odin.
  ##
  ## Nothing CONSULTS the mirror yet. It earns that by reproducing
  ## analysis_liveness exactly; until then this is the only thing that runs it.
  var bad: seq[string]
  for m in mods:
    # THE ORACLE. `analysis_liveness` no longer stamps anything — the mirror
    # does — so this recomputes its answer independently and checks the
    # mirror against it. One documented divergence is allowed, below.
    let reference = referenceFinalUses(res, m)
    for fn in buildModuleSsa(res, m):
      bad.add(structuralErrors(fn))
      # STAGE A.2, and the criterion is a SUPERSET rather than equality.
      #
      # The design document asked for an identical answer. Writing it showed
      # that was the wrong bar: SSA is strictly MORE precise in a loop,
      # because a loop-head phi is a fresh version each iteration, so
      #
      #     for i < n:
      #       out = {items: out, value: 0} push
      #
      # has a final read of `out` at the push — the old pass cannot say so,
      # since it reasons about the NAME `out`, which is live at the head.
      # That extra precision is the whole point of the mirror and refusing
      # it would be refusing the feature.
      #
      # What must hold is the other direction: every site the existing pass
      # proves final, the mirror must also prove. A site it misses is a
      # capability lost; a site it invents is a use-after-move. So
      # `onlyPass` is the assertion and `onlyMirror` is the measurement.
      let d = livenessDiff(reference, fn)
      if d.onlyPass > 0 and not deferExempt(fn):
        bad.add(fn.name & ": the mirror misses " & $d.onlyPass &
                " final use(s) analysis_liveness proves")
      when not defined(release):
        if getEnv("TUCK_DEBUG_SSA") == "diff" and
           (d.onlyMirror > 0 or d.onlyPass > 0):
          echo "SSADIFF ", fn.name, " agree=", d.agree,
               " onlyMirror=", d.onlyMirror, " onlyPass=", d.onlyPass
  if bad.len > 0:
    raise newException(ValueError,
      "pipeline: the SSA mirror is malformed in " & $bad.len &
      " place(s) — " & bad[0 .. min(4, bad.high)].join("; "))

proc allMangled(name: string): bool =
  name.len == 0 or name.startsWith("tuck_")

proc assertMangleIdempotent*(mods: seq[Module]) =
  ## After psMangle: every manglable name mangleProgram touches must
  ## already carry its prefix — mangleName's own documented claim
  ## ("re-running the pass over an already-lowered tree is a no-op, which
  ## matters because each backend lowers its own deepCopy", mangle.nim)
  ## turned into a check instead of only a comment. Checks DECLARED names
  ## only (fn/type/object/actor/task/const/pool/registry/register/fn-sig),
  ## the same set mangle.nim itself renames — a plain string or a
  ## deliberately-unmangled extern is not expected to carry the prefix.
  var bad: seq[string]
  for m in mods:
    for d in m.decls:
      if d == nil: continue
      case d.kind
      of dkFn:
        if not d.isExtern and not allMangled(d.name): bad.add(d.name)
      of dkType, dkObject, dkActor, dkTask, dkConst, dkPool, dkRegistry,
         dkRegister, dkFnSig:
        if not allMangled(d.name): bad.add(d.name)
      else: discard
  if bad.len > 0:
    raise newException(ValueError,
      "pipeline: " & $bad.len &
      " declared name(s) missing the tuck_ prefix after mangling: " &
      bad.join(", "))


proc ssaRebuildDiff*(res: Resolution, mods: seq[Module]) =
  ## THE BRAUN REBUILD, measured against what it is meant to replace.
  ##
  ## `compiler/ssa_build.nim` implements Braun et al. (2013) properly, where
  ## `analysis_ssa.nim` is an ad-hoc two-thirds of the same paper. Nothing
  ## consults the new one yet; it earns that the way Stage A earned it, by
  ## reproducing the old answer across the corpus and both applications and
  ## having every difference accounted for.
  ##
  ## The criterion is NOT "identical". Sealing and trivial-phi removal make
  ## the new construction strictly more precise in a loop, exactly as SSA was
  ## strictly more precise than the walk it replaced. So `onlyOld` — a read
  ## the old builder called final and the new one does not — is the number
  ## that must be zero; `onlyNew` is a result to read, not a failure.
  ##
  ##   TUCK_DIFF_SSA=1 ./tuck ch file.tuck
  when not defined(release):
    if getEnv("TUCK_DIFF_SSA").len == 0: return
    var agree, onlyNew, onlyOld, structural = 0
    for m in mods:
      for d in m.allFns():
        if d.fnBody == nil: continue
        let old = analysis_ssa.finalUses(analysis_ssa.buildFn(res, d))
        let fresh = ssa_build.buildFn(res, d)
        for e in ssa_query.structuralErrors(fresh):
          inc structural
          echo "SSADIFF-STRUCT ", d.name, ": ", e
        let nw = ssa_query.finalUses(fresh)
        agree += (old * nw).len
        onlyNew += (nw - old).len
        onlyOld += (old - nw).len
        if (old - nw).len > 0:
          echo "SSADIFF ", d.name, " onlyOld=", (old - nw).len,
               "  <-- the new builder lost a final use"
          if getEnv("TUCK_DIFF_SSA") == "dump" and d.name == getEnv("TUCK_DIFF_FN"):
            echo ssa_build.dump(fresh)
            for v in fresh.values:
              for u in v.uses:
                echo "   use node=", $uint32(u.at), " of ", $v.id, " ", v.place,
                     " blk=", $u.blk,
                     (if u.at in old: " OLD-FINAL" else: ""),
                     (if u.at in nw: " NEW-FINAL" else: "")
    echo "SSATOTAL agree=", agree, " onlyNew=", onlyNew,
         " onlyOld=", onlyOld, " structural=", structural
