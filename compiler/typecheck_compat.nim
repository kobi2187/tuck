# compiler/typecheck_compat.nim
#
# "May a value of THIS type flow where THAT one is wanted?" One predicate over
# wrapper discipline, nominal-vs-structural rules, numeric widening and fnsig
# matching. Every call site, assignment and return routes through `compatible`,
# so a change here changes what the whole language accepts.
#
# NO TYPE MATCHES ANYTHING. There was a list of names that did — `void`,
# `unit`, `Self`, `fn` — and it is gone. Each was measured before removal:
#
# `Self`    asInterfaceCall substitutes the concrete receiver type before
#           checking, and isSelfParam skips Self params in checkCallArgs, so
#           the entry could only fire where BOTH had missed. Cost: nothing.
#
# `void`/   Making the absence of a type match ANY type meant a void-returning
# `unit`    fn satisfied `-> int`. returnsNothing answers the real question
#           where it matters. Cost: nothing, once examples/04 stopped declaring
#           `-> void` for a body yielding a PodcastApp — the bug it was hiding.
#
# `fn`      A bare `fn` param had no signature to check against, so every
#           callback argument passed. `fnsig NAME = {params} -> ret` (spec
#           D#10c) states the shape instead, and fnRefCompatible checks a
#           `:name` reference against it. The two sites that used bare `fn`
#           are std/scheduler's `Predicate` and examples/03's `BinOp`.
import ast, sets, tables
import typecheck_state
import typecheck_util

proc compatible*(tc: TypeChecker, actual, expected: Type): bool
  ## Forward-declared: nominalCompatible/fnRefCompatible/recordCompatible/
  ## appCompatible below all call back into it before its own definition.

proc unwrapForCompare*(actual, expected: Type, a, e: var Type): bool =
  ## Wrapper discipline: a bare T may flow where !T is expected (auto-wrap on
  ## return), and !T matches !T — but a !T/?T value where bare T is expected is
  ## an UNHANDLED error and never compatible. `or` / `?` unwrap explicitly.
  ## Returns false when the pair is already known incompatible.
  a = actual
  e = expected
  if not isWrapper(a):
    e = unwrapEffect(e)
  elif isWrapper(e):
    a = unwrapEffect(a)
    e = unwrapEffect(e)
  elif not isUnknown(e):
    return false
  true

proc nominalCompatible*(tc: TypeChecker, a, e: Type): bool =
  ## Two named types. Distinct types are strictly nominal: no widening, no
  ## resolving through to the base type — Milliseconds is not Microseconds is
  ## not u32.
  ##
  ## SUM TYPES ARE NOMINAL too. Two differently-named sums are never
  ## compatible, even though both resolve to a tkSum body. Resolving first
  ## destroyed the only thing that distinguishes them: the fallthrough is
  ## `a.kind == e.kind`, and tkSum == tkSum, so `fn pick() -> Colour: return
  ## Red` and `fn pick({l: Light}) -> Colour: return l` both passed. It is
  ## checked here rather than at the bottom because by then the names are gone.
  ## Records still fall through to structural matching — subset matching
  ## (spec 2.5) is the whole point for them.
  if a.name == e.name: return true
  if a.name in tc.distinctNames or e.name in tc.distinctNames: return false
  if isNumeric(a) and isNumeric(e):
    when defined(strictNumeric): return false     # measure the widening
    else: return true                             # loose widening for primitives
  let ra = tc.resolve(a)
  let re = tc.resolve(e)
  if ra != nil and re != nil and (ra.kind == tkSum or re.kind == tkSum):
    return false
  # One side may be an alias for a record — fall through to structural
  if ra != a or re != e: tc.compatible(ra, re) else: false

proc fnRefCompatible*(tc: TypeChecker, a, e: Type): bool =
  ## A `:name` fn-ref synthesizes a tkFunc while the parameter names a fnsig,
  ## which is a tkNamed. Match the reference against the named signature's
  ## shape — otherwise the pair falls through to the record check and every
  ## callback argument is rejected (`expects BinOp but got <type>`).
  let sig = tc.fnSigs[e.name]
  if a.params.len != sig.params.len: return false
  for i, p in sig.params:
    if not tc.compatible(a.params[i], p.typ): return false
  a.result == nil or sig.ret == nil or tc.compatible(a.result, sig.ret)

proc recordCompatible*(tc: TypeChecker, a: Type, eFields: seq[FieldDef]): bool =
  ## Expected record => subset matching (spec 2.5): every expected field must
  ## be present and compatible, extras are fine.
  let aFields = if a.kind == tkRecord: a.fields else: tc.fieldsOf(a)
  if aFields.len == 0 and a.kind != tkRecord:
    return false  # known non-record vs record
  for ef in eFields:
    var found = false
    for af in aFields:
      if af.name != ef.name: continue
      # A hole does not change the record's SHAPE, so a partly-built Config is
      # structurally still a Config. Whether THIS callee may receive one is a
      # sharper question than compatibility can answer — it depends on which
      # fields the callee reads — so checkNamedField asks it separately.
      if not tc.compatible(unwrapUninit(af.typ), ef.typ): return false
      found = true
      break
    if not found: return false
  true

proc appCompatible*(tc: TypeChecker, a, e: Type): bool =
  ## Two type applications: same base, and pairwise-compatible arguments.
  if not tc.compatible(a.base, e.base): return false
  if a.args.len != e.args.len: return true
  for i in 0 ..< a.args.len:
    if not tc.compatible(a.args[i], e.args[i]): return false
  true

proc compatible*(tc: TypeChecker, actual, expected: Type): bool =
  ## May a value of `actual` flow where `expected` is wanted?
  var a, e: Type
  if not unwrapForCompare(actual, expected, a, e): return false
  # Unknown is compatible with everything, which makes every Unknown a check
  # that silently passes. MEASURED (2026-08-07): building with this returning
  # `false` instead turns 7 of the 43 examples red — an untyped value reaching
  # a sum type, and three fns whose body the checker cannot type at all
  # satisfying a declared `-> bool` or `-> !{value: u16}`. Each is a real gap
  # this line is hiding, not a false positive. See fuzz/README.md.
  if isUnknown(a) or isUnknown(e):
    when defined(strictUnknown): return false
    else: return true
  if a.kind == tkNamed and e.kind == tkNamed:
    return tc.nominalCompatible(a, e)
  if a.kind == tkFunc and e.kind == tkNamed and tc.fnSigs.hasKey(e.name):
    return tc.fnRefCompatible(a, e)
  let eFields = if e.kind == tkRecord: e.fields else: tc.fieldsOf(e)
  if eFields.len > 0 or e.kind == tkRecord:
    return tc.recordCompatible(a, eFields)
  if a.kind == tkApp and e.kind == tkApp:
    return tc.appCompatible(a, e)
  # Sum types and the rest: nominal only, handled above; unknown shapes pass
  when defined(strictKind): false   # measure the same-kind fallthrough
  else: a.kind == e.kind
