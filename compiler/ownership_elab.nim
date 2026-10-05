# compiler/ownership_elab.nim
#
# THE ELABORATOR — Stage D of the ownership rules
# (thoughts/shared/plans/2026-10-05-ownership-rules-proposal.md, §2, §5).
#
# It computes, from the rules alone, the decisions the passes it replaces
# compute today: which parameters consume (P), which sinks move and which
# copy (S), where each owned place is dropped (D) and reset (M). It runs in
# SHADOW MODE first — beside today's passes, deciding nothing that is
# printed — so every difference between the two can be explained before
# anything switches (`ownership_shadow`).
#
# Every question starts from rule U's classifier (`ownership_rules`): what a
# read IS (borrow, sink, an argument) is decided there once, per node kind.
#
# RULE P — a parameter is consuming iff some final read of it (or of a path
# through it) is a sink. An argument is a sink when the parameter it feeds
# consumes, so the answer is the least fixed point over the call graph: a
# call back into a question still being answered reads as "borrows", which
# is what a recursive reader is. A read that cannot carry the parameter's
# storage away — a scalar field, `b.count` — is never a sink of it.
#
# A CALLEE WITH NO BODY to ask is answered by THE RUNTIME TABLE below when
# it is the runtime's: only `push` and `setAt` (and the compiler's own
# `tuckSetAt` / `tuckArraySetAt`) keep an argument; every other runtime
# extern and helper reads its arguments and returns fresh values. An extern
# the table does not know — foreign code a program links — is taken to
# consume: that is the safe answer (the caller hands over a value it will
# not touch again, moving a dead one and copying a live one), and the one
# `codegen_common.keptAt` gives every body-less callee today.
import tables, sets
import ast, ast_ops, ast_query
import resolution
import ownership_rules
from ssa_ir import rootOf
from twin_shape import ownsHeap

type ConsumeMemo* = object
  ## Rule P's answers so far, and the questions being answered (a recursive
  ## call into one reads as "borrows").
  known: Table[string, bool]
  busy: HashSet[string]

proc calleeOf(res: Resolution, m: Module, call: Expr): Decl =
  ## The fn a call reaches: as the checker resolved it, else by name (calls
  ## that lowering built carry no resolution of their own).
  result = res.declFor(call)
  if result == nil and call.callee != nil and call.callee.kind == exkVar:
    result = m.findFn(call.callee.name)
  if result != nil and result.kind != dkFn: result = nil

type Keeps = enum kUnknown, kBorrows, kKeeps

const
  RuntimeKeeps = [("push", "items"), ("push", "value"), ("setAt", "value")]
    ## The runtime externs' parameters that KEEP their argument: `push`
    ## returns `items` grown and stores `value`; `setAt` stores `value`.
  HelperKeeps = [("tuckSetAt", 2), ("tuckArraySetAt", 2)]
    ## The same for the helpers the compiler introduces (positional: no
    ## declaration names their parameters): the stored value.
  RuntimeNames = ["at", "setAt", "push", "count", "len", "toStr", "charAt",
                  "containsChar", "splitLines", "ord", "joinStr", "byteAt",
                  "byteCount", "parseFloat", "fromBytes", "print",
                  "printLine", "readFile", "writeFile", "appendFile",
                  "fileExists", "removeFile", "makeDir", "hash", "sqrt",
                  "pow", "send", "connect", "recv", "getEnv",
                  "tuckAt", "tuckSetAt", "tuckArrayAt", "tuckArraySetAt",
                  "tuckConcat", "tuckSat", "tuckSatI", "tuckSeqBounds",
                  "tuckSeqCopy"]
    ## Every runtime callee that can be handed an owning value. Unmangled:
    ## a user fn of the same name is `tuckˑfnˑ…` by the time this runs.

proc runtimeKeeps(callee: string, param: string, index: int): Keeps =
  ## What the runtime does with an argument, or kUnknown for a callee that
  ## is not the runtime's.
  if callee notin RuntimeNames: return kUnknown
  for (fn, p) in RuntimeKeeps:
    if fn == callee and p == param: return kKeeps
  for (fn, i) in HelperKeeps:
    if fn == callee and i == index: return kKeeps
  kBorrows

proc paramFed(d: Decl, a: ArgOf): string =
  ## The name of the parameter of `d` the argument `a` feeds, or "".
  if a.name.len > 0: return a.name
  if a.index >= 0 and a.index < d.fnParams.len: d.fnParams[a.index].name
  else: ""

proc consumes*(res: Resolution, m: Module, d: Decl, pname: string,
               memo: var ConsumeMemo): bool

proc argConsumesWhy(res: Resolution, m: Module, a: ArgOf,
                    memo: var ConsumeMemo): string =
  ## Why the parameter this argument feeds consumes it, or "" if it borrows.
  if a.call == nil: return "an unresolved call"   # `.name {args}` left as is
  let callee = res.calleeOf(m, a.call)
  let name = if callee != nil: callee.name
             elif a.call.callee != nil and a.call.callee.kind == exkVar:
               a.call.callee.name
             else: ""
  let p = if callee != nil: paramFed(callee, a) else: a.name
  case runtimeKeeps(name, p, a.index)
  of kKeeps: return "the runtime's " & name & " keeps it"
  of kBorrows: return ""
  of kUnknown: discard
  if callee == nil or callee.fnBody == nil or p.len == 0:
    return name & " has no body to ask"
  if res.consumes(m, callee, p, memo): name & " keeps it" else: ""

proc consumesWhy*(res: Resolution, m: Module, d: Decl, pname: string,
                  memo: var ConsumeMemo): string =
  ## Rule P with its reason: the first final read of `pname` that is a sink,
  ## named, or "" when `d` only borrows it. Not memoised; `consumes` is.
  if d.fnBody == nil: return ""
  for pu in res.placeUsesOf(d.fnBody):
    if rootOf(pu.path) != pname or not res.isLastUse(pu.read): continue
    if not ownsHeap(m, res.typeFor(pu.read)): continue   # carries nothing
    let at = " at " & $pu.read.span.line & ":" & $pu.read.span.col
    if pu.use == uSink: return "a sink" & at
    if pu.use == uArg:
      let why = res.argConsumesWhy(m, pu.arg, memo)
      if why.len > 0: return why & at
  ""

proc consumes*(res: Resolution, m: Module, d: Decl, pname: string,
               memo: var ConsumeMemo): bool =
  ## Rule P: does `d` consume its parameter `pname`? The least fixed point:
  ## a question asked again while it is being answered reads as "borrows".
  let key = $d.id.uint32 & "\0" & d.name & "\0" & pname
  if key in memo.known: return memo.known[key]
  if key in memo.busy: return false
  memo.busy.incl key
  result = res.consumesWhy(m, d, pname, memo).len > 0
  memo.busy.excl key
  memo.known[key] = result
