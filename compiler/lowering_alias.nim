# compiler/lowering_alias.nim
#
# ONE VALUE, TWO WAYS INTO A CALL (A23, ruled 2026-09-28).
#
#     k.absorb {other: k}        # absorb changes `self`, then reads `other`
#
# A member that changes its object takes its receiver by reference — that is
# how `k` itself changes — while `other` is a value: `k` as it was at the
# call. Nim and Odin pass a large by-value argument as a hidden pointer, so
# `other` pointed at the very `k` the member was changing, and read the
# change (101 where value semantics say 1). D copies and was right.
#
# So such an argument is copied into a fresh `let` just before the statement,
# and the call reads the copy:
#
#     let tuckAlias1 = k
#     k.absorb {other: tuckAlias1}
#
# It is a separate value, so whatever a host does with pointers, `other` is
# `k` as it was. Only where the argument reads the receiver's own variable,
# and only for an aggregate (an object, record, Seq, str…): a number or a
# bool travels in a register and cannot alias. Predictability before speed:
# the one extra copy is where it is needed, and nowhere else.
#
# The copy happens before the WHOLE statement, which is the right moment
# unless another call in the same statement also changes that variable —
# `k.bump + k.absorb {other: k}` — and that is refused by name rather than
# guessed at. A call through an interface value needs none of this: its
# dispatch works on its own copy of the payload and stores it back after.
import ast, ast_ops, ast_query
import resolution

var aliasCounter = 0

const ScalarNames = ["int", "i8", "i16", "i32", "i64", "u8", "u16", "u32",
                     "u64", "usize", "f32", "f64", "float", "bool", "char"]
  ## What a host passes in a register: never aliased, never copied here.

proc rootVar(e: Expr): Expr =
  ## The variable a place is rooted at — `k` for `k`, `k.inner`, `k.xs[0]`.
  var r = e
  while r != nil and r.kind in {exkField, exkBracket}:
    r = if r.kind == exkField: r.receiver else: r.brReceiver
  if r != nil and r.kind == exkVar: r else: nil

proc rootName(e: Expr): string =
  ## rootVar's (emitted) name, or "".
  let r = rootVar(e)
  if r != nil: r.name else: ""

proc readsName(e: Expr, name: string): bool =
  ## Does expression `e` read variable `name` anywhere?
  for n in nodes(e):
    if n.kind == exkVar and n.name == name: return true
  false

proc isAggregate(res: Resolution, e: Expr): bool =
  ## A value a host may pass by hidden pointer: anything but a scalar.
  let t = res.typeFor(e)
  t != nil and not (t.kind == tkNamed and t.name in ScalarNames)

proc changingCall(res: Resolution, m: Module, n: Expr): Expr =
  ## The call `n` is, when it passes its receiver by reference: a changing
  ## member called as a call, or as a field the checker resolved to one. An
  ## interface call is not one (its dispatch copies — see above).
  let c = if n.kind == exkCall: n
          elif n.kind == exkField and res.hasCall(n) and
               res.ifaceCallOf(n).member == "": res.call(n)
          else: nil
  if c != nil and callWritesSelf(res, m, c): c else: nil

proc changingCallsIn(res: Resolution, m: Module, e: Expr,
                     acc: var seq[(Expr, Expr)]) =
  ## Every changing call in one statement, as (the tree's node, its call).
  ## Not into a nested block: its statements are lowered on their own.
  if e == nil or e.kind == exkBlock: return
  let c = res.changingCall(m, e)
  if c != nil: acc.add((e, c))
  for ch in e.children: res.changingCallsIn(m, ch, acc)

proc retarget(site, arg: Expr, name: string) =
  ## Make `arg` — and its twin in the tree, which after a backend's deepCopy
  ## is a separate node with the same id — read `name`, keeping the id and
  ## so the type it was checked at.
  let id = arg.id
  var twins = @[arg]
  if site.kind == exkField and site.dotArg != nil:
    for n in nodes(site.dotArg):
      if n.id == id and n != arg: twins.add n
  for t in twins:
    t[] = Expr(span: t.span, kind: exkVar, name: name)[]
    t.id = id

proc refuse(site: Expr, root: Expr) =
  ## The one shape a copy before the statement could get wrong: another call
  ## in the same statement also changes `root`. Loud, as
  ## lowering_match_binds.refuse is: the checker passed it.
  quit("tuck: line " & $site.span.line & ": `" & writtenName(root) &
       "` is changed by " &
       "another call in this statement and also passed by value to a call " &
       "that changes it. Fix: split the statement, so each change reads the " &
       "value the one before left", 1)

proc hoistStmt(res: Resolution, m: Module, s: Expr): seq[Expr] =
  ## The `let` copies statement `s` needs before it, its arguments retargeted.
  var calls: seq[(Expr, Expr)]
  res.changingCallsIn(m, s, calls)
  for (site, c) in calls:
    let root = rootName(c.args[0])
    if root == "": continue
    for i in 1 ..< c.args.len:
      let arg = c.args[i]
      if arg == nil or not arg.readsName(root) or not res.isAggregate(arg):
        continue
      for (other, oc) in calls:
        if other != site and rootName(oc.args[0]) == root:
          refuse(site, rootVar(c.args[0]))
      inc aliasCounter
      let name = "tuckAlias" & $aliasCounter
      let t = res.typeFor(arg)
      result.add res.typed(Expr(span: arg.span, kind: exkAssign, isDecl: true,
                                target: res.typed(Expr(span: arg.span,
                                  kind: exkVar, name: name), t),
                                assignVal: res.freshCopy(arg)), t)
      retarget(site, arg, name)

proc lowerIn(res: Resolution, m: Module, e: Expr) =
  ## Every block under `e`: each statement preceded by the copies it needs.
  if e == nil: return
  if e.kind == exkBlock:
    var stmts: seq[Expr]
    for s in e.stmts:
      if s != nil: stmts.add res.hoistStmt(m, s)
      stmts.add s
    e.stmts = stmts
  for ch in e.children: res.lowerIn(m, ch)

proc lowerAliasedArgs*(res: Resolution, m: Module) =
  ## Every body of this backend's copy of the module. After lowering_chains
  ## (a `..` step on a changing member is a call by then) and before
  ## lowering_iface (whose dispatch needs none of this).
  for body in m.bodies: res.lowerIn(m, body)
