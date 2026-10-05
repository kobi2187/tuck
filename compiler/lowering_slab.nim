# compiler/lowering_slab.nim
#
# A SLAB'S OPERATIONS AND FIELDS JOIN THIS BACKEND'S TREE
# (thoughts/shared/plans/2026-09-29-slab-proposal.md, section 3).
#
# Two rewrites, both on the backend's own copy:
#
#   Nodes.new {data: 1, next: none}   # an exkSlabOp, built from the copy
#   b.prev.value.data += 10           # a field of the cell `b.prev` names
#
# An OPERATION: the checker resolves `Slab.op {...}` to an exkSlabOp in the
# semantic layer, which every backend shares — so a pass that rewrites the
# backend's copy of an operand (lowering_optional wrapping `prev: a` into a
# `?`) never reached the shared node, and codegen printed the unwrapped
# original. Here the field node BECOMES the operation, in place, its operands
# the copy's own nodes: a bare deepCopy keeps ids, so each is found under the
# field by the id of the operand the checker chose.
#
# A FIELD: the checker types `r.data` from the slab's element and stamps the
# access (Resolution.slabDerefs). Its RECEIVER becomes an exkSlabCell — the
# value in the cell the reference names, reached through the runtime's checked
# `tuckSlabCell` — so every backend prints `cell(r).data` with its ordinary
# field emission, for a read and an assignment target alike, and the
# stale-reference check rides with every one.
import ast, ast_ops
import resolution

proc copied(under, orig: Expr): Expr =
  ## The node under `under` that this backend copied from `orig`.
  if orig == nil: return nil
  for n in nodes(under):
    if n.id == orig.id: return n
  raiseAssert "lowering_slab: an operand is not under its operation"

proc slabRefFor(res: Resolution, n, op: Expr): Expr =
  ## The slab an operation acts on, in this tree. A slab's own operation
  ## names it as the receiver (`Nodes.new`); an arena's names the arena
  ## (`Frame.new`), and the checker chose the arena's slab for the element
  ## type — named on the op node, which mangling has already renamed.
  if n.receiver.kind == exkSlabRef: return n.receiver
  Expr(span: n.span, kind: exkSlabRef, refName: op.slabRef.refName)

proc lowerSlabOps(res: Resolution, m: Module) =
  var ops: seq[Expr]
  for body in m.bodies:
    for n in nodes(body):
      if n.kind == exkField and res.call(n) != nil and
         res.call(n).kind in {exkSlabOp, exkArenaReset}: ops.add n
  for n in ops:
    let op = res.call(n)
    let node =
      if op.kind == exkArenaReset:
        Expr(span: n.span, id: n.id, kind: exkArenaReset, arenaRef: n.receiver)
      else:
        Expr(span: n.span, id: n.id, kind: exkSlabOp, slabOp: op.slabOp,
             slabRef: slabRefFor(res, n, op), slabArg: copied(n, op.slabArg),
             slabValue: copied(n, op.slabValue))
    n[] = node[]

proc lowerSlabDerefs*(res: Resolution, m: Module) =
  ## Runs inside lowerModule, on the backend's own copy of the tree.
  lowerSlabOps(res, m)
  for body in m.bodies:
    for n in nodes(body):
      if n.kind != exkField: continue
      let slab = res.slabDerefOf(n)
      # Already routed: `a.data += 1` shares its target between the read and
      # the write, so the walk meets the one access twice.
      if slab == nil or n.receiver.kind == exkSlabCell: continue
      let cell = Expr(span: n.span, kind: exkSlabCell,
                      cellSlab: Expr(span: n.span, kind: exkSlabRef,
                                     refName: slab.name),
                      cellRef: n.receiver)
      res.setType(cell, slab.slabElem)
      n.receiver = cell
