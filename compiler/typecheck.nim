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
# Split so this one stays about RULES rather than plumbing:
#   typecheck_state.nim        the TypeChecker object, scopes, lookups
#   typecheck_util.nim         small shared predicates (isWrapper, isUninit, fail)
#   typecheck_flow.nim         pure pre-passes: transitions, callee scans, exits
#   typecheck_conformance.nim  `satisfies` — does this object meet the contract
#   typecheck_pointers.nim     where a raw pointer may and may not appear
#   typecheck_decisions.nim    decision-table coverage and overlap
#   typecheck_transitions.nim  validating a `transitions:` block's own shape
#   typecheck.nim              the rules themselves
#
# ---------------------------------------------------------------------------
# THE MAP. This file is long; these are its parts, in order. Grep `# === ` to
# move between them.
#
#   THE COMPATIBILITY RELATION   may this type flow where that one is wanted
#   FIELD ACCESS                 the seven meanings of `a.b`, in priority order
#   REGISTERS / MMIO             bit ranges and [read]/[write] permissions
#   OPERATORS                    arithmetic, division, comparison, boolean
#   BRANCHES, MATCH, THE MERGE   where per-variable knowledge forks and rejoins
#   CHAINS AND MUTATION          `..field {v}` / `..fn`, and what a write means
#   CALL SYNTHESIS               construction vs builtin vs plain call
#   THE SPINE                    one synth* per ExprKind — the walk itself
#   SIGNATURE COLLECTION         the pre-pass, and per-declaration validators
#   CONST PURITY                 a const may not call into the world
#   PROGRAM DRIVER               run the passes over every module, in order
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
import ast, semantics, lowering, tables, strutils, sets, sequtils
import resolution
import ast_query
import rewrite   # isLiteralPayload — recognize the wrap the pass introduced
import typecheck_util
export typecheck_util
import typecheck_state
export typecheck_state
import typecheck_flow
export typecheck_flow
import typecheck_transitions  # spec 4.4 sum-type transition graph
import typecheck_decisions    # spec 6.1 decision-table analysis
import typecheck_pointers     # pointers stay at the extern boundary
import typecheck_recursion    # a type may not contain itself by value
import typecheck_conformance  # spec 5.2 `satisfies` verification
import ./typecheck_compat
import ./typecheck_collect
import ./typecheck_registry
import ./typecheck_module
export typecheck_transitions

# UnknownName now lives in ast.nim (codegen needs it for typed-AST checks)
# Stateless helpers now live in typecheck_util; the TypeChecker state object +
# scope/resolve/fieldsOf now live in typecheck_state (both imported above).
# The compatibility relation (`compatible` and its helpers) now lives in
# typecheck_compat.nim, imported above.






proc synthesize(tc: var TypeChecker, e: Expr): Type
proc synthBracket(tc: var TypeChecker, e: Expr): Type
proc synthBracketAssign(tc: var TypeChecker, e: Expr): Type
proc checkCallArgs(tc: var TypeChecker, fnName: string, sig: FnSig, e: Expr,
                   bindings: var Table[string, Type])  # asSlotInvoke calls it

# === FIELD ACCESS: WHAT `a.b` MEANS ========================================
# The ordered dispatch documented at the top of this file — seven different
# things share one spelling, and the ORDER is the language rule. Each `as*`
# arm returns nil for "not mine"; the first non-nil wins.

# Method form: `x .fn {args}` / `x ..fn {args}` — the receiver rides as the
# fn's FIRST parameter (checked structurally when the receiver type has no
# name), the braced struct fills the remaining parameters by name. Builds and
# returns the positional exkCall node (receiver, then declared-order args),
# ty-stamped with the fn's return type — codegen emits it as-is.
proc failIfReceiverSlotMismatched(tc: var TypeChecker, fnName: string,
                                  sig: FnSig, recvT: Type, sp: Span): bool =
  ## Which slot the receiver of `d.crank {step: 1}` fills depends on whether
  ## `fnName` is a TOP-LEVEL fn or an OBJECT MEMBER — two genuinely
  ## different conventions synthMethodCall serves, told apart by
  ## `tc.topLevelFns` (populated only for top=true declarations;
  ## collectFnSig's own comment names object/type members as excluded).
  ##
  ## - A TOP-LEVEL fn used as a mutator (spec 5.1: "mutators take the
  ##   receiver as their first param") — `fn withPort({count: int, value:
  ##   int}) -> Server` called `server ..withPort {80}`. The receiver ALWAYS
  ##   fills params[0], whatever it happens to be named (a top-level fn may
  ##   spell it "self" explicitly — `fn loadEpisode({self: App, ...})` — or
  ##   not, as here; either way it is the receiver's slot and gets checked
  ##   against it), and the payload fills params[1..] by name.
  ## - An OBJECT MEMBER fn, whose self is either an EXPLICIT first param
  ##   (interface implementations declare `{self: Self}`, so the contract
  ##   has something to check) or IMPLICIT — added later, during lowering
  ##   (normalizeSelf), not something this signature carries at all. Only
  ##   when the member itself names its first param "self" does the
  ##   receiver get checked here and that param excluded from the by-name
  ##   match below; otherwise self is fully absent from sig.params and
  ##   EVERY declared param is matched by name, from index 0.
  ##
  ## Returns whether the receiver fills params[0] (so the caller knows
  ## where the by-name match should start). Collapsing member fns into the
  ## top-level rule (an earlier version of this fix did, checking only the
  ## first param's NAME) broke exactly the mutator convention above:
  ## `withPort`'s first param is "count", not "self", so it read as a
  ## member with implicit self and skipped the type check spec 5.1
  ## requires ("first parameter expects Server but the receiver is ..."
  ## never fired, when it should have).
  let isTopLevel = fnName in tc.topLevelFns
  if isTopLevel and sig.params.len == 0:
    fail("Type Error: '" & fnName & "' takes no parameters — it cannot be " &
         "called as a method on " & typeName(recvT), sp)
  let selfIsExplicit = sig.params.len > 0 and sig.params[0].name == "self"
  result = isTopLevel or selfIsExplicit
  if result and not tc.compatible(recvT, sig.params[0].typ):
    fail("Type Error: '" & fnName & "' first parameter expects " &
         typeName(sig.params[0].typ) & " but the receiver is " &
         typeName(recvT), sp)

proc synthMethodCall(tc: var TypeChecker, fnName: string, receiver: Expr,
                     recvT: Type, argStruct: Expr, sp: Span): Expr =
  ## `d.crank {step: 1}` — the receiver fills a slot, the payload fills the
  ## rest by name. See failIfReceiverSlotMismatched for which slot and why.
  let sig = tc.fnSigs[fnName]
  let receiverFillsFirstParam =
    tc.failIfReceiverSlotMismatched(fnName, sig, recvT, sp)
  var argFields: seq[FieldInit]
  if argStruct != nil:
    if argStruct.kind != exkStruct:
      fail("Type Error: arguments to '" & fnName &
           "' must be a struct literal: {name: value, ...}", argStruct.span)
    argFields = argStruct.fields
  var args: seq[Expr] = @[receiver]
  let startAt = if receiverFillsFirstParam: 1 else: 0
  for i in startAt ..< sig.params.len:
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
  if e.receiver.kind != exkVar or not tc.isNarrowed(e.receiver.name):
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
  else: Type(span: e.span, kind: tkNamed, name: "u16")
    # .err — the runtime's real carrier type (TuckResult.err: uint16,
    # tuck_rt.nim). `match r.err:` validates its arms against the fn's
    # declared [error: E] enum separately (matchErrEnums, keyed off the
    # RECEIVER's name, not this synthesized type), so giving `.err` its
    # real numeric type here does not touch that path — it only means a
    # dynamic re-raise (`err resp.err`) carries a real type instead of
    # riding the checker's own "could not work it out" sentinel through
    # to codegen.

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
  ## Also nil whenever an explicit payload is attached (`.fn {args}` —
  ## `d.crank {step: 1}`): that is the METHOD form, always handled by
  ## asFnByName's synthMethodCall (receiver fills self, the payload fills
  ## the rest), never "the bare receiver IS the one declared param" this
  ## proc exists for. Without this guard, a member fn with exactly one
  ## SOURCE-visible param (self is added later, by lowering, not something
  ## the checker's signature carries here) read as sig.params.len == 1 and
  ## got claimed here first — checking the receiver's type against the
  ## payload's own param instead of against self, and failing with a
  ## confusing "expects int but got Deck".
  if tc.currentFn == "" or e.receiver == nil or e.dotArg != nil or
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

proc failUninitRead(name: string, t: Type, sp: Span) =
  ## Reading a field the construction never supplied.
  ##
  ## The READ is the error, not the omission: an untouched hole is legal, so
  ## the message names what to do about it rather than scolding the
  ## construction.
  fail(dcTyUninitRead,
       "'" & name & "' is " & UninitName & " here — it was not " &
       "supplied at construction and nothing has assigned it since. Set it " &
       "first (`" & name & " = ...` or `.." & name & " {...}`), or declare " &
       "it '" & typeName(unwrapUninit(t)) & "?' if it is genuinely optional",
       sp)

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
    if isUninit(f.typ): failUninitRead(e.fieldName, f.typ, e.span)
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

proc asStaticMemberCall(tc: var TypeChecker, e: Expr): Type =
  ## `Pool.acquire` / `Pool.release {v}` (spec 7.2) — a STATIC member call on a
  ## singleton type, the way `StaticClass.method` reads elsewhere. The receiver
  ## is the pool ITSELF, not a value whose type carries the fn, so the signature
  ## is registered under `Owner.member` (collectPoolSigs).
  ##
  ## NOT qualification. Module qualification is `::` — a separate token
  ## (tkColonColon) producing exkQualified with a modulePath. This `.` is
  ## ordinary field-access syntax whose receiver happens to name a type. The
  ## proc was called asQualifiedMemberCall, which read as though the two were
  ## the same mechanism; they are not, and never were.
  if e.receiver == nil or e.receiver.kind != exkPoolRef: return nil
  let qualified = e.receiver.refName & "." & e.fieldName
  if not tc.fnSigs.hasKey(qualified): return nil
  let extra = unwrapSingleField(e.dotArg)
  let args = if extra != nil: @[e.receiver, extra] else: @[e.receiver]
  setCall(semLayer, e, Expr(span: e.span, kind: exkCall, args: args,
                            callee: Expr(span: e.span, kind: exkVar,
                                         name: e.fieldName)))
  tc.fnSigs[qualified].ret

proc genericFnSigSig(tc: TypeChecker, name: string, args: seq[Type],
                     sp: Span): FnSig =
  ## `Mapper[int, str]`'s concrete signature: substitute the fnsig's own
  ## declared generics (`fnSigGenerics[name]`) with the SLOT's own type args
  ## directly — known outright from where the slot is declared, unlike an
  ## ordinary generic call's params, which infer bindings from arguments.
  let gs = tc.fnSigGenerics[name]
  if gs.len != args.len:
    fail("Type Error: '" & name & "' takes " & $gs.len &
         " type argument(s), got " & $args.len, sp)
  var b = initTable[string, Type]()
  for i in 0 ..< gs.len: b[gs[i]] = args[i]
  let base = tc.fnSigs[name]
  var params: seq[Param]
  for p in base.params:
    params.add(Param(name: p.name, typ: substituteType(p.typ, b), span: p.span))
  (params, substituteType(base.ret, b), newSeq[string](), base.effects)

proc checkThroughFnSig(tc: var TypeChecker, slotT: Type, call: Expr): Type =
  ## A call THROUGH a slot whose type is a `fnsig` NAME — bare (`Adder`) or
  ## generic-instantiated (`Mapper[int, str]`): validate the arguments
  ## against the named signature and yield its return type. nil when the slot
  ## names no signature, so the caller can decide what an untyped slot means.
  ## Shared by both spellings of the same operation — `{args} c.op`
  ## (asIndirectCall) and `c.op.invoke {args}` (asSlotInvoke).
  var name = ""
  var sig: FnSig
  if slotT != nil and slotT.kind == tkNamed and slotT.name in tc.fnSigNames:
    name = slotT.name
    sig = tc.fnSigs[name]
  elif slotT != nil and slotT.kind == tkApp and slotT.base != nil and
       slotT.base.kind == tkNamed and slotT.base.name in tc.fnSigNames and
       tc.fnSigGenerics.hasKey(slotT.base.name):
    name = slotT.base.name
    sig = tc.genericFnSigSig(name, slotT.args, slotT.span)
  else:
    return nil
  var bindings = initTable[string, Type]()
  tc.checkCallArgs(name, sig, call, bindings)
  sig.ret

proc invokeArgs(tc: var TypeChecker, e: Expr): seq[Expr] =
  ## The braced payload of `slot.invoke {a, b}`, synthesized. Empty for a
  ## nullary invoke.
  if e.dotArg == nil: return @[]
  if e.dotArg.kind != exkStruct:
    fail("Type Error: invoke arguments must be a struct literal: " &
         "slot.invoke {a, b}", e.dotArg.span)
  discard tc.synthesize(e.dotArg)
  @[e.dotArg]

proc asSlotInvoke(tc: var TypeChecker, e: Expr): Type =
  ## `slot.invoke {args}` — a call through a baked fn slot. A slot typed by a
  ## `fnsig` is checked against that signature; an untyped one has nothing to
  ## check against and stays gradual.
  if e.fieldName != "invoke": return nil
  let slotT = tc.resolve(tc.synthesize(e.receiver))
  let call = Expr(span: e.span, kind: exkCall, callee: e.receiver,
                  args: tc.invokeArgs(e))
  setCall(semLayer, e, call)
  result = tc.checkThroughFnSig(slotT, call)
  if result == nil: result = unknownType(e.span)

type Diag = tuple[code: DiagCode, msg: string]
  ## A diagnostic under construction: the code to look up, and what to say.
  ## An empty msg means "nothing definite enough to report".

proc missingFieldMessage(e: Expr, recvT: Type, fields: seq[FieldDef]): Diag =
  ## Known record, missing field, no matching fn: the payoff error. Sum types
  ## carry variant fields we don't track per-variant in v1, so only a plain
  ## record is flagged; anything else falls through to gradual typing.
  if fields.len == 0: return (dcNone, "")
  if recvT.kind != tkRecord: return (dcNone, "")
  (dcTyNoField, "no field '" & e.fieldName & "' on type " & typeName(recvT))

proc unresolvedFieldMessage(e: Expr, recvT: Type, fields: seq[FieldDef]): Diag =
  ## Why `x.name` resolved to nothing, most specific reason first.
  if e.dotArg != nil:
    # `.fn {args}` — the brace proves call intent (ruling 2026-07-23), so this
    # is an undeclared CALL, not a field read to fall through on.
    return (dcTyUndeclared,
            "'" & e.fieldName & "' is called with arguments here but is not " &
            "declared — a `.fn {args}` call needs a declared fn (add one, or " &
            "a `pending:` stub)")
  if isLiteralPayload(e.receiver):
    # The rewrite pass turned a bare literal receiver into the payload
    # `{value: n}` (`5.ms` is `{value: 5} .ms`), so by here BOTH lookups have
    # failed: no field of that record, and no fn in scope. Say both, and name
    # the likeliest cause — an unimported helper is how this reads in
    # practice. missingFieldMessage would instead describe a wrap the user
    # never wrote.
    return (dcTyUndeclared,
            "'" & e.fieldName & "' is neither a field of " & typeName(recvT) &
            " nor a fn in scope — a literal applied to a name wraps as that " &
            "payload, so `" & e.fieldName & "` must be a declared fn. Is an " &
            "`import` missing?")
  missingFieldMessage(e, recvT, fields)

proc failUnresolvedFieldAccess(tc: TypeChecker, e: Expr, recvT: Type,
                               fields: seq[FieldDef]) =
  ## `x.name` matched no field and no fn. Report the most specific reason —
  ## every arm of synthFieldAccess has already declined, so this is the end of
  ## the line and a vague message here is what the user is left with.
  ##
  ## Pick the diagnostic, then fail once.
  let d = unresolvedFieldMessage(e, recvT, fields)
  if d.msg.len > 0: fail(d.code, d.msg, e.span)

proc syntacticFieldForm(tc: var TypeChecker, e: Expr): Type =
  ## The arms that read `x.name` from its SHAPE alone, before the receiver's
  ## type is known. First non-nil wins; nil means none of them claimed it.
  result = tc.asResultIntrospection(e)
  if result == nil: result = tc.asSlotInvoke(e)
  if result == nil: result = tc.asPostfixApplication(e)
  if result == nil: result = tc.asVariantConstruction(e)

proc typedFieldForm(tc: var TypeChecker, e: Expr, recvT: Type,
                    fields: seq[FieldDef]): Type =
  ## The arms that need the receiver's TYPE. Order matters once: an interface
  ## receiver must resolve against its CONTRACT before asFnByName, which looks
  ## the bare name up in the flat signature table and would find whichever
  ## object declared one — rejecting the receiver ("expects Dog but got
  ## Animal"), or worse, silently picking the wrong object's member.
  result = tc.asPlainField(e, fields, recvT)
  if result == nil: result = tc.asStaticMemberCall(e)
  if result == nil: result = tc.asInterfaceCall(e, recvT)
  if result == nil: result = tc.asFnByName(e, recvT)

const RegisterWidth = 32
  ## Bits in a memory-mapped register. Not declared per register today — the
  ## targets §8.1 names (STM32, RP2040, Cortex-M generally) are 32-bit MMIO,
  ## and the Nim backend's registerMMIO macro assumes it. If a register ever
  ## needs another width, this becomes an attribute rather than a constant.

# === REGISTERS / MMIO (spec 8.1) ===========================================
# A `register` type maps named bit ranges onto a hardware word. Self-contained
# bit arithmetic plus the [read]/[write] permission check — the only
# per-field permission rule in the checker that comes from a DECLARATION
# rather than from flow.

proc regBits(f: FieldDef): tuple[lo, hi: int, ok: bool] =
  ## The bit range a register field occupies. The parser keeps it in the
  ## field's type NAME — "bit 0" or "bits 3..7" — so this is where that
  ## spelling gets turned back into numbers.
  if f.typ == nil or f.typ.kind != tkNamed: return (0, 0, false)
  let spec = f.typ.name.replace("bits ", "").replace("bit ", "").strip()
  try:
    if ".." in spec:
      let parts = spec.split("..")
      if parts.len != 2: return (0, 0, false)
      return (parseInt(parts[0].strip()), parseInt(parts[1].strip()), true)
    let one = parseInt(spec)
    return (one, one, true)
  except ValueError:
    return (0, 0, false)

proc checkRegisterDecl(d: Decl) =
  ## spec 8.1: a register's fields describe real hardware, so the layout has
  ## to be one the hardware could have — bits inside the register, and no two
  ## fields claiming the same bit.
  ##
  ## Neither was checked. `bit 99` emitted a mask no hardware has, and two
  ## fields overlapping meant writing one silently corrupted the other, which
  ## is exactly the datasheet-transcription slip a compiler should catch.
  var owner: array[RegisterWidth, string]
  for f in d.regFields:
    let (lo, hi, ok) = regBits(f)
    if not ok: continue        # malformed spec — the parser reports its own
    if lo < 0 or hi >= RegisterWidth or lo > hi:
      fail(dcReBitRange,
           "register '" & d.name & "', field '" & f.name & "': bits " &
           $lo & ".." & $hi & " do not fit a " & $RegisterWidth &
           "-bit register (valid bits are 0.." & $(RegisterWidth - 1) & ")",
           f.span)
    for b in lo .. hi:
      if owner[b] != "":
        fail(dcReOverlap,
             "register '" & d.name & "': fields '" & owner[b] & "' and '" &
             f.name & "' both claim bit " & $b & " — writing one would " &
             "corrupt the other", f.span)
      owner[b] = f.name

proc registerFieldAccess(m: Module, regName, fieldName: string):
    tuple[found, canRead, canWrite: bool] =
  ## What a register field permits. No `[read]`/`[write]` attribute at all
  ## means both, which is how the corpus writes a plain field.
  for d in m.decls:
    if d == nil or d.kind != dkRegister or d.name != regName: continue
    for f in d.regFields:
      if f.name != fieldName: continue
      var sawRead, sawWrite = false
      for a in f.attrs:
        if a.name == "read": sawRead = true
        elif a.name == "write": sawWrite = true
      if not sawRead and not sawWrite: return (true, true, true)
      return (true, sawRead, sawWrite)
  (false, false, false)

proc actorFieldType(m: Module, actorName, fieldName: string): Type =
  ## An actor singleton's own declared field type (`Counter.total`) — nil
  ## if `actorName` names no actor, or that actor has no such field.
  for d in m.decls(dkActor):
    if d.name != actorName: continue
    for f in d.actorFields:
      if f.name == fieldName: return f.typ
  nil

proc registerFieldType(m: Module, regName, fieldName: string, span: Span): Type =
  ## A register field's type — matching what the generated accessor
  ## actually returns (genRegister/genDRegister's bitGetter/dBitGetter): a
  ## single `bit N` reads as `bool`, a `bits LO..HI` range reads as `u32`.
  ##
  ## Without this, `DAC_CR.EN` fell through synthVar's ordinary bare-name
  ## resolution — a register is a DECLARATION, not a local, fn or sum
  ## variant, so it silently became `unknownType`, the exact fallback
  ## `discard` was riding (see synthBareVariant). Harmless for Nim (no
  ## explicit type needed) and Odin (`:=` infers from the accessor call's
  ## own native return type), but D's "never `auto`, state the checker's
  ## type explicitly" policy turns it into a real failure: `let en =
  ## DAC_CR.EN` had no type to declare `en` with.
  for d in m.decls:
    if d == nil or d.kind != dkRegister or d.name != regName: continue
    for f in d.regFields:
      if f.name != fieldName: continue
      let (lo, hi, ok) = regBits(f)
      if not ok: return unknownType(span)
      return Type(span: span, kind: tkNamed,
                  name: (if lo == hi: "bool" else: "u32"))
  nil

proc failIfRegisterAccess(tc: var TypeChecker, e: Expr) =
  ## spec 8.1: "Writing to a read-only field is a compile error. Reading a
  ## write-only field is a compile error." Neither was one — a `[read]` field
  ## took a write and emitted it, so the promise in the spec was prose.
  ##
  ## A register write is a chain step (`DAC_CR ..EN {false}`); a read is an
  ## ordinary field access (`DAC_CR.EN`). Both are recognised by the RECEIVER
  ## naming a `register` declaration, which is unambiguous: a register is a
  ## declaration, not a value, so nothing else can be named there.
  if e == nil: return
  if e.kind == exkChain and e.base != nil and e.base.kind == exkRegisterRef:
    for step in e.steps:
      if step.op != coDotDot or step.target == nil: continue
      let acc = registerFieldAccess(tc.module, e.base.refName, step.target.name)
      if acc.found and not acc.canWrite:
        fail(dcReReadOnly,
             "register field '" & e.base.refName & "." & step.target.name &
             "' is declared [read] — writing it is a compile error (spec " &
             "§8.1). On hardware the write is ignored or has an undocumented " &
             "side effect", step.span)
  if e.kind == exkField and e.receiver != nil and e.receiver.kind == exkRegisterRef:
    let acc = registerFieldAccess(tc.module, e.receiver.refName, e.fieldName)
    if acc.found and not acc.canRead:
      fail(dcReWriteOnly,
           "register field '" & e.receiver.refName & "." & e.fieldName &
           "' is declared [write] — reading it is a compile error (spec " &
           "§8.1); a write-only field reads back undefined", e.span)

proc registryEventOwner(variant: string): string =
  ## Mirrors sumTypeOwning, for the ONE OTHER place a bare Capitalized name
  ## is a value: a registry's own declared event (spec Part 10). Reuses
  ## resolve_refs.nim's whole-program registryNames table (already resolves
  ## a registry declared in an imported module, which a tc.module.decls
  ## scan would miss). "A program declares ONE registry" (checkRegistry's
  ## own RULE 1) means there is at most one to check here, unlike sum
  ## types' first-wins scan across possibly many.
  for name, d in semLayer.registryNames:
    for v in d.variants:
      if v.name == variant: return name
  ""

proc synthFieldAccess(tc: var TypeChecker, e: Expr): Type =
  ## `x.name` is many things — a field read, a call, a variant construction, an
  ## interface dispatch. Try them in two groups: what the syntax alone can
  ## settle, then what needs the receiver's type.
  tc.failIfRegisterAccess(e)   # spec 8.1: no reading a [write] field
  if e.receiver != nil and e.receiver.kind == exkRegisterRef:
    let regT = registerFieldType(tc.module, e.receiver.refName, e.fieldName, e.span)
    if regT != nil: return regT
  if e.receiver != nil and e.receiver.kind == exkActorRef:
    let actT = actorFieldType(tc.module, e.receiver.refName, e.fieldName)
    if actT != nil: return actT
  if e.receiver != nil and e.receiver.kind == exkRegistryRef and
     e.fieldName == "raise":
    # `Registry.raise` — not a real field, the raise-call grammar's own
    # marker (lowering.flattenRegistryRaise/raisedEventsIn read the AST
    # shape directly, never this type). `unit`, matching the whole raise
    # call's own type (asNamedCallee's registryEventOwner branch) — never
    # a real value, so never something a real type should be built for.
    return Type(span: e.span, kind: tkNamed, name: "unit")
  if e.receiver != nil and e.receiver.kind == exkVar and e.receiver.name == "Error":
    # `Error.name` (spec 4.9) — the app-wide error namespace, hashed to a
    # numeric code at emit time (codegen*.nim's own isErrorDotRef/
    # genReturn special-case, matched the SAME way: receiver named
    # literally "Error", never a real declaration). u16 matches the same
    # runtime carrier type `.err` already resolves to (asResultIntrospection).
    return Type(span: e.span, kind: tkNamed, name: "u16")
  result = tc.syntacticFieldForm(e)
  if result != nil: return
  let rawT = tc.synthesize(e.receiver)
  if isWrapper(rawT):
    fail("Type Error: unhandled " & typeName(rawT) &
         " — pass it to a handling function or propagate with '?' before accessing fields", e.span)
  let recvT = tc.resolve(rawT)
  let fields = tc.fieldsOf(recvT)
  result = tc.typedFieldForm(e, recvT, fields)
  if result != nil: return
  tc.failUnresolvedFieldAccess(e, recvT, fields)
  return unknownType(e.span)

# === OPERATORS =============================================================
# Arithmetic, division (`/i` vs `/f` — Tuck has no bare `/`), comparison,
# ranges, boolean ops. Mostly small: both operands must agree, and an
# unhandled !T/?T may not reach an operator at all.

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
     not tc.isNarrowed(cond.receiver.name):
    cond.receiver.name
  else: ""

# === BRANCHES, MATCH, AND THE MERGE ========================================
# Where the checker's per-variable knowledge FORKS and rejoins. Each branch
# runs from the same entry state and the exits are merged; getting the merge
# wrong is how narrowing or variant state leaks across a branch it should not.
# The three join sites (if/else, match arms, loop body) are all here.

proc synthBranches(tc: var TypeChecker, e: Expr, guard: string): (Type, Type) =
  ## Both branches from the same entry state; the after-if state is their union.
  if guard != "": tc.setNarrowed(guard, true)
  let entryVariants = tc.varVariants
  let thenT = tc.synthesize(e.thenBranch)
  let thenVariants = tc.varVariants
  if guard != "": tc.setNarrowed(guard, false)
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

proc bindArmPattern(tc: var TypeChecker, arm: MatchArm, subjT: Type,
                    trackedVar, trackedType: string) =
  ## A variant pattern narrows the subject and does NOT bind the name;
  ## v1: any other pattern-bound name enters scope as Unknown.
  ##
  ## "Is this pattern a real variant" and "should reassignment through it
  ## be TRACKED" are two different questions — trackedVar/trackedType only
  ## answer the second one (spec 4.4b's reassignment bookkeeping, which
  ## needs a NAMED sum type with a `transitions:` block). The first
  ## question is answered directly from subjT, which works for an INLINE
  ## sum type too (`state: {Red, Yellow, Green}` has no name to look up in
  ## tc.typeDecls at all) — a real variant with nothing to track just skips
  ## the tracking half, same as a named-but-transitionless sum type already
  ## does today.
  if arm.pattern == nil or arm.pattern.kind != pkVar: return
  # A NAMED sum type's subject synthesizes as `tkNamed "Door"`, not the
  # tkSum body directly (only an INLINE sum field type — no name to look
  # up at all — synthesizes AS its own tkSum body). tc.resolve unwraps the
  # name for the named case and is a no-op for the inline one (already not
  # tkNamed), so one call covers both.
  let subjBody = tc.resolve(subjT)
  if subjBody != nil and subjBody.kind == tkSum and
     hasVariant(subjBody, arm.pattern.name):
    if trackedVar != "": tc.varVariants[trackedVar] = @[arm.pattern.name]
  else:
    tc.bindName(arm.pattern.name, unknownType(arm.pattern.span), false)

proc synthArm(tc: var TypeChecker, arm: MatchArm, subjT: Type, trackedVar,
              trackedType: string): Type =
  ## One arm, typed in its own scope with the subject narrowed.
  tc.pushScope()
  tc.bindArmPattern(arm, subjT, trackedVar, trackedType)
  let savedSubjectType = tc.expectedVariantType
  tc.expectedVariantType = subjT
  result = tc.synthesize(arm.body)
  tc.expectedVariantType = savedSubjectType
  tc.popScope()

proc unifyArmType(tc: var TypeChecker, armT: var Type, t: Type, sp: Span) =
  ## Every arm must produce the same type.
  if not isUnknown(t) and not isUnknown(armT) and
     not tc.compatible(t, armT) and not tc.compatible(armT, t):
    fail("Type Error: match arms produce different types: " &
         typeName(armT) & " vs " & typeName(t), sp)
  if isUnknown(armT): armT = t

proc synthArms(tc: var TypeChecker, e: Expr, subjT: Type, trackedVar,
               trackedType: string): Type =
  ## Type every arm from the same entry state; the after-match state is the
  ## union of the arm exits (spec 4.4b).
  let entryVariants = tc.varVariants
  var mergedExit: Table[string, seq[string]]
  var firstArm = true
  result = unknownType(e.span)
  for arm in e.arms:
    tc.varVariants = entryVariants
    let t = tc.synthArm(arm, subjT, trackedVar, trackedType)
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
  result = tc.synthArms(e, subjT, trackedVar, trackedType)
  tc.checkExhaustive(e, tc.matchDomain(subjT, trackedType, errEnums))

# === CHAINS AND MUTATION ===================================================
# `x ..field {v}` / `x ..fn`. Who may be written (mutability), what a step
# means (field set vs mutator call), and what a write does to the checker's
# knowledge — transitions taken, <uninit> holes filled.

proc assignRoot*(e: Expr): Expr =
  ## The variable a write ultimately lands on: `c` for `c`, `c.n`, or
  ## `c.inner.n`. Indexing is deliberately NOT followed — `xs[i]` writes
  ## through a collection, which is its own question.
  result = e
  while result != nil and result.kind == exkField and result.receiver != nil:
    result = result.receiver

proc failIfMutatingLet(tc: var TypeChecker, e: Expr) =
  ## Spec 2.3: `..` mutation only on var bindings — and NEVER on a parameter,
  ## which is a value the caller owns (spec §7.1).
  ##
  ## The two rejections are separate because their fixes are: a `let` becomes
  ## a `var`, whereas a parameter can never become one — you copy it. Telling
  ## a user to "use 'var'" on a parameter sends them somewhere that does not
  ## exist.
  ##
  ## The base may be a FIELD PATH, not just a name: `o.i ..n {9}` mutates
  ## through `o` just as surely as `o ..n {9}` does, so this follows the chain
  ## to its root binding rather than bailing on anything that is not a bare
  ## name.
  if e.base == nil: return
  let base = assignRoot(e.base)
  if base == nil or base.kind != exkVar: return
  var hasMutation = false
  for step in e.steps:
    if step.op == coDotDot: hasMutation = true
  if not hasMutation: return
  let (found, b) = tc.lookup(base.name)
  if not found: return
  let whole = base.id == e.base.id     # `c ..n` vs `c.inner ..n`
  if b.isParam:
    # One line: `fail` appends "at line L:C", so a multi-line fix sketch would
    # read with the location dangling off the end of it.
    fail(dcTyParamMutation,
         "cannot mutate " &
         (if whole: "parameter '" & base.name & "'"
          else: "a field of parameter '" & base.name & "'") &
         " with '..' — a parameter is a value the caller owns, not a var. " &
         "Fix: copy it first (`var s = " & base.name & "`), chain on the " &
         "copy, and return it", e.span)
  if not b.isVar:
    fail(dcTyImmutable,
         "cannot mutate " &
         (if whole: "'" & base.name & "'"
          else: "a field of '" & base.name & "'") &
         " with '..' — it was declared with 'let'; use 'var'", e.span)

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
  # Against the field's DECLARED type: setting an unsupplied field is how the
  # hole gets filled, so the value is matched against what the field will
  # hold, not against the marker saying it holds nothing yet.
  let want = unwrapUninit(f.typ)
  if not tc.compatible(vt, want):
    fail("Type Error: field '" & f.name & "' of " & typeName(recvT) & " is " &
         typeName(want) & " but got " & typeName(vt), valExpr.span)

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
  # Compare shapes, not hole state: the receiver may be partly built, and a
  # mutator returning a complete value is exactly what fills it. Marking the
  # target would make `c ..fn` unusable on the records that most need it.
  if not tc.compatible(retT, stripUninit(baseT)):
    fail("Type Error: cannot assign " & typeName(retT) & " to " &
         typeName(baseT) & " — a '..' mutator must return the receiver's type",
         step.span)
  tc.checkMutatorTransition(step, e.base, baseT)

proc checkChainStep(tc: var TypeChecker, step: var ChainStep, e: Expr,
                    baseT, recvT: Type, fields: seq[FieldDef]) =
  ## One `..name {args}` step: either it SETS a field or it calls a mutator.
  ## Both fill holes — a field set fills its own, and a mutator fills the ones
  ## its body provably assigns, which is why `c ..configure` works without
  ## pretending a mutator touched fields it never mentions.
  let base = if e.base != nil and e.base.kind == exkVar: e.base.name else: ""
  for f in fields:
    if f.name == step.target.name:
      tc.checkFieldSet(step, f, recvT)
      if base != "": tc.clearUninit(base, step.target.name)
      return
  if tc.fnSigs.hasKey(step.target.name):
    tc.checkMutatorCall(step, e, baseT, recvT)
    if base != "":
      for f in tc.mutatorFillsFields(step.target.name):
        tc.clearUninit(base, f)
  elif recvT.kind == tkRecord:
    fail("Type Error: no field or fn '" & step.target.name & "' on type " &
         typeName(recvT), step.span)

proc synthChain(tc: var TypeChecker, e: Expr): Type =
  ## A `..` chain stays on its base var: every step either sets a field or
  ## calls a mutator that returns the receiver's type.
  ##
  ## A register/actor/registry/pool/mixin base (spec 8.1's `CTRL ..EN
  ## {true}` register write is the only real case) has no such "own type"
  ## to stay on — it is a pure side effect, not a builder chain. Synthesize
  ## it as `unit` directly rather than the base's OWN synthesizeKind arm,
  ## which exists only so a stray direct-synthesize elsewhere stays
  ## exhaustive and would otherwise leak a fake "type named after the
  ## register" out of the enclosing fn body.
  case e.base.kind
  of exkActorRef, exkRegisterRef, exkRegistryRef, exkPoolRef, exkMixinRef:
    discard tc.synthesize(e.base)
    result = Type(span: e.span, kind: tkNamed, name: "unit")
  else:
    result = tc.synthesize(e.base)
  tc.failIfMutatingLet(e)
  tc.failIfRegisterAccess(e)   # spec 8.1: no writing a [read] field
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
  ## known.
  ##
  ## Recorded for top-level fns and for OBJECT MEMBERS. The restriction to
  ## top-level was justified by "the only callees lowering touches" — no
  ## longer true since lowering learned to flatten a member call with an
  ## explicit payload (flattenMemberCallPayload), which had to look the params
  ## up from the declaration for want of this. A recorded fact beats a lookup:
  ## the lookup cannot see a by-type match.
  ##
  ## TASKS stay excluded, deliberately: a task call is SCHEDULED rather than
  ## called (spec §9.2), so the backends emit a spawn and must not have its
  ## payload exploded underneath them. Recording params for tasks broke
  ## examples 28/29/30 — verified, not assumed.
  if e.kind != exkCall: return
  if fnName notin tc.topLevelFns:
    # A member fn: known to fnDecls (which indexes members too) but not to
    # topLevelFns. Pending stubs stay out for the reason given above — their
    # emitted params are ({payload: T},), nothing like the declared ones.
    let d = tc.fnDecls.getOrDefault(fnName, nil)
    if d == nil or d.kind != dkFn or d.isPending: return
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

proc holesOf(t: Type): HashSet[string] =
  ## The unsupplied fields of a record, empty for anything else.
  if t != nil and t.kind == tkRecord:
    for f in t.fields:
      if isUninit(f.typ): result.incl(f.name)

proc failIfCalleeReadsHole(tc: var TypeChecker, fnName, paramName: string,
                           af: ArgField) =
  ## Passing a partly-built record is fine unless the callee READS one of the
  ## holes.
  ##
  ## Checked here rather than in `compatible`, which sees only the declared
  ## types and would have to refuse every partial record — including the many
  ## a callee never looks at. Reported at the CALL site, because that is where
  ## the missing field can actually be supplied.
  let holes = holesOf(af.typ)
  if holes.len == 0: return
  let hit = tc.uninitFieldsRead(fnName, paramName, holes)
  if hit.len == 0: return
  fail(dcTyUninitRead,
       "'" & fnName & "' reads " &
       (if hit.len == 1: "field '" & hit[0] & "'" else: "fields " & $hit) &
       " of '" & paramName & "', which this call leaves " & UninitName &
       " — set " & (if hit.len == 1: "it" else: "them") & " before the call",
       af.span)

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
  tc.failIfCalleeReadsHole(fnName, p.name, af)

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

# === CALL SYNTHESIS ========================================================
# What `{payload} name` MEANS: a construction, a restructuring builtin
# (alias/merge/bake), a distinct conversion, or a plain call. synthCall is the
# ordered chain that decides which — the same "first arm that claims it wins"
# shape as the field-access dispatch above.

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

proc failIfDuplicateField(fields: seq[FieldDef], f: FieldDef, sp: Span,
                          op, source: string) =
  ## Every path that BUILDS a field set routes its additions through here, so
  ## a name landing twice is an error rather than a silent shadowing. `op` and
  ## `source` name the operation and where the collision came from, because
  ## the same collision means something different per caller — merge unions
  ## two members, alias renames two sources onto one target.
  ##
  ## Tuck has three field-combining paths: `+` composition (guarded
  ## separately by duplicates.nim's failIfComposedCollision), `merge`, and
  ## `alias`. alias went unguarded and emitted a Nim tuple with the same field
  ## written twice, which `nim check` rejects — a diagnostic about generated
  ## code the user never wrote. A fourth combiner must call this too.
  for existing in fields:
    if existing.name == f.name:
      fail("Type Error: duplicate " & op & " field '" & f.name & "' — " &
           source, sp)

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
    let renamed = FieldDef(name: newExpr.name, span: e.span,
                           typ: (if ft == nil: unknownType(e.span) else: ft))
    failIfDuplicateField(fields, renamed, e.span, "alias",
                         "two sources renamed onto the same target")
    fields.add(renamed)
  Type(span: e.span, kind: tkRecord, fields: fields)

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
      failIfDuplicateField(fields, f, e.span, "merge",
                           "the same name is contributed by two members")
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
  let viaSig = tc.checkThroughFnSig(tc.resolve(result), e)
  if viaSig != nil: return viaSig
  for a in e.args: discard tc.synthesize(a)

proc declaredFieldsOf(tc: TypeChecker, e: Expr, calleeName: string): seq[FieldDef] =
  ## The fields a construction is measured against.
  ##
  ## Objects keep theirs in objFields, not typeBody, and getFieldsForType only
  ## reaches those through a recorded decl edge — which a bare construction has
  ## not got. objDecls is the checker's own table and answers directly.
  if tc.objDecls.hasKey(calleeName):
    composedFields(tc.module, tc.objDecls[calleeName])
  else:
    getFieldsForType(tc.module, Type(span: e.span, kind: tkNamed,
                                     name: calleeName))

proc suppliedFieldTypes(tc: var TypeChecker, e: Expr): Table[string, Type] =
  ## The payload's fields by name, typed.
  ##
  ## Synthesized here rather than read back from semLayer: the stamp is
  ## deliberately stripped of `<uninit>` markers (codegen must never see one),
  ## and the marker is exactly what this needs. Mirrors synthStruct's own
  ## per-field expectedVariantType hint: this walks the same fields a SECOND
  ## time (asNamedCallee's own synthesize pass is the first), bypassing
  ## synthStruct entirely, so a bare inline-sum-variant field value needs
  ## the same hint set here too or it resolves once and fails the next.
  if e.args.len == 1 and e.args[0] != nil and e.args[0].kind == exkStruct:
    for f in e.args[0].fields:
      let savedExpected = tc.expectedVariantType
      if tc.fieldTypeHints.hasKey(f.name): tc.expectedVariantType = tc.fieldTypeHints[f.name]
      result[f.name] = tc.synthesize(f.value)
      tc.expectedVariantType = savedExpected

proc constructedField(d: FieldDef, supplied: Table[string, Type],
                      sp: Span, holes: var bool): FieldDef =
  ## One field of a construction: supplied, supplied-but-itself-holed, or
  ## missing.
  ##
  ## A supplied field keeps the type of the VALUE given for it whenever that
  ## value carries holes of its own — that is what stops nesting from
  ## laundering. Storing a partly-built Inner into an Outer makes the Outer
  ## carry Inner's hole, so `o.inner.b` is refused just as `i.b` would be.
  ## Everywhere else the DECLARED type is kept, so nothing else shifts.
  if not supplied.hasKey(d.name):
    holes = true
    return FieldDef(name: d.name, typ: markUninit(d.typ, sp), span: d.span)
  let vt = supplied[d.name]
  if vt != nil and vt.kind == tkRecord and anyUninit(vt):
    holes = true
    return FieldDef(name: d.name, typ: vt, span: d.span)
  d

proc constructedType(tc: var TypeChecker, e: Expr, calleeName: string): Type =
  ## `{fields} TypeName` — the declared type, EXCEPT that any declared field
  ## the payload did not supply comes back marked `<uninit>`.
  ##
  ## No holes ⇒ the plain nominal type, byte-identical to before this feature,
  ## so the common path is untouched. Only a partial construction yields a
  ## structural record — normal here: asAliasCall and asMergeCall already
  ## return synthesized tkRecords that match no declaration.
  ##
  ## The marker rides on the FIELD's type, never on the record's: a marked
  ## record would hit synthFieldAccess's isWrapper gate and make even reading
  ## a SUPPLIED field an error.
  let declared = tc.declaredFieldsOf(e, calleeName)
  let nominal = Type(span: e.span, kind: tkNamed, name: calleeName)
  if declared.len == 0: return nominal
  let supplied = tc.suppliedFieldTypes(e)
  var holes = false
  var fs: seq[FieldDef]
  for d in declared: fs.add(constructedField(d, supplied, e.span, holes))
  if holes: Type(span: e.span, kind: tkRecord, fields: fs) else: nominal

const ParenBuiltinNames = ["sizeof", "alignof", "offsetof"]
  ## Mirrors parser_expr.ParenBuiltins (not imported here — the checker
  ## deliberately does not depend on the parser stage). `sizeof(int)` reads
  ## like a call, but `int` names a TYPE, not a value in scope — codegen
  ## already reads it as bare text (asParenBuiltinOdin/D), never as a typed
  ## expression. Synthesizing the arg as an ordinary value used to be
  ## tolerated only because a bare unresolved name silently degraded to
  ## Unknown; now that synthBareVariant's fallback is a real error, a
  ## primitive type name (int, str, ...) has nowhere to resolve FROM as a
  ## value — it was never one.

proc synthArgsUnknown(tc: var TypeChecker, e: Expr): Type =
  ## Type the arguments for their side effects and give up on the result. The
  ## gradual escape hatch: the call itself is not understood, but its
  ## arguments still have to check out.
  for a in e.args: discard tc.synthesize(a)
  unknownType(e.span)

proc synthArgsAs(tc: var TypeChecker, e: Expr, name: string): Type =
  ## Type the arguments, then answer with a named type regardless — a
  ## conversion, where the args are checked but the result is the target type.
  for a in e.args: discard tc.synthesize(a)
  Type(span: e.span, kind: tkNamed, name: name)

proc asRestructuringBuiltin(tc: var TypeChecker, e: Expr,
                            calleeName: string): Type =
  ## `alias` / `merge` / `bake` — the three builtins that rearrange a record's
  ## fields rather than calling anything. Each wants a specific argument
  ## shape; a wrong shape is not an error, it degrades to Unknown so sketch
  ## code keeps compiling.
  case calleeName
  of "alias":
    if e.args.len == 2 and e.args[1].kind == exkStruct: tc.asAliasCall(e)
    else: tc.synthArgsUnknown(e)
  of "merge":
    if e.args.len == 1 and e.args[0].kind == exkStruct: tc.asMergeCall(e)
    else: nil                      # `merge` is also an ordinary name
  of "bake":
    if e.args.len == 2 and e.args[1].kind == exkStruct: tc.asBakeCall(e)
    else: tc.synthArgsUnknown(e)
  else: nil

proc asNamedCallee(tc: var TypeChecker, e: Expr, calleeName: string): Type =
  ## A callee that resolved to a NAME: a distinct conversion, a generic or
  ## plain construction, or a declared fn. Ordered — the first that claims the
  ## name wins, and nil means none did.
  if calleeName == "": return nil
  if calleeName in tc.distinctNames:
    # Calling a distinct type's name converts from its base (Nim-native)
    return tc.synthArgsAs(e, calleeName)
  if tc.typeGenerics.hasKey(calleeName):
    return tc.asGenericConstruction(e, calleeName)
  if not tc.fnSigs.hasKey(calleeName) and
     (tc.typeDecls.hasKey(calleeName) or tc.objDecls.hasKey(calleeName)):
    # {fields} TypeName — construction produces the declared type. Objects are
    # constructible by name like records, but are deliberately absent from
    # typeDecls: `resolve` unwraps anything found there to its body, and an
    # object is NOMINAL. So the gate asks both tables while the result stays
    # the name either way.
    let savedHints = tc.fieldTypeHints
    tc.fieldTypeHints = initTable[string, Type]()
    for fd in tc.declaredFieldsOf(e, calleeName): tc.fieldTypeHints[fd.name] = fd.typ
    for a in e.args: discard tc.synthesize(a)
    # constructedType -> suppliedFieldTypes re-synthesizes the same field
    # values a SECOND time (to read back each field's type without the
    # <uninit> stamp) — the hints must still be live for that pass too, or
    # a bare inline-sum-variant field value resolves once and fails the next.
    result = tc.constructedType(e, calleeName)
    tc.fieldTypeHints = savedHints
    return result
  if tc.fnSigs.hasKey(calleeName):
    return tc.asDeclaredCall(e, calleeName)
  if registryEventOwner(calleeName) != "":
    # `Registry.raise Event` / `Registry.raise Event {payload}` — Event as
    # a CALLEE (its `.raise` argument is the other half of the same shape,
    # typed separately by synthFieldAccess's own exkRegistryRef case).
    # lowering.flattenRegistryRaise reads this call's AST shape directly,
    # never this type. `unit`, not the registry's name: this call sits in
    # TAIL position in a `fn ... -> void:` whose only statement is the
    # raise (spec's fire-and-forget shape) — a real named type here fails
    # the "flows X out of body" check the same way a register chain-write
    # used to fail it before that one was given `unit` too (synthChain).
    for a in e.args: discard tc.synthesize(a)
    return Type(span: e.span, kind: tkNamed, name: "unit")
  nil

proc synthCall(tc: var TypeChecker, e: Expr): Type =
  ## What `{payload} name` means, in priority order: a restructuring builtin,
  ## then a name (distinct / construction / declared fn), then a callee that
  ## is not a bare name at all. Nothing claims it -> Unknown, gradually.
  let calleeName = tc.calleeNameOf(e)
  if calleeName in ParenBuiltinNames:
    # Args are type names, not values — see ParenBuiltinNames. Result is
    # always a plain size/offset.
    return Type(span: e.span, kind: tkNamed, name: "int")
  result = tc.asRestructuringBuiltin(e, calleeName)
  if result != nil: return
  result = tc.asNamedCallee(e, calleeName)
  if result != nil: return
  if e.callee != nil and e.callee.kind != exkVar:
    return tc.asIndirectCall(e)
  return tc.synthArgsUnknown(e)

# === THE SPINE: ONE synth* PER EXPRESSION KIND =============================
# Everything above is reached FROM here. synthesizeKind is the case over
# ExprKind; each arm is a synthX that returns the expression's type. This is
# the walk — the rest of the file is what the individual kinds need.

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
  if e.name == "...":
    # The pending-hole marker (parser_expr.nim parses it as a literal
    # exkVar named "...", same magic-identifier shape as "input"/"Error"
    # elsewhere in this file — codegen's genVar already special-cases it
    # to `discard`). Its real sentinel already exists (pendingType,
    # "declared, not implemented" — spec §5.4); it was riding unknownType
    # by accident, not by design, same as every other fix in this proc.
    return pendingType(e.span)
  let owner = tc.sumTypeOwning(e.name)
  if owner != "": return Type(span: e.span, kind: tkNamed, name: owner)
  let regOwner = registryEventOwner(e.name)
  if regOwner != "": return Type(span: e.span, kind: tkNamed, name: regOwner)
  if tc.expectedVariantType != nil:
    # Inline sum type (no name to find in typeDecls): the enclosing match's
    # subject, or the assignment target's own type, IS the type, if this
    # name is one of its variants.
    let subjBody = tc.resolve(tc.expectedVariantType)
    if subjBody != nil and subjBody.kind == tkSum and
       hasVariant(subjBody, e.name):
      return tc.expectedVariantType
  if tc.typeDecls.hasKey(e.name) or tc.objDecls.hasKey(e.name):
    # A declared type/object name used bare, as a VALUE — `+ AudioPlayer`
    # composition is the shape found here, but this is the same "type name
    # in value position" case asNamedCallee already trusts at the CALL
    # position (`{fields} TypeName` construction); this is its bare-name
    # sibling, not a new exemption invented for this one call site.
    return Type(span: e.span, kind: tkNamed, name: e.name)
  # Every legitimate shape a bare Capitalized-or-lowercase name can be —
  # local, nullary call, sum variant, registry event, pending marker,
  # declared type/object name, inline sum variant inside a match arm — is
  # handled above. Nothing genuine reaches here any more (confirmed by
  # assertNoUnknownTypes across all 44 examples, TODO.md); a name that does
  # is undefined, and gradual typing's <unknown> sentinel is for a
  # constrained TYPE the checker cannot pin down yet, not a NAME the
  # program never declared at all.
  fail(dcTyUndeclared, "'" & e.name & "' is not declared — no local, fn, " &
       "sum-type variant, registry event or type by that name is in scope",
       e.span)
  unknownType(e.span)

proc synthVar(tc: var TypeChecker, e: Expr): Type =
  ## A bare name: a binding in scope, else a nullary call, a fn REFERENCE,
  ## else a variant.
  let (found, b) = tc.lookup(e.name)
  if found: b.typ
  elif tc.fnSigs.hasKey(e.name) and tc.fnSigs[e.name].params.len == 0:
    tc.synthNullaryCall(e)
  elif tc.fnSigs.hasKey(e.name):
    # A fn WITH params, referenced bare rather than called: a bake/fnsig
    # target (`{mapFn: double} Box` filling a Mapper[int, str] slot).
    # Deliberately Unknown, not a gap — applyBakeOverride's own comment
    # already documents this: "fn refs come through as Unknown and pass
    # gradually", v1 has no first-class fn-value type to give it instead.
    unknownType(e.span)
  else:
    tc.synthBareVariant(e)

proc synthStruct(tc: var TypeChecker, e: Expr): Type =
  ## A record literal types field by field.
  var fs: seq[FieldDef]
  for f in e.fields:
    tc.checkFieldValue(f.name, f.value)
    let savedExpected = tc.expectedVariantType
    if tc.fieldTypeHints.hasKey(f.name): tc.expectedVariantType = tc.fieldTypeHints[f.name]
    fs.add(FieldDef(name: f.name, typ: tc.synthesize(f.value), span: f.value.span))
    tc.expectedVariantType = savedExpected
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

proc isControlFlowExit(s: Expr): bool =
  ## Does this statement LEAVE the fn rather than produce a value to drop?
  ##
  ## `err X` is the base case. It also rides inside a branch — `if raw == "":
  ## err Empty` — and there the enclosing `if` carries the raise's type (the
  ## fn's !T) without being a value anyone dropped. Missing that read the
  ## guard clause as an unhandled result and, under a continue/exit policy,
  ## wrapped a branch that only ever `return`s in `(let tmp = ...)`, which is
  ## not an expression: `Error: invalid indentation`.
  if s == nil: return false
  case s.kind
  of exkRaise, exkReturn: true
  of exkIf:
    # A guard clause — `if cond: err X` with no else — exits on the taken
    # path and falls through on the other, so nothing is dropped either way.
    # With an else, both paths have to exit for the same to hold.
    if s.elseBranch == nil: isControlFlowExit(s.thenBranch)
    else: isControlFlowExit(s.thenBranch) and isControlFlowExit(s.elseBranch)
  of exkBlock:
    s.stmts.len > 0 and isControlFlowExit(s.stmts[^1])
  else: false

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
  if g != "" and not tc.isNarrowed(g):
    tc.setNarrowed(g, true)
    narrowed.add(g)
  # a control-flow exit (`err X`, or a branch that only exits) is never a drop
  if isWrapper(result) and not tc.isImplicitReturn(blk, s) and
     not isControlFlowExit(s):
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
  # Unwind BEFORE popScope: the narrowing lives on the binding, and a guard
  # set here may have marked a binding from an ENCLOSING scope (the block
  # pushes its own scope, but `let r` sits outside it). Popping first would
  # leave that outer binding narrowed for the rest of the fn.
  for g in narrowed: tc.setNarrowed(g, false)
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

proc failIfTargetImmutable(tc: var TypeChecker, e: Expr) =
  ## An assignment may not write through a parameter or a `let`, whether it
  ## names the binding itself (`c = ...`), one of its fields (`c.n = ...`), or
  ## a nested field (`c.inner.n = ...`). `+=` and friends desugar to `x = x +
  ## v` in the parser, so they arrive here too.
  ##
  ## WHY THIS IS SEPARATE FROM failIfMutatingLet: that one guards `..`, which
  ## is only one of the doors. This is the other, and it was unguarded — both
  ## `c.n = 9` on a parameter and `c = ...` on a `let` reached the backend,
  ## where NIM rejected them with a message naming generated code the user
  ## never wrote ("'c.n' cannot be assigned to"). A rejection Nim makes is a
  ## rejection Tuck should make first, with a code the user can look up.
  if e.target == nil: return
  let root = assignRoot(e.target)
  if root == nil or root.kind != exkVar: return
  let (found, b) = tc.lookup(root.name)
  if not found: return
  let whole = root.id == e.target.id   # `c = v` vs `c.n = v`
  if b.isParam:
    fail(dcTyParamMutation,
         "cannot assign to " &
         (if whole: "parameter '" & root.name & "'"
          else: "a field of parameter '" & root.name & "'") &
         " — a parameter is a value the caller owns, not a var. Fix: copy " &
         "it first (`var s = " & root.name & "`), change the copy, and " &
         "return it", e.span)
  if not b.isVar:
    fail(dcTyImmutable,
         "cannot assign to " &
         (if whole: "'" & root.name & "'"
          else: "a field of '" & root.name & "'") &
         " — it was declared with 'let'; use 'var'", e.span)

proc synthAssignVal(tc: var TypeChecker, e: Expr, targetT: Type): Type =
  ## spec 4.4b: the RHS of a checked transition assignment may construct a
  ## non-initial sealed variant — the transition IS the legal path (static
  ## analogue of the old transitionTo-chain exemption).
  let tracked = e.target != nil and e.target.kind == exkVar and
                tc.transType(targetT) != ""
  let prevCtx = tc.transitionCtx
  if tracked: tc.transitionCtx = true
  let savedExpected = tc.expectedVariantType
  tc.expectedVariantType = targetT
  result = tc.synthesize(e.assignVal)
  tc.expectedVariantType = savedExpected
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
  tc.failIfTargetImmutable(e)
  # `c.f = v` fills the hole. Clear it BEFORE synthesizing the target: the
  # target is synthesized for its TYPE, which routes through asPlainField, so
  # clearing afterwards would make the statement that fixes the hole the one
  # that reports it. (The RHS is synthesized separately below, so reading the
  # hole on the right of its own assignment is still caught.)
  if e.target != nil and e.target.kind == exkField and
     e.target.receiver != nil and e.target.receiver.kind == exkVar:
    tc.clearUninit(e.target.receiver.name, e.target.fieldName)
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

proc isErrorDotRef(v: Expr): bool =
  ## `Error.name` (spec 4.9) — the app-wide error namespace, matched the
  ## same way codegen*.nim's own isErrorDotRef/genReturn special-case
  ## already does: receiver named literally "Error", never a real
  ## declaration.
  v != nil and v.kind == exkField and v.receiver != nil and
    v.receiver.kind == exkVar and v.receiver.name == "Error"

proc checkReturnValue(tc: var TypeChecker, e: Expr) =
  ## `return [d, c]` where the fn returns Seq[Animal]: the list literal takes
  ## its element type from the first item, so it must be wrapped element by
  ## element against the RETURN type — the same treatment a call argument
  ## gets, at the other position where an expected type is known.
  if isErrorDotRef(e.returnVal):
    # codegen*.nim rewrites this into `terr(errCode(...))` wholesale — the
    # SAME implicit wrap `err X` (synthRaise) gets, just spelled as a plain
    # `return` instead of the `err` keyword. Synthesize for its side
    # effects (checkFieldValue-style validation, if any) but skip the
    # ordinary compat() check: comparing its raw u16 against a declared
    # !T is exactly the mismatch this construct exists to bypass.
    discard tc.synthesize(e.returnVal)
    return
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

proc synthDiscard(tc: var TypeChecker, e: Expr): Type =
  ## `discard <expr>` evaluates and silently drops a value — the explicit,
  ## intentional escape from the dropped-fallible-result diagnostic (spec
  ## 4.9): the STATEMENT's own type is unit regardless of what `discardVal`
  ## synthesizes to, so synthStmt's dropped-result check (which reads the
  ## statement's type, not what is nested inside it) never fires. Bare
  ## `discard` is a pure no-op.
  if e.discardVal != nil:
    discard tc.synthesize(e.discardVal)
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
  # `err X` BUILDS the error case of the fn's !T — errors are values in Tuck,
  # not exceptions, so this yields that result type and `return err X` is an
  # ordinary checked return. It used to yield unit, which type-checked only
  # because `unit` matched everything; with that hatch gone, a raise in tail
  # position has to carry the fn's real return type or it cannot satisfy it.
  tc.currentRet

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

proc failIfUnlowerableArm(arm: SelectArm) =
  ## A task select arm the backends cannot lower must be REFUSED here, not
  ## discovered at emission time.
  ##
  ## codegen lowered exactly one shape — a `read` arm raced against a
  ## `timeout` arm — and sent everything else to a bare `discard`, dropping
  ## the whole handler body with no error, no warning, and no PENDING entry.
  ## A program that looks correct, compiles clean and does nothing at the
  ## deadline is the worst outcome available; refusing to compile it is
  ## strictly better than silently emitting a no-op.
  ##
  ## The case is exhaustive on purpose: a new source kind cannot be added
  ## without deciding, right here, whether it can be lowered yet.
  case arm.sourceKind
  of sskRead, sskTimeout: discard        # the lowered shape
  of sskTimeoutTyped:
    fail("Type Error: a typed timeout source (`" & arm.source & "`) is " &
         "parsed but not yet lowered — use `timeout <ms>` for now. Its body " &
         "would otherwise be silently dropped", arm.span)
  of sskOther:
    fail("Type Error: unsupported `on select` source '" & arm.source &
         "' — a task select takes `read <fd>` and `timeout <ms>` arms. Its " &
         "body would otherwise be silently dropped", arm.span)

proc synthSelect(tc: var TypeChecker, e: Expr): Type =
  ## task `on select` (spec §9.3): each arm waits on a source (read fd /
  ## timeout ms) then runs its body. Type the args (fd/ms are ints) and the
  ## bodies; the select's value is a branch outcome — leave it unknown, the
  ## bodies carry the returns.
  for arm in e.selArms:
    failIfUnlowerableArm(arm)
    if arm.arg != nil: discard tc.synthesize(arm.arg)
    discard tc.synthesize(arm.body)
  branchOutcomeType(e.span)

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
  of exkDiscard: tc.synthDiscard(e)
  of exkChain: tc.synthChain(e)
  of exkSend: tc.synthSend(e)
  of exkSelect: tc.synthSelect(e)
  of exkQualified, exkImport: tc.synthQualified(e)
  of exkActorRef, exkRegisterRef, exkRegistryRef, exkPoolRef, exkMixinRef:
    # A reference to a declaration, not a value — same shape as a bare sum
    # variant (synthBareVariant), named after the declaration itself. Field
    # access on one of these (synthFieldAccess) special-cases the receiver's
    # KIND directly and never reaches this generically; this arm exists so
    # the dispatch stays exhaustive and a stray direct synthesize (there
    # should be none) gets a real type instead of a crash or Unknown.
    Type(span: e.span, kind: tkNamed, name: e.refName)

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

proc failIfMutatingIndexTarget(tc: var TypeChecker, e: Expr) =
  ## `xs[i] = v` writes THROUGH `xs`, so it is bound by the same rules as
  ## `..` (spec §7.1, §2.3): never through a parameter, which is a value the
  ## caller owns, and not through a `let`.
  ##
  ## failIfMutatingLet guards only the chain form, so this path used to slip
  ## past both: `items[0] = 0` on a param typechecked clean and then failed
  ## in the Nim backend with an error about generated code the author never
  ## wrote. Found while auditing stage boundaries for the D backend.
  let br = e.brTarget
  if br == nil or br.brReceiver == nil: return
  let base = assignRoot(br.brReceiver)
  if base == nil or base.kind != exkVar: return
  let (found, b) = tc.lookup(base.name)
  if not found: return
  let whole = base.id == br.brReceiver.id
  if b.isParam:
    fail(dcTyParamMutation,
         "cannot assign into " &
         (if whole: "parameter '" & base.name & "'"
          else: "a field of parameter '" & base.name & "'") &
         " — a parameter is a value the caller owns, not a var. " &
         "Fix: copy it first (`var s = " & base.name & "`), assign into the " &
         "copy, and return it", e.span)
  if not b.isVar:
    fail(dcTyImmutable,
         "cannot assign into " &
         (if whole: "'" & base.name & "'"
          else: "a field of '" & base.name & "'") &
         " — it was declared with 'let'; use 'var'", e.span)

proc synthBracketAssign(tc: var TypeChecker, e: Expr): Type =
  let br = e.brTarget
  if br.brReceiver != nil and br.brReceiver.kind == exkVar and
     tc.typeDecls.hasKey(br.brReceiver.name):
    fail("Type Error: cannot assign into the type application '" &
         br.brReceiver.name & "[...]'", e.span)
  tc.failIfMutatingIndexTarget(e)
  let recvT = tc.synthesize(br.brReceiver)
  let ac = tc.resolveIndex(br, e.brValue, recvT, e.span)
  setCall(semLayer, e, ac)
  tc.synthesize(ac)

proc synthesize(tc: var TypeChecker, e: Expr): Type =
  if e == nil: return unknownType(Span())
  result = tc.synthesizeKind(e)
  # Two different consumers, two different answers. The RETURNED type keeps
  # the `<uninit>` marker, because that is how it rides with the value —
  # synthStruct types a literal from its fields' synthesized types, so a
  # partial record stored inside another carries its holes along and cannot
  # be laundered. What is STORED for codegen has the marker stripped: the
  # backends must see the field's real type, and the emitted record is
  # unchanged by this feature.
  setType(semLayer, e, unwrapUninit(result))

# Signature collection (the pre-pass that fills fnSigs/typeDecls/objDecls
# before any body is checked) now lives in typecheck_collect.nim, imported
# above.











# Pure functions are total: only [io]-marked functions (I/O, unknown input)
# may declare fallible !T returns. The pure core provably cannot fail.

proc bindParam(tc: var TypeChecker, p: Param, gsub: Table[string, Type]) =
  ## Bind one parameter, and note its variant set if its type is tracked.
  ##
  ## THE `self` EXCEPTION (spec §5.1). An object member declares its receiver
  ## explicitly (`fn louder({self: Self})`), so by the time we get here it
  ## looks like any other parameter — but checkObjectDecl has already bound a
  ## mutable `self` in the enclosing scope, and re-binding it immutable here
  ## would shadow that and break `self ..volume {11}`, which the spec shows
  ## as valid.
  ##
  ## So: a param that shadows an already-mutable binding of the same name
  ## inherits its mutability. Outside an object member nothing has bound
  ## `self`, so the lookup misses and the ordinary rule applies — a plain fn
  ## whose first param merely happens to be NAMED `self` gets no exemption,
  ## which is right, because it is still someone else's value.
  ##
  ## Otherwise a parameter is an IMMUTABLE binding of a value (spec §7.1).
  ## Bound `isVar: false, isParam: true` — the second flag is what lets
  ## failIfMutatingLet reject `..` here with the right message instead of the
  ## one about `let`.
  ##
  ## This used to bind them mutable, justified by "`set` functions
  ## legitimately use `..` on them". That justification outlived the feature:
  ## `set`/`pred` prefixes were dropped (spec §3.6, never implemented), while
  ## the mutable binding stayed and made codegen emit `var T` for every record
  ## param — which in Nim is a BY-REFERENCE pass, so a callee could silently
  ## write through to the caller's record. The Odin backend never did this and
  ## rejected the same program outright, which is how the divergence surfaced.
  let (shadowsMutable, outer) = tc.lookup(p.name)
  let inheritsMutable = shadowsMutable and outer.isVar and not outer.isParam
  if inheritsMutable:
    tc.bindName(p.name, substituteType(p.typ, gsub), true)
  else:
    tc.bindName(p.name, substituteType(p.typ, gsub), false, isParam = true)
  # spec 4.4b: a param of a tracked type enters at the FULL variant set —
  # transitions on it need `match` narrowing first.
  let tn = tc.transType(p.typ)
  if tn != "": tc.varVariants[p.name] = tc.allVariants(tn)

proc bindInput(tc: var TypeChecker, params: seq[Param],
               gsub: Table[string, Type]) =
  ## `input` — the whole incoming payload as one struct (reserved keyword).
  if params.len == 0: return
  var inputFields: seq[FieldDef]
  for p in params:
    inputFields.add(FieldDef(name: p.name, typ: substituteType(p.typ, gsub),
                             span: p.span))
  tc.bindName("input", Type(span: params[0].span, kind: tkRecord,
                            fields: inputFields), false)

proc tailIsImplicitReturn(tc: TypeChecker, body: Expr, bodyT, ret: Type): bool =
  ## Does the value flowing off the end of `body` have to match `ret`?
  ##
  ## Only for a block whose last statement is an expression: an explicit
  ## return or raise has already been checked, a unit/void tail means the
  ## fn ends without producing anything, and an Unknown tail is sketch code
  ## the checker cannot judge. Branch agreement (if/match) has already
  ## unified branch types into bodyT by this point.
  if ret == nil or body == nil: return false
  if body.kind != exkBlock or body.stmts.len == 0: return false
  if body.stmts[^1].kind in {exkReturn, exkRaise}: return false
  if isUnknown(bodyT): return false
  bodyT.kind != tkNamed or bodyT.name notin ["unit", "void"]

proc checkFnBody(tc: var TypeChecker, name: string, params: seq[Param],
                 ret: Type, body: Expr, generics: seq[string] = @[]) =
  ## Check one callable body: bind its params, bind `input`, synthesize, and
  ## verify the value that flows off the end against the declared return.
  ##
  ## Everything mutated here is saved and restored around the body, so a
  ## nested check (an object member, an actor handler) cannot leak state into
  ## its enclosing one.
  tc.pushScope()
  # `T` inside a generic body is not unknown — it is ANY type, fixed per call
  # site. The body is checked once against that abstraction; each instantiation
  # is rechecked by the backend.
  var gsub = initTable[string, Type]()
  for g in generics: gsub[g] = typeParamType(Span())

  let savedVariants = tc.varVariants
  let prevBody = tc.bodyBlock
  tc.varVariants = initTable[string, seq[string]]()

  for p in params: tc.bindParam(p, gsub)
  tc.bindInput(params, gsub)

  tc.currentRet = ret
  tc.currentFn = name
  tc.bodyBlock = body
  let bodyT = tc.synthesize(body)

  if tc.tailIsImplicitReturn(body, bodyT, ret) and
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

proc checkInvariants(tc: var TypeChecker, d: Decl) =
  ## spec 4.7: an `invariant:` predicate is a yes/no about a value of this
  ## type, checked wherever one is produced. So it may name the type's OWN
  ## fields and nothing else, and it must be a bool.
  ##
  ## Nothing checked either. codegen emits the predicate into a `validate`
  ## proc with only the fields in scope, so a typo became a Nim error about
  ## generated code ("candidates (edit distance...): 'tuckYield'"), and a
  ## non-boolean predicate became `assert(value + 1, ...)` — a type error in
  ## the emitted file, naming a line the user never wrote.
  if d.typeBody == nil or d.typeBody.kind != tkRecord: return
  var hasInvariant = false
  for member in d.typeMembers:
    if member != nil and member.kind == dkExpr: hasInvariant = true
  if not hasInvariant: return

  var known: HashSet[string]
  for f in d.typeBody.fields: known.incl(f.name)

  proc failIfUnknownName(tc: var TypeChecker, e: Expr, owner: string) =
    ## Every bare name in the predicate must be one of this type's fields.
    ##
    ## Checked on the NAMES rather than on the predicate's synthesized type,
    ## because `nosuchfield <= 100` still synthesizes `bool` — a comparison
    ## with an unknown operand is not itself unknown, so looking only at the
    ## result would let exactly the typo case through.
    if e == nil: return
    case e.kind
    of exkVar:
      if e.name notin known and not tc.fnSigs.hasKey(e.name):
        fail(dcIvUnknownField,
             "invariant on '" & owner & "' names '" & e.name & "', which is " &
             "not a field of it — an invariant may only mention this type's " &
             "own fields, since that is all that is in scope where it runs",
             e.span)
    of exkBinary:
      tc.failIfUnknownName(e.left, owner); tc.failIfUnknownName(e.right, owner)
    of exkUnary: tc.failIfUnknownName(e.operand, owner)
    of exkField: tc.failIfUnknownName(e.receiver, owner)
    of exkCall:
      for a in e.args: tc.failIfUnknownName(a, owner)
    else: discard

  tc.pushScope()
  for f in d.typeBody.fields: tc.bindName(f.name, f.typ, false)
  for member in d.typeMembers:
    if member == nil or member.kind != dkExpr or member.expr == nil: continue
    tc.failIfUnknownName(member.expr, d.name)
    let t = tc.synthesize(member.expr)
    if not (t.kind == tkNamed and t.name == "bool"):
      fail(dcIvNotBool,
           "invariant on '" & d.name & "' must be a bool, got " &
           typeName(t) & " — an invariant is a yes/no about the value " &
           "(`value <= 100`), not a computation", member.expr.span)
  tc.popScope()

proc checkPoolDecl(tc: TypeChecker, d: Decl) =
  ## spec 7.2: a pool is N slots of a real type, and `count` is required
  ## precisely so the footprint is static. The parser already rejects a
  ## missing or non-numeric count; what nothing checked was whether the
  ## ELEMENT TYPE exists, so `pool P = NoSuchType [count: 4]` emitted an
  ## ObjectPool over an undeclared name and failed in Nim with a spell
  ## suggestion about generated code.
  ##
  ## Primitives and the builtin containers are not in typeDecls (they are a
  ## closed set the backends know), so only a Capitalized name that resolves
  ## nowhere is an error — the same rule declarations use everywhere else.
  if d.poolElem == nil or d.poolElem.kind != tkNamed: return
  let n = d.poolElem.name
  if n.len == 0 or not n[0].isUpperAscii: return    # primitive: u8, int, ...
  if tc.typeDecls.hasKey(n) or tc.objDecls.hasKey(n): return
  if n in ["Seq", "Array", "Buf"]: return           # builtin containers
  fail(dcTyUndeclared,
       "pool '" & d.name & "': no type named '" & n &
       "' — a pool holds slots of a declared type", d.span)

proc checkArenaAttrs(d: Decl) =
  ## spec 7.3: `arena A [size: N]` reserves N bytes up front, so N has to be
  ## a positive count for the same reason an actor's queue does — the number
  ## IS the allocation.
  ##
  ## An arena parses into a dkType carrying its attrs, which is why this runs
  ## from the dkType arm rather than an arm of its own.
  if d.typeBody == nil: return
  for attr in d.typeBody.attrs:
    if attr.name != "size": continue
    var n = 0
    try:
      n = parseInt(attr.value.strip())
    except ValueError:
      fail(dcMeSizeCount,
           "arena '" & d.name & "': size must be a whole number of bytes, " &
           "got '" & attr.value & "'", attr.span)
    if n <= 0:
      fail(dcMeSizeCount,
           "arena '" & d.name & "': size must be at least 1 byte, got " & $n &
           " — the size IS the reservation, so a zero or negative one " &
           "cannot hold anything", attr.span)

proc checkActorQueue(d: Decl) =
  ## `[queue: N]` is the mailbox ring's exact capacity, so N must be a
  ## positive whole number.
  ##
  ## Nothing validated it, and the value rides to codegen as a STRING, so
  ## `queue: 0` emitted `Mailbox[Msg, 0]` and the program built cleanly and
  ## then died on the first send with a division by zero (the ring wraps with
  ## `mod Cap`). `queue: -5` built too, and died with an index-out-of-bounds.
  ## A declaration that cannot work should not reach a backend.
  ##
  ## An ABSENT attribute is fine — codegen_common.actorQueueSize defaults to
  ## 8. This checks the value only when one was written.
  for attr in d.attrs:
    if attr.name != "queue": continue
    var n = 0
    try:
      n = parseInt(attr.value.strip())
    except ValueError:
      fail(dcAcQueueSize,
           "actor '" & d.name & "': queue size must be a whole number, got '" &
           attr.value & "'", attr.span)
    if n <= 0:
      fail(dcAcQueueSize,
           "actor '" & d.name & "': queue size must be at least 1, got " &
           $n & " — the mailbox is a ring of exactly this many slots, so a " &
           "zero or negative one cannot hold a message (it builds, then " &
           "fails on the first send)", attr.span)

proc checkActorDecl(tc: var TypeChecker, d: Decl) =
  ## Handlers see the actor's fields, bare AND through `self` — mirrors
  ## checkObjectDecl. Nothing bound `self` here before; a handler spelling
  ## `self.field` synthesized `self` as a silently-unknown name and rode
  ## through on gradual typing, same shape as `result` in checkHandler below.
  checkActorQueue(d)
  tc.pushScope()
  for f in d.actorFields: tc.bindName(f.name, f.typ, true)
  tc.bindName("self", Type(span: d.span, kind: tkNamed, name: d.name), true)
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
  of dkType:
    checkTransitions(d)
    tc.checkInvariants(d)
    checkArenaAttrs(d)          # an arena parses into a dkType (spec 7.3)
  of dkRegister: checkRegisterDecl(d)
  of dkPool: tc.checkPoolDecl(d)
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

# Module-level validation, const-purity checking, and unhandled-result
# reporting now live in typecheck_module.nim, imported above.



# === PROGRAM DRIVER ========================================================
# Whole-program orchestration: build a checker per module, run the passes in
# order, collect diagnostics. `typecheckProgram` at the bottom is the only
# entry the pipeline calls.















proc bindConsts*(tc: var TypeChecker, m: Module) =
  ## const declarations are bound BEFORE body checks so any fn can reference
  ## them; constCheck says what a const is allowed to be.
  for d in m.decls:
    if d != nil and d.kind == dkConst:
      constCheck(tc, m, d.name, d.constVal, d.span)
      tc.bindName(d.name, tc.synthesize(d.constVal), false)

proc typecheckModule*(m: Module,
                      externSigs = initTable[string, FnSig](),
                      externPending = initTable[string, Span]()): seq[string] {.discardable.} =
  var tc = newModuleChecker(m, externSigs, externPending)
  tc.pushScope()  # module-level scope: consts visible across decls
  tc.collectSigs(m.decls)
  tc.resolveTypeNames(m)
  checkPointers(tc.typeDeclsByName, m)  # pointers stay at the extern boundary
  # Before checkDecl: a type with no finite size cannot be reasoned about, so
  # the author should see THAT rather than a cascade about a type that cannot
  # exist. Was caught only by the backend, in the backend's words.
  checkRecursiveTypes(tc.typeDeclsByName, m)
  checkConformance(m)      # `satisfies I` means every I member is implemented
  tc.bindConsts(m)
  failIfDuplicateDecl(m)
  failIfDuplicateMembers(m)
  tc.failIfFieldShadowsDeclaredFn(m)
  for d in m.decls:
    failIfTopLevelStatement(d)
    tc.checkDecl(d)
  # INFERRED types get their declaration edge too, now that every expression
  # has been typed. resolveTypeNames above only walks types MENTIONED IN
  # DECLARATIONS; the types the checker synthesizes for expressions never
  # passed through it, so `declForType` missed on every one of them and every
  # later consumer fell back to scanning the decl list by name — which is
  # what made emit quadratic (measured: 200 misses for 200 types).
  #
  # Cheap: one walk of the types already recorded, resolving only tkNamed.
  tc.resolveInferredTypes()
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


# The registry rules (spec Part 10) are four independent passes over the same
# program. One proc each, in the order checkRegistry runs them.

  ## The declared surface: registries by name, and every "Reg.Event" variant.








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
  checkRegistry(mods)
  let sigs = collectProgramSigs(mods)
  for (name, path, m) in mods:
    let scope = importScopeFor(sigs, preSigs, name)
    try:
      result = typecheckModule(m, scope.extern, scope.pending)
    except SemanticError as err:
      raise withModulePrefix(err, path)
