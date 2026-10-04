# compiler/lowering_field_order.nim
#
# A CONSTRUCTION THAT HANDS A CONTAINER ON AND READS IT AGAIN (Nim only).
#
#     return {nodes: out, slot: out.len - 1} Built
#
# Nim evaluates an object constructor's fields in the order written, and
# moves a value only at its last read. `nodes: out` is not that read —
# `out.len` follows it — so Nim copied the whole array into the record on
# every return: benches/trees slab_thread, one copy per node built, 0.44 s at
# depth 13 and 2.3 s at 14, against 0.009 s once the read of `out` comes
# last. A named record's fields mean the same in any order, so the field
# that takes the container is moved after the fields that read it again.
#
# Only past fields that cannot CHANGE anything: names, literals, field reads,
# operators, and calls whose arguments are values — a free fn's (`out.len`
# is `len({items: out})`), or a member's known not to change its `self`.
# Evaluating those earlier than written cannot be observed. A chain, an
# assignment, or a call that might change its receiver keeps every field
# where it was written, and Nim copies as it did.
#
# Odin and D need none of this. Their containers are headers, a construction
# copies no buffer, and lowering_seqcopy decides the copies they do make.
import std/strutils
import ast, ast_ops, ast_query, resolution
import twin_shape

proc changesNothing(res: Resolution, m: Module, c: Expr): bool =
  ## Can this call change a local? Only an object's member can, through its
  ## `self`: any other call takes its arguments as values. A receiver that is
  ## not a named type, or is a record this module declares, is not an
  ## object; a member found here is asked; anything else — an object this
  ## module cannot see — is taken to change it.
  let rt = memberRecvType(res, c)
  if rt == nil or rt.kind != tkNamed or m.findDecl(dkType, rt.name) != nil:
    return true
  memberOwner(m, rt) != "" and not callWritesSelf(res, m, c)

proc pure(res: Resolution, m: Module, e: Expr): bool =
  ## Can evaluating `e` earlier than written be observed? Not when nothing
  ## in it can change a local.
  if e == nil: return true
  case e.kind
  of exkLit, exkVar: true
  of exkField:
    if res.hasCall(e): pure(res, m, res.call(e))
    else: e.dotArg == nil and pure(res, m, e.receiver)
  of exkCall:
    if not changesNothing(res, m, e): return false
    for a in e.args:
      if not pure(res, m, a): return false
    true
  of exkStruct:
    for f in e.fields:
      if not pure(res, m, f.value): return false
    true
  of exkBinary: pure(res, m, e.left) and pure(res, m, e.right)
  of exkUnary: pure(res, m, e.operand)
  else: false

proc rootTaken(res: Resolution, m: Module, v: Expr): string =
  ## The name a field value hands on whole — `out`, or `r` for `r.nodes` —
  ## when what it hands on owns heap storage; "" for anything else.
  let p = pathOf(v)
  if p.len == 0 or not ownsHeap(m, res.typeFor(v)): return ""
  let dot = p.find('.')
  if dot < 0: p else: p[0 ..< dot]

proc movesLast(res: Resolution, m: Module, fs: seq[FieldInit], i: int): bool =
  ## Should field `i` be evaluated after every field written after it? When
  ## it hands on a container that one of them reads again, and every one of
  ## them is pure.
  let root = rootTaken(res, m, fs[i].value)
  if root.len == 0: return false
  var readAgain = false
  for k in i + 1 ..< fs.len:
    if not pure(res, m, fs[k].value): return false
    if mentionsName(fs[k].value, root): readAgain = true
  readAgain

proc reorder(res: Resolution, m: Module, s: Expr) =
  ## The fields of one construction's payload: those that hand on a
  ## container read again later go last, in their written order.
  var kept, last: seq[FieldInit]
  for i in 0 ..< s.fields.len:
    if movesLast(res, m, s.fields, i): last.add s.fields[i]
    else: kept.add s.fields[i]
  if last.len > 0: s.fields = kept & last

proc orderConstructionFields*(res: Resolution, m: Module) =
  ## Every record construction in this backend's copy of the module.
  for body in m.bodies:
    for n in nodes(body):
      if isRecordConstruction(m, n): reorder(res, m, n.args[0])
