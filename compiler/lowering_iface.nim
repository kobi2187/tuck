# compiler/lowering_iface.nim
#
# CALLS THROUGH AN INTERFACE VALUE, LOWERED (ROADMAP M4.4).
#
#     fn hear({a: Animal}) -> int:
#       return a.noise
#
# An interface value is a variant over the objects that satisfy it: a tag and
# each object's payload. A call through one switches on the tag and calls
# that object's own member fn — no table, no thunk. What each arm calls, with
# what, and what the whole call produces are the same decision on every
# backend, so they are made here, once:
#
#     a.noise   ->   exkIfaceCall(recv: a, iface: Animal,
#                                 arms: [Cat: noise(tmp), Dog: noise(tmp)])
#
# where each arm's call is an ORDINARY member call, typed, with `tmp` the
# payload taken as that object. The emitters print the switch around calls
# they already know how to print. They each built it themselves before, and
# had drifted: Odin's switch was an immediately-called closure typed `-> int`
# whatever the member returned, so a member returning `str` did not compile
# (#40); a param the payload lacked was `nil` on Nim and a refusal on D.
#
# Not a `match` (the roadmap's first wording). The call sits in VALUE position,
# where Odin's `match` is a ternary chain: it can bind no payload, and it
# evaluates the receiver once per arm. Lowering to a match would need every
# value-position dispatch hoisted to statements first — a larger pass that
# this one does not need.
#
# The node gets a FRESH id. Keeping the original's would keep the checker's
# stamped call attached to it, and an emitter that prints `res.call(n)` before
# looking at the kind would print the unlowered form. Its type and wrap are
# carried across by hand; nothing else about the call is the node's.
import ast, ast_ops, ast_query
import resolution
import tables
from lowering_match_binds import replaceFreeIn

const PayloadBind* = "tmp"
  ## what each arm's call names the payload; declared by the emitter's arm

proc memberArgs(res: Resolution, mem: Decl, bound: seq[Expr],
                bindT: Type, span: Span): seq[Expr] =
  ## The payload taken as the satisfier, then each further param of the
  ## CONCRETE member from `bound` — the values the checker bound to the
  ## contract's params past the receiver, in order (typecheck.bindIfaceCall).
  ## Conformance holds the concrete params to the contract's names and
  ## order, so position i here is param i there. A fresh copy per arm: one
  ## node may sit in one place only.
  result.add res.typed(Expr(span: span, kind: exkVar, name: PayloadBind), bindT)
  doAssert bound.len == mem.fnParams.len - 1,
    "lowering_iface: the call to '" & mem.name & "' bound " & $bound.len &
    " argument(s) past the receiver, the member takes " &
    $(mem.fnParams.len - 1) & " — conformance should have refused it"
  for value in bound: result.add res.freshCopy(value)

proc returnsItself(mem: Decl, s: Decl): bool =
  ## Does member `mem` of object `s` return `s`'s own type?
  let r = mem.fnReturnType
  r != nil and r.kind == tkNamed and r.name == s.name

proc returnsInterface(res: Resolution, e: Expr, iface: string): bool =
  ## Is the call `e` through interface `iface` typed as that interface?
  let t = res.typeFor(e)
  t != nil and t.kind == tkNamed and t.name == iface

proc dispatchArm(res: Resolution, e: Expr, s: Decl,
                 iface, contractMember: string): DispatchArm =
  ## The arm for one satisfier `s`: a typed call to the member implementing
  ## `iface.contractMember` — its own name unless `satisfies iface {… -> …}`
  ## renamed it — with the payload (bound as `PayloadBind`) as `self` and the
  ## rest from the call's payload literal.
  let member = implementingName(s, iface, contractMember)
  let mem = findObjectMember(s, member)
  doAssert mem != nil and mem.fnParams.len > 0,
    "lowering_iface: '" & s.name & "' satisfies the interface but declares " &
    "no member '" & member & "' taking self — the conformance check missed it"
  # The satisfier's type as the checker built it, edge and all: the member's
  # own `self` param.
  let callee = Expr(span: e.span, kind: exkVar, name: member)
  let checked = res.call(e)
  let bound = if checked != nil and checked.args.len > 1: checked.args[1 .. ^1]
              else: @[]
  let args = memberArgs(res, mem, bound, mem.fnParams[0].typ, e.span)
  let call = res.typed(Expr(span: e.span, kind: exkCall, callee: callee,
                            args: args), res.typeFor(e))
  # `-> Self` is the interface (R13), and an implementation may return its
  # own type instead (covariant): that result enters the interface here.
  if returnsItself(mem, s) and returnsInterface(res, e, iface):
    res.markWrap(call, s.name, iface)
  DispatchArm(satisfier: s.name, bindName: PayloadBind, call: call)

proc lowerOne(res: Resolution, m: Module, real: Table[string, Module],
              e: Expr) =
  ## Replace an interface call IN PLACE, so every parent keeps its pointer.
  let ic = res.ifaceCallOf(e)
  var arms: seq[DispatchArm]
  for s in satisfiersOf(m, real, ic.iface):
    arms.add dispatchArm(res, e, s, ic.iface, ic.member)
  let t = res.typeFor(e)
  let node = res.typed(Expr(span: e.span, kind: exkIfaceCall,
                           dispatchRecv: e.receiver, dispatchIface: ic.iface,
                           dispatchArms: arms), t)
  # The one other fact about the call itself: its result entering an
  # interface slot (a member returning an object, wrapped where it lands).
  let w = res.wrapOf(e)
  if w.objName != "": res.markWrap(node, w.objName, w.iface)
  e[] = node[]

proc lowerIn(res: Resolution, m: Module, real: Table[string, Module],
             e: Expr) =
  ## Lowers every interface call under `e`, children first, so an argument
  ## that is itself an interface call is replaced before its parent copies it.
  if e == nil: return
  for ch in e.children: lowerIn(res, m, real, ch)
  if e.kind == exkField and res.ifaceCallOf(e).member != "":
    lowerOne(res, m, real, e)

proc lowerIfaceCalls*(res: Resolution, m: Module,
                      real: Table[string, Module]) =
  ## Every interface call in every body of this backend's copy of the module.
  ## `real` is the rest of the program: an object in another module that
  ## satisfies the interface is an arm too.
  for e in m.bodies: lowerIn(res, m, real, e)

# --- `match v: | Flac f -> ...` on an interface value (ruled 2026-09-28) ------
#
#     match v:                    if v is Flac:
#       | Flac f -> A      ->       A   (each `f` read as `v as Flac`)
#       | Mp3 m -> B              else: if v is Mp3:
#       | _ -> C                    B   (each `m` read as `v as Mp3`)
#                                 else:
#                                   C
#
# An `if` chain, because every backend already prints `if` in both statement
# and value position — Odin's value-position `match` is a ternary chain that
# can declare nothing, so `f` is not a local but the payload read in place.
# lowering_match_binds has already made the subject a place, read twice
# safely (a snapshot temp when it was not), and turned a catch-all binding
# into `_`. With no `_`, the checker proved every satisfier has an arm, so
# the last arm needs no test.

proc ifaceTag(res: Resolution, kind: ExprKind, subject: Expr,
              iface, obj: string, t: Type): Expr =
  ## An `exkIfaceIs` or `exkIfacePayload` on its own copy of `subject`.
  var e = Expr(span: subject.span, kind: kind)
  e.tagSubject = res.freshCopy(subject)
  e.tagIface = iface
  e.tagObject = obj
  res.typed(e, t)

proc asStatement(res: Resolution, body: Expr): Expr =
  ## An arm body as a statement branch: an `if` whose branches are blocks
  ## prints as a statement in every backend (ast_query.isValueIf), one whose
  ## branches are not prints as a value.
  if body == nil or body.kind == exkBlock: return body
  res.typed(Expr(span: body.span, kind: exkBlock, stmts: @[body]),
            res.typeFor(body))

proc armChain(res: Resolution, e: Expr, iface: string, stmt: bool): Expr =
  ## The match's arms as an `if` chain, built from the last arm up —
  ## statement branches when the match was a statement, values otherwise.
  let boolT = Type(span: e.span, kind: tkNamed, name: "bool")
  for i in countdown(e.arms.high, 0):
    var arm = e.arms[i]
    let p = arm.pattern
    if stmt: arm.body = res.asStatement(arm.body)
    if p == nil or p.kind != pkTypeTest:
      result = arm.body        # `_`: everything the arms above did not take
      continue
    let objT = Type(span: p.span, kind: tkNamed, name: p.testType)
    let payload = res.ifaceTag(exkIfacePayload, e.subject, iface,
                               p.testType, objT)
    replaceFreeIn(res, arm.body, p.bindAs, payload)
    if result == nil:
      result = arm.body        # the last arm, when every satisfier has one
    else:
      result = res.typed(Expr(span: arm.span, kind: exkIf,
                              cond: res.ifaceTag(exkIfaceIs, e.subject, iface,
                                                 p.testType, boolT),
                              thenBranch: arm.body, elseBranch: result),
                         res.typeFor(e))

proc isIfaceMatch(e: Expr): bool =
  ## A match with a type-test arm — only ever on an interface value (the
  ## checker refuses one anywhere else).
  if e.kind != exkMatch: return false
  for arm in e.arms:
    if arm.pattern != nil and arm.pattern.kind == pkTypeTest: return true
  false

proc lowerOneMatch(res: Resolution, e: Expr, stmt: bool) =
  ## Replace interface match `e` IN PLACE by its `if` chain, so every parent
  ## keeps its pointer.
  let t = res.typeFor(e.subject)
  let chain = res.armChain(e, if t != nil: t.name else: "", stmt)
  let id = e.id
  e[] = chain[]
  e.id = id
  res.setType(e, res.typeFor(chain))

proc lowerMatchesIn(res: Resolution, e: Expr) =
  ## Every interface match under `e`, outermost first: its arms' bodies are
  ## walked after, so a nested one is lowered in the arm that holds it. One
  ## that is a statement of a block becomes a statement; any other is in
  ## value position.
  if e == nil: return
  if e.kind == exkBlock:
    for s in e.stmts:
      if s != nil and isIfaceMatch(s): res.lowerOneMatch(s, stmt = true)
  elif isIfaceMatch(e):
    res.lowerOneMatch(e, stmt = false)
  for ch in e.children: lowerMatchesIn(res, ch)

proc returnTailMatch(res: Resolution, d: Decl) =
  ## A fn whose body ENDS in a value-armed match returns that value — the
  ## codegen adds the `return` for a tail `match` (injectTailReturn) but not
  ## for a tail `if`, which is what the match becomes. So it is said here.
  if d == nil or d.kind != dkFn or d.fnReturnType == nil: return
  let body = d.fnBody
  if body == nil or body.kind != exkBlock or body.stmts.len == 0: return
  let last = body.stmts[^1]
  if last == nil or not isIfaceMatch(last) or matchArmsReturn(last): return
  body.stmts[^1] = res.typed(Expr(span: last.span, kind: exkReturn,
                                  returnVal: last), res.typeFor(last))

proc lowerIfaceMatches*(res: Resolution, m: Module) =
  ## Every `match` on an interface value in the module's bodies. After
  ## lowering_match_binds (which made each subject a place) and before
  ## lowerIfaceCalls (which then lowers the calls inside the arms).
  for d in m.allDecls: res.returnTailMatch(d)
  for e in m.bodies: lowerMatchesIn(res, e)
