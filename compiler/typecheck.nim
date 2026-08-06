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
export typecheck_transitions

# UnknownName now lives in ast.nim (codegen needs it for typed-AST checks)
# Stateless helpers now live in typecheck_util; the TypeChecker state object +
# scope/resolve/fieldsOf now live in typecheck_state (both imported above).
proc compatible(tc: TypeChecker, actual, expected: Type): bool =
  # Wrapper discipline: a bare T may flow where !T is expected (auto-wrap on
  # return), and !T matches !T — but a !T/?T value where bare T is expected is
  # an UNHANDLED error and never compatible. `or` / `?` unwrap explicitly.
  var a = actual
  var e = expected
  if isWrapper(a):
    if isWrapper(e):
      a = unwrapEffect(a)
      e = unwrapEffect(e)
    elif not isUnknown(e):
      return false
  else:
    e = unwrapEffect(e)
  if isUnknown(a) or isUnknown(e): return true
  if e.kind == tkNamed and e.name in ["void", "unit", "Self", "fn"]: return true
  if a.kind == tkNamed and a.name in ["void", "unit", "Self", "fn"]: return true

  # Nominal fast path
  if a.kind == tkNamed and e.kind == tkNamed:
    if a.name == e.name: return true
    # Distinct types are strictly nominal: no widening, no resolving through
    # to the base type. Milliseconds is not Microseconds is not u32.
    if a.name in tc.distinctNames or e.name in tc.distinctNames:
      return false
    if isNumeric(a) and isNumeric(e): return true  # loose numeric widening for primitives
    # SUM TYPES ARE NOMINAL. Two differently-named sums are never compatible,
    # even though both resolve to a tkSum body. Resolving first destroyed the
    # only thing that distinguishes them: the fallthrough at the bottom is
    # `a.kind == e.kind`, and tkSum == tkSum, so `fn pick() -> Colour: return
    # Red` and `fn pick({l: Light}) -> Colour: return l` both passed.
    #
    # Checked here rather than at the bottom because by then the names are
    # gone. Records still fall through to structural matching below — subset
    # matching (spec 2.5) is the whole point for them.
    let ra = tc.resolve(a)
    let re = tc.resolve(e)
    if ra != nil and re != nil and
       (ra.kind == tkSum or re.kind == tkSum): return false
    # One side may be an alias for a record — fall through to structural
    if ra != a or re != e: return tc.compatible(ra, re)
    return false

  # A `:name` fn-ref synthesizes a tkFunc; the parameter names a fnsig, which
  # is a tkNamed. Match the reference against the named signature's shape —
  # otherwise the pair falls through to the record check and every callback
  # argument is rejected (`expects BinOp but got <type>`).
  if a.kind == tkFunc and e.kind == tkNamed and tc.fnSigs.hasKey(e.name):
    let sig = tc.fnSigs[e.name]
    if a.params.len != sig.params.len: return false
    for i, p in sig.params:
      if not tc.compatible(a.params[i], p.typ): return false
    return a.result == nil or sig.ret == nil or tc.compatible(a.result, sig.ret)

  # Structural: expected record => subset matching (spec 2.5)
  let eFields = if e.kind == tkRecord: e.fields else: tc.fieldsOf(e)
  if eFields.len > 0 or e.kind == tkRecord:
    let aFields = if a.kind == tkRecord: a.fields else: tc.fieldsOf(a)
    if aFields.len == 0 and a.kind != tkRecord:
      return false  # known non-record vs record
    for ef in eFields:
      var found = false
      for af in aFields:
        if af.name == ef.name:
          if not tc.compatible(af.typ, ef.typ): return false
          found = true
          break
      if not found: return false
    return true

  if a.kind == tkApp and e.kind == tkApp:
    if not tc.compatible(a.base, e.base): return false
    if a.args.len == e.args.len:
      for i in 0 ..< a.args.len:
        if not tc.compatible(a.args[i], e.args[i]): return false
    return true

  # Sum types and the rest: nominal only, handled above; unknown shapes pass
  return a.kind == e.kind

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

proc synthBinary(tc: var TypeChecker, e: Expr): Type =
  let lt = tc.synthesize(e.left)
  let rt = tc.synthesize(e.right)
  # `and`/`or`/`xor` are strictly boolean — they never unwrap a result. A ?T
  # operand is the one exception: in a boolean position it reads as "is
  # present", which is a test, not an unwrap. A !T still has to be handled.
  let boolCtx = e.binOp in {boAnd, boOr, boXor}
  for (t, side) in [(lt, e.left), (rt, e.right)]:
    if isWrapper(t) and not (boolCtx and isOptional(t)):
      fail("Type Error: unhandled " & typeName(t) &
           " — pass it to a handling function or propagate with '?'", side.span)
  case e.binOp
  of boAdd, boSub, boMul, boMod:
    if not isUnknown(lt) and not isUnknown(rt) and not tc.compatible(lt, rt):
      fail("Type Error: arithmetic between " & typeName(lt) & " and " &
           typeName(rt), e.span)
    if isUnknown(lt): rt else: lt
  of boDivInt, boDivFloat:
    # R1: the operator names the arithmetic, so the operands must actually BE
    # that kind. `compatible` alone would let `2 /f 3` through on loose numeric
    # widening — precisely the silent conversion this ruling removes.
    let wantFloat = e.binOp == boDivFloat
    let opName = if wantFloat: "/f" else: "/i"
    for (t, side) in [(lt, e.left), (rt, e.right)]:
      if isUnknown(t): continue
      let isFloatT = typeName(t) in ["float", "f32", "f64"]
      if wantFloat != isFloatT:
        fail("Type Error: `" & opName & "` takes " &
             (if wantFloat: "float" else: "integer") & " operands, got " &
             typeName(t) & " — use `" & (if wantFloat: "/i" else: "/f") &
             "`, or convert explicitly", side.span)
    if not isUnknown(lt) and not isUnknown(rt) and not tc.compatible(lt, rt):
      fail("Type Error: division between " & typeName(lt) & " and " &
           typeName(rt), e.span)
    if isUnknown(lt): rt else: lt
  of boEq, boNeq, boLt, boGt, boLe, boGe:
    if not isUnknown(lt) and not isUnknown(rt) and not tc.compatible(lt, rt):
      fail("Type Error: comparison between " & typeName(lt) & " and " &
           typeName(rt), e.span)
    Type(span: e.span, kind: tkNamed, name: "bool")
  of boRangeIncl, boRangeExcl:
    for (t, side) in [(lt, e.left), (rt, e.right)]:
      if not isUnknown(t) and typeName(t) notin
         ["int", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64"]:
        fail("Type Error: range bounds must be integers, got " & typeName(t),
             side.span)
    Type(span: e.span, kind: tkNamed, name: "range")
  of boAnd, boOr, boXor:
    # Strictly boolean. `or` is NOT an unwrap operator: a failed result is
    # handled with .ok / match r.err, never by falling through to a default.
    let opName = case e.binOp
                 of boAnd: "and"
                 of boOr: "or"
                 else: "xor"
    for (t, side) in [(lt, e.left), (rt, e.right)]:
      if isUnknown(t) or isOptional(t): continue  # ?T = "is present"
      if not (t != nil and t.kind == tkNamed and t.name == "bool"):
        fail("Type Error: '" & opName & "' expects bool, got " & typeName(t),
             side.span)
    Type(span: e.span, kind: tkNamed, name: "bool")

# spec 4.4b: union two branch states — narrowing is never discarded,
# only widened to the union of what the branches could produce

proc synthIf(tc: var TypeChecker, e: Expr): Type =
  let condT = tc.synthesize(e.cond)
  if isWrapper(condT):
    fail("Type Error: unhandled " & typeName(condT) &
         " in condition — pass it to a handling function or propagate with '?'", e.cond.span)
  if not isUnknown(condT) and not tc.compatible(condT,
      Type(span: e.span, kind: tkNamed, name: "bool")):
    fail("Type Error: if condition must be bool, got " & typeName(condT), e.cond.span)
  # `if r.ok:` narrows r inside the then-branch ONLY — outside the guard
  # the value is still the wrapped type (strict, scope-limited)
  var guard = ""
  if e.cond != nil and e.cond.kind == exkField and e.cond.fieldName == "ok" and
     e.cond.receiver != nil and e.cond.receiver.kind == exkVar and
     e.cond.receiver.name notin tc.okNarrowed:
    guard = e.cond.receiver.name
  if guard != "": tc.okNarrowed.incl(guard)
  let entryVariants = tc.varVariants
  let thenT = tc.synthesize(e.thenBranch)
  let thenVariants = tc.varVariants
  if guard != "": tc.okNarrowed.excl(guard)
  tc.varVariants = entryVariants
  let elseT = tc.synthesize(e.elseBranch)
  tc.varVariants = mergeVariants(thenVariants, tc.varVariants)
  # Branches that produce values must agree on the type
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

proc synthChain(tc: var TypeChecker, e: Expr): Type =
  let baseT = tc.synthesize(e.base)
  # Spec 2.3: `..` mutation only on var bindings
  if e.base != nil and e.base.kind == exkVar:
    var hasMutation = false
    for step in e.steps:
      if step.op == coDotDot: hasMutation = true
    if hasMutation:
      let (found, b) = tc.lookup(e.base.name)
      if found and not b.isVar:
        fail("Type Error: cannot mutate '" & e.base.name &
             "' with '..' — it was declared with 'let'; use 'var'", e.span)
  # Each `..name {args}` step either SETS a field (payload is the single
  # {value: X} sugar) or calls a mutator fn — receiver rides as the first
  # parameter, and the result is reassigned into the base var (an ordinary
  # var-reassignment type check, so the fn must return the receiver's type).
  # Either way the chain stays on the base var.
  let recvT = tc.resolve(baseT)
  let fields = tc.fieldsOf(recvT)
  for step in e.steps.mitems:
    var isField = false
    for f in fields:
      if f.name == step.target.name:
        isField = true
        if tc.fnSigs.hasKey(f.name):
          fail("Type Error: '" & f.name & "' is both a field here and a " &
               "declared fn — rename one; fields and fns share the call " &
               "namespace", step.span)
        if not isBareValuePayload(step.arg):
          fail("Type Error: setting field '" & f.name & "' with '..' takes " &
               "one bare value: ..." & f.name & " {" & typeName(f.typ) &
               "} — to set several fields, use a mutator fn", step.span)
        let valExpr = soleFieldValue(step.arg)
        let vt = tc.synthesize(valExpr)
        if not tc.compatible(vt, f.typ):
          fail("Type Error: field '" & f.name & "' of " & typeName(recvT) &
               " is " & typeName(f.typ) & " but got " & typeName(vt),
               valExpr.span)
        break
    if not isField:
      if tc.fnSigs.hasKey(step.target.name):
        var retT: Type
        if step.arg != nil:
          # braced args pin the method form: receiver = first param
          let sc = tc.synthMethodCall(step.target.name, e.base, recvT,
                                      step.arg, step.span)
          setStepCall(semLayer, step, sc)
          retT = semLayer.typeFor(sc)
        else:
          # bare `..fn`: same type-directed resolution as any other call
          # (whole-bind the receiver, else its fields fill the params)
          let sc = Expr(span: step.span, kind: exkCall,
                        callee: Expr(span: step.span, kind: exkVar,
                                     name: step.target.name),
                        args: @[e.base])
          setStepCall(semLayer, step, sc)
          retT = tc.synthesize(sc)
        if not tc.compatible(retT, baseT):
          fail("Type Error: cannot assign " & typeName(retT) & " to " &
               typeName(baseT) & " — a '..' mutator must return the " &
               "receiver's type", step.span)
        # spec 4.4b: a mutator reassignment on a tracked var is a transition
        if e.base != nil and e.base.kind == exkVar:
          let tn = tc.transType(baseT)
          if tn != "":
            let cur = if tc.varVariants.hasKey(e.base.name):
                        tc.varVariants[e.base.name]
                      else: tc.allVariants(tn)
            let next = tc.fnReturnVariants(step.target.name, tn)
            tc.checkTransSet(tn, cur, next, step.span)
            tc.varVariants[e.base.name] = next
      elif recvT.kind == tkRecord:
        fail("Type Error: no field or fn '" & step.target.name & "' on type " &
             typeName(recvT), step.span)
  baseT

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
    of dkFn:
      tc.fnSigs[d.name] = (d.fnParams, d.fnReturnType, d.fnGenerics, d.fnEffects)
      # Index it so a resolved call can point at this declaration rather than
      # describe it by name.
      indexDecl(semLayer, d)
      tc.fnDecls[d.name] = d
      # NOT pending: a pending fn emits a generic one-payload stub
      # (genPendingStub), so its real params are ({payload: T},) — nothing
      # like its DECLARED params, which is what topLevelFns's consumers
      # (lowering, codegen's explodeRecordArg/genCall) would explode against.
      if top and not d.isPending: tc.topLevelFns.incl(d.name)
      if "::" in d.name:
        # qualified sketch stub legalizes its module prefix
        tc.knownModules.incl(d.name.split("::")[0])
      # Stale-pending check, order-independent: implemented + still pending = error
      if d.isPending:
        if d.name in tc.implementedFns:
          fail("Pending Error: '" & d.name & "' is implemented — remove it from the pending block", d.span)
        tc.pendingFns[d.name] = d.span
      elif d.fnBody != nil:
        if tc.pendingFns.hasKey(d.name):
          fail("Pending Error: '" & d.name & "' is implemented — remove it from the pending block", d.span)
        tc.implementedFns.incl(d.name)
    of dkTask:
      tc.fnSigs[d.name] = (d.taskParams, d.taskReturnType,
                           newSeq[string](), d.taskEffects)
    of dkFnSig:
      # a named function-signature type: register its call shape under NAME and
      # mark NAME as a fnsig so a call through a NAME-typed slot is validated.
      # A signature TYPE declares no effects of its own — what gets baked into
      # the slot carries them.
      tc.fnSigs[d.name] = (d.sigParams, d.sigReturn,
                           newSeq[string](), newSeq[EffectMarker]())
      tc.fnSigNames.incl(d.name)
    of dkPool:
      # spec 7.2: a pool exposes two ordinary fns. Registering them as normal
      # signatures means `Pool.acquire` resolves through the same path as any
      # other call — no special-case lookup, and the ?T falls out of the
      # declared return type.
      let optElem = Type(span: d.span, kind: tkApp,
                         base: Type(span: d.span, kind: tkNamed, name: "?"),
                         args: @[d.poolElem])
      tc.fnSigs[d.name & ".acquire"] = (newSeq[Param](), optElem,
                                        newSeq[string](), newSeq[EffectMarker]())
      tc.fnSigs[d.name & ".release"] =
        (@[Param(name: "slot", typ: d.poolElem, span: d.span)],
         Type(span: d.span, kind: tkNamed, name: "void"),
         newSeq[string](), newSeq[EffectMarker]())
    of dkType:
      indexDecl(semLayer, d)
      tc.typeDeclsByName[d.name] = d
      if d.typeBody != nil:
        tc.typeDecls[d.name] = d.typeBody
        if d.generics.len > 0:
          tc.typeGenerics[d.name] = d.generics
        for a in d.typeBody.attrs:
          if a.name == "distinct":
            tc.distinctNames.incl(d.name)
      # manager types carry functionality: member fns join the catalog
      tc.collectSigs(d.typeMembers, top = false)
    of dkObject:
      tc.objDecls[d.name] = d
      tc.typeDeclsByName[d.name] = d
      # `{fields} Obj` constructs an object, exactly as `{fields} Rec`
      # constructs a record. Objects were absent from typeDecls, so the
      # construction path in synthCall fell through and produced Unknown —
      # which then made every field access on the result unchecked
      # (`r.nosuchfield` passed) and let any value into an interface slot.
      # NOT registered in typeDecls: `resolve` unwraps any name found there to
      # its body, and an object is NOMINAL — `loadEpisode({self: PodcastApp})`
      # must keep seeing PodcastApp, not the record shape behind it. Records
      # are structural and belong there; objects do not. Field lookup reaches
      # an object through typeDeclsByName + composedFields instead.
      tc.collectSigs(d.objMembers, top = false)
    of dkInterface:
      # Indexed, NOT collected into fnSigs: an interface's members are
      # requirements, not callable functions. Registering them would put
      # `noise` in the flat table with no body behind it.
      tc.ifaceDecls[d.name] = d
    of dkMixin, dkExtern, dkPending: tc.collectSigs(d.mixinMembers, top = false)
    of dkActor: tc.collectSigs(d.handlers)
    of dkErrors:
      tc.errPolicy = d.policyName
      if d.policyName in ["continue", "exit"] and d.errHandler == nil:
        fail("Policy Error: errors [policy: " & d.policyName &
             "] needs an 'on unhandled({code, site})' handler", d.span)
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

# --- Pointers are legal only at the extern boundary -------------------------
#
# Tuck is a safe language; unsafe types exist to talk to C and nowhere else. A
# pointer may be produced by an extern and consumed by another extern or a
# converter (`toStr`), but it may never be STORED — so no pointer outlives the
# expression that obtained it and a dangling reference is unreachable from safe
# code. examples/34-ffi-cstring.tuck already stated this as a comment; this is
# the rule behind it.
#
# Pointer-kind is `cstring` plus any FIELDLESS extern type — an opaque C handle
# (`typedef struct Foo Foo;`) whose size is unknown, so it can only ever be held
# as a pointer (codegen emits `ptr FooObj` / `rawptr`).

proc isPointerKind(tc: TypeChecker, t: Type): bool =
  if t == nil or t.kind != tkNamed: return false
  # Builtin FFI pointers: cstring (char*) and Buf (uint8_t*).
  if t.name in ["cstring", "Buf"]: return true
  if tc.typeDeclsByName.hasKey(t.name):
    let d = tc.typeDeclsByName[t.name]
    # typeExternHeader/typeBody exist only on dkType — the table also holds
    # dkObject (objects are constructible by name too), and touching a
    # dkType-only field on one is a FieldDefect, not a false.
    if d.kind != dkType: return false
    # `fields` only exists on a tkRecord body — a sum/named/alias extern type is
    # not an opaque handle, and reading .fields on those is a FieldDefect.
    return d.typeExternHeader != "" and
           d.typeBody != nil and d.typeBody.kind == tkRecord and
           d.typeBody.fields.len == 0
  false

proc failIfPointer(tc: TypeChecker, t: Type, where: string, sp: Span) =
  ## Reject a pointer-kind type anywhere it would escape the extern boundary.
  ## Recurses so a pointer buried in `Seq[Buf]` or a record field is caught too.
  if t == nil: return
  if tc.isPointerKind(t):
    fail("Type Error: " & typeName(t) & " is a pointer — it may only appear in " &
         "an extern signature, not " & where & " (cross into safe Tuck with a " &
         "converter such as toStr)", sp)
  case t.kind
  of tkApp:
    failIfPointer(tc, t.base, where, sp)
    for a in t.args: failIfPointer(tc, a, where, sp)
  of tkTuple:
    for e in t.elems: failIfPointer(tc, e, where, sp)
  of tkFunc:
    for p in t.params: failIfPointer(tc, p, where, sp)
    failIfPointer(tc, t.result, where, sp)
  of tkRecord:
    for f in t.fields: failIfPointer(tc, f.typ, where, sp)
  of tkEffect: failIfPointer(tc, t.inner, where, sp)
  of tkRename: failIfPointer(tc, t.underlying, where, sp)
  else: discard

proc failIfPointerReturn(tc: TypeChecker, t: Type, fnName: string, sp: Span) =
  ## An extern may TAKE a pointer; it may not hand one back. Recurses, so
  ## `!cstring` and `{p: Buf}` are caught as well as a bare return.
  if t == nil: return
  if tc.isPointerKind(t):
    fail("Type Error: extern '" & fnName & "' returns " & typeName(t) &
         " — a pointer may be passed INTO C but never returned out of it " &
         "(wrap it: have the binding return str or Seq[u8], and copy in the " &
         "implementation)", sp)
  case t.kind
  of tkApp:
    failIfPointerReturn(tc, t.base, fnName, sp)
    for a in t.args: failIfPointerReturn(tc, a, fnName, sp)
  of tkTuple:
    for e in t.elems: failIfPointerReturn(tc, e, fnName, sp)
  of tkRecord:
    for f in t.fields: failIfPointerReturn(tc, f.typ, fnName, sp)
  of tkEffect: failIfPointerReturn(tc, t.inner, fnName, sp)
  of tkRename: failIfPointerReturn(tc, t.underlying, fnName, sp)
  else: discard

proc checkPointerContainment(tc: TypeChecker, d: Decl, inExtern = false) =
  ## Mirrors resolveDeclTypeRefs' walk. `inExtern` is threaded from the PARENT
  ## decl rather than inferred here: dkMixin, dkExtern and dkPending share an
  ## arm and both recurse through mixinMembers, so keying on the arm would let a
  ## plain `mixin` hold a cstring — a real leak path, not a hypothetical one.
  if d == nil: return
  case d.kind
  of dkFn:
    if inExtern:
      # Pointers cross INTO C, never back out. A param is Tuck handing C
      # something it already holds; a RETURN would put a raw pointer in a Tuck
      # variable, and from there its lifetime is C's business and unknowable
      # here. A C fn returning char*/uint8_t* gets a shim in the Nim layer that
      # copies into str/Seq[u8], so the Tuck-visible signature is a safe type
      # and forgetting the conversion is impossible rather than merely
      # discouraged.
      failIfPointerReturn(tc, d.fnReturnType, d.name, d.span)
      return
    for p in d.fnParams:
      failIfPointer(tc, p.typ, "a fn parameter", p.span)
    failIfPointer(tc, d.fnReturnType, "a fn return type", d.span)
  of dkTask:
    for p in d.taskParams:
      failIfPointer(tc, p.typ, "a task parameter", p.span)
    failIfPointer(tc, d.taskReturnType, "a task return type", d.span)
  of dkType:
    # An extern type declaring an opaque handle is the declaration itself, not
    # a use of one — only its MEMBERS are ordinary code.
    if not inExtern and d.typeBody != nil and d.typeBody.kind == tkRecord:
      for f in d.typeBody.fields:
        failIfPointer(tc, f.typ, "a type field", f.span)
    for m in d.typeMembers: checkPointerContainment(tc, m, inExtern)
  of dkObject:
    for f in d.objFields:
      failIfPointer(tc, f.typ, "an object field", f.span)
    for m in d.objMembers: checkPointerContainment(tc, m, inExtern)
  of dkActor:
    for f in d.actorFields:
      failIfPointer(tc, f.typ, "an actor field", f.span)
    for h in d.handlers: checkPointerContainment(tc, h, inExtern)
  of dkExtern:
    for m in d.mixinMembers: checkPointerContainment(tc, m, true)
  of dkMixin, dkPending:
    for m in d.mixinMembers: checkPointerContainment(tc, m, inExtern)
  of dkInterface:
    for m in d.ifaceMembers: checkPointerContainment(tc, m, inExtern)
  of dkPool: failIfPointer(tc, d.poolElem, "a pool element type", d.span)
  of dkFnSig:
    if inExtern: return   # a C callback signature is part of the boundary
    for p in d.sigParams:
      failIfPointer(tc, p.typ, "a fnsig parameter", p.span)
    failIfPointer(tc, d.sigReturn, "a fnsig return type", d.span)
  of dkRegistry:
    for v in d.variants:
      for f in v.fields:
        failIfPointer(tc, f.typ, "a registry field", f.span)
  else: discard

proc checkPointers*(tc: TypeChecker, m: Module) =
  ## Run after resolveTypeNames, when typeDeclsByName knows every extern type.
  for d in m.decls: checkPointerContainment(tc, d)

# --- Interface conformance (spec §5.2) --------------------------------------
#
# `satisfies I` is a promise; this is where it is kept. An object must
# implement every fn the interface requires, with matching parameters and
# return type, and may declare FEWER effects but never more.

proc sameType(a, b: Type): bool =
  ## Structural equality — deliberately NOT `compatible`, which is lenient by
  ## design (Unknown, void, unit and Self match everything, so a conformance
  ## check built on it would accept an impl returning void where the contract
  ## says !str).
  if a == nil or b == nil: return a == nil and b == nil
  if a.kind != b.kind: return false
  case a.kind
  of tkNamed: a.name == b.name
  of tkApp:
    if not sameType(a.base, b.base) or a.args.len != b.args.len: return false
    for i in 0 ..< a.args.len:
      if not sameType(a.args[i], b.args[i]): return false
    true
  of tkTuple:
    if a.elems.len != b.elems.len: return false
    for i in 0 ..< a.elems.len:
      if not sameType(a.elems[i], b.elems[i]): return false
    true
  of tkRecord:
    if a.fields.len != b.fields.len: return false
    for i in 0 ..< a.fields.len:
      if a.fields[i].name != b.fields[i].name or
         not sameType(a.fields[i].typ, b.fields[i].typ): return false
    true
  of tkFunc:
    if a.params.len != b.params.len: return false
    for i in 0 ..< a.params.len:
      if not sameType(a.params[i], b.params[i]): return false
    sameType(a.result, b.result)
  else: typeName(a) == typeName(b)

proc substSelf(t: Type, objName: string): Type =
  ## `Self` in a required signature means the implementing type.
  if t == nil: return nil
  if t.kind == tkNamed and t.name == "Self":
    return Type(span: t.span, kind: tkNamed, name: objName)
  if t.kind == tkApp:
    var args: seq[Type]
    for a in t.args: args.add(substSelf(a, objName))
    return Type(span: t.span, kind: tkApp, base: substSelf(t.base, objName),
                args: args)
  t

proc sigText(d: Decl): string =
  ## One line naming a signature, for both halves of a mismatch report.
  var ps: seq[string]
  for p in d.fnParams: ps.add(p.name & ": " & typeName(p.typ))
  var effs: seq[string]
  for e in d.fnEffects: effs.add(($e)[2 .. ^1].toLowerAscii)
  result = "fn " & d.name & "({" & ps.join(", ") & "})"
  if d.fnReturnType != nil: result.add(" -> " & typeName(d.fnReturnType))
  if effs.len > 0: result.add(" [" & effs.join(", ") & "]")

proc failConformance(objName, iname: string, want, got: Decl, why: string) =
  fail("Conformance Error: object '" & objName & "' does not satisfy '" &
       iname & "'\n  contract   " & sigText(want) &
       "\n  implements " & sigText(got) & "\n  " & why, got.span)

proc checkSigMatch(want, got: Decl, objName, iname: string) =
  if want.fnParams.len != got.fnParams.len:
    failConformance(objName, iname, want, got,
      "takes " & $got.fnParams.len & " parameter(s), the contract declares " &
      $want.fnParams.len)
  for i in 0 ..< want.fnParams.len:
    let w = want.fnParams[i]
    let g = got.fnParams[i]
    if w.name != g.name:
      failConformance(objName, iname, want, got,
        "parameter " & $(i + 1) & " is named '" & g.name &
        "', the contract calls it '" & w.name &
        "' (payload fields bind by name, so the name is part of the contract)")
    if not sameType(substSelf(w.typ, objName), g.typ):
      failConformance(objName, iname, want, got,
        "parameter '" & w.name & "' is " & typeName(g.typ) &
        ", the contract declares " & typeName(substSelf(w.typ, objName)))
  if not sameType(substSelf(want.fnReturnType, objName), got.fnReturnType):
    failConformance(objName, iname, want, got,
      "returns " & typeName(got.fnReturnType) & ", the contract declares " &
      typeName(substSelf(want.fnReturnType, objName)))
  # Effects may be a SUBSET: an implementation may do less than the contract
  # permits, never more. Same direction as the caller/callee effect budget.
  for e in got.fnEffects:
    if e notin want.fnEffects:
      failConformance(objName, iname, want, got,
        "declares effect [" & ($e)[2 .. ^1].toLowerAscii &
        "], which the contract does not permit (an implementation may do " &
        "LESS than the contract allows, never more)")

proc applySatisfiesDecls*(m: Module) =
  ## Fold every top-level `Obj satisfies Iface` into that object's own
  ## `satisfies` list, BEFORE conformance runs.
  ##
  ## Doing it here rather than teaching each later pass about dkSatisfies is
  ## the whole point: conformance checking, interface wrapping and both
  ## backends' satisfiersOf all read `dkObject.satisfies`, so after this merge
  ## an attached contract is indistinguishable from a declared one — which is
  ## exactly the intent. Attaching widens WHERE a promise may be stated, never
  ## what the promise means.
  ##
  ## Re-stating a contract the object already declares is a NO-OP, not an
  ## error: a calling module cannot be expected to know what the library
  ## already promised, and demanding it check would defeat the feature.
  var objs = initTable[string, Decl]()
  for d in m.decls:
    if d != nil and d.kind == dkObject: objs[d.name] = d
  for d in m.decls:
    if d == nil or d.kind != dkSatisfies: continue
    if d.name notin objs:
      fail("Conformance Error: `" & d.name & " satisfies ...` names '" &
           d.name & "', which is not a declared object in scope", d.span)
    let obj = objs[d.name]
    for iname in d.satisfyTargets:
      if iname notin obj.satisfies:
        obj.satisfies.add(iname)

proc checkConformance*(tc: TypeChecker, m: Module) =
  ## Every `satisfies I` on an object is verified against interface I —
  ## whether the object declared it or a later module attached it.
  applySatisfiesDecls(m)
  var ifaces = initTable[string, Decl]()
  for d in m.decls:
    if d != nil and d.kind == dkInterface: ifaces[d.name] = d
  for d in m.decls:
    if d == nil or d.kind != dkObject or d.satisfies.len == 0: continue
    for iname in d.satisfies:
      if iname notin ifaces:
        fail("Conformance Error: object '" & d.name & "' satisfies '" & iname &
             "' but no interface by that name is declared", d.span)
      for want in ifaces[iname].ifaceMembers:
        if want == nil or want.kind != dkFn: continue
        var got: Decl = nil
        for have in d.members():
          # A body-less member is a signature, not an implementation — there
          # would be no code to run.
          if have.kind == dkFn and have.name == want.name and have.fnBody != nil:
            got = have
            break
        if got == nil:
          fail("Conformance Error: object '" & d.name & "' satisfies '" &
               iname & "' but does not implement\n    " & sigText(want) &
               "\n  (add it as a member fn, or drop the `satisfies " & iname &
               "` line)", d.span)
        checkSigMatch(want, got, d.name, iname)

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

# --- Decision tables (spec 6.1): row width, unreachable rows, completeness ---

proc patCovers(a, b: Pattern): bool =
  # Does pattern a match everything pattern b matches? (per column)
  if a == nil or a.kind == pkWild: return true
  if b == nil or b.kind == pkWild: return false
  if a.kind != b.kind: return false
  case a.kind
  of pkVar: a.name == b.name
  of pkLit: a.litKind == b.litKind and a.litValue == b.litValue
  else: false

type
  DecisionRow = tuple[pats: seq[Pattern], span: Span]
    ## One row of a decision table: a pattern per input column.

const MaxEnumeratedCombos = 4096
  ## Above this, exact enumeration costs more than it is worth and the
  ## pairwise fallback takes over.

proc patValue(p: Pattern): string =
  ## The value a pattern names, or "_" for a wildcard.
  if p == nil: return "_"
  case p.kind
  of pkWild: "_"
  of pkVar: p.name
  of pkLit: p.litValue
  else: "_"

proc rowPatterns(pat: Pattern): seq[Pattern] =
  ## A row's columns. A tuple pattern is already one per column; anything
  ## else is a single-column row.
  if pat != nil and pat.kind == pkTuple: pat.elems else: @[pat]

proc collectRows(tc: var TypeChecker, d: Decl): seq[DecisionRow] =
  ## Every row of the table, checked for width and typed.
  for s in d.fnBody.stmts:
    if s.kind != exkMatch or s.arms.len == 0: continue
    let pats = rowPatterns(s.arms[0].pattern)
    if pats.len != d.fnParams.len:
      fail("Decision Error: row in '" & d.name & "' has " & $pats.len &
           " columns but the table declares " & $d.fnParams.len & " inputs",
           s.span)
    result.add((pats, s.span))
    discard tc.synthesize(s.arms[0].body)

proc columnDomains(tc: TypeChecker, d: Decl, allEnum: var bool,
                   comboCount: var int): seq[seq[string]] =
  ## The values each input column can take. allEnum stays true only when
  ## every column is enumerable (bool / fieldless sum types).
  allEnum = true
  comboCount = 1
  for p in d.fnParams:
    let dom = enumDomain(tc.module, p.typ)
    if dom.len == 0: allEnum = false
    result.add(dom)
    comboCount *= max(dom.len, 1)

proc comboValues(domains: seq[seq[string]], combo: int): seq[string] =
  ## Decode a mixed-radix combination index into one value per column.
  var rem = combo
  for c in countdown(domains.high, 0):
    result.insert(domains[c][rem mod domains[c].len], 0)
    rem = rem div domains[c].len

proc rowMatches(r: DecisionRow, vals: seq[string]): bool =
  ## Does this row fire for this input combination?
  for c in 0 ..< r.pats.len:
    let v = patValue(r.pats[c])
    if v != "_" and v != vals[c]: return false
  true

proc checkRowSymbols(d: Decl, rows: seq[DecisionRow],
                     domains: seq[seq[string]]) =
  ## Symbols in rows must be actual values of the column type.
  for r in rows:
    for c in 0 ..< r.pats.len:
      let v = patValue(r.pats[c])
      if v != "_" and v notin domains[c]:
        fail("Decision Error: '" & v & "' is not a value of " &
             typeName(d.fnParams[c].typ) & " in table '" & d.name & "'", r.span)

proc failGap(d: Decl, vals: seq[string]) =
  ## No row fires for this input combination.
  var desc: seq[string]
  for c in 0 ..< vals.len:
    desc.add(d.fnParams[c].name & ": " & vals[c])
  fail("Decision Error: '" & d.name & "' has a gap — no row matches (" &
       desc.join(", ") & ")", d.span)

proc firstMatchingRow(rows: seq[DecisionRow], vals: seq[string]): int =
  ## The row that fires for this combination, -1 if there is none.
  for i, r in rows:
    if rowMatches(r, vals): return i
  -1

proc checkExactly(d: Decl, rows: seq[DecisionRow], domains: seq[seq[string]],
                  comboCount: int) =
  ## EXACT analysis: every input combination is enumerated, so gaps and
  ## unreachable rows are proven, not approximated.
  checkRowSymbols(d, rows, domains)
  var rowUsed = newSeq[bool](rows.len)
  for combo in 0 ..< comboCount:
    let vals = comboValues(domains, combo)
    let hit = firstMatchingRow(rows, vals)
    if hit < 0: failGap(d, vals)
    rowUsed[hit] = true
  for i, used in rowUsed:
    if not used:
      fail("Decision Error: row " & $(i+1) & " of '" & d.name &
           "' is unreachable — earlier rows cover all its inputs", rows[i].span)

proc coversRow(earlier, later: DecisionRow): bool =
  ## Does an earlier row match everything a later one matches?
  for c in 0 ..< later.pats.len:
    if not patCovers(earlier.pats[c], later.pats[c]): return false
  true

proc checkPairwise(d: Decl, rows: seq[DecisionRow]) =
  ## Open domains: completeness cannot be proven, so check rows against each
  ## other and require a catch-all row.
  for j in 1 ..< rows.len:
    for i in 0 ..< j:
      if coversRow(rows[i], rows[j]):
        fail("Decision Error: row " & $(j+1) & " of '" & d.name &
             "' is unreachable — row " & $(i+1) & " already covers it",
             rows[j].span)
  for p in rows[^1].pats:
    if p != nil and p.kind != pkWild:
      fail("Decision Error: '" & d.name & "' cannot be proven complete — " &
           "end the table with a catch-all row (all _)", d.span)

proc checkDecisionTable(tc: var TypeChecker, d: Decl) =
  ## spec 6.1: row width, unreachable rows, completeness.
  if d.fnBody == nil or d.fnBody.kind != exkBlock or d.fnBody.stmts.len == 0:
    fail("Decision Error: decision table '" & d.name & "' has no rows", d.span)
  let rows = tc.collectRows(d)
  var allEnum = true
  var comboCount = 1
  let domains = tc.columnDomains(d, allEnum, comboCount)
  if allEnum and comboCount <= MaxEnumeratedCombos:
    checkExactly(d, rows, domains, comboCount)
  else:
    checkPairwise(d, rows)

proc checkDecl(tc: var TypeChecker, d: Decl) =
  if d == nil: return
  case d.kind
  of dkFn:
    if d.isDecision:
      tc.checkDecisionTable(d)
      return
    checkFallibleNeedsIo(d.name, d.fnReturnType, d.fnEffects, d.span)
    tc.currentErrTypes = d.fnErrorTypes
    tc.checkFnBody(d.name, d.fnParams, d.fnReturnType, d.fnBody, d.fnGenerics)
    tc.currentErrTypes = @[]
  of dkTask:
    checkFallibleNeedsIo(d.name, d.taskReturnType, d.taskEffects, d.span)
    tc.checkFnBody(d.name, d.taskParams, d.taskReturnType, d.taskBody)
  of dkExpr: discard tc.synthesize(d.expr)
  of dkObject:
    tc.pushScope()
    for f in d.objFields: tc.bindName(f.name, f.typ, true)
    # member fns see the object itself as a mutable `self`
    tc.bindName("self", Type(span: d.span, kind: tkNamed, name: d.name), true)
    for m in d.objMembers: tc.checkDecl(m)
    tc.popScope()
  of dkMixin, dkExtern, dkPending:
    for m in d.mixinMembers: tc.checkDecl(m)
  of dkActor:
    tc.pushScope()
    for f in d.actorFields: tc.bindName(f.name, f.typ, true)
    for h in d.handlers:
      # `result` inside a handler IS its declared return type. Nothing bound it,
      # so it synthesized as Unknown and every assignment to it was accepted.
      # A handler with no return type gets no binding at all, which makes
      # `result = ...` the undeclared-name error it should be.
      tc.pushScope()
      if h != nil and h.kind == dkFn and h.fnReturnType != nil:
        tc.bindName("result", h.fnReturnType, true)
      tc.checkDecl(h)
      tc.popScope()
    tc.popScope()
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
  of exkField:
    # unit sugar (5.ms) and field reads over const sub-expressions
    if e.receiver != nil: constCheck(tc, m, cname, e.receiver, sp)
    if e.receiver != nil and e.receiver.kind == exkLit and
       tc.isIoFn(e.fieldName):
      fail("Const Error: 'const " & cname & "' must be pure — '" &
           e.fieldName & "' is [io]", sp)
  of exkCall:
    for a in e.args: constCheck(tc, m, cname, a, sp)
    if e.callee != nil and e.callee.kind == exkVar:
      let callee = e.callee.name
      if callee in ["bake", "merge", "alias"]: discard
      elif tc.typeDecls.hasKey(callee) and
           tc.typeDecls[callee].kind == tkRecord:
        fail("Const Error: 'const " & cname & "' cannot hold a " &
             "record construction (records are reference values) — " &
             "use a plain struct literal", sp)
      elif tc.distinctNames.contains(callee): discard  # base conversion
      elif tc.isIoFn(callee):
        fail("Const Error: 'const " & cname & "' must be pure — '" &
             callee & "' is [io]", sp)
      elif m.findDecl(dkFn, callee) == nil and
           not tc.typeDecls.hasKey(callee):
        fail("Const Error: 'const " & cname & "' needs declared pure " &
             "fns — '" & callee & "' is unknown", sp)
    elif e.callee != nil and e.callee.kind == exkField:
      # {payload} Type.Variant — sum variants are value objects: fine
      discard
  else:
    fail("Const Error: 'const " & cname & "' must be a pure " &
         "compile-time expression", sp)

proc typecheckModule*(m: Module,
                      externSigs = initTable[string, FnSig](),
                      externPending = initTable[string, Span]()): seq[string] {.discardable.} =
  var tc = TypeChecker(module: m,
                       fnSigs: externSigs,
                       pendingFns: externPending,
                       typeDecls: initTable[string, Type](),
                       distinctNames: initHashSet[string](),
                       errPolicy: "strict")
  for qualName in externSigs.keys:
    if "::" in qualName:
      tc.knownModules.incl(qualName.split("::")[0])
  tc.pushScope()  # module-level scope: consts visible across decls
  tc.collectSigs(m.decls)
  tc.resolveTypeNames(m)
  tc.checkPointers(m)      # pointers may not escape the extern boundary
  tc.checkConformance(m)   # `satisfies I` means every I member is implemented
  # const declarations are bound BEFORE body checks so any fn can reference
  # them; constCheck says what a const is allowed to be.
  for d in m.decls:
    if d != nil and d.kind == dkConst:
      constCheck(tc, m, d.name, d.constVal, d.span)
      tc.bindName(d.name, tc.synthesize(d.constVal), false)
  # Either/or namespace: a declared field name may not shadow a declared fn —
  # `.name` resolves by lookup, so a clash would silently change meaning.
  for d in m.decls:
    if d == nil: continue
    for f in d.declaredFields():
      if tc.fnSigs.hasKey(f.name):
        fail("Type Error: field '" & f.name & "' of '" & d.name & "' has " &
             "the same name as a declared fn — rename one; fields and fns " &
             "share the call namespace", d.span)
  for d in m.decls:
    # Module top level is declarations only — the runnable program lives in
    # `fn main`. (User ruling 2026-07-13: no top-level statements, not even
    # pure lets; `tuck build` without main = library.)
    if d != nil and d.kind == dkExpr:
      fail("Structure Error: top-level statements are not allowed — move " &
           "this into `fn main` (a module is declarations; main is the " &
           "program)", d.span)
    tc.checkDecl(d)
  if tc.errPolicy == "strict" and tc.unhandledSites.len > 0:
    fail("Type Error: " & $tc.unhandledSites.len & " unhandled error result(s)" &
         " — bind, pass on, or propagate with '?' (policy: strict):\n  " &
         tc.unhandledSites.join("\n  "), m.span)
  if tc.errPolicy in ["continue", "exit"]:
    return tc.unhandledSites

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

proc typecheckProgram*(mods: seq[tuple[name, path: string, m: Module]],
                       preSigs = initTable[string, seq[SigInfo]]()): seq[string] {.discardable.} =
  # one semantic layer per program; clear any previous run's entries
  resetResolution()
  checkErrCodeCollisions(mods)
  var sigsByMod = initTable[string, Table[string, FnSig]]()
  var pendByMod = initTable[string, Table[string, Span]]()
  var importsByMod = initTable[string, seq[string]]()
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
      err.msg = path & ":" & $err.line & ":" & $err.col & ": " & err.msg
      raise
    sigsByMod[name] = tc.fnSigs
    pendByMod[name] = tc.pendingFns
    var imps: seq[string]
    for d in m.decls:
      if d != nil and d.kind == dkImport: imps.add(d.name)
    importsByMod[name] = imps
  for (name, path, m) in mods:
    # `import fs` brings fs's public fns into scope UNQUALIFIED — the
    # idiomatic form (`readFile`, not `fs::readFile`) — same as most
    # languages. The qualified key is always added too, since `::` is still
    # how a caller disambiguates a genuine collision between two imports.
    # A LOCAL declaration of the same name wins: collectSigs runs after this
    # table seeds tc.fnSigs, so a same-named local overwrites the bare key.
    var extern = initTable[string, FnSig]()
    var externPend = initTable[string, Span]()
    var bareOwner = initTable[string, string]()  # bare name -> which import
    for imp in importsByMod[name]:
      template addBare(fname: string, sig: FnSig) =
        if bareOwner.hasKey(fname) and bareOwner[fname] != imp:
          fail("Type Error: '" & fname & "' is exported by both '" &
               bareOwner[fname] & "' and '" & imp & "' — call it as '" &
               bareOwner[fname] & "::" & fname & "' or '" & imp & "::" &
               fname & "' to disambiguate", Span())
        elif not bareOwner.hasKey(fname):
          bareOwner[fname] = imp
          extern[fname] = sig
      if sigsByMod.hasKey(imp):
        for fname, sig in sigsByMod[imp]:
          if "::" notin fname:
            extern[imp & "::" & fname] = sig
            addBare(fname, sig)
        for fname, sp in pendByMod.getOrDefault(imp):
          if "::" notin fname:
            externPend[imp & "::" & fname] = sp
      else:
        for si in preSigs.getOrDefault(imp):
          if "::" notin si.name:
            let sig: FnSig = (si.params, si.ret, si.generics, si.effects)
            extern[imp & "::" & si.name] = sig
            addBare(si.name, sig)
            if si.isPending:
              externPend[imp & "::" & si.name] = Span(line: si.line, col: 1)
    try:
      result = typecheckModule(m, extern, externPend)
    except SemanticError as err:
      err.msg = path & ":" & $err.line & ":" & $err.col & ": " & err.msg
      raise
