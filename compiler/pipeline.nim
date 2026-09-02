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

proc walkNoUnknownTypes(e: Expr, bad: var seq[Expr]) =
  if e == nil: return
  # Only a node the checker actually SYNTHESIZED a type for counts — most
  # nodes (declarations, patterns, statement-level constructs) never go
  # through `tc.synthesize` and have no recorded type at all (`typeFor`
  # returns nil), which is not evidence of anything. Only a type the
  # checker recorded AS `UnknownName` — its "I could not work this out"
  # sentinel — is the real signal: every OTHER gradual-typing marker
  # (`<typeparam>`, `<pending>`, `<emptyrec>`) means something legitimate,
  # not a gap, so this checks the exact name rather than reusing
  # ast_query's `hasUnknownType` (which also treats a nil type as unknown —
  # right for a backend about to emit one, wrong for "was this even typed
  # at all").
  let t = semLayer.typeFor(e)
  if t != nil and t.kind == tkNamed and t.name == UnknownName: bad.add(e)
  for c in e.children: walkNoUnknownTypes(c, bad)

proc assertNoUnknownTypes*(mods: seq[Module]) =
  ## After psTypecheck: no expression may still carry the checker's own
  ## "I could not work this out" marker. Gradual typing has real, deliberate
  ## holes (a `pending:` stub, a generic's type param inside its own body) —
  ## none of those are `UnknownName`, they are their own distinct sentinels.
  ## A node that reaches here still tagged `UnknownName` means some checker
  ## path returned it instead of reporting — `synthBareVariant`'s old
  ## silent fallback was exactly this, caught only by hand after three
  ## unrelated bugs rode through it (discard, register-field reads, a
  ## sizeof argument) before each got its own dedicated fix. This turns
  ## that class of bug into an immediate, located failure instead of a
  ## silent pass-through to codegen.
  var bad: seq[Expr]
  for m in mods:
    for fn in m.allFns(): walkNoUnknownTypes(fn.fnBody, bad)
    for d in m.decls(dkTask): walkNoUnknownTypes(d.taskBody, bad)
    for d in m.decls(dkExpr): walkNoUnknownTypes(d.expr, bad)
  if bad.len > 0:
    var lines: seq[string]
    for e in bad: lines.add($e.span.line & ":" & $e.span.col)
    raise newException(ValueError,
      "pipeline: " & $bad.len & " expression(s) still carry the checker's " &
      "<unknown> marker after typecheck (a checker gap, not a real error) " &
      "at " & lines.join(", "))

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
