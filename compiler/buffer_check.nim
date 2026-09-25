# compiler/buffer_check.nim
#
# NO BUFFER IS RELEASED TWICE, AND NONE IS RETURNED AFTER IT IS RELEASED.
#
# The ownership pass decides frees per NAME and per slot; a double free or a
# use-after-free is about BUFFERS, and several names can denote one buffer:
# a binding the copy pass left uncopied, a slot of the moved parameter, the
# result of a call that hands its argument back. Three shipped Odin bugs were
# exactly that gap — `let t = xs` in a twin freed as `t` and again as `xs`;
# a local that took the moved parameter freed with it; an overwrite free
# ahead of the value that read it — and each was found by reading a rule
# against its emitter, not by anything that checked.
#
# This checks. For every value in the body's SSA graph (the lowered tree, the
# one being emitted) and every heap slot of it, the set of buffers it may
# denote is computed from the same facts the emitter prints:
#
#   a parameter's slot        the caller's buffer, named by its place
#   a binding the copy pass   a NEW buffer at that binding
#     COPIED
#   a binding it did not      the source's buffers (a transfer, or an
#     (transfer / exclusive)    exclusive result — the same buffer, renamed)
#   a field of a value        that value's buffer, one field down
#   a phi                     the union of its operands
#   a call result             a new buffer — or, for a MOVED call, possibly
#                             its first argument's
#   anything else             a new buffer
#
# and then every free site is mapped to the buffers it releases. Two sites
# sharing a buffer is a double free; a buffer released at exit that the body
# also returns is a use-after-free in the caller.
import tables, sets, strutils, sequtils
import ast
import resolution
import ssa_ir, ssa_cache
from lowering_seqcopy import needsDup, recordDupFields

type
  Buffers = HashSet[string]
  Checker = object
    res: Resolution
    fn: SsaFn
    memo: Table[(int32, string), Buffers]
    busy: HashSet[(int32, string)]

proc slotName(place, slot: string): string =
  if slot.len == 0: place else: place & "." & slot

proc buffersOf(c: var Checker, v: ValueId, slot: string): Buffers

proc buffersOfRead(c: var Checker, e: Expr, slot: string): Buffers =
  ## What a READ expression denotes, if the graph indexed it.
  if e != nil and e.id.isSet and e.id in c.fn.byNode:
    return c.buffersOf(c.fn.byNode[e.id], slot)
  result.incl "?:" & $uint32(e.id) & "." & slot   # unmodelled: its own buffer

proc bindingCopied(res: Resolution, e: Expr, slot: string): bool =
  ## Did the binding whose right-hand side is `e` copy this slot?
  if slot.len == 0: needsDup(res, e)
  else: slot in recordDupFields(res, e)

proc fresh(v: Value, tag, slot: string): Buffers =
  result.incl tag & ":" & $int32(v.id) & "." & slot

proc projectBuffers(c: var Checker, v: Value, slot: string): Buffers =
  ## A field read: of another VALUE (one field down its buffer), or bound
  ## from a read expression (the source's, unless the binding copied it).
  let src = v.def.src
  if v.def.inputs.len > 0:
    let field = v.place[v.place.rfind('.') + 1 .. ^1]
    for b in c.buffersOf(v.def.inputs[0], ""):
      result.incl slotName(b, slotName(field, slot))
  elif src != nil and src.kind in {exkField, exkVar} and
       not bindingCopied(c.res, src, slot):
    result = c.buffersOfRead(src, slot)
  else:
    result = fresh(v, "n", slot)

proc aliasBuffers(c: var Checker, v: Value, slot: string): Buffers =
  ## `let t = s`: the copy pass copied it (a new buffer), or it did not — a
  ## transfer at the moved parameter's last read — and `t` IS `s`'s.
  let src = v.def.src
  if src != nil and bindingCopied(c.res, src, slot): fresh(v, "c", slot)
  else: c.buffersOfRead(src, slot)

proc callBuffers(c: var Checker, v: Value, slot: string): Buffers =
  ## A call's result: copied at the binding, or a new buffer — which a MOVED
  ## call may instead be its first argument's, handed straight back.
  let src = v.def.src
  if src != nil and bindingCopied(c.res, src, slot): return fresh(v, "c", slot)
  result = fresh(v, "n", slot)
  if src != nil and src.kind == exkCall and src.args.len > 0 and
     src.args[0] != nil and src.args[0].id.isSet and
     isMovedArg(c.res, src.args[0]):
    for b in c.buffersOfRead(src.args[0], slot): result.incl b

proc buffersOfDef(c: var Checker, v: Value, slot: string): Buffers =
  case v.def.kind
  of dkEntry: result.incl "p:" & slotName(v.place, slot)
  of dkProject: result = c.projectBuffers(v, slot)
  of dkAlias: result = c.aliasBuffers(v, slot)
  of dkCall: result = c.callBuffers(v, slot)
  of dkPhi:
    for op in v.def.inputs:
      for b in c.buffersOf(op, slot): result.incl b
  of dkLiteral, dkConstruct, dkOpaque, dkUndef: result = fresh(v, "n", slot)

proc buffersOf(c: var Checker, v: ValueId, slot: string): Buffers =
  let key = (int32(v), slot)
  if key in c.memo: return c.memo[key]
  if key in c.busy: return   # a phi cycle: its other operands answer
  c.busy.incl key
  result = c.buffersOfDef(c.fn.values[int32(v)], slot)
  c.busy.excl key
  c.memo[key] = result

proc valuesOf(fn: SsaFn, local: string): seq[ValueId] =
  ## Every definition of a local — what its frees can release.
  for v in fn.values:
    if v.place == local and v.def.kind != dkPhi: result.add v.id

proc returnedReads(body: Expr): seq[Expr] =
  ## The read expressions a `return` hands back directly.
  var stack = @[body]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil: continue
    for ch in n.children: stack.add ch
    if n.kind == exkReturn and n.returnVal != nil and
       n.returnVal.kind in {exkVar, exkField}:
      result.add n.returnVal

proc siteBuffers(c: var Checker, d: Decl, local, slot: string): Buffers =
  ## What one release frees: a parameter's slot, or every value of a local.
  if local in d.fnParams.mapIt(it.name):
    result.incl "p:" & slotName(local, slot)
  else:
    for v in c.fn.valuesOf(local):
      for b in c.buffersOf(v, slot): result.incl b

proc bufferErrors*(res: Resolution, d: Decl,
                   sites: seq[tuple[local, slot: string, atExit: bool]],
                   returnSlots: seq[string]): seq[string] =
  ## The two assertions, over one body. `sites` are the ownership pass's
  ## releases; `atExit` marks the ones that fire as a scope ends (a `defer`
  ## at scope exit, and every twin-parameter free) — a `return` inside that
  ## scope runs them too.
  if d == nil or d.fnBody == nil: return
  var c = Checker(res: res, fn: ssaOf(res, d, ssLowered).fn)
  var owner: Table[string, string]
  var atExit: HashSet[string]
  # 1. NO BUFFER RELEASED BY TWO SITES.
  for s in sites:
    let who = slotName(s.local, s.slot)
    for b in c.siteBuffers(d, s.local, s.slot):
      if b.startsWith("?:"): continue
      if b in owner and owner[b] != who:
        result.add "buffer " & b & " is released by both " & owner[b] &
                   " and " & who
      owner[b] = who
      if s.atExit: atExit.incl b
  # 2. NO BUFFER RELEASED AT EXIT IS ALSO RETURNED.
  for r in returnedReads(d.fnBody):
    for slot in returnSlots:
      for b in c.buffersOfRead(r, slot):
        if b in atExit:
          result.add "buffer " & b & " is released at exit by " & owner[b] &
                     " and also returned"
