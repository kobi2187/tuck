# compiler/ownership_escape.nim
#
# CAN A LOCAL'S BUFFER OUTLIVE THE BODY? — asked of the SSA graph's uses.
#
# The ownership pass frees what a body owns and never lets go, and "never
# lets go" is this question. It used to be answered by walking the WHOLE body
# once per local per slot, carrying a `sealed` flag down from every node that
# takes its contents away (docs/ownership-and-ssa.md §5 M5) — and then a
# second time, by a second walk with its own copy of the rules, for `str`
# (M6). Five locals with three fields was fifteen traversals, plus the `str`
# ones, and two sets of rules kept in step by hand.
#
# The graph already records every read of every local: `Value.uses`, each at
# a node. So the question is a lookup: for each use of this local, is the node
# it happens at INSIDE something that carries it out of the body? The one
# thing the graph does not hold is a node's ancestors, and one walk per body
# (`indexBody`) supplies them, shared by every local and both kinds of
# storage.
#
# ---------------------------------------------------------------------------
# WHAT CARRIES A VALUE OUT
# ---------------------------------------------------------------------------
#
# A node carries its contents out of the body (`carriesOut`) when it is
#
#   a `send`                  always: a message outlives its sender
#   a `return` / `raise`      when what it hands back could hold ours
#   a call                    when its result could hold ours — unless the
#                             rule exempts it (below)
#
# and one EDGE carries out, the right-hand side of a binding to ANOTHER name:
#
#   t = <rhs>                 when `t` could hold ours, the rhs is now
#                             reachable through a name we are not following.
#                             Unless the rule exempts the binding.
#
# "Could hold ours" is always asked of the DESTINATION's type, never of the
# node kind: `return acc + s.len` returns an int, which cannot be carrying a
# buffer away, and sealing on the kind alone made every local in every fold
# look escaped.
#
# A use escapes when it sits under a carrying node, or on a carrying edge —
# and, for a bare name, when it is handed to a MOVED callee, which consumes
# it. A read of a DIFFERENT field of the local (`b.height` while asking about
# `b.light`) is not a mention of the slot being asked about; a bare read of
# the local is a mention of every slot.
#
# ---------------------------------------------------------------------------
# THE RULE — the only thing that differs between the two kinds of storage
# ---------------------------------------------------------------------------
#
#   heap slots (`Seq`, and a record's `Seq` fields): a binding, or a call
#     bound to one, that COPIED every slot out captured nothing of what went
#     in (`analysis_ownership.findCopiedOut`).
#   `str`: a call on the backend's list of allocating runtime procs hands
#     back fresh storage, so passing ours in does not carry it out.
#
# Every answer fails towards "escapes": an escape that is not one is a leak,
# and a missed one is a use-after-free.
import tables, sets
import ast, ast_ops, ast_query
import resolution
import ssa_ir, ssa_cache
from twin_shape import seqFieldNames

type
  Carried* = enum
    ## What is being followed out of the body.
    cHeapSlots   ## a `Seq`, or a record's `Seq` fields
    cStr         ## a `str` the body allocated

  SealRule* = object
    carried*: Carried
    exemptCalls*: HashSet[NodeId]
      ## calls (and `str` concatenations) whose result holds none of their
      ## operands: they never carry an operand out, and nothing that carries
      ## their result out does either
    exemptBindings*: HashSet[NodeId]
      ## right-hand sides whose binding captured nothing of them

  BodyIndex* = object
    ## One body, indexed for escape questions. Built once per body.
    res: Resolution
    m: Module
    fn: SsaFn
    root: Expr
    node: Table[NodeId, Expr]
      ## every node of the body by id — a use names its node by id — plus
      ## the nodes of the calls its resolved fields print as
    tree: HashSet[NodeId]
      ## which of those are the body's own: what the coverage check covers
    parents: Table[NodeId, seq[Expr]]
      ## a node's parents. A SEQ, because nothing forbids lowering from
      ## sharing a subtree, and a shared node is reached along every path.
    valuesOf: Table[string, seq[ValueId]]
      ## every value, grouped by the ROOT of its place — `b` and `b.light`
      ## both under `b`

proc holdsAStrType*(t: Type): bool =
  ## Could a value of this type be CARRYING a `str` it was handed?
  ##
  ## A scalar cannot. A `str` OBVIOUSLY CAN — it is one. This once answered
  ## false for `str`, reasoning that "the runtime procs that answer one
  ## allocate rather than passing a string through", and that reasoning
  ## confuses what a CALL RETURNS with what a VALUE CAN HOLD. The exemption
  ## belongs to the call (`SealRule.exemptCalls`); made here, it made
  ## `return s` not an escape, so a returned local was freed before its caller
  ## read it:
  ##
  ##     tuck_label :: proc (n: int) -> string {
  ##       tuck_s := str.toStr(n)
  ##       defer delete(tuck_s)
  ##       return tuck_s          // <- freed, then returned
  ##     }
  if t == nil: return true                 # unknown: assume it could
  case t.kind
  of tkNamed: t.name notin ["int", "bool", "float", "void",
                            "u8", "u16", "u32", "u64",
                            "i8", "i16", "i32", "i64", "f32", "f64"]
  else: true

proc holdsHeapSlots*(res: Resolution, m: Module, t: Type): bool =
  ## Can a value of this type be carrying a heap buffer at all? A scalar
  ## cannot, and asking about one only ever produces a false alarm.
  if t == nil: return false
  seqElem(t) != nil or seqFieldNames(res, m, t).len > 0

proc holds(ix: BodyIndex, rule: SealRule, t: Type): bool =
  case rule.carried
  of cHeapSlots: holdsHeapSlots(ix.res, ix.m, t)
  of cStr: holdsAStrType(t)

# --- the premise ---------------------------------------------------------------

proc readByOuterField(ix: BodyIndex, n: Expr): bool =
  ## Is `n` the receiver of a field path the graph recorded? `b.light` is
  ## one read, of `b.light`; the `b` inside it is not a read of its own.
  for p in ix.parents.getOrDefault(n.id):
    if p.kind == exkField and p.receiver == n and
       (p.id in ix.fn.byNode or ix.readByOuterField(p)):
      return true
  false

proc notARead(ix: BodyIndex, n: Expr): bool =
  ## A name in a position that does not read storage: the fn a call names,
  ## the name an assignment writes, or a field the checker resolved to a
  ## CALL (`a.total`) — the builder reads the call, whose argument is the
  ## receiver, and the receiver is then checked like any other read.
  if n.kind == exkField and ix.res.hasCall(n): return true
  for p in ix.parents.getOrDefault(n.id):
    if p.kind == exkCall and p.callee == n: return true
    if p.kind == exkAssign and p.target == n: return true
  false

proc coverageErrors(ix: BodyIndex): seq[string] =
  ## EVERY READ OF A NAME IN THE TREE IS A USE IN THE GRAPH. The escape
  ## question looks only at uses, so a read the builder skipped is a mention
  ## this module never sees — an escape missed, a use-after-free. The walk it
  ## replaced saw every node by construction; this is what makes the lookup
  ## answer the same.
  for id, n in ix.node:
    if n.kind notin {exkVar, exkField} or pathOf(n).len == 0: continue
    if n.id notin ix.tree: continue      # a resolved call's copy: not the tree
    if id in ix.fn.byNode or ix.notARead(n) or ix.readByOuterField(n):
      continue
    result.add pathOf(n) & " at line " & $n.span.line

# --- the index ---------------------------------------------------------------

proc addParent(ix: var BodyIndex, child, parent: Expr) =
  let ps = addr ix.parents.mgetOrPut(child.id, @[])
  if parent notin ps[]: ps[].add parent

proc indexResolvedCall(ix: var BodyIndex, field: Expr) =
  ## A field the checker (or a lowering) resolved to a CALL is printed AS that
  ## call, and the builder reads the call instead of the field — so the call's
  ## arguments are where this field's reads are recorded. They are indexed as
  ## children of the field, which is where they are printed.
  ##
  ## Not always the tree's own nodes. `lowering_recursive` resolves `e.left`
  ## to `tuckAt(<a fresh copy of e.left>, 0)`, fresh so that emitting the
  ## argument does not find the same call again; the read of `e.left` is
  ## recorded on the copy, which the tree does not hold. Found by the
  ## coverage assertion on its first run, over `examples/44`.
  ##
  ## The CALL itself is not indexed: the walk this replaced never treated a
  ## resolved field as a call, and a pure refactor keeps that answer.
  var stack: seq[(Expr, Expr)]
  for a in ix.res.call(field).args: stack.add (a, field)
  while stack.len > 0:
    let (n, parent) = stack.pop()
    if n == nil: continue
    if not n.id.isSet:
      # Never read by the builder (it numbers what it records). Its children
      # hang off the nearest numbered ancestor.
      for ch in n.children: stack.add (ch, parent)
      continue
    ix.addParent(n, parent)
    if n.id in ix.node: continue          # the tree's own node: indexed
    ix.node[n.id] = n
    for ch in n.children: stack.add (ch, n)

proc indexBody*(res: Resolution, m: Module, d: Decl): BodyIndex =
  ## Parents and graph for one lowered body — the graph the emitter's tree
  ## describes (`ssLowered`), since that is the tree whose frees are printed.
  let body = if d.kind == dkTask: d.taskBody else: d.fnBody
  result = BodyIndex(res: res, m: m, root: body)
  if body == nil: return
  result.fn = ssaOf(res, d, ssLowered).fn
  var stack = @[body]
  var resolved: seq[Expr]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil: continue
    doAssert n.id.isSet, "ownership_escape: " & d.name & " has a node " &
      "without an id — fillIds runs before ownership"
    let seen = n.id in result.node
    result.node[n.id] = n
    result.tree.incl n.id
    if seen: continue          # a shared subtree: its children are indexed
    if n.kind == exkField and res.hasCall(n): resolved.add n
    for ch in n.children:
      if ch == nil: continue
      result.addParent(ch, n)
      stack.add ch
  for f in resolved: result.indexResolvedCall(f)
  for v in result.fn.values:
    result.valuesOf.mgetOrPut(rootOf(v.place), @[]).add v.id
  let missed = result.coverageErrors()
  doAssert missed.len == 0,
    "ownership_escape: " & d.name & " reads " & missed[0] &
    " but its SSA graph records no use there"

# --- the question --------------------------------------------------------------

proc handedBack(n: Expr): Expr =
  ## What a `return` or a `raise` hands back. Two fields, not one: reading
  ## `returnVal` off a `raise` is a field of the wrong branch.
  if n.kind == exkReturn: n.returnVal else: n.raiseVal

proc carriesOut(ix: BodyIndex, rule: SealRule, n: Expr): bool =
  ## Does this node, by itself, take whatever is inside it out of the body?
  case n.kind
  of exkSend: true
  of exkReturn, exkRaise:
    let v = handedBack(n)
    v == nil or ix.holds(rule, ix.res.typeFor(v))
  of exkCall:
    n.id notin rule.exemptCalls and ix.holds(rule, ix.res.typeFor(n))
  else: false

proc bindsElsewhere(ix: BodyIndex, rule: SealRule, parent, child: Expr,
                    name: string): bool =
  ## Is `child` the right-hand side of a binding to another name, one that
  ## could hold what we follow and that the rule does not exempt?
  parent.kind == exkAssign and child == parent.assignVal and
    parent.target != nil and pathOf(parent.target) != name and
    child.id notin rule.exemptBindings

proc underCarrier(ix: BodyIndex, rule: SealRule, n: Expr, name: string,
                  memo: var Table[NodeId, bool]): bool =
  ## Is `n` inside something that carries it out of the body — along ANY
  ## path from the body's root? The body itself is not.
  if n.id in memo: return memo[n.id]
  memo[n.id] = false           # a cycle cannot happen in a tree; be safe
  var sealed = false
  for p in ix.parents.getOrDefault(n.id):
    if p.id in rule.exemptCalls:
      # AN EXEMPT CALL'S RESULT HOLDS NONE OF ITS ARGUMENTS, so whatever
      # carries that result out does not carry `n` with it. Letting the seal
      # through made `let t = s + "-"` an escape of `s`: the binding carries
      # `t` out of reach, and `t` is fresh storage the concatenation built.
      # Every `str` read into a concatenation or a `toStr` stayed unfreed.
      continue
    if ix.bindsElsewhere(rule, p, n, name):
      # The binding decides, whatever is above it: the rhs is now reachable
      # through the other name exactly when that name could hold ours.
      if ix.holds(rule, ix.res.typeFor(p.target)): sealed = true
    elif ix.carriesOut(rule, p) or ix.underCarrier(rule, p, name, memo):
      sealed = true
    if sealed: break
  memo[n.id] = sealed
  sealed

proc mentions(v: Value, name, slot: string): bool =
  ## Does a read of this value read the slot being asked about? A bare read
  ## of the local reads every slot; a field read reads its own field, and
  ## `slot == ""` (the whole value) is read by every field read.
  v.place == name or slot.len == 0 or v.place == name & "." & slot

proc threadsBack(ix: BodyIndex, n: Expr, name: string): bool =
  ## Is `n` the moved first argument of `name = f(name, ...)` — handed to a
  ## twin that consumes it, with the result bound straight back to the name?
  for call in ix.parents.getOrDefault(n.id):
    if call.kind != exkCall or call.args.len == 0 or call.args[0] != n:
      continue
    for asg in ix.parents.getOrDefault(call.id):
      if asg.kind == exkAssign and asg.assignVal == call and
         asg.target != nil and asg.target.kind == exkVar and
         asg.target.name == name:
        return true
  false

proc escapes*(ix: BodyIndex, rule: SealRule, name, slot: string,
              threading = false): bool =
  ## Can this slot of this local still be reached once the body returns?
  ##
  ## `threading` asks about the value the local ENDS with: a moved argument
  ## threaded straight back (`x = f(x)`) is not an escape of that, since the
  ## name owns the result — every other moved argument still is.
  if ix.root == nil: return false
  var memo: Table[NodeId, bool]
  for vid in ix.valuesOf.getOrDefault(name):
    let v = ix.fn.val(vid)
    if not v.place.isUnder(name) or not v.mentions(name, slot): continue
    for u in v.uses:
      let n = ix.node.getOrDefault(u.at)
      # A use at a node the tree does not hold is a read the walk cannot place
      # — answered the safe way.
      if n == nil: return true
      # A MOVED ARGUMENT IS GONE, unconditionally: the callee's twin consumes
      # it. Relaxing this to "gone only if the twin really frees it" once
      # needed a second copy of the twin's own rule, which drifted into a
      # double free.
      if v.place == name and n.kind == exkVar and isMovedArg(ix.res, n) and
         not (threading and ix.threadsBack(n, name)):
        return true
      if ix.underCarrier(rule, n, name, memo): return true
  false
