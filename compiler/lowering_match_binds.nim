# compiler/lowering_match_binds.nim
#
# A BINDING ARM, LOWERED (ROADMAP S2.9).
#
#     match n:
#       0: 10
#       other: other + 1
#
# `other` names the subject's value inside its arm; the checker binds it and
# marks the pattern `pkBind`. No backend has a pattern that binds a name —
# Nim printed it as a `case` label, Odin as a comparison, D as an undeclared
# identifier — so the arm becomes a catch-all `_`, and the name is replaced
# by a value every backend already prints:
#
#   * THE SUBJECT ITSELF, when it is a named place (`n`, `p.x`) the arms do
#     not write. `other + 1` becomes `n + 1`. No temporary, and it works in
#     any position — including value position, where Odin's `match` is a
#     ternary chain with nowhere to declare anything.
#   * A SNAPSHOT otherwise — a call, an arithmetic subject, or a place an arm
#     overwrites before reading the binding. The subject is evaluated once
#     into a temp declared just before the statement the match heads (the
#     statement itself, a binding's value, a return's value), the match
#     tests the temp, and the arm reads it.
#
# A snapshot needs such a statement to go before. A binding arm in a match
# nested deeper in an expression, over a subject that cannot be read twice,
# is refused by name rather than guessed at.
#
# Renaming respects scope: a read of the name after the arm re-binds it
# (`let other = 3`, a loop variable, an inner binding arm of that name) is
# the new binding's and is left alone.
import ast, ast_ops
import resolution

var tmpCounter = 0

proc isPlace(e: Expr): bool =
  ## A name, or a field path rooted at one: readable twice with one answer.
  e != nil and pathOf(e).len > 0

proc bindsName(p: Pattern, name: string): bool =
  ## Does this pattern bind `name`?
  if p == nil: return false
  case p.kind
  of pkBind: p.name == name
  of pkVar: false        # a tag; it tests, it does not bind
  of pkRecord:
    for (_, sub) in p.fields:
      if bindsName(sub, name): return true
    false
  of pkTuple:
    for sub in p.elems:
      if bindsName(sub, name): return true
    false
  of pkOr: bindsName(p.left, name)
  of pkWild, pkLit: false

proc replaceFree(res: Resolution, e: Expr, name: string, by: Expr)

proc replaceFreeIn(res: Resolution, slot: var Expr, name: string, by: Expr) =
  ## `slot`, with every free read of `name` under it replaced by a fresh copy
  ## of `by`.
  if slot == nil: return
  if slot.kind == exkVar and slot.name == name:
    slot = res.freshCopy(by)
  else:
    replaceFree(res, slot, name, by)

proc replaceInBlock(res: Resolution, b: Expr, name: string, by: Expr) =
  ## A block's statements, up to one that re-binds `name` (`let name = ...`):
  ## its value still reads the old binding, the statements after it the new.
  for s in b.stmts.mitems:
    if s != nil and s.kind == exkAssign and s.isDecl and s.target != nil and
       s.target.kind == exkVar and s.target.name == name:
      replaceFreeIn(res, s.assignVal, name, by)
      return
    replaceFreeIn(res, s, name, by)

proc replaceInArms(res: Resolution, m: Expr, name: string, by: Expr) =
  ## A nested match: its subject and guards, and each arm that does not bind
  ## `name` again.
  replaceFreeIn(res, m.subject, name, by)
  for arm in m.arms.mitems:
    replaceFreeIn(res, arm.guard, name, by)
    if not bindsName(arm.pattern, name): replaceFreeIn(res, arm.body, name, by)

proc replaceFree(res: Resolution, e: Expr, name: string, by: Expr) =
  ## The children of `e`, with the scopes that re-bind `name` left alone.
  case e.kind
  of exkBlock: replaceInBlock(res, e, name, by)
  of exkMatch: replaceInArms(res, e, name, by)
  of exkFor:
    replaceFreeIn(res, e.iterable, name, by)
    if not bindsName(e.iter, name): replaceFreeIn(res, e.body, name, by)
  else:
    for c in e.childSlots: replaceFreeIn(res, c, name, by)

proc writesRoot(e: Expr, root: string): bool =
  ## Does anything under `e` write the variable `root` (or through it)?
  for n in e.nodes:
    let target = case n.kind
                 of exkAssign: n.target
                 of exkBracketAssign: n.brTarget
                 of exkChain: n.base
                 else: nil
    if target != nil:
      var r = target
      while r != nil and r.kind in {exkField, exkBracket}:
        r = if r.kind == exkField: r.receiver else: r.brReceiver
      if r != nil and r.kind == exkVar and r.name == root: return true
  false

proc hasBindArm(m: Expr): bool =
  for arm in m.arms:
    if arm.pattern != nil and arm.pattern.kind == pkBind: return true
  false

proc readsSubjectDirectly(m: Expr): bool =
  ## May the arms read the subject itself in place of the binding?
  if not isPlace(m.subject): return false
  var root = m.subject
  while root.kind == exkField: root = root.receiver
  for arm in m.arms:
    if arm.body != nil and writesRoot(arm.body, root.name): return false
  true

proc rebind(res: Resolution, m: Expr, by: Expr) =
  ## Each binding arm reads `by`, and becomes a catch-all.
  for arm in m.arms.mitems:
    if arm.pattern != nil and arm.pattern.kind == pkBind:
      replaceFreeIn(res, arm.body, arm.pattern.name, by)
      arm.pattern = Pattern(span: arm.pattern.span, kind: pkWild)

proc snapshot(res: Resolution, m: Expr): Expr =
  ## `let tuckBindN = <subject>`, to go before the statement the match heads;
  ## the match then tests the temp and its binding arms read it.
  inc tmpCounter
  let t = res.typeFor(m.subject)
  let tmp = res.typed(Expr(span: m.span, kind: exkVar,
                           name: "tuckBind" & $tmpCounter), t)
  result = Expr(span: m.span, kind: exkAssign, target: tmp,
                assignVal: m.subject, isDecl: true)
  m.subject = res.freshCopy(tmp)
  rebind(res, m, tmp)

proc headedMatch(s: Expr): Expr =
  ## The match a statement heads — the statement itself, a binding's or
  ## assignment's value, a return's value — if it has a binding arm.
  let m = case s.kind
          of exkMatch: s
          of exkAssign: s.assignVal
          of exkReturn: s.returnVal
          else: nil
  if m != nil and m.kind == exkMatch and hasBindArm(m): m else: nil

proc refuse(m: Expr) =
  ## Loudly, like the D emitter's `dUnsupported`: the checker passed it, and
  ## printing a guess is the one outcome that is never acceptable.
  quit("tuck: line " & $m.span.line & ": a binding match arm needs its " &
       "subject read once, and this match heads no statement to read it " &
       "before (it is another arm's value). Fix: bind the subject first — " &
       "`let v = ...`, then `match v:`", 1)

proc lowerIn(res: Resolution, e: Expr) =
  if e == nil: return
  if e.kind == exkBlock:
    var stmts: seq[Expr]
    for s in e.stmts:
      let m = if s != nil: headedMatch(s) else: nil
      if m != nil and not readsSubjectDirectly(m): stmts.add snapshot(res, m)
      stmts.add s
    e.stmts = stmts
  if e.kind == exkMatch and hasBindArm(e):
    if readsSubjectDirectly(e): rebind(res, e, e.subject) else: refuse(e)
  for c in e.children: lowerIn(res, c)

proc lowerMatchBinds*(res: Resolution, m: Module) =
  ## Every binding arm in the module's bodies.
  for body in m.bodies: lowerIn(res, body)
