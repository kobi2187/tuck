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

const PayloadBind* = "tmp"
  ## what each arm's call names the payload; declared by the emitter's arm

proc memberArgs(res: Resolution, mem: Decl, dotArg: Expr,
                bindT: Type, span: Span): seq[Expr] =
  ## The payload taken as the satisfier, then each further param of the
  ## CONCRETE member, positionally, from the call's payload literal. A fresh
  ## copy per arm: one node may sit in one place only.
  let recv = Expr(span: span, kind: exkVar, name: PayloadBind)
  fillIdsIn(recv)
  res.setType(recv, bindT)
  result.add recv
  for i, pname in mem.paramNames():
    if i == 0: continue   # self
    var value: Expr = nil
    if dotArg != nil and dotArg.kind == exkStruct:
      for f in dotArg.fields:
        if f.name == pname: value = f.value
    doAssert value != nil,
      "lowering_iface: the call to '" & mem.name & "' supplies no '" & pname &
      "' — the checker matches an interface call's payload to the contract, " &
      "so a concrete member wanting a param the contract lacks got past it"
    result.add res.freshCopy(value)

proc dispatchArm(res: Resolution, e: Expr, s: Decl,
                 member: string): DispatchArm =
  let mem = findObjectMember(s, member)
  doAssert mem != nil and mem.fnParams.len > 0,
    "lowering_iface: '" & s.name & "' satisfies the interface but declares " &
    "no member '" & member & "' taking self — the conformance check missed it"
  # The satisfier's type as the checker built it, edge and all: the member's
  # own `self` param.
  let call = Expr(span: e.span, kind: exkCall,
                  callee: Expr(span: e.span, kind: exkVar, name: member),
                  args: memberArgs(res, mem, e.dotArg, mem.fnParams[0].typ,
                                   e.span))
  fillIdsIn(call)
  res.setType(call, res.typeFor(e))
  DispatchArm(satisfier: s.name, bindName: PayloadBind, call: call)

proc lowerOne(res: Resolution, m: Module, real: Table[string, Module],
              e: Expr) =
  ## Replace an interface call IN PLACE, so every parent keeps its pointer.
  let ic = res.ifaceCallOf(e)
  var arms: seq[DispatchArm]
  for s in satisfiersOf(m, real, ic.iface):
    arms.add dispatchArm(res, e, s, ic.member)
  let t = res.typeFor(e)
  let node = Expr(span: e.span, kind: exkIfaceCall, dispatchRecv: e.receiver,
                  dispatchIface: ic.iface, dispatchArms: arms)
  fillIdsIn(node)          # fills the new node only: its children have ids
  res.setType(node, t)
  # The one other fact about the call itself: its result entering an
  # interface slot (a member returning an object, wrapped where it lands).
  let w = res.wrapOf(e)
  if w.objName != "": res.markWrap(node, w.objName, w.iface)
  e[] = node[]

proc lowerIn(res: Resolution, m: Module, real: Table[string, Module],
             e: Expr) =
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
