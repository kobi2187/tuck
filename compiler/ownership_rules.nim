# compiler/ownership_rules.nim
#
# THE OWNERSHIP RULES, IN THE CODE — rule U's classifier, the first piece of
# Stage D (thoughts/shared/plans/2026-10-05-ownership-rules-proposal.md, §2
# and §5 step 0; ruled 2026-10-05, "yes to all").
#
#   U  every read of an owning value is a borrow or a sink
#   S  a sink moves at the final use of an owned place, and copies otherwise
#   P  a parameter is consuming iff some final read of it is a sink
#   D  every owned place is dropped exactly once, at the end of its scope
#   M  a move out of a place still to be dropped resets it to empty
#   G  copy, drop and reset are derived from the type, once per type
#   E  operands are evaluated left to right, and "final" is decided so
#   A  a place mutably borrowed in a call is not also read by value there
#   T  a send is a sink into the mailbox
#   V  all of it is checked after elaboration, not trusted
#
# Every other rule asks rule U first: S moves or copies only at a sink, P
# looks for a sink among a parameter's final reads, D's drops are what is
# left after the sinks took theirs. So the classification is written ONCE,
# here, as one `case` over every node kind with no `else` — a new kind does
# not build until its children's uses are decided.
#
# WHAT A CHILD'S USE CAN BE. The proposal's three (borrow, sink, mutable
# borrow) plus the structural cases a single node cannot settle alone:
#
#   uBorrow    read in place; nothing is taken (an operand, an index base,
#              a condition, an iterable, a match subject)
#   uSink      taken by a new owner: a binding, a construction field, a
#              container element, a `return`, a `send` payload (S decides
#              move or copy)
#   uMutBorrow written in place (the in-place append's target)
#   uArg       a call's argument: a sink when the parameter consumes, a
#              borrow when it does not (P decides)
#   uThrough   the value passes on to the parent's own use (an `if` or
#              `match` branch, a block's last value, a wrap into `?T`)
#   uProject   the receiver of a field read: the PLACE grows by one field,
#              and the use of the whole path is the parent's
#   uWrite     the place being defined (an assignment's target)
#   uDrop      the place being released (`exkDrop`)
#   uNone      not a read of a value: a callee's name, a statement whose
#              value is discarded, a loop body
#
# A CALL THE CHECKER RESOLVED is what every emitter prints in the node's
# place (`a.total` is `total(a)`), so it is the call that is classified.
import os, strutils
import ast, ast_ops, ast_query
import resolution
from twin_shape import ownsHeap

type
  Use* = enum
    uBorrow, uSink, uMutBorrow, uArg, uThrough, uProject, uWrite, uDrop, uNone

proc constructs*(res: Resolution, call: Expr): bool =
  ## `{lo: 1, hi: 2} Pair` — a record construction: its callee is the TYPE
  ## it builds, which the checker types the call as. A generic record's
  ## construction (`{items: xs} Set`) is typed as the application
  ## `Set[T]`, so its base is the name.
  var t = res.typeFor(call)
  if t != nil and t.kind == tkApp: t = t.base
  call.callee != nil and call.callee.kind == exkVar and
    t != nil and t.kind == tkNamed and t.name == call.callee.name

proc variantConstruction(res: Resolution, e: Expr): bool =
  if e.kind != exkField or e.receiver == nil or e.receiver.kind != exkVar:
    return false
  var typ = res.typeFor(e)
  if typ != nil and typ.kind == tkApp: typ = typ.base
  typ != nil and typ.kind == tkNamed and typ.name == e.receiver.name

proc payloadOf*(call: Expr): Expr =
  ## A record-style call's payload struct, still unexploded, or nil.
  if not call.argsExploded and call.args.len == 1 and call.args[0] != nil and
     call.args[0].kind == exkStruct: call.args[0]
  else: nil

type ChildUse* = tuple[child: Expr, use: Use]

proc all(xs: seq[Expr], u: Use): seq[ChildUse] =
  ## Every one of `xs`, put to the same use.
  for x in xs: result.add (x, u)

proc fieldValues(fs: seq[FieldInit], u: Use): seq[ChildUse] =
  ## A struct's field values, put to the same use.
  for f in fs: result.add (f.value, u)

proc callUses(res: Resolution, call: Expr): seq[ChildUse] =
  ## A call's operands. A payload struct is not a value of its own: its
  ## fields are the parameters (or, for a construction, the record's fields).
  let named = call.callee != nil and call.callee.kind == exkVar and
              (res.declFor(call) != nil or res.constructs(call))
  result.add (call.callee, if named: uNone else: uBorrow)  # a closure local
  let payload = payloadOf(call)
  let fieldUse = if res.constructs(call): uSink else: uArg
  if payload != nil: result.add fieldValues(payload.fields, fieldUse)
  else: result.add all(call.args, fieldUse)

proc blockUses(b: Expr): seq[ChildUse] =
  ## Statements discard their values; the last one is the block's value.
  for i, s in b.stmts:
    result.add (s, if i == b.stmts.high: uThrough else: uNone)

proc chainUses(e: Expr): seq[ChildUse] =
  ## Lowered away before any backend (lowering_chains); classified for the
  ## checker's tree. The base is threaded through every step.
  result.add (e.base, uSink)
  for s in e.steps: result.add @[(s.target, uNone), (s.arg, uArg)]

proc armUses(e: Expr): seq[ChildUse] =
  ## A match: the subject is looked at; each arm's value is the match's.
  result.add (e.subject, uBorrow)
  for arm in e.arms: result.add (arm.body, uThrough)

proc selectUses(e: Expr): seq[ChildUse] =
  ## `on select`: each arm's source operand is read, its body is run.
  for arm in e.selArms: result.add @[(arm.arg, uBorrow), (arm.body, uNone)]

proc dispatchUses(e: Expr): seq[ChildUse] =
  ## An interface call: each arm's member call reads the receiver's payload.
  result.add (e.dispatchRecv, uBorrow)
  for arm in e.dispatchArms: result.add (arm.call, uThrough)

proc appendUses(e: Expr): seq[ChildUse] =
  ## `xs += v`: the target grows in place; a Seq element is kept, a str's
  ## bytes are only copied.
  @[(e.appendTarget, uMutBorrow),
    (e.appendValue, if e.appendsElement: uSink else: uBorrow)]

proc kindUses(res: Resolution, e: Expr): seq[ChildUse] =
  ## The dispatch: one arm per kind, no `else`.
  case e.kind
  of exkLit, exkVar, exkQualified, exkImport, exkBreak, exkContinue,
     exkTripleDot, exkActorRef, exkRegisterRef, exkRegistryRef,
     exkPoolRef, exkMixinRef, exkSlabRef, exkArenaRef: @[]
  # `.name {args}` left unresolved keeps its arguments in `dotArg`.
  of exkField:
    if e.dotArg != nil or res.variantConstruction(e):
      @[(e.receiver, uNone), (e.dotArg, uSink)]
    # A place projection is handled as ONE read by placeUses/isPlaceRead.
    # For a non-place projection (e.g. xs[i].len), computing the field only
    # borrows its receiver; the parent's sink must not consume the receiver.
    else: @[(e.receiver, uBorrow)]
  of exkStruct: fieldValues(e.fields, uSink)
  of exkList: all(e.items, uSink)
  # A fill's value is copied into every element.
  of exkFill: @[(e.fillValue, uSink), (e.fillCount, uBorrow)]
  # An element is never moved out of its container.
  of exkBracket: @[(e.brReceiver, uBorrow)] & all(e.brArgs, uBorrow)
  of exkBracketAssign: @[(e.brTarget, uMutBorrow), (e.brValue, uSink)]
  of exkCall: res.callUses(e)
  # A combinator's operands carry their fields into the result.
  of exkCombinator: @[(e.combRecv, uSink), (e.combArg, uSink)]
  of exkChain: chainUses(e)
  # Arithmetic, comparison, and a concat (which copies the bytes).
  of exkBinary: @[(e.left, uBorrow), (e.right, uBorrow)]
  of exkUnary: @[(e.operand, uBorrow)]
  of exkBlock: blockUses(e)
  of exkIf:
    @[(e.cond, uBorrow), (e.thenBranch, uThrough), (e.elseBranch, uThrough)]
  of exkMatch: armUses(e)
  of exkFor: @[(e.iterable, uBorrow), (e.body, uNone)]
  of exkWhile: @[(e.whileCond, uBorrow), (e.whileBody, uNone)]
  of exkAssign: @[(e.target, uWrite), (e.assignVal, uSink)]
  of exkReturn: @[(e.returnVal, uSink)]
  of exkRaise: @[(e.raiseVal, uSink)]
  of exkDiscard: @[(e.discardVal, uNone)]
  of exkSend: @[(e.sendPayload, uSink)]        # rule T: into the mailbox
  of exkSelect: selectUses(e)
  of exkDefer: @[(e.deferBody, uNone)]
  of exkAcquire: @[(e.acquireRef, uBorrow)]
  of exkFinish: @[(e.finishHandle, uBorrow)]
  of exkOrdinal: @[(e.ordinalOf, uBorrow)]
  of exkValidate: @[(e.validated, uBorrow)]
  of exkIfaceCall: dispatchUses(e)
  of exkIfaceIs: @[(e.tagSubject, uBorrow)]
  of exkIfacePayload: @[(e.tagSubject, uProject)]
  of exkWrapOk, exkAbsent: @[(e.optValue, uThrough)]
  of exkPoolOp:
    @[(e.poolRef, uNone), (e.poolHandle, uBorrow), (e.poolValue, uSink)]
  # A slab reference is plain data; the value is stored into the cell.
  of exkSlabOp:
    @[(e.slabRef, uNone), (e.slabArg, uBorrow), (e.slabValue, uSink)]
  of exkSlabCell: @[(e.cellSlab, uNone), (e.cellRef, uBorrow)]
  of exkArenaReset: @[(e.arenaRef, uNone)]
  of exkAppend: appendUses(e)
  # A Seq's copy only reads its value. A record's field copy (`cpFields`)
  # binds the value itself and then copies the listed fields in place.
  of exkCopy: @[(e.copied, if e.copyKind == cpFields: uSink else: uBorrow)]
  of exkDrop: @[(e.dropped, uDrop)]
  of exkReset: @[(e.resetPlace, uWrite)]
  of exkMove: @[(e.movedValue, uSink)]

const ByOwnKind* = {exkCall, exkBracket, exkBracketAssign}
  ## Nodes classified by their own kind even when the checker resolved them
  ## to a call: a bracket is the language's element read (or write), and the
  ## runtime call that implements it is not what it means.

proc uses*(res: Resolution, e: Expr): seq[ChildUse] =
  ## Every child of `e` with the use `e` makes of it (rule U). The children
  ## are exactly `ast_ops.childSlots`'s, plus a resolved call in a node's
  ## place and a payload struct's fields in its own.
  if e == nil: @[]
  elif e.kind notin ByOwnKind and res.hasCall(e): @[(res.call(e), uThrough)]
  else: res.kindUses(e)

proc effective*(parent, child: Use): Use =
  ## The use a child makes once its parent's own use is known: a branch or a
  ## block's value takes the parent's, and so does a projection — reading
  ## `b.items` uses the path the way the parent uses the field.
  case child
  of uThrough, uProject: parent
  of uBorrow, uSink, uMutBorrow, uArg, uWrite, uDrop, uNone: child

proc isSingletonRead*(e: Expr): bool =
  ## Any-depth projection through singleton state, not merely `A.field`.
  var base = e
  while base != nil and base.kind == exkField: base = base.receiver
  base != nil and base.kind == exkActorRef and e != base

proc isPlaceRead*(res: Resolution, e: Expr): bool =
  ## A name, or a path through one (`b.items`) — not a call the checker
  ## resolved in its place: one written as a field (`a.total`), or a nullary
  ## fn named bare (`emptyChain`).
  e != nil and e.kind in {exkVar, exkField} and
    (pathOf(e).len > 0 or isSingletonRead(e)) and
    not res.hasCall(e) and
    (e.kind != exkField or (e.dotArg == nil and not res.variantConstruction(e)))

type
  ArgOf* = tuple[call: Expr, index: int, name: string]
    ## The call an argument is given to, and the parameter it feeds: by
    ## `name` for a record-style payload, else by position `index`.
  PlaceUse* = tuple[read: Expr, path: string, use: Use, arg: ArgOf]
    ## A read of a place, and the use it is put to; `arg` is set when the
    ## use is `uArg`.
  Ctx = tuple[use: Use, arg: ArgOf]

let NoArg*: ArgOf = (nil, -1, "")

proc argOf*(call: Expr, k: int): ArgOf =
  ## The parameter a call's `k`-th argument feeds (callUses' order).
  let payload = payloadOf(call)
  if payload != nil and k < payload.fields.len:
    (call, k, payload.fields[k].name)
  else: (call, k, "")

proc placeUses(res: Resolution, e: Expr, ctx: Ctx, acc: var seq[PlaceUse]) =
  ## Every read of a place under `e`, with the use it is put to once every
  ## pass-through above it is resolved. A path is one read: `b.items` is a
  ## read of `b.items`, not also of `b` (the SSA mirror stamps it the same).
  if e == nil: return
  if res.isPlaceRead(e):
    acc.add (e, pathOf(e), ctx.use, ctx.arg)
    if e.kind == exkField: res.placeUses(e.dotArg, (uArg, NoArg), acc)
    return
  var argNo = 0
  for (c, u) in res.uses(e):
    var a = NoArg
    if u in {uThrough, uProject}: a = ctx.arg
    elif u == uArg and e.kind == exkCall:
      a = argOf(e, argNo)
      inc argNo
    res.placeUses(c, (effective(ctx.use, u), a), acc)

proc placeUsesOf*(res: Resolution, body: Expr): seq[PlaceUse] =
  ## A body's place reads with their uses. The body's own value is the fn's
  ## result, so it is a sink.
  res.placeUses(body, (uSink, NoArg), result)

proc placeUsesUnder*(res: Resolution, e: Expr, use: Use): seq[PlaceUse] =
  ## The place reads under `e`, which is itself put to `use` — for a walk
  ## that visits statements one at a time.
  res.placeUses(e, (use, NoArg), result)

proc typeResolvedCalls*(res: Resolution, m: Module) =
  ## A call the checker resolved in a node's place (`ys.len` is
  ## `len(ys)`) has the node's type: what the call returns is what the node
  ## is. The checker records the call before the node's type is known, so
  ## the call is typed here, before anything asks what a callee returns.
  for body in m.bodies:
    for n in body.nodes:
      if n.kind == exkCall or not res.hasCall(n): continue
      let c = res.call(n)
      if c != nil and res.typeFor(c) == nil and res.typeFor(n) != nil:
        res.setType(c, res.typeFor(n))

let DebugUses = getEnv("TUCK_DEBUG_OWN") == "uses"
  ## Read once at module init.

proc dumpUses*(res: Resolution, m: Module) =
  ## TUCK_DEBUG_OWN=uses: every read of an OWNING place in every fn body,
  ## with its use and whether the mirror proved it final — what rule S reads.
  if not DebugUses: return
  for d in m.allFns:
    if d == nil or d.fnBody == nil: continue
    for (read, path, use, _) in res.placeUsesOf(d.fnBody):
      if not ownsHeap(m, res.typeFor(read)): continue
      let final = if res.isLastUse(read): " final" else: ""
      echo "USE ", d.name, " ", path, " ", ($use)[1 .. ^1].toLowerAscii,
           final, " ", read.span.line, ":", read.span.col
