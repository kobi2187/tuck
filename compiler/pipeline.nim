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

type
  PipelineStage* = enum
    psLoad          ## loadOrDie/loadProgram: lex+parse+import-closure
    psInjectTypes   ## injectImportedTypes
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
