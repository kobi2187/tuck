# compiler/typecheck.nim
#
# STAGE 4 OF THE PIPELINE — does this program actually make sense?
#
# The parser will happily build a tree for `"hello" + 5`. That is perfectly
# good SYNTAX. It is nonsense SEMANTICS, and this file is what says so — before
# the program runs, rather than after it crashes. This is where a compiler
# earns its keep.
#
# BIDIRECTIONAL CHECKING. Two cooperating questions, used in alternation:
#
#   synthesize  "I have no expectations. What type IS this?"   (`5` -> int)
#   check       "I expect a str here. Does this fit?"
#
# Most real typecheckers work this way. Pure inference gets expensive and
# fragile; pure annotation gets tedious to write. Alternating between pulling
# types up and pushing them down gets most of the convenience for far less
# machinery.
#
# FAIL-FAST. The first type error raises SemanticError and stops. No error
# recovery, no cascade of confused follow-up messages caused by the first
# mistake. One real error at a time, with a source position.
#
# GRADUAL BY DESIGN. An undeclared symbol synthesizes Unknown, and Unknown is
# compatible with everything. So half-written sketch code still compiles while
# the parts you HAVE declared are checked strictly. This is what makes Tuck's
# `pending:` blocks work — declare the signature, leave the body for later, and
# keep running the program in the meantime.
#
# ---------------------------------------------------------------------------
# THE PART WORTH READING: synthFieldAccess, further down.
#
# `a.b` means several different things in Tuck, and the checker decides which
# by trying them in a fixed order:
#
#   1. .ok / .err / .value on a fallible value   result introspection
#   2. slot.invoke {args}                        call through a baked slot
#   3. 5.ms, n.toStr                             postfix application, EARLY
#                                                (literal/var receiver, in a body)
#   4. Color.Red                                 sum-type variant construction
#   5. point.x                                   an ordinary field read
#   6. Pool.acquire, Pool.release {v}            pool member call
#   7. x.describe                                postfix application, FALLTHROUGH
#                                                plus `.fn {args}`, the method form
#
# THAT ORDER IS THE LANGUAGE RULE. It is not an implementation detail — change
# the order and you change what programs mean. Each case is a small proc
# returning nil for "not mine", so the parent reads as exactly the list above.
#
# 3 AND 7 ARE THE SAME OPERATION, reached from two points. Both stamp a call
# with the receiver as its argument. They are separate only because the
# ordering demands it: 3 must precede variant construction and field reads so
# `5.ms` is not read as a field, and 7 must follow them so a real field wins
# over a same-named fn. asPlainField sits between and fails on a field/fn name
# clash, which is what makes the split safe. Only 7's `.fn {args}` branch is a
# distinct meaning — that one routes to synthMethodCall.
#
# 6 IS NOT `module::function`. That is exkQualified, resolved in synthCall via
# calleeNameOf, and it never reaches this proc. What arrives here is the dot
# form for pool members, registered in fnSigs under a dot-joined key
# ("Pool.acquire", built by the dkPool arm of collectSigs). Both namespaces
# live in fnSigs: `.` for pool members, `::` for module calls.
#
# There is a general lesson in that: a surprising amount of what feels like
# "language design" turns out to be the order in which you try interpretations.
# ---------------------------------------------------------------------------
#
# Split across four files so this one stays about RULES rather than plumbing:
#   typecheck_state.nim   the TypeChecker object and its lookups
#   typecheck_util.nim    small shared predicates (isNumeric, isWrapper, fail)
#   typecheck_flow.nim    control-flow questions (does this branch always exit?)
#   typecheck.nim         the rules themselves
#
# ---------------------------------------------------------------------------
# HOW IT RUNS, AND WHAT IT COSTS
#
# The shape is a single recursive walk. synthesize() descends an expression,
# each node combining its children's types into its own, so one pass over the
# tree types the whole tree — no fixpoint iteration, no constraint solver, no
# unification queue. Errors raise immediately (fail-fast), so there is no error
# recovery machinery either. That is the main reason a checker doing this much
# work still lands at roughly a quarter of total compile time.
#
# THE INDEXES THAT MAKE IT FAST. Before walking anything, typecheck_state.nim
# fills two tables:
#
#   fnSigs      name -> (params, return type, generics)
#   typeDecls   name -> declared type body
#
# Both are hash tables built once per module, so name resolution during the
# walk is O(1). The alternative — asking ast_query's findDecl/findFn each
# time — is a linear scan of the declaration list, and doing that per node
# turns the pass O(N²). The tables are the single most important performance
# decision in this file.
#
# It is not fully O(1) yet: some paths still reach for the linear helpers, and
# it shows. Between a 4,000- and a 32,000-line module (8x input) this pass
# grows 14.4x while lexing and parsing grow 8.9x. Lowering, which leans on the
# scans harder, grows 18.3x. Not urgent — 32,000 lines still checks in about a
# third of a second — but that is where the time goes if it ever matters.
#
# TWO MORE THINGS THAT KEEP THE COST DOWN:
#
#   Unknown short-circuits. An undeclared symbol synthesizes Unknown, which is
#   compatible with everything, so sketch code stops the checker early instead
#   of dragging it through cascading failures.
#
#   Signature-only imports. modules.nim hands the checker its imports'
#   SIGNATURES rather than their bodies, so `tuck check` never walks the
#   interior of an imported module at all. The cheapest pass is the one that
#   does not run.
#
# MEASURE, DO NOT GUESS: benches/bench_phases.nim times each phase in
# isolation against a generated program, re-parsing between mutating phases so
# the work is real.
# ---------------------------------------------------------------------------
import ast, semantics, lowering, tables, strutils, sets
import resolution
import ast_query
import typecheck_util
export typecheck_util
import typecheck_state
export typecheck_state
import typecheck_flow
export typecheck_flow
import typecheck_transitions  # spec 4.4 sum-type transition graph
import typecheck_decisions    # spec 6.1 decision-table analysis
import typecheck_pointers     # pointers stay at the extern boundary
import typecheck_conformance  # spec 5.2 `satisfies` verification
export typecheck_transitions

# UnknownName now lives in ast.nim (codegen needs it for typed-AST checks)
# Stateless helpers now live in typecheck_util; the TypeChecker state object +
# scope/resolve/fieldsOf now live in typecheck_state (both imported above).
proc compatible(tc: TypeChecker, actual, expected: Type): bool

const AnyMatchingNames = ["void", "unit", "fn"]
  ## Names that match anything: the absence of a type, and the untyped
  ## callable.
  ##
  ## `Self` USED to be here and is not, because two real mechanisms already
  ## handle it and this entry could only fire where they had missed — which
  ## is precisely where a diagnostic is due. asInterfaceCall substitutes the
  ## concrete receiver type for Self before checking (search `pt = selfT`),
  ## and isSelfParam skips Self params in checkCallArgs, since the receiver
  ## comes from the call site rather than the payload. Removing it cost
  ## nothing: the full gate stayed green.

proc matchesAnything(t: Type): bool =
  ## Does this type accept any counterpart?
  t.kind == tkNamed and t.name in AnyMatchingNames

proc unwrapForCompare(actual, expected: Type, a, e: var Type): bool =
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

proc nominalCompatible(tc: TypeChecker, a, e: Type): bool =
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

proc fnRefCompatible(tc: TypeChecker, a, e: Type): bool =
  ## A `:name` fn-ref synthesizes a tkFunc while the parameter names a fnsig,
  ## which is a tkNamed. Match the reference against the named signature's
  ## shape — otherwise the pair falls through to the record check and every
  ## callback argument is rejected (`expects BinOp but got <type>`).
  let sig = tc.fnSigs[e.name]
  if a.params.len != sig.params.len: return false
  for i, p in sig.params:
    if not tc.compatible(a.params[i], p.typ): return false
  a.result == nil or sig.ret == nil or tc.compatible(a.result, sig.ret)

proc recordCompatible(tc: TypeChecker, a: Type, eFields: seq[FieldDef]): bool =
  ## Expected record => subset matching (spec 2.5): every expected field must
  ## be present and compatible, extras are fine.
  let aFields = if a.kind == tkRecord: a.fields else: tc.fieldsOf(a)
  if aFields.len == 0 and a.kind != tkRecord:
    return false  # known non-record vs record
  for ef in eFields:
    var found = false
    for af in aFields:
      if af.name != ef.name: continue
      if not tc.compatible(af.typ, ef.typ): return false
      found = true
      break
    if not found: return false
  true

proc appCompatible(tc: TypeChecker, a, e: Type): bool =
  ## Two type applications: same base, and pairwise-compatible arguments.
  if not tc.compatible(a.base, e.base): return false
  if a.args.len != e.args.len: return true
  for i in 0 ..< a.args.len:
    if not tc.compatible(a.args[i], e.args[i]): return false
  true

proc compatible(tc: TypeChecker, actual, expected: Type): bool =
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
  if matchesAnything(e) or matchesAnything(a):
    when defined(strictAny): return false
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

proc synthesize(tc: var TypeChecker, e: Expr): Type
proc synthBracket(tc: var TypeChecker, e: Expr): Type
proc synthBracketAssign(tc: var TypeChecker, e: Expr): Type

# Method form: `x .fn {args}` / `x ..fn {args}` — the receiver rides as the
# fn's FIRST parameter (checked structurally when the receiver type has no
# name), the braced struct fills the remaining parameters by name. Builds and
# returns the positional exkCall node (receiver, then declared-order args),
# ty-stamped with the fn's return type — codegen emits it as-is.
proc synthMethodCall(tc: var TypeChecker, fnName: string, receiver: Expr,
                     recvT: Type, argStruct: Expr, sp: Span): Expr =
  let sig = tc.fnSigs[fnName]
  if sig.params.len == 0:
    fail("Type Error: '" & fnName & "' takes no parameters — it cannot be " &
         "called as a method on " & typeName(recvT), sp)
  if not tc.compatible(recvT, sig.params[0].typ):
    fail("Type Error: '" & fnName & "' first parameter expects " &
         typeName(sig.params[0].typ) & " but the receiver is " &
         typeName(recvT), sp)
  var argFields: seq[FieldInit]
  if argStruct != nil:
    if argStruct.kind != exkStruct:
      fail("Type Error: arguments to '" & fnName &
           "' must be a struct literal: {name: value, ...}", argStruct.span)
    argFields = argStruct.fields
  var args: seq[Expr] = @[receiver]
  for i in 1 ..< sig.params.len:
    let p = sig.params[i]
    var found = false
    for f in argFields:
      if f.name == p.name:
        let ft = tc.synthesize(f.value)
        if not tc.compatible(ft, p.typ):
          fail("Type Error: field '" & p.name & "' of call to '" & fnName &
               "' expects " & typeName(p.typ) & " but got " & typeName(ft),
               f.value.span)
        args.add(f.value)
        found = true
        break
    if not found:
      fail("Type Error: call to '" & fnName & "' is missing required field '" &
           p.name & ": " & typeName(p.typ) & "'", sp)
  result = Expr(span: sp, kind: exkCall,
                callee: Expr(span: sp, kind: exkVar, name: fnName), args: args)
  setType(semLayer, result, sig.ret)

# `a.b` is one spelling for seven different things. Each of the procs below
# recognises exactly one of them and returns nil for "not mine", so
# synthFieldAccess reads as the ordered list of what `a.b` can mean — the
# order matters and is the real content of this part of the checker.

proc unwrapGuarded(tc: var TypeChecker, e: Expr, recvT: Type): Type =
  ## `.value` is legal only under this result's own `if x.ok` guard.
  if e.receiver.kind != exkVar or e.receiver.name notin tc.okNarrowed:
    let n = if e.receiver.kind == exkVar: e.receiver.name else: "<result>"
    fail("Type Error: unhandled " & typeName(recvT) & " — guard it " &
         "first: `if " & n & ".ok:` and read .value inside, or " &
         "`if not " & n & ".ok:` with a return, which narrows " &
         "everything after it", e.span)
  unwrapEffect(recvT)

proc asResultIntrospection(tc: var TypeChecker, e: Expr): Type =
  ## `.ok` / `.err` / `.value` on a !T/?T — introspection IS the handling,
  ## unwrapping is a plain if rather than special syntax.
  if e.fieldName notin ["ok", "err", "value"] or e.receiver == nil or
     e.receiver.kind notin {exkVar, exkField}: return nil
  let recvT = tc.synthesize(e.receiver)
  if not isWrapper(recvT): return nil
  case e.fieldName
  of "ok": Type(span: e.span, kind: tkNamed, name: "bool")
  of "value": tc.unwrapGuarded(e, recvT)
  else: unknownType(e.span)  # .err — code; enum-typed later

proc hasVariant(t: Type, name: string): bool =
  ## Does this sum type declare a variant by this name?
  for v in t.variants:
    if v.name == name: return true
  false

proc sumTypeOwning(tc: TypeChecker, variant: string): string =
  ## The declared sum type that owns this variant name, or "".
  ##
  ## A bare `Red` is a value of its sum type — it used to synthesize as Unknown
  ## (exkVar knows only locals and fnSigs), so `return Red` was accepted
  ## wherever any type was expected. Ambiguity is not resolved here: if two sum
  ## types declare the same variant the first wins, exactly as the qualified
  ## form `Light.Red` exists to disambiguate.
  for name, body in tc.typeDecls:
    if body != nil and body.kind == tkSum and body.hasVariant(variant):
      return name
  ""

proc isSealed(t: Type): bool =
  ## Sealed types are entered only at their first variant; the rest are
  ## reached through transitions.
  for a in t.attrs:
    if a.name == "sealed": return true
  false

proc sealedEntryOnly(tc: TypeChecker, t: Type, e: Expr): bool =
  ## Is this a sealed type being constructed at a variant that is not its
  ## entry point, outside a transition and without the [unsafe] escape?
  isSealed(t) and t.variants.len > 0 and e.fieldName != t.variants[0].name and
    not e.ctorUnsafe and not tc.transitionCtx

proc asVariantConstruction(tc: var TypeChecker, e: Expr): Type =
  ## `Type.Variant` — constructing a sum type's variant by name.
  if e.receiver == nil or e.receiver.kind != exkVar or
     not tc.typeDecls.hasKey(e.receiver.name): return nil
  let declared = tc.typeDecls[e.receiver.name]
  if declared.kind != tkSum or not declared.hasVariant(e.fieldName): return nil
  if tc.sealedEntryOnly(declared, e):
    fail("Sealed Error: " & e.receiver.name & "." & e.fieldName &
         " cannot be constructed directly — sealed types start at '" &
         declared.variants[0].name & "'; reach '" & e.fieldName &
         "' via transitions, or mark [unsafe] for deserialization", e.span)
  Type(span: e.span, kind: tkNamed, name: e.receiver.name)

proc unwrapSingleField(arg: Expr): Expr =
  ## `Pool.release {v}` hands a one-field payload to a one-param fn, where the
  ## VALUE is the argument — passing the wrapper tuple would not match the rt
  ## signature. Anything else passes through untouched.
  soleFieldValue(arg)

proc fieldsCover(fields: seq[FieldDef], params: seq[Param]): bool =
  ## Do these fields supply every param by name? That is the "explode" shape —
  ## `server.describe` feeding a payload's fields to the params it declares.
  if fields.len == 0 or params.len == 0: return false
  for p in params:
    var found = false
    for f in fields:
      if f.name == p.name: found = true
    if not found: return false
  true

proc failIfFieldShadowsFn(fields: seq[FieldDef], recvT: Type, e: Expr) =
  ## A DECLARED type's field clashing with a fn name is already caught at
  ## declaration. An ANONYMOUS record has no declaration for that check to
  ## see, so `{port: 80}.port` stays genuinely ambiguous until used.
  if recvT.kind != tkRecord: return
  for f in fields:
    if f.name == e.fieldName:
      fail("Type Error: '" & e.fieldName & "' is both a field here and " &
           "a declared fn — rename one; fields and fns share the call " &
           "namespace", e.span)

proc failIfArgMismatched(tc: var TypeChecker, sig: FnSig, recvT: Type, e: Expr) =
  ## The receiver must fit the single param it is about to fill. A generic
  ## param accepts anything — checking against an unbound type VARIABLE would
  ## reject every receiver.
  let pt = sig.params[0].typ
  let isTypeVar = pt != nil and pt.kind == tkNamed and pt.name in sig.generics
  if not isTypeVar and not tc.compatible(recvT, pt):
    fail("Type Error: argument to '" & e.fieldName & "' expects " &
         typeName(pt) & " but got " & typeName(recvT), e.span)

proc asPostfixApplication(tc: var TypeChecker, e: Expr): Type =
  ## Postfix application in a fn BODY: `5.ms`, `n.toStr`. `x doSth` and
  ## `{value: x} doSth` are the same call — a bare receiver wraps into the
  ## one-field payload the signature declares. tc.currentFn gates this to
  ## bodies: the same `a.b` spelling in a SIGNATURE is a type or field path.
  ## Returns nil for the explode shape (`server.describe`), which synthCall
  ## handles further down — this must fall through rather than claim it.
  if tc.currentFn == "" or e.receiver == nil or
     e.receiver.kind notin {exkLit, exkVar} or
     not tc.fnSigs.hasKey(e.fieldName): return nil
  let sig = tc.fnSigs[e.fieldName]
  let recvT = tc.synthesize(e.receiver)
  # An interface receiver belongs to asInterfaceCall: `noise` is in fnSigs
  # because some OBJECT declares a member by that name, and matching against
  # that object's signature here would reject the interface ("expects Dog but
  # got Animal") before the contract is ever consulted.
  if recvT != nil and recvT.kind == tkNamed and tc.ifaceDecls.hasKey(recvT.name):
    return nil
  let recvFields = tc.fieldsOf(tc.resolve(recvT))
  failIfFieldShadowsFn(recvFields, recvT, e)
  if fieldsCover(recvFields, sig.params) or sig.params.len != 1: return nil
  tc.failIfArgMismatched(sig, recvT, e)
  # Stamp a real call node so codegen emits `toStr(n)`, not `n.toStr`.
  setCall(semLayer, e, Expr(span: e.span, kind: exkCall, args: @[e.receiver],
                            callee: Expr(span: e.span, kind: exkVar,
                                         name: e.fieldName)))
  sig.ret

proc asPlainField(tc: var TypeChecker, e: Expr, fields: seq[FieldDef],
                  recvT: Type): Type =
  ## `x.field` — an ordinary field read off the receiver's type.
  for f in fields:
    if f.name != e.fieldName: continue
    if tc.fnSigs.hasKey(e.fieldName):
      fail("Type Error: '" & e.fieldName & "' is both a field here and a " &
           "declared fn — rename one; fields and fns share the call " &
           "namespace", e.span)
    if e.dotArg != nil:
      fail("Type Error: '" & e.fieldName & "' is a field of " &
           typeName(recvT) & " — fields take no arguments; to set it, " &
           "use '.." & e.fieldName & " {value}' on a var", e.span)
    return f.typ
  nil

proc asInterfaceCall(tc: var TypeChecker, e: Expr, recvT: Type): Type =
  ## `a.noise` where `a` is an interface value — resolved against the CONTRACT,
  ## which is all the callee knows about its argument.
  ##
  ## The contract is also the whole of what is reachable: a member the concrete
  ## object happens to have but the interface does not declare is not callable
  ## here, because nothing at this site knows which object it was handed.
  if recvT == nil or recvT.kind != tkNamed: return nil
  if not tc.ifaceDecls.hasKey(recvT.name): return nil
  let iface = tc.ifaceDecls[recvT.name]
  for mem in iface.ifaceMembers:
    if mem == nil or mem.kind != dkFn or mem.name != e.fieldName: continue
    # `Self` in the contract is the interface here: the callee holds an
    # interface value, not the concrete type behind it.
    let selfT = Type(span: e.span, kind: tkNamed, name: recvT.name)
    var params: seq[Param]
    for p in mem.fnParams:
      var pt = p.typ
      if pt != nil and pt.kind == tkNamed and pt.name == "Self": pt = selfT
      params.add(Param(name: p.name, typ: pt, span: p.span))
    var ret = mem.fnReturnType
    if ret != nil and ret.kind == tkNamed and ret.name == "Self": ret = selfT
    let extra = unwrapSingleField(e.dotArg)
    let args = if extra != nil: @[e.receiver, extra] else: @[e.receiver]
    setCall(semLayer, e, Expr(span: e.span, kind: exkCall, args: args,
                              callee: Expr(span: e.span, kind: exkVar,
                                           name: e.fieldName)))
    semLayer.markIfaceCall(e, recvT.name, mem.name)
    return ret
  # The receiver IS an interface, so a name the contract lacks is an error
  # here rather than something for a later arm to try.
  var names: seq[string]
  for mem in iface.ifaceMembers:
    if mem != nil and mem.kind == dkFn: names.add(mem.name)
  fail("Type Error: interface " & recvT.name & " declares no '" & e.fieldName &
       "' — it requires: " & names.join(", ") &
       " (a member the concrete object has but the contract does not is not " &
       "reachable through the interface)", e.span)

proc asFnByName(tc: var TypeChecker, e: Expr, recvT: Type): Type =
  ## Not a field: `x.name` resolves to a fn by LOOKUP rather than syntax.
  ## `.fn {args}` is the method form (receiver first, args fill the rest);
  ## bare `.fn` is a whitespace call with the receiver as the payload.
  if not tc.fnSigs.hasKey(e.fieldName): return nil
  if e.dotArg != nil:
    let mc = tc.synthMethodCall(e.fieldName, e.receiver, recvT,
                                e.dotArg, e.span)
    setCall(semLayer, e, mc)
    return semLayer.typeFor(mc)
  let bc = Expr(span: e.span, kind: exkCall, args: @[e.receiver],
                callee: Expr(span: e.span, kind: exkVar, name: e.fieldName))
  setCall(semLayer, e, bc)
  tc.synthesize(bc)

proc asQualifiedMemberCall(tc: var TypeChecker, e: Expr): Type =
  ## `Pool.acquire` / `Pool.release {v}` (spec 7.2) — registered under the
  ## qualified name because the receiver is the POOL itself, not a value whose
  ## type carries the fn.
  if e.receiver == nil or e.receiver.kind != exkVar: return nil
  let qualified = e.receiver.name & "." & e.fieldName
  if not tc.fnSigs.hasKey(qualified): return nil
  let extra = unwrapSingleField(e.dotArg)
  let args = if extra != nil: @[e.receiver, extra] else: @[e.receiver]
  setCall(semLayer, e, Expr(span: e.span, kind: exkCall, args: args,
                            callee: Expr(span: e.span, kind: exkVar,
                                         name: e.fieldName)))
  tc.fnSigs[qualified].ret

proc asSlotInvoke(tc: var TypeChecker, e: Expr): Type =
  ## `slot.invoke {args}` — a call through a baked fn slot. Builtin; the
  ## slot's signature is checked by Nim at instantiation, gradual here.
  if e.fieldName != "invoke": return nil
  discard tc.synthesize(e.receiver)
  var callArgs: seq[Expr] = @[]
  if e.dotArg != nil:
    if e.dotArg.kind != exkStruct:
      fail("Type Error: invoke arguments must be a struct literal: " &
           "slot.invoke {a, b}", e.dotArg.span)
    discard tc.synthesize(e.dotArg)
    callArgs.add(e.dotArg)
  setCall(semLayer, e, Expr(span: e.span, kind: exkCall, callee: e.receiver,
                           args: callArgs))
  unknownType(e.span)

proc synthFieldAccess(tc: var TypeChecker, e: Expr): Type =
  result = tc.asResultIntrospection(e)
  if result != nil: return
  result = tc.asSlotInvoke(e)
  if result != nil: return
  result = tc.asPostfixApplication(e)
  if result != nil: return
  result = tc.asVariantConstruction(e)
  if result != nil: return
  let rawT = tc.synthesize(e.receiver)
  if isWrapper(rawT):
    fail("Type Error: unhandled " & typeName(rawT) &
         " — pass it to a handling function or propagate with '?' before accessing fields", e.span)
  let recvT = tc.resolve(rawT)
  let fields = tc.fieldsOf(recvT)
  result = tc.asPlainField(e, fields, recvT)
  if result != nil: return
  result = tc.asQualifiedMemberCall(e)
  if result != nil: return
  # Before asFnByName: an interface receiver must resolve against its CONTRACT.
  # asFnByName looks the bare name up in the flat signature table and would
  # find whichever object declared one, then reject the receiver ("expects Dog
  # but got Animal") — or worse, silently pick the wrong object's member.
  result = tc.asInterfaceCall(e, recvT)
  if result != nil: return
  result = tc.asFnByName(e, recvT)
  if result != nil: return
  # `.fn {args}` — the brace proves call intent (ruling 2026-07-23). If we
  # reach here the callee matched neither a field nor a declared fn, so it is
  # an undeclared call, not a field read to fall through on.
  if e.dotArg != nil:
    fail("Type Error: '" & e.fieldName & "' is called with arguments here " &
         "but is not declared — a `.fn {args}` call needs a declared fn " &
         "(add one, or a `pending:` stub)", e.span)
  # Known record, missing field, no matching fn: the payoff error.
  # Sum types carry variant fields we don't track per-variant in v1 — only
  # flag when the receiver is a plain record.
  if fields.len > 0 and recvT.kind == tkRecord:
    fail("Type Error: no field '" & e.fieldName & "' on type " & typeName(recvT), e.span)
  return unknownType(e.span)

proc isOptional(t: Type): bool =
  t != nil and t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
    t.base.name == "?" and t.args.len == 1

const IntegerTypeNames = ["int", "i8", "i16", "i32", "i64",
                          "u8", "u16", "u32", "u64"]
const FloatTypeNames = ["float", "f32", "f64"]

type
  Operand = tuple[typ: Type, expr: Expr]
    ## One side of a binary operator, with the expression it came from so a
    ## diagnostic can point at the offending side rather than the whole
    ## expression.

proc operands(lt, rt: Type, e: Expr): array[2, Operand] =
  [(lt, e.left), (rt, e.right)]

proc failIfUnhandled(lt, rt: Type, e: Expr) =
  ## `and`/`or`/`xor` are strictly boolean — they never unwrap a result. A ?T
  ## operand is the one exception: in a boolean position it reads as "is
  ## present", which is a test, not an unwrap. A !T still has to be handled.
  let boolCtx = e.binOp in {boAnd, boOr, boXor}
  for (t, side) in operands(lt, rt, e):
    if isWrapper(t) and not (boolCtx and isOptional(t)):
      fail("Type Error: unhandled " & typeName(t) &
           " — pass it to a handling function or propagate with '?'", side.span)

proc failIfMismatched(tc: TypeChecker, lt, rt: Type, what: string, sp: Span) =
  ## Both sides of an arithmetic or comparison operator must agree.
  if not isUnknown(lt) and not isUnknown(rt) and not tc.compatible(lt, rt):
    fail("Type Error: " & what & " between " & typeName(lt) & " and " &
         typeName(rt), sp)

proc widerOperand(lt, rt: Type): Type =
  ## The type an arithmetic result carries.
  if isUnknown(lt): rt else: lt

proc synthArithmetic(tc: TypeChecker, lt, rt: Type, e: Expr): Type =
  tc.failIfMismatched(lt, rt, "arithmetic", e.span)
  widerOperand(lt, rt)

proc failIfWrongDivKind(lt, rt: Type, e: Expr) =
  ## R1: the operator names the arithmetic, so the operands must actually BE
  ## that kind. `compatible` alone would let `2 /f 3` through on loose numeric
  ## widening — precisely the silent conversion this ruling removes.
  let wantFloat = e.binOp == boDivFloat
  let opName = if wantFloat: "/f" else: "/i"
  let alternative = if wantFloat: "/i" else: "/f"
  for (t, side) in operands(lt, rt, e):
    if isUnknown(t): continue
    if wantFloat != (typeName(t) in FloatTypeNames):
      fail("Type Error: `" & opName & "` takes " &
           (if wantFloat: "float" else: "integer") & " operands, got " &
           typeName(t) & " — use `" & alternative & "`, or convert explicitly",
           side.span)

proc synthDivision(tc: TypeChecker, lt, rt: Type, e: Expr): Type =
  failIfWrongDivKind(lt, rt, e)
  tc.failIfMismatched(lt, rt, "division", e.span)
  widerOperand(lt, rt)

proc synthComparison(tc: TypeChecker, lt, rt: Type, e: Expr): Type =
  tc.failIfMismatched(lt, rt, "comparison", e.span)
  Type(span: e.span, kind: tkNamed, name: "bool")

proc synthRange(lt, rt: Type, e: Expr): Type =
  ## Range bounds must be integers.
  for (t, side) in operands(lt, rt, e):
    if not isUnknown(t) and typeName(t) notin IntegerTypeNames:
      fail("Type Error: range bounds must be integers, got " & typeName(t),
           side.span)
  Type(span: e.span, kind: tkNamed, name: "range")

proc boolOpName(op: BinOp): string =
  case op
  of boAnd: "and"
  of boOr: "or"
  else: "xor"

proc synthBoolOp(lt, rt: Type, e: Expr): Type =
  ## Strictly boolean. `or` is NOT an unwrap operator: a failed result is
  ## handled with .ok / match r.err, never by falling through to a default.
  for (t, side) in operands(lt, rt, e):
    if isUnknown(t) or isOptional(t): continue  # ?T = "is present"
    if not (t != nil and t.kind == tkNamed and t.name == "bool"):
      fail("Type Error: '" & boolOpName(e.binOp) & "' expects bool, got " &
           typeName(t), side.span)
  Type(span: e.span, kind: tkNamed, name: "bool")

proc synthBinary(tc: var TypeChecker, e: Expr): Type =
  let lt = tc.synthesize(e.left)
  let rt = tc.synthesize(e.right)
  failIfUnhandled(lt, rt, e)
  case e.binOp
  of boAdd, boSub, boMul, boMod: tc.synthArithmetic(lt, rt, e)
  of boDivInt, boDivFloat: tc.synthDivision(lt, rt, e)
  of boEq, boNeq, boLt, boGt, boLe, boGe: tc.synthComparison(lt, rt, e)
  of boRangeIncl, boRangeExcl: synthRange(lt, rt, e)
  of boAnd, boOr, boXor: synthBoolOp(lt, rt, e)

# spec 4.4b: union two branch states — narrowing is never discarded,
# only widened to the union of what the branches could produce

proc checkCondition(tc: var TypeChecker, cond: Expr, sp: Span) =
  ## A condition must be a plain bool — an unhandled fallible result is the
  ## common mistake and gets its own message.
  let condT = tc.synthesize(cond)
  if isWrapper(condT):
    fail("Type Error: unhandled " & typeName(condT) & " in condition — pass " &
         "it to a handling function or propagate with '?'", cond.span)
  if not isUnknown(condT) and
     not tc.compatible(condT, Type(span: sp, kind: tkNamed, name: "bool")):
    fail("Type Error: if condition must be bool, got " & typeName(condT),
         cond.span)

proc okGuardName(tc: TypeChecker, cond: Expr): string =
  ## `if r.ok:` narrows r inside the then-branch ONLY — outside the guard the
  ## value is still the wrapped type (strict, scope-limited).
  if cond != nil and cond.kind == exkField and cond.fieldName == "ok" and
     cond.receiver != nil and cond.receiver.kind == exkVar and
     cond.receiver.name notin tc.okNarrowed:
    cond.receiver.name
  else: ""

proc synthBranches(tc: var TypeChecker, e: Expr, guard: string): (Type, Type) =
  ## Both branches from the same entry state; the after-if state is their union.
  if guard != "": tc.okNarrowed.incl(guard)
  let entryVariants = tc.varVariants
  let thenT = tc.synthesize(e.thenBranch)
  let thenVariants = tc.varVariants
  if guard != "": tc.okNarrowed.excl(guard)
  tc.varVariants = entryVariants
  let elseT = tc.synthesize(e.elseBranch)
  tc.varVariants = mergeVariants(thenVariants, tc.varVariants)
  (thenT, elseT)

proc synthIf(tc: var TypeChecker, e: Expr): Type =
  ## Branches that produce values must agree on the type.
  tc.checkCondition(e.cond, e.span)
  let (thenT, elseT) = tc.synthBranches(e, tc.okGuardName(e.cond))
  if e.elseBranch != nil and not isUnknown(thenT) and not isUnknown(elseT) and
     not tc.compatible(thenT, elseT) and not tc.compatible(elseT, thenT):
    fail("Type Error: if branches produce different types: " &
         typeName(thenT) & " vs " & typeName(elseT), e.span)
  if isUnknown(thenT): elseT else: thenT

proc matchErrEnums(tc: TypeChecker, subject: Expr): seq[string] =
  ## `match r.err` — the producer's declared error enums, if the subject is
  ## the `err` field of a binding that remembered them.
  if subject == nil or subject.kind != exkField or subject.fieldName != "err" or
     subject.receiver == nil or subject.receiver.kind != exkVar or
     not tc.varErrTypes.hasKey(subject.receiver.name): return
  tc.varErrTypes[subject.receiver.name]

proc enumsOwningVariant(tc: TypeChecker, enums: seq[string],
                        variant: string): seq[string] =
  ## Which of these sum types declare a variant by this name.
  for en in enums:
    if tc.typeDecls.hasKey(en) and tc.typeDecls[en].kind == tkSum:
      for v in tc.typeDecls[en].variants:
        if v.name == variant: result.add(en)

proc qualifyErrArm(tc: TypeChecker, arm: var MatchArm, errEnums: seq[string]) =
  ## Rewrite a bare error arm to Enum.Variant so codegen emits the hashed
  ## code constants, failing on a typo or an ambiguous name.
  if arm.pattern == nil or arm.pattern.kind == pkWild: return
  if arm.pattern.kind != pkVar:
    fail("Type Error: match over an error code takes variant names of " &
         errEnums.join(" | ") & " (or _)", arm.span)
  let aname = arm.pattern.name
  if "." in aname: return  # already qualified
  let owners = tc.enumsOwningVariant(errEnums, aname)
  if owners.len == 0:
    fail("Type Error: '" & aname & "' is not a variant of " &
         errEnums.join(" | "), arm.span)
  if owners.len > 1:
    fail("Type Error: '" & aname & "' is ambiguous (" & owners.join(", ") &
         ") — qualify it: " & owners[0] & "." & aname, arm.span)
  arm.pattern = Pattern(span: arm.pattern.span, kind: pkVar,
                        name: owners[0] & "." & aname)

proc bindArmPattern(tc: var TypeChecker, arm: MatchArm, trackedVar,
                    trackedType: string) =
  ## A variant pattern narrows the subject and does NOT bind the name;
  ## v1: any other pattern-bound name enters scope as Unknown.
  if arm.pattern == nil or arm.pattern.kind != pkVar: return
  if trackedVar != "" and arm.pattern.name in tc.allVariants(trackedType):
    tc.varVariants[trackedVar] = @[arm.pattern.name]
  else:
    tc.bindName(arm.pattern.name, unknownType(arm.pattern.span), false)

proc synthArm(tc: var TypeChecker, arm: MatchArm, trackedVar,
              trackedType: string): Type =
  ## One arm, typed in its own scope with the subject narrowed.
  tc.pushScope()
  tc.bindArmPattern(arm, trackedVar, trackedType)
  result = tc.synthesize(arm.body)
  tc.popScope()

proc unifyArmType(tc: var TypeChecker, armT: var Type, t: Type, sp: Span) =
  ## Every arm must produce the same type.
  if not isUnknown(t) and not isUnknown(armT) and
     not tc.compatible(t, armT) and not tc.compatible(armT, t):
    fail("Type Error: match arms produce different types: " &
         typeName(armT) & " vs " & typeName(t), sp)
  if isUnknown(armT): armT = t

proc synthArms(tc: var TypeChecker, e: Expr, trackedVar,
               trackedType: string): Type =
  ## Type every arm from the same entry state; the after-match state is the
  ## union of the arm exits (spec 4.4b).
  let entryVariants = tc.varVariants
  var mergedExit: Table[string, seq[string]]
  var firstArm = true
  result = unknownType(e.span)
  for arm in e.arms:
    tc.varVariants = entryVariants
    let t = tc.synthArm(arm, trackedVar, trackedType)
    mergedExit = if firstArm: tc.varVariants
                 else: mergeVariants(mergedExit, tc.varVariants)
    firstArm = false
    tc.unifyArmType(result, t, arm.span)
  if not firstArm: tc.varVariants = mergedExit

proc matchDomain(tc: TypeChecker, subjT: Type, trackedType: string,
                 errEnums: seq[string]): seq[string] =
  ## Every case a closed subject can take. Open domains (int/str/unknown)
  ## cannot be enumerated, so they return empty and go unchecked — same as Nim.
  if errEnums.len > 0:
    for en in errEnums:
      if tc.typeDecls.hasKey(en) and tc.typeDecls[en].kind == tkSum:
        for v in tc.typeDecls[en].variants: result.add(en & "." & v.name)
    return
  let sumName = if trackedType != "": trackedType
                elif subjT != nil and subjT.kind == tkNamed and
                     tc.typeDecls.hasKey(subjT.name) and
                     tc.typeDecls[subjT.name].kind == tkSum: subjT.name
                else: ""
  if sumName != "": tc.allVariants(sumName)
  elif subjT != nil and subjT.kind == tkNamed and subjT.name == "bool":
    @["true", "false"]
  else: @[]

proc checkExhaustive(tc: TypeChecker, e: Expr, domain: seq[string]) =
  ## spec #10b: a match over a closed domain must cover every case OR end
  ## with a catch-all `_`.
  if domain.len == 0: return
  var hasWild = false
  var covered: HashSet[string]
  for arm in e.arms:
    if arm.pattern == nil or arm.pattern.kind == pkWild: hasWild = true
    elif arm.pattern.kind == pkVar: covered.incl(arm.pattern.name)
  if hasWild: return
  var missing: seq[string]
  for v in domain:
    if v notin covered: missing.add(v)
  if missing.len > 0:
    fail("Type Error: match is not exhaustive — missing " & missing.join(", ") &
         " (cover all cases or add a catch-all `_`)", e.span)

proc synthMatch(tc: var TypeChecker, e: Expr): Type =
  ## A match types every arm to one type, then checks it covers its subject.
  let subjT = tc.synthesize(e.subject)
  # spec 4.4b: matching a tracked var narrows it to the arm's variant
  var trackedType = ""
  var trackedVar = ""
  if e.subject != nil and e.subject.kind == exkVar:
    trackedType = tc.transType(subjT)
    if trackedType != "": trackedVar = e.subject.name
  let errEnums = tc.matchErrEnums(e.subject)
  if errEnums.len > 0:
    for arm in e.arms.mitems: tc.qualifyErrArm(arm, errEnums)
  result = tc.synthArms(e, trackedVar, trackedType)
  tc.checkExhaustive(e, tc.matchDomain(subjT, trackedType, errEnums))

proc failIfMutatingLet(tc: var TypeChecker, e: Expr) =
  ## Spec 2.3: `..` mutation only on var bindings.
  if e.base == nil or e.base.kind != exkVar: return
  var hasMutation = false
  for step in e.steps:
    if step.op == coDotDot: hasMutation = true
  if not hasMutation: return
  let (found, b) = tc.lookup(e.base.name)
  if found and not b.isVar:
    fail("Type Error: cannot mutate '" & e.base.name &
         "' with '..' — it was declared with 'let'; use 'var'", e.span)

proc checkFieldSet(tc: var TypeChecker, step: ChainStep, f: FieldDef,
                   recvT: Type) =
  ## `..name {value}` — set a field to one bare value.
  if tc.fnSigs.hasKey(f.name):
    fail("Type Error: '" & f.name & "' is both a field here and a declared " &
         "fn — rename one; fields and fns share the call namespace", step.span)
  if not isBareValuePayload(step.arg):
    fail("Type Error: setting field '" & f.name & "' with '..' takes one " &
         "bare value: ..." & f.name & " {" & typeName(f.typ) &
         "} — to set several fields, use a mutator fn", step.span)
  let valExpr = soleFieldValue(step.arg)
  let vt = tc.synthesize(valExpr)
  if not tc.compatible(vt, f.typ):
    fail("Type Error: field '" & f.name & "' of " & typeName(recvT) & " is " &
         typeName(f.typ) & " but got " & typeName(vt), valExpr.span)

proc mutatorReturnType(tc: var TypeChecker, step: var ChainStep, base: Expr,
                       recvT: Type): Type =
  ## Call the mutator, recording the call for codegen. Braced args pin the
  ## method form (receiver = first param); a bare `..fn` gets the same
  ## type-directed resolution as any other call.
  let sc = if step.arg != nil:
             tc.synthMethodCall(step.target.name, base, recvT, step.arg,
                                step.span)
           else:
             Expr(span: step.span, kind: exkCall, args: @[base],
                  callee: Expr(span: step.span, kind: exkVar,
                               name: step.target.name))
  setStepCall(semLayer, step, sc)
  if step.arg != nil: semLayer.typeFor(sc) else: tc.synthesize(sc)

proc checkMutatorTransition(tc: var TypeChecker, step: ChainStep, base: Expr,
                            baseT: Type) =
  ## spec 4.4b: a mutator reassignment on a tracked var is a transition.
  if base == nil or base.kind != exkVar: return
  let tn = tc.transType(baseT)
  if tn == "": return
  let cur = if tc.varVariants.hasKey(base.name): tc.varVariants[base.name]
            else: tc.allVariants(tn)
  let next = tc.fnReturnVariants(step.target.name, tn)
  tc.checkTransSet(tn, cur, next, step.span)
  tc.varVariants[base.name] = next

proc checkMutatorCall(tc: var TypeChecker, step: var ChainStep, e: Expr,
                      baseT, recvT: Type) =
  ## `..fn {args}` — the receiver rides as the first parameter and the result
  ## is reassigned into the base var, so the fn must return the receiver's type.
  let retT = tc.mutatorReturnType(step, e.base, recvT)
  if not tc.compatible(retT, baseT):
    fail("Type Error: cannot assign " & typeName(retT) & " to " &
         typeName(baseT) & " — a '..' mutator must return the receiver's type",
         step.span)
  tc.checkMutatorTransition(step, e.base, baseT)

proc checkChainStep(tc: var TypeChecker, step: var ChainStep, e: Expr,
                    baseT, recvT: Type, fields: seq[FieldDef]) =
  ## One `..name {args}` step: either it SETS a field or it calls a mutator.
  for f in fields:
    if f.name == step.target.name:
      tc.checkFieldSet(step, f, recvT)
      return
  if tc.fnSigs.hasKey(step.target.name):
    tc.checkMutatorCall(step, e, baseT, recvT)
  elif recvT.kind == tkRecord:
    fail("Type Error: no field or fn '" & step.target.name & "' on type " &
         typeName(recvT), step.span)

proc synthChain(tc: var TypeChecker, e: Expr): Type =
  ## A `..` chain stays on its base var: every step either sets a field or
  ## calls a mutator that returns the receiver's type.
  result = tc.synthesize(e.base)
  tc.failIfMutatingLet(e)
  let recvT = tc.resolve(result)
  let fields = tc.fieldsOf(recvT)
  for step in e.steps.mitems:
    tc.checkChainStep(step, e, result, recvT, fields)

proc check(tc: var TypeChecker, e: Expr, expected: Type, what: string) =
  if e == nil or expected == nil: return
  let actual = tc.synthesize(e)
  if not tc.compatible(actual, expected):
    fail("Type Error: " & what & " expects " & typeName(expected) &
         " but got " & typeName(actual), e.span)

# --- Generics: simple substitution, Nim/C# style. No variance, no HKTs. ---
# Type params are inferred at the call site by unifying declared param types
# against the payload's field types, then substituted into params and return.

proc inferBindings(tc: TypeChecker, declared, actual: Type,
                   generics: seq[string], bindings: var Table[string, Type],
                   fnName: string, sp: Span) =
  if declared == nil or actual == nil or isUnknown(actual): return
  case declared.kind
  of tkNamed:
    if declared.name in generics:
      if bindings.hasKey(declared.name):
        if not tc.compatible(actual, bindings[declared.name]) or
           not tc.compatible(bindings[declared.name], actual):
          fail("Type Error: generic parameter '" & declared.name & "' of '" &
               fnName & "' bound to both " & typeName(bindings[declared.name]) &
               " and " & typeName(actual), sp)
      else:
        bindings[declared.name] = actual
  of tkApp:
    if actual.kind == tkApp and declared.args.len == actual.args.len:
      tc.inferBindings(declared.base, actual.base, generics, bindings, fnName, sp)
      for i in 0 ..< declared.args.len:
        tc.inferBindings(declared.args[i], actual.args[i], generics, bindings, fnName, sp)
  of tkRecord:
    let aFields = if actual.kind == tkRecord: actual.fields else: tc.fieldsOf(actual)
    for df in declared.fields:
      for af in aFields:
        if af.name == df.name:
          tc.inferBindings(df.typ, af.typ, generics, bindings, fnName, sp)
          break
  else: discard

# Match a single call argument against declared params.
# Tuck convention: one struct-shaped payload whose fields map to params by name.
proc ifaceSlot(tc: TypeChecker, t: Type): string =
  ## The interface an argument position demands, or "" when it demands an
  ## ordinary type. An interface name in type position is the variant over its
  ## satisfying types, never a value — nothing is ever an instance of one.
  if t == nil or t.kind != tkNamed: return ""
  if tc.ifaceDecls.hasKey(t.name): return t.name
  ""

proc ifaceElemSlot(tc: TypeChecker, t: Type): string =
  ## The interface a COLLECTION position demands: `Seq[Animal]` -> "Animal".
  ## A list literal takes its element type from the first item, so `[d, c]`
  ## synthesizes as Seq[Dog] and would be rejected — the expected type has to
  ## come from the parameter instead, and each element wrapped in its own pair.
  if t == nil or t.kind != tkApp or t.base == nil: return ""
  if t.base.kind != tkNamed or t.base.name notin ["Seq", "Array"]: return ""
  if t.args.len == 0: return ""
  let elem = t.args[^1]
  if elem != nil and elem.kind == tkNamed and tc.ifaceDecls.hasKey(elem.name):
    return elem.name
  ""

proc checkIfaceArg(tc: var TypeChecker, iname: string, argT: Type,
                   argExpr: Expr, what: string) =
  ## An object reaches an interface slot only by DECLARING `satisfies I`.
  ## Having the right members by coincidence is not enough: conformance is
  ## explicit (spec §5.2), so that adding a member can never silently enrol a
  ## type in a contract its author never agreed to.
  ##
  ## The wrap is recorded here because this is the last point where the
  ## concrete type is known — the callee sees only the interface. Recording it
  ## also demands the (object, interface) pair, which is what makes variant
  ## emission demand-driven rather than one-per-`satisfies`.
  if argT == nil or isUnknown(argT): return   # gradual: let it flow
  let objName = if argT.kind == tkNamed: argT.name else: ""
  # Already an interface value of the SAME interface — passing one onward is
  # just handing over the pair, so there is nothing to wrap. Without this,
  # `fn outer({a: Animal}) = {a: a} inner` was rejected with "Animal is not an
  # object, so it cannot satisfy Animal", which is both wrong and confusing.
  if objName == iname: return
  if objName != "" and tc.objDecls.hasKey(objName) and
     iname in tc.objDecls[objName].satisfies:
    semLayer.markWrap(argExpr, objName, iname)
    return
  let why =
    if objName != "" and tc.objDecls.hasKey(objName):
      "object '" & objName & "' does not declare `satisfies " & iname & "`"
    elif objName != "" and tc.typeDeclsByName.hasKey(objName):
      "'" & objName & "' is a type, not an object — only objects may satisfy " &
        "an interface"
    else:
      typeName(argT) & " is not an object, so it cannot satisfy " & iname
  fail("Type Error: " & what & " expects " & iname & ", but " & why,
       argExpr.span)

proc checkIfaceElems(tc: var TypeChecker, iname: string, argExpr: Expr,
                     what: string) =
  ## Every element of a list literal reaching a `Seq[Interface]` slot gets its
  ## own wrap — the variant is per element, each tagged with ITS concrete type.
  ## That is what makes the elements uniform in size while dispatching
  ## differently.
  ##
  ## A non-literal argument (a variable already holding a Seq) is left alone:
  ## its elements were wrapped wherever the list was built.
  if argExpr == nil or argExpr.kind != exkList: return
  for item in argExpr.items:
    let t = tc.synthesize(item)
    tc.checkIfaceArg(iname, t, item, what)

type
  ArgField = tuple[name: string, typ: Type, span: Span]
    ## One field of a call's payload, once its type is known.

proc isSelfParam(p: Param): bool =
  ## A `Self` param is the receiver, supplied by the call site, not the payload.
  p.typ != nil and p.typ.kind == tkNamed and p.typ.name == "Self"

proc recordCallParams(tc: var TypeChecker, fnName: string, params: seq[Param],
                      e: Expr) =
  ## Record the callee's params for lowering, which explodes a struct payload
  ## into positional args. Set before any early return, since lowering needs it
  ## whenever the callee resolved rather than only when the payload shape was
  ## known — and ONLY for top-level fns, which are the only callees lowering
  ## touches. A non-empty value therefore already means "safe to explode", so
  ## lowering needs no second lookup to find that out.
  if e.kind != exkCall or fnName notin tc.topLevelFns: return
  var names: seq[string]
  for p in params: names.add(p.name)
  setCallParams(semLayer, e, names)

proc checkWholeBind(tc: var TypeChecker, fnName: string, sig: FnSig, arg: Expr,
                    t: Type, bindings: var Table[string, Type]): bool =
  ## A single-param fn whose param accepts the value WHOLE takes it as-is
  ## (`9 addOne`, `server describe` where describe's param is the Server
  ## itself). Returns true when the value bound whole; only otherwise does
  ## the value's SHAPE matter — its fields map onto the params by name.
  ##
  ## An interface slot is checked BEFORE `compatible`: an interface name has
  ## no type declaration, so it resolves to Unknown, and Unknown is compatible
  ## with everything — the early return would otherwise accept any argument.
  let param = sig.params[0]
  let what = "argument to '" & fnName & "'"
  let elemIface = tc.ifaceElemSlot(param.typ)
  if elemIface != "":
    tc.checkIfaceElems(elemIface, arg, what)
    return true
  let iname = tc.ifaceSlot(param.typ)
  if iname != "":
    tc.checkIfaceArg(iname, t, arg, what)
    return true
  if sig.generics.len > 0:
    tc.inferBindings(param.typ, t, sig.generics, bindings, fnName, arg.span)
  let expected = substituteType(param.typ, bindings)
  if tc.compatible(t, expected): return true
  if tc.fieldsOf(t).len == 0:
    fail("Type Error: argument to '" & fnName & "' expects " &
         typeName(expected) & " but got " & typeName(t), arg.span)

proc payloadFields(tc: var TypeChecker, fnName: string, sig: FnSig, arg: Expr,
                   bindings: var Table[string, Type],
                   shapeKnown: var bool): seq[ArgField] =
  ## The payload's fields with their types, from a struct literal directly or
  ## from the shape of any other value. shapeKnown stays false for an Unknown
  ## payload, which is let through unchecked.
  if arg.kind == exkStruct:
    shapeKnown = true
    for f in arg.fields:
      result.add((f.name, tc.synthesize(f.value), f.value.span))
    return
  let t = tc.synthesize(arg)
  if isUnknown(t): return
  if sig.params.len == 1 and tc.checkWholeBind(fnName, sig, arg, t, bindings):
    return
  let fs = tc.fieldsOf(t)
  if fs.len > 0:
    shapeKnown = true
    for f in fs: result.add((f.name, f.typ, arg.span))

proc substituteParams(tc: var TypeChecker, fnName: string, sig: FnSig,
                      argFields: seq[ArgField],
                      bindings: var Table[string, Type]): seq[Param] =
  ## Infer type-param bindings from the payload, then check against the
  ## substituted signature (conflicts reported inside inferBindings).
  for p in sig.params:
    for af in argFields:
      if af.name == p.name:
        tc.inferBindings(p.typ, af.typ, sig.generics, bindings, fnName, af.span)
        break
  for p in sig.params:
    result.add(Param(name: p.name, typ: substituteType(p.typ, bindings),
                     span: p.span))

proc payloadFieldExpr(e: Expr, name: string): Expr =
  ## The expression that supplied a payload field. The interface wrap is marked
  ## on the FIELD's expression, which is the value that becomes the pair —
  ## argFields carries only types, so the expression is fetched by name.
  result = e
  if e.args.len == 1 and e.args[0].kind == exkStruct:
    for f in e.args[0].fields:
      if f.name == name: result = f.value

proc checkNamedField(tc: var TypeChecker, fnName: string, p: Param,
                     af: ArgField, e: Expr) =
  ## One payload field against the param that claimed it.
  let what = "field '" & p.name & "' of call to '" & fnName & "'"
  let elemIface = tc.ifaceElemSlot(p.typ)
  if elemIface != "":
    # `Seq[Animal]` — wrap each element, and skip `compatible`, which would
    # compare Seq[Dog] against Seq[Animal] and reject it.
    tc.checkIfaceElems(elemIface, payloadFieldExpr(e, af.name), what)
    return
  let iname = tc.ifaceSlot(p.typ)
  if iname != "":
    # An interface slot: `compatible` would reject Dog-vs-Animal (they are
    # unrelated names) and has no way to know about `satisfies`.
    tc.checkIfaceArg(iname, af.typ, payloadFieldExpr(e, af.name), what)
    return
  if not tc.compatible(af.typ, p.typ):
    fail("Type Error: field '" & p.name & "' of call to '" & fnName &
         "' expects " & typeName(p.typ) & " but got " & typeName(af.typ), af.span)

proc claimByName(tc: var TypeChecker, fnName: string, params: seq[Param],
                 argFields: seq[ArgField], e: Expr, claimed: var seq[bool],
                 resolved: var seq[string]): seq[int] =
  ## Pass 1: every param takes the field of its own name. Returns the params
  ## left unmatched.
  for pi, p in params:
    if isSelfParam(p): continue
    var found = false
    for ai, af in argFields:
      if claimed[ai] or af.name != p.name: continue
      tc.checkNamedField(fnName, p, af, e)
      claimed[ai] = true
      resolved[pi] = af.name
      found = true
      break
    if not found: result.add(pi)

proc soleFieldOfType(params: seq[Param], argFields: seq[ArgField],
                     claimed: seq[bool], pi: int): int =
  ## The one unclaimed field whose type matches this param exactly, or -1 when
  ## there is no such field or more than one.
  ##
  ## STRICT type equality rather than the looser `compatible` rule: widening
  ## int -> float is a coercion the user never wrote, and distinct types stay
  ## nominal (Milliseconds is not u32).
  result = -1
  for ai, af in argFields:
    if claimed[ai] or typeName(af.typ) != typeName(params[pi].typ): continue
    if result >= 0: return -1   # ambiguous
    result = ai

proc claimByType(tc: var TypeChecker, fnName: string, params: seq[Param],
                 argFields: seq[ArgField], e: Expr, pending: seq[int],
                 claimed: var seq[bool], resolved: var seq[string]) =
  ## Pass 2: a param still unmatched takes the sole unclaimed field of its
  ## type. That lets a producer's output record feed a consumer whose param
  ## names differ, without an explicit alias() for every handoff.
  for pi in pending:
    let candidate = soleFieldOfType(params, argFields, claimed, pi)
    if candidate < 0:
      fail("Type Error: call to '" & fnName & "' is missing required field '" &
           params[pi].name & ": " & typeName(params[pi].typ) &
           "' (add it, or alias a field to that name)", e.span)
    claimed[candidate] = true
    resolved[pi] = argFields[candidate].name

proc checkPayloadCall(tc: var TypeChecker, fnName: string, sig: FnSig, e: Expr,
                      bindings: var Table[string, Type]) =
  ## A call whose single argument is a payload: its fields satisfy the params.
  var shapeKnown = false
  let argFields = tc.payloadFields(fnName, sig, e.args[0], bindings, shapeKnown)
  if not shapeKnown: return  # Unknown payload — let it flow
  let params = if sig.generics.len > 0:
                 tc.substituteParams(fnName, sig, argFields, bindings)
               else: sig.params
  var claimed = newSeq[bool](argFields.len)
  var resolved = newSeq[string](params.len)  # param index -> field name
  let pending = tc.claimByName(fnName, params, argFields, e, claimed, resolved)
  tc.claimByType(fnName, params, argFields, e, pending, claimed, resolved)
  # Hand the decision to codegen, which would otherwise re-derive the mapping
  # by name and miss anything matched by type.
  if e.kind == exkCall:
    setArgFields(semLayer, e, resolved)

proc checkPositionalArgs(tc: var TypeChecker, fnName: string,
                         params: seq[Param], e: Expr) =
  ## One argument per param, checked in order.
  for i in 0 ..< params.len:
    if isSelfParam(params[i]): continue
    let t = tc.synthesize(e.args[i])
    if not tc.compatible(t, params[i].typ):
      fail("Type Error: argument " & $(i+1) & " to '" & fnName & "' expects " &
           typeName(params[i].typ) & " but got " & typeName(t), e.args[i].span)

proc checkCallArgs(tc: var TypeChecker, fnName: string, sig: FnSig, e: Expr,
                   bindings: var Table[string, Type]) =
  ## Arguments reach a fn in one of two shapes: a single payload whose fields
  ## map onto the params, or one argument per param.
  tc.recordCallParams(fnName, sig.params, e)
  if e.args.len == 1 and sig.params.len > 0:
    tc.checkPayloadCall(fnName, sig, e, bindings)
  elif e.args.len == sig.params.len:
    tc.checkPositionalArgs(fnName, sig.params, e)
  else:
    for a in e.args: discard tc.synthesize(a)

proc calleeNameOf(tc: var TypeChecker, e: Expr): string =
  ## The name being called. `module::fn` against a KNOWN module (imported or
  ## pending-stubbed) is strict — the fn must exist; an unknown prefix stays
  ## gradual like any undeclared identifier, so sketch code keeps compiling.
  if e.callee == nil: return ""
  if e.callee.kind == exkVar: return e.callee.name
  if e.callee.kind != exkQualified: return ""
  let modName = if e.callee.modulePath.len > 0: e.callee.modulePath[0] else: ""
  result = modName & "::" & e.callee.qualName
  if modName in tc.knownModules and not tc.fnSigs.hasKey(result):
    fail("Type Error: module '" & modName & "' has no function '" &
         e.callee.qualName & "'", e.span)

proc aliasedFieldType(fields: seq[FieldDef], name: string): Type =
  ## The type of the field an alias renames, nil if there is no such field.
  for f in fields:
    if f.name == name: return f.typ
  nil

proc asAliasCall(tc: var TypeChecker, e: Expr): Type =
  ## `expr alias(old: new, ...)` — restructure: the same values under renamed
  ## fields. The result is a REAL record type; consumers check against it.
  let recvT = tc.resolve(tc.synthesize(e.args[0]))
  let recvFields = tc.fieldsOf(recvT)
  var fields: seq[FieldDef]
  for (oldName, newExpr) in e.args[1].fields.items:
    let ft = aliasedFieldType(recvFields, oldName)
    if ft == nil and recvFields.len > 0:
      fail("Type Error: alias source field '" & oldName &
           "' does not exist on " & typeName(recvT), e.span)
    if newExpr == nil or newExpr.kind != exkVar:
      fail("Type Error: alias target must be a plain field name: " &
           oldName & ": newName", e.span)
    fields.add(FieldDef(name: newExpr.name, span: e.span,
                        typ: (if ft == nil: unknownType(e.span) else: ft)))
  Type(span: e.span, kind: tkRecord, fields: fields)

proc failIfDuplicateField(fields: seq[FieldDef], f: FieldDef, sp: Span) =
  ## Merge unions field sets, so a name in two members is an error rather
  ## than a silent shadowing.
  for existing in fields:
    if existing.name == f.name:
      fail("Type Error: merge field '" & f.name &
           "' collides between members", sp)

proc asMergeCall(tc: var TypeChecker, e: Expr): Type =
  ## `{a, b} merge` — flatten the UNION of the member structs' fields into
  ## one flat struct.
  var fields: seq[FieldDef]
  for (mname, mexpr) in e.args[0].fields.items:
    let mt = tc.resolve(tc.synthesize(mexpr))
    if isUnknown(mt): continue  # sketch member — stays gradual
    let mfs = tc.fieldsOf(mt)
    if mfs.len == 0:
      fail("Type Error: merge member '" & mname & "' must be a struct, " &
           "got " & typeName(mt), mexpr.span)
    for f in mfs:
      failIfDuplicateField(fields, f, e.span)
      fields.add(f)
  if fields.len == 0: return unknownType(e.span)
  Type(span: e.span, kind: tkRecord, fields: fields)

proc applyBakeOverride(tc: var TypeChecker, fields: var seq[FieldDef],
                       name: string, valExpr: Expr) =
  ## One `slot: value` from a bake payload: override the field if it exists,
  ## otherwise ADD it. A value override keeps the field's declared type; fn
  ## refs come through as Unknown and pass gradually.
  let vt = tc.synthesize(valExpr)
  for f in fields.mitems:
    if f.name != name: continue
    if not isUnknown(vt) and not tc.compatible(vt, f.typ):
      fail("Type Error: bake override '" & name & "' expects " &
           typeName(f.typ) & " but got " & typeName(vt), valExpr.span)
    return
  fields.add(FieldDef(name: name, typ: vt, span: valExpr.span))

proc asBakeCall(tc: var TypeChecker, e: Expr): Type =
  ## `expr bake {slot: :fn, arg: value, ...}` — compile-time partial
  ## application: rebuild the context struct with slots filled or argument
  ## values overridden.
  let recvT = tc.resolve(tc.synthesize(e.args[0]))
  var fields = tc.fieldsOf(recvT)
  for (name, valExpr) in e.args[1].fields.items:
    tc.applyBakeOverride(fields, name, valExpr)
  if fields.len == 0: return unknownType(e.span)
  Type(span: e.span, kind: tkRecord, fields: fields)

proc inferConstructionArgs(tc: var TypeChecker, e: Expr, calleeName: string,
                           gs: seq[string],
                           bindings: var Table[string, Type]) =
  ## Bind a generic type's params from the payload's field types.
  if e.args.len != 1 or e.args[0].kind != exkStruct:
    for a in e.args: discard tc.synthesize(a)
    return
  let declFields = getFieldsForType(tc.module, tc.typeDecls[calleeName])
  for f in e.args[0].fields:
    let ft = tc.synthesize(f.value)
    for df in declFields:
      if df.name == f.name:
        tc.inferBindings(df.typ, ft, gs, bindings, calleeName, f.value.span)
        break

proc asGenericConstruction(tc: var TypeChecker, e: Expr,
                           calleeName: string): Type =
  ## `{value: 5} Box` — infer the type params from the payload fields; the ty
  ## stamp lets codegen emit the explicit Box[int](...) Nim needs.
  let gs = tc.typeGenerics[calleeName]
  var bindings = initTable[string, Type]()
  tc.inferConstructionArgs(e, calleeName, gs, bindings)
  var gargs: seq[Type]
  for g in gs:
    if not bindings.hasKey(g):
      fail("Type Error: cannot infer generic parameter '" & g & "' of '" &
           calleeName & "' from the construction payload", e.span)
    gargs.add(bindings[g])
  Type(span: e.span, kind: tkApp, args: gargs,
       base: Type(span: e.span, kind: tkNamed, name: calleeName))

proc asDeclaredCall(tc: var TypeChecker, e: Expr, calleeName: string): Type =
  ## A call to a fn with a known signature.
  let sig = tc.fnSigs[calleeName]
  # The name resolved here; record the edge so later passes read the answer
  # instead of scanning the decl list to re-derive it.
  if tc.fnDecls.hasKey(calleeName):
    resolveTo(semLayer, e, tc.fnDecls[calleeName])
  var bindings = initTable[string, Type]()
  tc.checkCallArgs(calleeName, sig, e, bindings)
  if sig.generics.len == 0: return sig.ret
  # Unbound type params degrade to Unknown (gradual, like sketch code)
  for g in sig.generics:
    if not bindings.hasKey(g):
      bindings[g] = unknownType(e.span)
  substituteType(sig.ret, bindings)

proc viaTransitionChain(e: Expr): bool =
  ## Is this construction fed by a transitionTo chain? That is a transition,
  ## not a direct construction — sealed rules allow it (the runtime matrix
  ## checks it).
  for a in e.args:
    if a == nil or a.kind != exkCall or a.callee == nil: continue
    if (a.callee.kind == exkVar and a.callee.name == "transitionTo") or
       (a.callee.kind == exkField and a.callee.fieldName == "transitionTo"):
      return true
  false

proc synthCalleeType(tc: var TypeChecker, e: Expr): Type =
  ## The callee's own type, synthesized in a transition context when the
  ## construction is fed by a transitionTo chain.
  let prevCtx = tc.transitionCtx
  if viaTransitionChain(e): tc.transitionCtx = true
  result = tc.synthesize(e.callee)  # variant constructions carry their type
  tc.transitionCtx = prevCtx

proc asIndirectCall(tc: var TypeChecker, e: Expr): Type =
  ## A callee that is not a bare name. Calling THROUGH a fnsig-typed slot
  ## (`{args} c.op` where op: Adder) validates the args against the named
  ## signature and yields its return type; anything else keeps the callee's
  ## own type.
  result = tc.synthCalleeType(e)
  let ct = tc.resolve(result)
  if ct != nil and ct.kind == tkNamed and ct.name in tc.fnSigNames:
    let sig = tc.fnSigs[ct.name]
    var bindings = initTable[string, Type]()
    tc.checkCallArgs(ct.name, sig, e, bindings)
    return sig.ret
  for a in e.args: discard tc.synthesize(a)

proc synthCall(tc: var TypeChecker, e: Expr): Type =
  let calleeName = tc.calleeNameOf(e)
  if calleeName == "alias" and e.args.len == 2 and e.args[1].kind == exkStruct:
    return tc.asAliasCall(e)
  if calleeName == "merge" and e.args.len == 1 and e.args[0].kind == exkStruct:
    return tc.asMergeCall(e)
  if calleeName == "bake" and e.args.len == 2 and e.args[1].kind == exkStruct:
    return tc.asBakeCall(e)
  if calleeName in ["bake", "alias"]:
    for a in e.args: discard tc.synthesize(a)
    return unknownType(e.span)
  if calleeName != "" and calleeName in tc.distinctNames:
    # Calling a distinct type's name converts from its base (Nim-native)
    for a in e.args: discard tc.synthesize(a)
    return Type(span: e.span, kind: tkNamed, name: calleeName)
  if calleeName != "" and tc.typeGenerics.hasKey(calleeName):
    return tc.asGenericConstruction(e, calleeName)
  if calleeName != "" and not tc.fnSigs.hasKey(calleeName) and
     (tc.typeDecls.hasKey(calleeName) or tc.objDecls.hasKey(calleeName)):
    # {fields} TypeName — construction produces the declared type. Objects are
    # constructible by name like records, but are deliberately absent from
    # typeDecls: `resolve` unwraps anything found there to its body, and an
    # object is NOMINAL. So the gate asks both tables while the result stays
    # the name either way.
    for a in e.args: discard tc.synthesize(a)
    return Type(span: e.span, kind: tkNamed, name: calleeName)
  if calleeName != "" and tc.fnSigs.hasKey(calleeName):
    return tc.asDeclaredCall(e, calleeName)
  if e.callee != nil and e.callee.kind != exkVar:
    return tc.asIndirectCall(e)
  for a in e.args: discard tc.synthesize(a)
  unknownType(e.span)

# Kind dispatch lives in synthesizeKind; synthesize stamps the result onto the
# node (typed AST — codegen reads semLayer.typeFor(e) for type-directed lowering)


# A record field holds a VALUE, so a call that builds one has to produce one
# and nothing else. Without these two checks a void call reaches Nim as
# `(a: tuck_shout(5))` and fails there — a message about generated code the
# user never wrote — and an effectful call is smuggled into what reads as
# plain data construction, silently.

proc returnsNothing(sig: FnSig): bool =
  ## Does this signature return no usable value?
  sig.ret == nil or
    (sig.ret.kind == tkNamed and sig.ret.name in ["void", "unit"])

proc declaredEffects(tc: TypeChecker, fnName: string): seq[EffectMarker] =
  ## The effects declared on `fnName`, empty if it has none or is unknown.
  ## Reads the signature table rather than scanning declarations, so this
  ## answers for imported fns too — their effects ride in through the index.
  if tc.fnSigs.hasKey(fnName): tc.fnSigs[fnName].effects else: @[]

proc appliedFnName(e: Expr): string =
  ## For `5.ms` in a field value, the name being applied — "" if this value
  ## is not a postfix application.
  if e != nil and e.kind == exkField: e.fieldName else: ""

proc checkFieldValue(tc: var TypeChecker, fieldName: string, val: Expr) =
  ## A record field's value must be a value: reject applying a fn that
  ## returns nothing or declares effects.
  let fn = appliedFnName(val)
  if fn == "" or not tc.fnSigs.hasKey(fn): return
  if returnsNothing(tc.fnSigs[fn]):
    fail("Type Error: '" & fn & "' returns nothing, so it cannot fill field '" &
         fieldName & "' — a record field needs a value", val.span)
  let effects = tc.declaredEffects(fn)
  if effects.len > 0:
    fail("Type Error: '" & fn & "' declares effects, so it cannot fill field '" &
         fieldName & "' — build the record from pure values and do the " &
         "effectful call on its own line", val.span)

proc litTypeName(k: LitKind): string =
  ## The primitive type a literal denotes.
  case k
  of lkInt: "int"
  of lkFloat: "float"
  of lkStr: "str"
  of lkBool: "bool"
  of lkUnit: "unit"

proc synthNullaryCall(tc: var TypeChecker, e: Expr): Type =
  ## spec 2.3: a bare name IS a call — `f`, `.f` and `.f {}` are one form.
  ## Only nullary fns: a fn with params referenced bare is a fn-ref (bake).
  let vc = Expr(span: e.span, kind: exkCall,
                callee: Expr(span: e.span, kind: exkVar, name: e.name),
                args: @[])
  setCall(semLayer, e, vc)
  tc.synthesize(vc)

proc synthBareVariant(tc: var TypeChecker, e: Expr): Type =
  ## A bare sum-type variant is a value of its sum type. `Light.Red` is the
  ## qualified form of the same thing, handled by the field-access path.
  let owner = tc.sumTypeOwning(e.name)
  if owner != "": Type(span: e.span, kind: tkNamed, name: owner)
  else: unknownType(e.span)

proc synthVar(tc: var TypeChecker, e: Expr): Type =
  ## A bare name: a binding in scope, else a nullary call, else a variant.
  let (found, b) = tc.lookup(e.name)
  if found: b.typ
  elif tc.fnSigs.hasKey(e.name) and tc.fnSigs[e.name].params.len == 0:
    tc.synthNullaryCall(e)
  else:
    tc.synthBareVariant(e)

proc synthStruct(tc: var TypeChecker, e: Expr): Type =
  ## A record literal types field by field.
  var fs: seq[FieldDef]
  for f in e.fields:
    tc.checkFieldValue(f.name, f.value)
    fs.add(FieldDef(name: f.name, typ: tc.synthesize(f.value), span: f.value.span))
  Type(span: e.span, kind: tkRecord, fields: fs)

proc synthList(tc: var TypeChecker, e: Expr): Type =
  ## A list literal takes its element type from the first item.
  var elemT = unknownType(e.span)
  for item in e.items:
    let t = tc.synthesize(item)
    if isUnknown(elemT): elemT = t
  Type(span: e.span, kind: tkApp,
       base: Type(span: e.span, kind: tkNamed, name: "Seq"), args: @[elemT])

proc synthUnary(tc: var TypeChecker, e: Expr): Type =
  ## `not` yields bool; every other unary keeps its operand's type.
  let t = tc.synthesize(e.operand)
  if e.unaryOp == uoNot: Type(span: e.span, kind: tkNamed, name: "bool") else: t

proc isImplicitReturn(tc: TypeChecker, blk, s: Expr): bool =
  ## The last statement of a fn's body block stands in for its return.
  blk == tc.bodyBlock and s == blk.stmts[^1] and tc.currentRet != nil

proc noteDroppedResult(tc: var TypeChecker, s: Expr, last: Type) =
  ## A dropped fallible result in statement position: the policy decides.
  ## strict collects it as an error (ALL sites reported at the end);
  ## continue/exit mark the site so codegen routes it to the handler.
  let site = tc.currentFn & " line " & $s.span.line
  if tc.errPolicy in ["continue", "exit"]:
    setShortcut(semLayer, s, site)
    tc.unhandledSites.add(typeName(last) & " at " & site)
  else:
    tc.unhandledSites.add(typeName(last) & " discarded at " & site)

proc synthStmt(tc: var TypeChecker, blk, s: Expr, narrowed: var seq[string]): Type =
  ## One statement of a block: type it, apply any early-return narrowing,
  ## and report it if it drops a fallible result.
  result = tc.synthesize(s)
  let g = earlyReturnGuard(s)
  if g != "" and g notin tc.okNarrowed:
    tc.okNarrowed.incl(g)
    narrowed.add(g)
  # `err X` is a control-flow exit (early error return), never a drop
  if isWrapper(result) and not tc.isImplicitReturn(blk, s) and s.kind != exkRaise:
    tc.noteDroppedResult(s, result)

proc synthBlock(tc: var TypeChecker, e: Expr): Type =
  ## A block's type is its last statement's.
  ##
  ## `if not r.ok: return` proves r is present for the REST of this block.
  ## Unlike `if r.ok:`, which narrows its own then-branch, an early-return
  ## guard narrows everything after it — so the narrowing is applied here,
  ## where statements are sequenced, and undone when the block ends.
  tc.pushScope()
  var narrowed: seq[string]
  result = unknownType(e.span)
  for s in e.stmts:
    result = tc.synthStmt(e, s, narrowed)
  for g in narrowed: tc.okNarrowed.excl(g)
  tc.popScope()

proc unitType(sp: Span): Type =
  ## The type of a statement.
  Type(span: sp, kind: tkNamed, name: "unit")

proc elementType(tc: var TypeChecker, iterT: Type, sp: Span): Type =
  ## The element type an iterable yields.
  ##
  ## An unrecognised iterable stays Unknown rather than failing: a stdlib
  ## container or a sketch-mode value should not become an error here.
  if iterT != nil and iterT.kind == tkApp and iterT.base != nil and
     iterT.base.kind == tkNamed and iterT.base.name in ["Seq", "Array"] and
     iterT.args.len >= 1:
    iterT.args[^1]   # Array[N, T] carries its length first
  elif iterT != nil and iterT.kind == tkNamed and iterT.name == "range":
    Type(span: sp, kind: tkNamed, name: "int")
  else:
    unknownType(sp)

proc bindLoopVars(tc: var TypeChecker, iter: Pattern, elemT: Type) =
  ## Bind the loop variable(s). `for idx, item in xs:` binds idx as int.
  if iter == nil: return
  if iter.kind == pkVar:
    tc.bindName(iter.name, elemT, false)
  elif iter.kind == pkTuple:
    if iter.elems.len >= 1 and iter.elems[0].kind == pkVar:
      tc.bindName(iter.elems[0].name,
                  Type(span: iter.span, kind: tkNamed, name: "int"), false)
    if iter.elems.len >= 2 and iter.elems[1].kind == pkVar:
      tc.bindName(iter.elems[1].name, elemT, false)

proc synthLoopBody(tc: var TypeChecker, body: Expr) =
  ## spec 4.4b: the body is checked ONCE against the entry set (no
  ## fixed-point simulation); after the loop the state is entry ∪ body-exit.
  let entryVariants = tc.varVariants
  inc tc.loopDepth
  discard tc.synthesize(body)
  dec tc.loopDepth
  tc.varVariants = mergeVariants(entryVariants, tc.varVariants)

proc synthFor(tc: var TypeChecker, e: Expr): Type =
  ## The loop variable carries the ELEMENT type. Binding it Unknown silently
  ## disabled checking inside every loop body, because Unknown is compatible
  ## with everything — `for p in people: p.nosuchfield` typechecked clean.
  let iterT = tc.resolve(tc.synthesize(e.iterable))
  let iterSpan = if e.iter != nil: e.iter.span else: e.span
  tc.pushScope()
  tc.bindLoopVars(e.iter, tc.elementType(iterT, iterSpan))
  tc.synthLoopBody(e.body)
  tc.popScope()
  unitType(e.span)

proc synthWhile(tc: var TypeChecker, e: Expr): Type =
  ## A while condition must be bool.
  if e.whileCond != nil:
    let ct = tc.synthesize(e.whileCond)
    if not isUnknown(ct) and typeName(ct) != "bool":
      fail("Type Error: loop condition must be bool, got " & typeName(ct),
           e.whileCond.span)
  tc.synthLoopBody(e.whileBody)
  unitType(e.span)

proc synthLoopExit(tc: var TypeChecker, e: Expr, what: string): Type =
  ## `break` / `continue` are legal only inside a loop.
  if tc.loopDepth == 0:
    fail("Control Flow Error: " & what & " outside of a loop", e.span)
  unitType(e.span)

proc rememberErrTypes(tc: var TypeChecker, name: string, val: Expr) =
  ## A result binding remembers its producer's declared error enums, so
  ## `match r.err` can be typed.
  if val == nil or val.kind != exkCall or val.callee == nil or
     val.callee.kind != exkVar: return
  for fd in tc.module.decls:
    if fd != nil and fd.kind == dkFn and fd.name == val.callee.name and
       fd.fnErrorTypes.len > 0:
      tc.varErrTypes[name] = fd.fnErrorTypes

proc synthDeclAssign(tc: var TypeChecker, e: Expr) =
  ## A fresh binding. spec 4.4b: a tracked type starts at the RHS's set.
  let valT = tc.synthesize(e.assignVal)
  tc.bindName(e.target.name, valT, e.isMutable)
  let tn = tc.transType(valT)
  if tn != "":
    tc.varVariants[e.target.name] = tc.exprVariants(tn, e.assignVal)
  if isWrapper(valT):
    tc.rememberErrTypes(e.target.name, e.assignVal)

proc failIfTargetUnbound(tc: var TypeChecker, e: Expr) =
  ## An assignment TARGET must name something. A bare name resolving to
  ## nothing is a typo, and letting it through was silent: the target
  ## synthesized as Unknown, and Unknown is compatible with everything, so
  ## `nosuchfield += n` typechecked in a fn and in an actor handler alike.
  ##
  ## Only the target position, and only a BARE name. Unknown stays load-
  ## bearing everywhere else — it is what keeps sketch code compiling (an
  ## unknown module prefix, a pending fn's callers), so making exkVar
  ## synthesis itself strict would break gradual typing.
  if e.target == nil or e.target.kind != exkVar: return
  let (found, _) = tc.lookup(e.target.name)
  if not found and not tc.fnSigs.hasKey(e.target.name) and
     tc.sumTypeOwning(e.target.name) == "":
    fail("Type Error: cannot assign to '" & e.target.name &
         "' — no variable, parameter or field by that name is in scope", e.span)

proc synthAssignVal(tc: var TypeChecker, e: Expr, targetT: Type): Type =
  ## spec 4.4b: the RHS of a checked transition assignment may construct a
  ## non-initial sealed variant — the transition IS the legal path (static
  ## analogue of the old transitionTo-chain exemption).
  let tracked = e.target != nil and e.target.kind == exkVar and
                tc.transType(targetT) != ""
  let prevCtx = tc.transitionCtx
  if tracked: tc.transitionCtx = true
  result = tc.synthesize(e.assignVal)
  tc.transitionCtx = prevCtx

proc checkTransition(tc: var TypeChecker, e: Expr, targetT: Type) =
  ## spec 4.4b: a reassignment that changes variant IS a transition —
  ## checked against the table, no user-written transitionTo needed.
  if e.target == nil or e.target.kind != exkVar: return
  let tn = tc.transType(targetT)
  if tn == "": return
  let cur = if tc.varVariants.hasKey(e.target.name): tc.varVariants[e.target.name]
            else: tc.allVariants(tn)
  let next = tc.exprVariants(tn, e.assignVal)
  tc.checkTransSet(tn, cur, next, e.span)
  tc.varVariants[e.target.name] = next

proc synthReassign(tc: var TypeChecker, e: Expr) =
  ## Assignment to an existing binding.
  tc.failIfTargetUnbound(e)
  let targetT = tc.synthesize(e.target)
  let valT = tc.synthAssignVal(e, targetT)
  if not tc.compatible(valT, targetT):
    fail("Type Error: cannot assign " & typeName(valT) & " to " &
         typeName(targetT), e.span)
  tc.checkTransition(e, targetT)

proc synthAssign(tc: var TypeChecker, e: Expr): Type =
  ## An assignment is a statement: it yields unit.
  if e.isDecl and e.target != nil and e.target.kind == exkVar:
    tc.synthDeclAssign(e)
  else:
    tc.synthReassign(e)
  unitType(e.span)

proc checkReturnValue(tc: var TypeChecker, e: Expr) =
  ## `return [d, c]` where the fn returns Seq[Animal]: the list literal takes
  ## its element type from the first item, so it must be wrapped element by
  ## element against the RETURN type — the same treatment a call argument
  ## gets, at the other position where an expected type is known.
  let what = "return value of '" & tc.currentFn & "'"
  let retIface = tc.ifaceElemSlot(tc.currentRet)
  if retIface != "" and e.returnVal.kind == exkList:
    tc.checkIfaceElems(retIface, e.returnVal, what)
    return
  let retScalar = tc.ifaceSlot(tc.currentRet)
  if retScalar != "":
    tc.checkIfaceArg(retScalar, tc.synthesize(e.returnVal), e.returnVal, what)
  else:
    tc.check(e.returnVal, tc.currentRet, what)

proc synthReturn(tc: var TypeChecker, e: Expr): Type =
  ## A return checks its value against the fn's declared return type.
  if e.returnVal != nil and tc.currentRet != nil:
    tc.checkReturnValue(e)
  elif e.returnVal != nil:
    discard tc.synthesize(e.returnVal)
  unitType(e.span)

proc errEnumsOwning(tc: TypeChecker, variant: string): seq[string] =
  ## Which of the current fn's declared error enums have this variant.
  for en in tc.currentErrTypes:
    if tc.typeDecls.hasKey(en) and tc.typeDecls[en].kind == tkSum:
      for v in tc.typeDecls[en].variants:
        if v.name == variant: result.add(en)

proc resolveBareErr(tc: var TypeChecker, e, rv: Expr) =
  ## `err V` — resolve the shorthand for codegen: err V → err Enum.V.
  if tc.currentErrTypes.len == 0:
    fail("Type Error: 'err " & rv.name & "' needs a declared error type" &
         " — add [error: <Enum>] to '" & tc.currentFn & "'", e.span)
  let owners = tc.errEnumsOwning(rv.name)
  if owners.len == 0:
    fail("Type Error: '" & rv.name & "' is not a variant of " &
         tc.currentErrTypes.join(" | "), e.span)
  if owners.len > 1:
    fail("Type Error: '" & rv.name & "' is ambiguous (" & owners.join(", ") &
         ") — qualify it: " & owners[0] & "." & rv.name, e.span)
  e.raiseVal = Expr(span: rv.span, kind: exkField,
                    receiver: Expr(span: rv.span, kind: exkVar, name: owners[0]),
                    fieldName: rv.name)

proc isQualifiedErr(tc: TypeChecker, rv: Expr): bool =
  ## Is this `err Enum.Variant`?
  rv != nil and rv.kind == exkField and rv.receiver != nil and
    rv.receiver.kind == exkVar and tc.typeDecls.hasKey(rv.receiver.name) and
    tc.typeDecls[rv.receiver.name].kind == tkSum

proc checkQualifiedErr(tc: var TypeChecker, e, rv: Expr) =
  ## `err Enum.V` — the enum must be declared and V must be one of its variants.
  let en = rv.receiver.name
  if tc.currentErrTypes.len > 0 and en notin tc.currentErrTypes:
    fail("Type Error: '" & tc.currentFn & "' raises " & en &
         " but declares [error: " & tc.currentErrTypes.join(" | ") & "]", e.span)
  for v in tc.typeDecls[en].variants:
    if v.name == rv.fieldName: return
  fail("Type Error: '" & rv.fieldName & "' is not a variant of " & en, e.span)

proc synthRaise(tc: var TypeChecker, e: Expr): Type =
  ## `err X` — an error value of the current fn's fallible result type.
  ## X is a variant of a declared [error: E] enum (qualified E.V or bare V),
  ## or a dynamic re-raise of an existing code (err resp.err).
  if tc.currentRet == nil or not isWrapper(tc.currentRet):
    fail("Type Error: 'err' raises into a fallible result, so '" &
         tc.currentFn & "' must declare a !T return type", e.span)
  let rv = e.raiseVal
  if rv != nil and rv.kind == exkVar: tc.resolveBareErr(e, rv)
  elif tc.isQualifiedErr(rv): tc.checkQualifiedErr(e, rv)
  else: discard tc.synthesize(rv)  # dynamic re-raise
  # control-flow exit: neutral type so branches/blocks don't see a wrapper
  unitType(e.span)

proc sendHandlerParams(tc: TypeChecker, actorDecl: Decl, handler: string,
                       found: var bool): seq[Param] =
  ## The params a handler expects. It is an `on <name>` block OR an `on select`
  ## message arm (spec §9.3); `shutdown` is the reserved control message and
  ## takes an empty payload.
  if handler == "shutdown": found = true
  for h in actorDecl.handlers:
    if found: break
    if h != nil and h.kind == dkFn and h.name == handler:
      found = true; return h.fnParams
    elif h != nil and h.kind == dkSelect:
      for arm in h.selectArms:
        if arm.source == handler:
          found = true; return arm.binding

proc sendPayloadFields(tc: var TypeChecker, e: Expr): seq[FieldInit] =
  ## The payload's fields, typed. A send payload must be a struct literal.
  if e.sendPayload == nil: return
  if e.sendPayload.kind != exkStruct:
    fail("Type Error: send payload must be a struct literal {name: value}",
         e.sendPayload.span)
  discard tc.synthesize(e.sendPayload)
  e.sendPayload.fields

proc checkSendField(tc: var TypeChecker, e: Expr, p: Param,
                    given: seq[FieldInit]) =
  ## One handler param must be supplied by the payload, at a matching type.
  for f in given:
    if f.name != p.name: continue
    let ft = tc.synthesize(f.value)
    if p.typ != nil and not tc.compatible(ft, p.typ):
      fail("Type Error: send field '" & p.name & "' expects " &
           typeName(p.typ) & " but got " & typeName(ft), f.value.span)
    return
  fail("Type Error: send to '" & e.sendActor & "." & e.sendHandler &
       "' is missing field '" & p.name & "'", e.span)

proc synthSend(tc: var TypeChecker, e: Expr): Type =
  ## `ActorType send handler {payload}` — the actor must be declared, the
  ## handler must be one of its `on` handlers, and the payload must match the
  ## handler's params. A send is a statement: it yields unit.
  let actorDecl = tc.module.findDecl(dkActor, e.sendActor)
  if actorDecl == nil:
    fail("Type Error: 'send' target '" & e.sendActor &
         "' is not a declared actor", e.span)
  var found = false
  let handlerParams = tc.sendHandlerParams(actorDecl, e.sendHandler, found)
  if not found:
    fail("Type Error: actor '" & e.sendActor & "' has no handler '" &
         e.sendHandler & "'", e.span)
  let given = tc.sendPayloadFields(e)
  for p in handlerParams: tc.checkSendField(e, p, given)
  unitType(e.span)

proc synthSelect(tc: var TypeChecker, e: Expr): Type =
  ## task `on select` (spec §9.3): each arm waits on a source (read fd /
  ## timeout ms) then runs its body. Type the args (fd/ms are ints) and the
  ## bodies; the select's value is a branch outcome — leave it unknown, the
  ## bodies carry the returns.
  for arm in e.selArms:
    if arm.arg != nil: discard tc.synthesize(arm.arg)
    discard tc.synthesize(arm.body)
  unknownType(e.span)

proc synthQualified(tc: var TypeChecker, e: Expr): Type =
  ## `:name` with no module path is a FUNCTION REFERENCE (`{add: :plus}`,
  ## `waitUntil {pred: :ready}`). Resolving it to a real tkFunc keeps the
  ## signature — params and result — instead of erasing it to Unknown, so a
  ## backend can emit a typed callable rather than an opaque pointer.
  if e.modulePath.len != 0 or not tc.fnSigs.hasKey(e.qualName):
    return unknownType(e.span)
  let sig = tc.fnSigs[e.qualName]
  var ps: seq[Type]
  for p in sig.params: ps.add(p.typ)
  Type(span: e.span, kind: tkFunc, params: ps, result: sig.ret)

proc synthesizeKind(tc: var TypeChecker, e: Expr): Type =
  case e.kind
  of exkLit: Type(span: e.span, kind: tkNamed, name: litTypeName(e.litKind))
  of exkVar: tc.synthVar(e)
  of exkField: tc.synthFieldAccess(e)
  of exkStruct: tc.synthStruct(e)
  of exkList: tc.synthList(e)
  of exkBracket: tc.synthBracket(e)
  of exkBracketAssign: tc.synthBracketAssign(e)
  of exkCall: tc.synthCall(e)
  of exkBinary: tc.synthBinary(e)
  of exkUnary: tc.synthUnary(e)
  of exkBlock: tc.synthBlock(e)
  of exkIf: tc.synthIf(e)
  of exkMatch: tc.synthMatch(e)
  of exkFor: tc.synthFor(e)
  of exkWhile: tc.synthWhile(e)
  of exkBreak: tc.synthLoopExit(e, "break")
  of exkContinue: tc.synthLoopExit(e, "continue")
  of exkAssign: tc.synthAssign(e)
  of exkReturn: tc.synthReturn(e)
  of exkRaise: tc.synthRaise(e)
  of exkChain: tc.synthChain(e)
  of exkSend: tc.synthSend(e)
  of exkSelect: tc.synthSelect(e)
  of exkQualified, exkImport: tc.synthQualified(e)

# A bracket's meaning comes from its RECEIVER, which only the checker knows:
# a declared type name is a type application (`Array[128, u8]`), anything
# else is indexing (`xs[i]`). The parser deliberately does not guess.

proc typeAppFromBracket(tc: var TypeChecker, e: Expr, name: string): Type =
  # `Name[a, b]` where Name is declared — the type-application form. Argument
  # arity is checked against the decl's generic params when it has any;
  # value arguments (`Array[128, u8]`) carry sizes and are not resolved here.
  # Arena/alloc semantics stay unimplemented (ROADMAP §7.3) — this only gives
  # the expression a type instead of misreading it as indexing.
  if tc.typeGenerics.hasKey(name):
    let arity = tc.typeGenerics[name].len
    if arity != e.brArgs.len:
      fail("Type Error: '" & name & "' takes " & $arity &
           " type argument(s), got " & $e.brArgs.len, e.span)
  var args: seq[Type]
  for a in e.brArgs:
    args.add(if a.kind == exkVar: Type(span: a.span, kind: tkNamed, name: a.name)
             else: tc.synthesize(a))
  Type(span: e.span, kind: tkApp,
       base: Type(span: e.span, kind: tkNamed, name: name), args: args)

proc indexCallee(tc: var TypeChecker, recvT: Type, fnName: string,
                 sp: Span): Expr =
  # A Seq comes from std/seq; any other type supplies its own `at`/`setAt`.
  # (fnSigs is keyed by name alone — no overloading — so Seq's must stay
  # qualified to avoid colliding with a user type's.)
  let isSeq = recvT != nil and recvT.kind == tkApp and recvT.base != nil and
              recvT.base.kind == tkNamed and recvT.base.name == "Seq"
  if isSeq:
    return Expr(span: sp, kind: exkQualified, modulePath: @["seq"],
                qualName: fnName)
  if fnName notin tc.fnSigs:
    let tn = if recvT == nil: "unknown" else: typeName(recvT)
    fail("Type Error: type '" & tn & "' is not indexable — define '" &
         fnName & "' for it", sp)
  Expr(span: sp, kind: exkVar, name: fnName)

# Indexing a VALUE: `at` when value is nil, `setAt` when it is not. The
# resolved call is stamped as a side node (the house idiom — see exkField's
# callNode) so the source node survives; codegen emits the stamped call.
proc resolveIndex(tc: var TypeChecker, br: Expr, value: Expr,
                  recvT: Type, sp: Span): Expr =
  if br.brArgs.len != 1:
    fail("Type Error: indexing takes exactly one index, got " &
         $br.brArgs.len, sp)
  let idx = br.brArgs[0]
  let idxT = tc.synthesize(idx)
  if not isUnknown(idxT) and not (idxT.kind == tkNamed and idxT.name == "int"):
    fail("Type Error: index must be int, got " & typeName(idxT), idx.span)
  var fields = @[("items", br.brReceiver), ("index", idx)]
  if value != nil:
    fields.add(("value", value))
  let callee = tc.indexCallee(recvT, if value == nil: "at" else: "setAt", sp)
  Expr(span: sp, kind: exkCall, callee: callee,
       args: @[Expr(span: sp, kind: exkStruct, fields: fields)])

proc synthBracket(tc: var TypeChecker, e: Expr): Type =
  if e.brReceiver != nil and e.brReceiver.kind == exkVar and
     tc.typeDecls.hasKey(e.brReceiver.name):
    return tc.typeAppFromBracket(e, e.brReceiver.name)
  let recvT = tc.synthesize(e.brReceiver)
  let ic = tc.resolveIndex(e, nil, recvT, e.span)
  setCall(semLayer, e, ic)
  tc.synthesize(ic)

proc synthBracketAssign(tc: var TypeChecker, e: Expr): Type =
  let br = e.brTarget
  if br.brReceiver != nil and br.brReceiver.kind == exkVar and
     tc.typeDecls.hasKey(br.brReceiver.name):
    fail("Type Error: cannot assign into the type application '" &
         br.brReceiver.name & "[...]'", e.span)
  let recvT = tc.synthesize(br.brReceiver)
  let ac = tc.resolveIndex(br, e.brValue, recvT, e.span)
  setCall(semLayer, e, ac)
  tc.synthesize(ac)

proc synthesize(tc: var TypeChecker, e: Expr): Type =
  if e == nil: return unknownType(Span())
  result = tc.synthesizeKind(e)
  setType(semLayer, e, result)

proc collectSigs(tc: var TypeChecker, decls: seq[Decl], top = true)

proc failIfPendingClash(tc: TypeChecker, d: Decl) =
  ## Stale-pending check, order-independent: implemented + still pending is an
  ## error whichever declaration the checker reaches first.
  fail("Pending Error: '" & d.name &
       "' is implemented — remove it from the pending block", d.span)

proc collectFnSig(tc: var TypeChecker, d: Decl, top: bool) =
  ## A fn joins the signature catalog, and is indexed so a resolved call can
  ## point at this declaration rather than describe it by name.
  tc.fnSigs[d.name] = (d.fnParams, d.fnReturnType, d.fnGenerics, d.fnEffects)
  indexDecl(semLayer, d)
  tc.fnDecls[d.name] = d
  # NOT pending: a pending fn emits a generic one-payload stub
  # (genPendingStub), so its real params are ({payload: T},) — nothing like its
  # DECLARED params, which is what topLevelFns's consumers (lowering,
  # codegen's explodeRecordArg/genCall) would explode against.
  if top and not d.isPending: tc.topLevelFns.incl(d.name)
  if "::" in d.name:
    # qualified sketch stub legalizes its module prefix
    tc.knownModules.incl(d.name.split("::")[0])
  if d.isPending:
    if d.name in tc.implementedFns: tc.failIfPendingClash(d)
    tc.pendingFns[d.name] = d.span
  elif d.fnBody != nil:
    if tc.pendingFns.hasKey(d.name): tc.failIfPendingClash(d)
    tc.implementedFns.incl(d.name)

proc collectFnSigType(tc: var TypeChecker, d: Decl) =
  ## A named function-signature type: register its call shape under NAME and
  ## mark NAME as a fnsig so a call through a NAME-typed slot is validated.
  ## A signature TYPE declares no effects of its own — what gets baked into
  ## the slot carries them.
  tc.fnSigs[d.name] = (d.sigParams, d.sigReturn,
                       newSeq[string](), newSeq[EffectMarker]())
  tc.fnSigNames.incl(d.name)

proc collectPoolSigs(tc: var TypeChecker, d: Decl) =
  ## spec 7.2: a pool exposes two ordinary fns. Registering them as normal
  ## signatures means `Pool.acquire` resolves through the same path as any
  ## other call — no special-case lookup, and the ?T falls out of the declared
  ## return type.
  let optElem = Type(span: d.span, kind: tkApp, args: @[d.poolElem],
                     base: Type(span: d.span, kind: tkNamed, name: "?"))
  tc.fnSigs[d.name & ".acquire"] = (newSeq[Param](), optElem,
                                    newSeq[string](), newSeq[EffectMarker]())
  tc.fnSigs[d.name & ".release"] =
    (@[Param(name: "slot", typ: d.poolElem, span: d.span)],
     Type(span: d.span, kind: tkNamed, name: "void"),
     newSeq[string](), newSeq[EffectMarker]())

proc collectTypeDecl(tc: var TypeChecker, d: Decl) =
  ## A type's body joins the type table; manager types carry functionality, so
  ## their member fns join the catalog too.
  indexDecl(semLayer, d)
  tc.typeDeclsByName[d.name] = d
  if d.typeBody != nil:
    tc.typeDecls[d.name] = d.typeBody
    if d.generics.len > 0:
      tc.typeGenerics[d.name] = d.generics
    for a in d.typeBody.attrs:
      if a.name == "distinct":
        tc.distinctNames.incl(d.name)
  tc.collectSigs(d.typeMembers, top = false)

proc collectObjectDecl(tc: var TypeChecker, d: Decl) =
  ## `{fields} Obj` constructs an object, exactly as `{fields} Rec` constructs
  ## a record. Objects were absent from typeDecls, so the construction path in
  ## synthCall fell through and produced Unknown — which made every field
  ## access on the result unchecked (`r.nosuchfield` passed) and let any value
  ## into an interface slot.
  ##
  ## Still NOT registered in typeDecls: `resolve` unwraps any name found there
  ## to its body, and an object is NOMINAL — `loadEpisode({self: PodcastApp})`
  ## must keep seeing PodcastApp, not the record shape behind it. Records are
  ## structural and belong there; objects do not. Field lookup reaches an
  ## object through typeDeclsByName + composedFields instead.
  tc.objDecls[d.name] = d
  tc.typeDeclsByName[d.name] = d
  tc.collectSigs(d.objMembers, top = false)

proc collectErrPolicy(tc: var TypeChecker, d: Decl) =
  ## The module's error policy, which decides what a dropped fallible result
  ## does.
  tc.errPolicy = d.policyName
  if d.policyName in ["continue", "exit"] and d.errHandler == nil:
    fail("Policy Error: errors [policy: " & d.policyName &
         "] needs an 'on unhandled({code, site})' handler", d.span)

proc collectSigs(tc: var TypeChecker, decls: seq[Decl], top = true) =
  ## `top` distinguishes a module's own declarations from the members nested
  ## inside a type, object, mixin or actor. Only top-level fns get recorded in
  ## topLevelFns, because they are the only callees lowering explodes payloads
  ## for — a member fn's explosion belongs to the backends, which see the
  ## receiver.
  for d in decls:
    if d == nil: continue
    case d.kind
    of dkImport:
      tc.knownModules.incl(d.name)
    of dkFn: tc.collectFnSig(d, top)
    of dkTask:
      tc.fnSigs[d.name] = (d.taskParams, d.taskReturnType,
                           newSeq[string](), d.taskEffects)
    of dkFnSig: tc.collectFnSigType(d)
    of dkPool: tc.collectPoolSigs(d)
    of dkType: tc.collectTypeDecl(d)
    of dkObject: tc.collectObjectDecl(d)
    of dkInterface:
      # Indexed, NOT collected into fnSigs: an interface's members are
      # requirements, not callable functions. Registering them would put
      # `noise` in the flat table with no body behind it.
      tc.ifaceDecls[d.name] = d
    of dkMixin, dkExtern, dkPending: tc.collectSigs(d.mixinMembers, top = false)
    of dkActor: tc.collectSigs(d.handlers)
    of dkErrors: tc.collectErrPolicy(d)
    else: discard

proc resolveTypeRefs(tc: TypeChecker, t: Type) =
  ## Point every named type reference at the declaration it names, so later
  ## passes follow an edge instead of matching a string. Recursive, because a
  ## reference can be buried in a generic argument or a record field.
  if t == nil: return
  case t.kind
  of tkNamed:
    if tc.typeDeclsByName.hasKey(t.name):
      resolveTypeTo(semLayer, t, tc.typeDeclsByName[t.name])
  of tkApp:
    resolveTypeRefs(tc, t.base)
    for a in t.args: resolveTypeRefs(tc, a)
  of tkTuple:
    for e in t.elems: resolveTypeRefs(tc, e)
  of tkFunc:
    for p in t.params: resolveTypeRefs(tc, p)
    resolveTypeRefs(tc, t.result)
  of tkRecord:
    for f in t.fields: resolveTypeRefs(tc, f.typ)
  of tkUnion:
    for mem in t.members: resolveTypeRefs(tc, mem)
  of tkEffect: resolveTypeRefs(tc, t.inner)
  of tkRename: resolveTypeRefs(tc, t.underlying)
  of tkSum:
    for v in t.variants:
      for f in v.fields: resolveTypeRefs(tc, f.typ)

proc resolveDeclTypeRefs(tc: TypeChecker, d: Decl) =
  ## Every type a declaration mentions.
  if d == nil: return
  case d.kind
  of dkType:
    resolveTypeRefs(tc, d.typeBody)
    for m in d.typeMembers: resolveDeclTypeRefs(tc, m)
  of dkFn:
    for p in d.fnParams: resolveTypeRefs(tc, p.typ)
    resolveTypeRefs(tc, d.fnReturnType)
  of dkTask:
    for p in d.taskParams: resolveTypeRefs(tc, p.typ)
    resolveTypeRefs(tc, d.taskReturnType)
  of dkObject:
    for f in d.objFields: resolveTypeRefs(tc, f.typ)
    for m in d.objMembers: resolveDeclTypeRefs(tc, m)
  of dkMixin, dkExtern, dkPending:
    for m in d.mixinMembers: resolveDeclTypeRefs(tc, m)
  of dkActor:
    for f in d.actorFields: resolveTypeRefs(tc, f.typ)
    for h in d.handlers: resolveDeclTypeRefs(tc, h)
  of dkPool: resolveTypeRefs(tc, d.poolElem)
  of dkFnSig:
    for p in d.sigParams: resolveTypeRefs(tc, p.typ)
    resolveTypeRefs(tc, d.sigReturn)
  of dkRegistry:
    for v in d.variants:
      for f in v.fields: resolveTypeRefs(tc, f.typ)
  else: discard

proc resolveTypeNames*(tc: TypeChecker, m: Module) =
  ## Run after collectSigs, when every declaration is known.
  for d in m.decls: resolveDeclTypeRefs(tc, d)

# Pure functions are total: only [io]-marked functions (I/O, unknown input)
# may declare fallible !T returns. The pure core provably cannot fail.
proc checkFallibleNeedsIo(name: string, ret: Type, effects: seq[EffectMarker], span: Span) =
  if ret != nil and isWrapper(ret) and ret.base.name in ["!", "!?"] and
     emIo notin effects:
    fail("Effect Error: '" & name & "' returns " & typeName(ret) &
         " — fallible functions must be marked [io]; pure functions are total", span)

proc checkFnBody(tc: var TypeChecker, name: string, params: seq[Param],
                 ret: Type, body: Expr, generics: seq[string] = @[]) =
  tc.pushScope()
  # Generic bodies are gradual: type params bind as Unknown (checked at the
  # call site via inference; Nim rechecks per instantiation)
  var gsub = initTable[string, Type]()
  # `T` inside a generic body is not unknown — it is ANY type, fixed per call
  # site. The body is checked once against that abstraction; each instantiation
  # is rechecked by the backend.
  for g in generics: gsub[g] = typeParamType(Span())
  let savedVariants = tc.varVariants
  tc.varVariants = initTable[string, seq[string]]()
  for p in params:
    # Params bound mutable: `set` functions legitimately use `..` on them
    tc.bindName(p.name, substituteType(p.typ, gsub), true)
    # spec 4.4b: a param of a tracked type enters at the FULL variant set —
    # transitions on it need `match` narrowing first
    let ptn = tc.transType(p.typ)
    if ptn != "":
      tc.varVariants[p.name] = tc.allVariants(ptn)
  # `input` — the whole incoming payload as one struct (reserved keyword)
  if params.len > 0:
    var inputFields: seq[FieldDef]
    for p in params:
      inputFields.add(FieldDef(name: p.name, typ: substituteType(p.typ, gsub),
                               span: p.span))
    tc.bindName("input", Type(span: params[0].span, kind: tkRecord,
                              fields: inputFields), false)
  tc.currentRet = ret
  tc.currentFn = name
  let prevBody = tc.bodyBlock
  tc.bodyBlock = body
  let bodyT = tc.synthesize(body)
  # Implicit return: the value flowing at the end of the body is the result.
  # Branch agreement (if/match) already unified branch types into bodyT.
  # unit/unknown tails mean explicit returns or sketch code — checked elsewhere.
  if ret != nil and body != nil and body.kind == exkBlock and body.stmts.len > 0:
    let lastKind = body.stmts[^1].kind
    if lastKind notin {exkReturn, exkRaise} and
       not isUnknown(bodyT) and
       not (bodyT.kind == tkNamed and bodyT.name in ["unit", "void"]) and
       not tc.compatible(bodyT, ret):
      fail("Type Error: '" & name & "' flows " & typeName(bodyT) &
           " out of its body but declares " & typeName(ret), body.stmts[^1].span)
  tc.bodyBlock = prevBody
  tc.currentRet = nil
  tc.currentFn = ""
  tc.varVariants = savedVariants
  tc.popScope()

# --- Decision tables (spec 6.1) ---------------------------------------------
# The analysis lives in typecheck_decisions; only collecting the rows needs
# the checker, because each row's body has to be typed.

proc collectRows(tc: var TypeChecker, d: Decl): seq[DecisionRow] =
  ## Every row of the table, checked for width and typed.
  for s in d.fnBody.stmts:
    if s.kind != exkMatch or s.arms.len == 0: continue
    let pats = rowPatterns(s.arms[0].pattern)
    checkRowWidth(d, pats, s.span)
    result.add((pats, s.span))
    discard tc.synthesize(s.arms[0].body)

proc checkDecisionTable(tc: var TypeChecker, d: Decl) =
  ## spec 6.1: row width, unreachable rows, completeness.
  if d.fnBody == nil or d.fnBody.kind != exkBlock or d.fnBody.stmts.len == 0:
    fail("Decision Error: decision table '" & d.name & "' has no rows", d.span)
  checkDecisionRows(tc.module, d, tc.collectRows(d))

proc checkDecl(tc: var TypeChecker, d: Decl)

proc checkFnDecl(tc: var TypeChecker, d: Decl) =
  ## A decision table is checked as a table; anything else as a fn body.
  if d.isDecision:
    tc.checkDecisionTable(d)
    return
  checkFallibleNeedsIo(d.name, d.fnReturnType, d.fnEffects, d.span)
  tc.currentErrTypes = d.fnErrorTypes
  tc.checkFnBody(d.name, d.fnParams, d.fnReturnType, d.fnBody, d.fnGenerics)
  tc.currentErrTypes = @[]

proc checkObjectDecl(tc: var TypeChecker, d: Decl) =
  ## Member fns see the object's fields, and the object itself as a mutable
  ## `self`.
  tc.pushScope()
  for f in d.objFields: tc.bindName(f.name, f.typ, true)
  tc.bindName("self", Type(span: d.span, kind: tkNamed, name: d.name), true)
  for m in d.objMembers: tc.checkDecl(m)
  tc.popScope()

proc checkHandler(tc: var TypeChecker, h: Decl) =
  ## `result` inside a handler IS its declared return type. Nothing bound it,
  ## so it synthesized as Unknown and every assignment to it was accepted. A
  ## handler with no return type gets no binding at all, which makes
  ## `result = ...` the undeclared-name error it should be.
  tc.pushScope()
  if h != nil and h.kind == dkFn and h.fnReturnType != nil:
    tc.bindName("result", h.fnReturnType, true)
  tc.checkDecl(h)
  tc.popScope()

proc checkActorDecl(tc: var TypeChecker, d: Decl) =
  ## Handlers see the actor's fields.
  tc.pushScope()
  for f in d.actorFields: tc.bindName(f.name, f.typ, true)
  for h in d.handlers: tc.checkHandler(h)
  tc.popScope()

proc checkDecl(tc: var TypeChecker, d: Decl) =
  if d == nil: return
  case d.kind
  of dkFn: tc.checkFnDecl(d)
  of dkTask:
    checkFallibleNeedsIo(d.name, d.taskReturnType, d.taskEffects, d.span)
    tc.checkFnBody(d.name, d.taskParams, d.taskReturnType, d.taskBody)
  of dkExpr: discard tc.synthesize(d.expr)
  of dkObject: tc.checkObjectDecl(d)
  of dkMixin, dkExtern, dkPending:
    for m in d.mixinMembers: tc.checkDecl(m)
  of dkActor: tc.checkActorDecl(d)
  of dkStaticAssert: discard tc.synthesize(d.assertExpr)
  of dkType: checkTransitions(d)
  of dkErrors:
    if d.errHandler != nil: tc.checkDecl(d.errHandler)
  else: discard

proc sigStr(d: Decl): string =
  var parts: seq[string]
  for p in d.fnParams:
    parts.add(p.name & ": " & typeName(p.typ))
  result = d.name & "({" & parts.join(", ") & "})"
  if d.fnReturnType != nil:
    result.add(" -> " & typeName(d.fnReturnType))

proc collectPending(decls: seq[Decl], acc: var seq[string]) =
  for d in decls:
    if d == nil: continue
    case d.kind
    of dkFn:
      if d.isPending:
        acc.add(sigStr(d) & "   line " & $d.span.line)
    of dkObject: collectPending(d.objMembers, acc)
    of dkMixin, dkExtern, dkPending: collectPending(d.mixinMembers, acc)
    of dkActor: collectPending(d.handlers, acc)
    else: discard

# The compile-time TODO list: every debug build prints what is still unimplemented.
proc pendingReport*(m: Module): seq[string] =
  collectPending(m.decls, result)

# Same line format as pendingReport, from an index SigInfo (no AST needed).
proc sigLine*(si: SigInfo): string =
  var parts: seq[string]
  for p in si.params:
    parts.add(p.name & ": " & typeName(p.typ))
  result = si.name & "({" & parts.join(", ") & "})"
  if si.ret != nil:
    result.add(" -> " & typeName(si.ret))
  result.add("   line " & $si.line)

# Returns the SHORTCUTS list (continue/exit policies): each statement-position
# drop that will route to the global handler. Empty under strict — strict
# raises instead, listing every unhandled site at once (spec 4.9).
proc isIoFn(tc: TypeChecker, name: string): bool =
  ## Reads the signature table, so an imported [io] fn counts too.
  emIo in tc.declaredEffects(name)

proc constCheck(tc: TypeChecker, m: Module, cname: string, e: Expr, sp: Span)

proc constCheckField(tc: TypeChecker, m: Module, cname: string, e: Expr,
                     sp: Span) =
  ## Unit sugar (5.ms) and field reads over const sub-expressions.
  if e.receiver == nil: return
  constCheck(tc, m, cname, e.receiver, sp)
  if e.receiver.kind == exkLit and tc.isIoFn(e.fieldName):
    fail("Const Error: 'const " & cname & "' must be pure — '" &
         e.fieldName & "' is [io]", sp)

proc constCheckCallee(tc: TypeChecker, m: Module, cname, callee: string,
                      sp: Span) =
  ## What a const's call may name: a compile-time combinator, a distinct base
  ## conversion, or a declared pure fn.
  if callee in ["bake", "merge", "alias"]: return
  if tc.distinctNames.contains(callee): return  # base conversion
  if tc.typeDecls.hasKey(callee) and tc.typeDecls[callee].kind == tkRecord:
    fail("Const Error: 'const " & cname & "' cannot hold a record " &
         "construction (records are reference values) — use a plain struct " &
         "literal", sp)
  if tc.isIoFn(callee):
    fail("Const Error: 'const " & cname & "' must be pure — '" & callee &
         "' is [io]", sp)
  if m.findDecl(dkFn, callee) == nil and not tc.typeDecls.hasKey(callee):
    fail("Const Error: 'const " & cname & "' needs declared pure fns — '" &
         callee & "' is unknown", sp)

proc constCheckCall(tc: TypeChecker, m: Module, cname: string, e: Expr,
                    sp: Span) =
  ## A call in a const: its arguments and, for a named callee, the callee
  ## itself. `{payload} Type.Variant` names a field — sum variants are value
  ## objects, which are fine.
  for a in e.args: constCheck(tc, m, cname, a, sp)
  if e.callee != nil and e.callee.kind == exkVar:
    constCheckCallee(tc, m, cname, e.callee.name, sp)

proc constCheck(tc: TypeChecker, m: Module, cname: string, e: Expr, sp: Span) =
  ## Reject what a const cannot be. Nim-static semantics: arbitrary PURE
  ## computation, evaluated at compile time by the backend's const evaluator,
  ## so this forbids only what would break there — [io] calls, record-type
  ## constructions (records are reference values), and unknown callees.
  if e == nil: return
  case e.kind
  of exkLit, exkQualified: discard  # literals; :fn refs
  of exkStruct:
    for f in e.fields: constCheck(tc, m, cname, f.value, sp)
  of exkList:
    for it in e.items: constCheck(tc, m, cname, it, sp)
  of exkUnary: constCheck(tc, m, cname, e.operand, sp)
  of exkBinary:
    constCheck(tc, m, cname, e.left, sp)
    constCheck(tc, m, cname, e.right, sp)
  of exkField: constCheckField(tc, m, cname, e, sp)
  of exkCall: constCheckCall(tc, m, cname, e, sp)
  else:
    fail("Const Error: 'const " & cname & "' must be a pure " &
         "compile-time expression", sp)

proc newModuleChecker(m: Module, externSigs: Table[string, FnSig],
                      externPending: Table[string, Span]): TypeChecker =
  ## A checker seeded with what this module's imports export.
  result = TypeChecker(module: m,
                       fnSigs: externSigs,
                       pendingFns: externPending,
                       typeDecls: initTable[string, Type](),
                       distinctNames: initHashSet[string](),
                       errPolicy: "strict")
  for qualName in externSigs.keys:
    if "::" in qualName:
      result.knownModules.incl(qualName.split("::")[0])

proc bindConsts(tc: var TypeChecker, m: Module) =
  ## const declarations are bound BEFORE body checks so any fn can reference
  ## them; constCheck says what a const is allowed to be.
  for d in m.decls:
    if d != nil and d.kind == dkConst:
      constCheck(tc, m, d.name, d.constVal, d.span)
      tc.bindName(d.name, tc.synthesize(d.constVal), false)

proc failIfFieldShadowsDeclaredFn(tc: TypeChecker, m: Module) =
  ## Either/or namespace: a declared field name may not shadow a declared fn —
  ## `.name` resolves by lookup, so a clash would silently change meaning.
  for d in m.decls:
    if d == nil: continue
    for f in d.declaredFields():
      if tc.fnSigs.hasKey(f.name):
        fail("Type Error: field '" & f.name & "' of '" & d.name & "' has the " &
             "same name as a declared fn — rename one; fields and fns share " &
             "the call namespace", d.span)

proc declaredName(d: Decl): string =
  ## The name a declaration introduces into the module's namespace, or "" for
  ## one that introduces none (an expression, an import, the errors block).
  case d.kind
  of dkFn, dkType, dkObject, dkActor, dkTask, dkConst, dkRegistry, dkPool,
     dkFnSig, dkInterface, dkRegister: d.name
  else: ""

proc failIfDuplicateDecl(m: Module) =
  ## A name may be declared once per module.
  ##
  ## Without this a duplicate reached CODEGEN and emitted invalid target code
  ## — two `proc tuck_f*(): int` in one Nim module — so the user got an error
  ## about generated code they never wrote. Fns and types share one namespace
  ## because they share the call syntax: `{x: 1} F` cannot mean both
  ## "construct F" and "call F".
  var seen = initTable[string, Span]()
  for d in m.decls:
    if d == nil: continue
    let name = declaredName(d)
    if name == "": continue
    if seen.hasKey(name):
      fail("Structure Error: '" & name & "' is declared twice in this module" &
           " (first at line " & $seen[name].line & ") — every top-level name " &
           "is declared once; fns and types share one namespace because they " &
           "share the call syntax", d.span)
    seen[name] = d.span

proc failIfDuplicateMember(what, owner: string, names: seq[(string, Span)]) =
  ## A field, variant or parameter name may appear once per declaration.
  var seen = initTable[string, Span]()
  for (name, span) in names:
    if seen.hasKey(name):
      fail("Structure Error: " & what & " '" & name & "' appears twice in '" &
           owner & "' (first at line " & $seen[name].line & ")", span)
    seen[name] = span

proc fieldNames(fields: seq[FieldDef]): seq[(string, Span)] =
  for f in fields: result.add((f.name, f.span))

proc paramNames(params: seq[Param]): seq[(string, Span)] =
  for p in params: result.add((p.name, p.span))

proc failIfDuplicateMembers(m: Module) =
  ## The same rule one level down: inside a type, object, actor or fn.
  for d in m.decls:
    if d == nil: continue
    case d.kind
    of dkFn:
      failIfDuplicateMember("parameter", d.name, paramNames(d.fnParams))
    of dkTask:
      failIfDuplicateMember("parameter", d.name, paramNames(d.taskParams))
    of dkObject:
      failIfDuplicateMember("field", d.name, fieldNames(d.objFields))
    of dkActor:
      failIfDuplicateMember("field", d.name, fieldNames(d.actorFields))
    of dkType:
      if d.typeBody == nil: continue
      if d.typeBody.kind == tkRecord:
        failIfDuplicateMember("field", d.name, fieldNames(d.typeBody.fields))
      elif d.typeBody.kind == tkSum:
        var vs: seq[(string, Span)]
        for v in d.typeBody.variants: vs.add((v.name, v.span))
        failIfDuplicateMember("variant", d.name, vs)
    else: discard

proc failIfTopLevelStatement(d: Decl) =
  ## Module top level is declarations only — the runnable program lives in
  ## `fn main`. (User ruling 2026-07-13: no top-level statements, not even
  ## pure lets; `tuck build` without main = library.)
  if d != nil and d.kind == dkExpr:
    fail("Structure Error: top-level statements are not allowed — move this " &
         "into `fn main` (a module is declarations; main is the program)",
         d.span)

proc reportUnhandled(tc: TypeChecker, m: Module): seq[string] =
  ## Under `strict` a dropped fallible result is an error; the other policies
  ## hand the sites to codegen, which routes them to the handler.
  if tc.errPolicy == "strict" and tc.unhandledSites.len > 0:
    fail("Type Error: " & $tc.unhandledSites.len & " unhandled error result(s)" &
         " — bind, pass on, or propagate with '?' (policy: strict):\n  " &
         tc.unhandledSites.join("\n  "), m.span)
  if tc.errPolicy in ["continue", "exit"]: tc.unhandledSites else: @[]

proc typecheckModule*(m: Module,
                      externSigs = initTable[string, FnSig](),
                      externPending = initTable[string, Span]()): seq[string] {.discardable.} =
  var tc = newModuleChecker(m, externSigs, externPending)
  tc.pushScope()  # module-level scope: consts visible across decls
  tc.collectSigs(m.decls)
  tc.resolveTypeNames(m)
  checkPointers(tc.typeDeclsByName, m)  # pointers stay at the extern boundary
  checkConformance(m)      # `satisfies I` means every I member is implemented
  tc.bindConsts(m)
  failIfDuplicateDecl(m)
  failIfDuplicateMembers(m)
  tc.failIfFieldShadowsDeclaredFn(m)
  for d in m.decls:
    failIfTopLevelStatement(d)
    tc.checkDecl(d)
  tc.reportUnhandled(m)

# Signature export for the .tuck-cache index: same collection walk the
# checker uses (nested fns in objects/mixins/actors included).
proc moduleSigs*(m: Module): seq[SigInfo] =
  var tc = TypeChecker(module: m,
                       fnSigs: initTable[string, FnSig](),
                       typeDecls: initTable[string, Type](),
                       distinctNames: initHashSet[string](),
                       errPolicy: "strict")
  tc.collectSigs(m.decls)
  tc.resolveTypeNames(m)
  for name, sig in tc.fnSigs:
    result.add(SigInfo(name: name, params: sig.params, ret: sig.ret,
                       generics: sig.generics, effects: sig.effects,
                       isPending: tc.pendingFns.hasKey(name),
                       line: tc.pendingFns.getOrDefault(name).line))

# Whole-program checking, order-independent: pass 1 collects EVERY module's
# signatures; pass 2 checks bodies against the full picture. `mods` is
# dep-first with the entry module last (compiler/modules.nim order); the
# entry module's SHORTCUTS list is returned.
# `preSigs`: modules resolved from the signature index — typechecked in an
# earlier run and unchanged since, so only their signatures participate.
# Mirror of tuck_rt's errCode: FNV-1a over "module/Enum.Variant", folded to
# 16 bits. Used only for the program-wide collision check — a hash collision
# between two error names would silently alias two errors at runtime.
proc fnv16(name: string): uint16 =
  var h = 2166136261'u32
  for c in name:
    h = (h xor uint32(c)) * 16777619'u32
  uint16((h xor (h shr 16)) and 0xFFFF'u32)

proc checkErrCodeCollisions*(mods: seq[tuple[name, path: string, m: Module]]) =
  ## Every declared error id ("module/Enum.Variant") must hash uniquely
  ## across the whole program. The forward table is built here; a collision
  ## is a compile error with a rename pointer.
  var seen = initTable[uint16, string]()
  for (name, path, m) in mods:
    for d in m.sumTypes():
      if d.span.file.startsWith(ImportedTypeMarker): continue  # origin owns it
      for v in d.typeBody.variants:
        if v.fields.len > 0: continue  # error enums are fieldless
        let full = name & "/" & d.name & "." & v.name
        let code = fnv16(full)
        if seen.hasKey(code) and seen[code] != full:
          fail("Error Id Collision: '" & full & "' and '" & seen[code] &
               "' hash to the same 16-bit code (0x" & $code &
               ") — rename one variant", d.span)
        seen[code] = full

type
  ProgramSigs = object
    ## What every module exports, gathered before any module is checked, so an
    ## import can be resolved regardless of declaration order.
    byMod: Table[string, Table[string, FnSig]]
    pendByMod: Table[string, Table[string, Span]]
    importsByMod: Table[string, seq[string]]

  ImportScope = object
    ## The names an importing module can see. `extern` holds both spellings;
    ## `bareOwner` remembers which import claimed each unqualified name, so a
    ## genuine collision between two imports is reported rather than silently
    ## resolved.
    extern: Table[string, FnSig]
    pending: Table[string, Span]
    bareOwner: Table[string, string]

proc withModulePrefix(err: ref SemanticError, path: string): ref SemanticError =
  ## Prefix a module-local error with the file it came from.
  err.msg = path & ":" & $err.line & ":" & $err.col & ": " & err.msg
  err

proc moduleImports(m: Module): seq[string] =
  ## The modules this one imports, in declaration order.
  for d in m.decls:
    if d != nil and d.kind == dkImport: result.add(d.name)

proc collectProgramSigs(mods: seq[tuple[name, path: string, m: Module]]): ProgramSigs =
  ## Every module's signatures and pending fns, before any body is checked.
  for (name, path, m) in mods:
    var tc = TypeChecker(module: m,
                         fnSigs: initTable[string, FnSig](),
                         typeDecls: initTable[string, Type](),
                         distinctNames: initHashSet[string](),
                         errPolicy: "strict")
    try:
      tc.collectSigs(m.decls)
      tc.resolveTypeNames(m)
    except SemanticError as err:
      raise withModulePrefix(err, path)
    result.byMod[name] = tc.fnSigs
    result.pendByMod[name] = tc.pendingFns
    result.importsByMod[name] = moduleImports(m)

proc addBare(scope: var ImportScope, fname, imp: string, sig: FnSig) =
  ## Claim an unqualified name for an import, or report the collision.
  if scope.bareOwner.hasKey(fname) and scope.bareOwner[fname] != imp:
    fail("Type Error: '" & fname & "' is exported by both '" &
         scope.bareOwner[fname] & "' and '" & imp & "' — call it as '" &
         scope.bareOwner[fname] & "::" & fname & "' or '" & imp & "::" &
         fname & "' to disambiguate", Span())
  elif not scope.bareOwner.hasKey(fname):
    scope.bareOwner[fname] = imp
    scope.extern[fname] = sig

proc importChecked(scope: var ImportScope, sigs: ProgramSigs, imp: string) =
  ## Bring in a module that is part of this program.
  for fname, sig in sigs.byMod[imp]:
    if "::" notin fname:
      scope.extern[imp & "::" & fname] = sig
      scope.addBare(fname, imp, sig)
  for fname, sp in sigs.pendByMod.getOrDefault(imp):
    if "::" notin fname:
      scope.pending[imp & "::" & fname] = sp

proc importPrebuilt(scope: var ImportScope, preSigs: Table[string, seq[SigInfo]],
                    imp: string) =
  ## Bring in a module whose signatures came from an index rather than source.
  for si in preSigs.getOrDefault(imp):
    if "::" in si.name: continue
    let sig: FnSig = (si.params, si.ret, si.generics, si.effects)
    scope.extern[imp & "::" & si.name] = sig
    scope.addBare(si.name, imp, sig)
    if si.isPending:
      scope.pending[imp & "::" & si.name] = Span(line: si.line, col: 1)

proc importScopeFor(sigs: ProgramSigs, preSigs: Table[string, seq[SigInfo]],
                    name: string): ImportScope =
  ## `import fs` brings fs's public fns into scope UNQUALIFIED — the idiomatic
  ## form (`readFile`, not `fs::readFile`), same as most languages. The
  ## qualified key is always added too, since `::` is still how a caller
  ## disambiguates a genuine collision between two imports.
  ##
  ## A LOCAL declaration of the same name wins: collectSigs runs after this
  ## table seeds tc.fnSigs, so a same-named local overwrites the bare key.
  for imp in sigs.importsByMod[name]:
    if sigs.byMod.hasKey(imp): result.importChecked(sigs, imp)
    else: result.importPrebuilt(preSigs, imp)

proc typecheckProgram*(mods: seq[tuple[name, path: string, m: Module]],
                       preSigs = initTable[string, seq[SigInfo]]()): seq[string] {.discardable.} =
  ## Signatures are gathered across the whole program first, then each module
  ## is checked against what its imports export.
  resetResolution()  # one semantic layer per program
  checkErrCodeCollisions(mods)
  let sigs = collectProgramSigs(mods)
  for (name, path, m) in mods:
    let scope = importScopeFor(sigs, preSigs, name)
    try:
      result = typecheckModule(m, scope.extern, scope.pending)
    except SemanticError as err:
      raise withModulePrefix(err, path)
