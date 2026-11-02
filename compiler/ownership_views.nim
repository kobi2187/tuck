# compiler/ownership_views.nim
#
# A `let` THAT ONLY LOOKS: borrow it instead of copying it (issue #213).
#
#   let ins = re.prog[pc]        # a record that owns a Seq
#   if ins.op == 8: ...          # ...and the binding is only read
#
# Rule S makes a binding a sink, and a sink of an element copies it: a deep
# copy of `ins`, with the Seq it owns, and a drop where its scope ends. A
# virtual machine does that on every instruction it runs (regex-redux: 45% of
# the time in copies and the frees of the copies). Nothing in the program
# needs the copy. The binding is immutable, and the thing it was read from
# does not change while the binding is looked at.
#
# So such a binding is a VIEW, the same kind of place a `for` or a `match`
# binds (ownership_elab.placesOf): a place of the body that it does not own.
# No copy is made where it is bound and nothing drops it; and because it is not
# owned, every sink of it copies by rule S as it already does for a borrowed
# parameter, so a view that is returned, stored or handed to a consuming
# parameter becomes a copy there, at the one place it is needed.
#
# THE CONDITION. A `let` binds a view when, in the statements from the binding
# to the last one that mentions it, nothing writes, appends to, sends or
# consumes the local its value was read from. Whole statements, so a mutation
# later in the same statement as the last read is also refused: that is the
# conservative side. The refusals are cheap to add to and expensive to get wrong.
#
# Not asked of the author: no annotation, no new word. The same program.
import ast, ast_ops, ast_query
import resolution
import ownership_rules, ownership_elab
from ssa_ir import rootOf

proc rootName(e: Expr): string =
  ## The local a chain of fields and index reads starts at, or "" when it
  ## starts anywhere else (a call's result, a literal, a slab cell).
  var x = e
  while x != nil:
    case x.kind
    of exkVar: return x.name
    of exkField: x = x.receiver
    of exkBracket: x = x.brReceiver
    else: return ""
  ""

proc readsPlainly(res: Resolution, e: Expr): bool =
  ## Is `e` only names, fields and index reads: a place, not a computation?
  var x = e
  while x != nil:
    case x.kind
    of exkVar: return true
    of exkField:
      if x.dotArg != nil or res.hasCall(x): return false
      x = x.receiver
    of exkBracket: x = x.brReceiver
    else: return false
  false

proc mutatesViaExtern(res: Resolution, m: Module, pu: PlaceUse): bool =
  ## A body-less callee that returns nothing and is given the place can only
  ## be acting on it (`setAt`): treated as a write.
  if pu.arg.call == nil: return false
  let d = res.calleeOf(m, pu.arg.call)
  d != nil and d.fnBody == nil and emPure notin d.fnEffects and
    (d.fnReturnType == nil or
     (d.fnReturnType.kind == tkNamed and d.fnReturnType.name == "void"))

proc writes(res: Resolution, m: Module, memo: var ConsumeMemo, stmt: Expr,
            root: string): bool =
  ## Does `stmt` write, append to, hand away or consume the local `root`?
  for n in stmt.nodes:
    case n.kind
    of exkAssign:
      if rootName(n.target) == root: return true
    of exkBracketAssign:
      if rootName(n.brTarget) == root: return true
    of exkAppend:
      if rootName(n.appendTarget) == root: return true
    else: discard
  for pu in res.placeUsesUnder(stmt, uNone):
    if rootOf(pu.path) != root: continue
    case pu.use
    of uSink, uMutBorrow, uWrite, uDrop: return true
    of uArg:
      if res.argConsumesWhy(m, pu.arg, memo).len > 0 or
         res.mutatesViaExtern(m, pu): return true
    of uBorrow, uThrough, uProject, uNone: discard
  false

proc viewRoot(res: Resolution, m: Module, ps: Places, n: Expr): string =
  ## The local an immutable `let` reads, when it reads a place a view could
  ## stand for, or "".
  if n.kind != exkAssign or not n.isDecl or n.isMutable or n.target == nil or
     n.target.kind != exkVar or n.assignVal == nil: return ""
  let v = n.assignVal
  if not res.readsPlainly(v) or not res.owning(m, res.typeFor(v)): return ""
  # An element read always copies; a plain place read copies unless it is the
  # place's final use, and then it moves, which is cheaper than a view.
  let copies = v.kind == exkBracket or res.readsElement(m, v) or
               res.copiesRead(ps, v)
  if copies: rootName(v) else: ""

proc lastRead(b: Expr, i: int, name: string): int =
  ## The last statement of `b` after `i` that mentions `name`: where a view of
  ## it must still be valid. -1 when a `defer` mentions it (it runs at the
  ## scope's end, after anything else).
  result = i
  for j in i + 1 .. b.stmts.high:
    if b.stmts[j].mentionsName(name):
      if b.stmts[j].kind == exkDefer: return -1
      result = j

proc isView(res: Resolution, m: Module, ps: Places, memo: var ConsumeMemo,
            b: Expr, i: int): bool =
  ## Is statement `i` of block `b` a `let` that can be a view?
  let n = b.stmts[i]
  let root = res.viewRoot(m, ps, n)
  if root.len == 0: return false
  let last = lastRead(b, i, n.target.name)
  if last < 0: return false
  for j in i + 1 .. last:
    if res.writes(m, memo, b.stmts[j], root): return false
  true

proc markViews*(res: Resolution, m: Module, d: Decl, memo: var ConsumeMemo) =
  ## Mark every `let` of `d`'s body that can look instead of copy. Run before
  ## anything asks which places the body owns.
  if d.fnBody == nil: return
  let ps = res.placesOf(m, d, memo)
  for blk in d.fnBody.nodes:
    if blk.kind != exkBlock: continue
    for i in 0 ..< blk.stmts.len:
      if res.isView(m, ps, memo, blk, i): blk.stmts[i].viewBinding = true
