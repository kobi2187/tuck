# compiler/ownership_str.nim
#
# WHICH `str` LOCALS A BODY ALLOCATED AND NEVER LETS GO — the `str` half of
# the ownership pass (ROADMAP M3.3).
#
# It lived in the Odin EMITTER, a second ownership analysis beside
# `analysis_ownership` with its own once-assigned rule and its own escape
# walk, deciding frees while printing. Moved here unchanged in logic; what
# changed is where the answer goes — into the same `Ownership` record as
# every other free, so the pass's invariants (one release per slot) and
# buffer_check (no buffer released at exit and also returned — the exact
# shape of the `str` use-after-free this analysis once shipped) now cover it.
#
# THE BACKEND-SPECIFIC PART IS A PARAMETER. Which runtime calls hand back a
# `str` the caller owns is a fact about each backend's runtime, not about
# Tuck, so it arrives as a list (backend_prepare.ownedStrProcs) rather than
# as a second analysis per backend.
import tables, strutils
import ast, ast_query
import resolution
from ssa_ir import pathOf


proc ownedStrCall(res: Resolution, procs: seq[string], e: Expr): bool =
  ## Is this expression a call to one of those?
  ##
  ## RESOLVED, not read off the syntax: `i.toStr` is an `exkField` in the
  ## tree and only the resolution layer knows it is a call at all. Matching
  ## on the node kind alone answered false for the commonest spelling there
  ## is, which is how this was found.
  if e == nil: return false
  if e.kind == exkBinary and isStringConcat(e): return true   # `a + b`
  var c = e
  if res.hasCall(c): c = res.call(c)
  if c == nil or c.kind != exkCall or c.callee == nil or
     c.callee.kind != exkVar: return false
  var n = c.callee.name
  for sep in [".", ":"]:
    let i = n.rfind(sep)
    if i >= 0: n = n[i + sep.len .. ^1]
  n in procs

proc holdsAStrType(t: Type): bool =
  ## Could a value of this type be CARRYING a `str` it was handed?
  ##
  ## A scalar cannot. A `str` OBVIOUSLY CAN — it is one. This used to answer
  ## false for `str`, reasoning that "the runtime procs that answer one
  ## allocate rather than passing a string through", and that reasoning
  ## confuses what a CALL RETURNS with what a VALUE CAN HOLD. The exemption
  ## belongs to the call, and it is made in `sealsFor` where it is true;
  ## making it here made `return s` not an escape, so a returned local was
  ## freed before its caller read it:
  ##
  ##     tuck_label :: proc (n: int) -> string {
  ##       tuck_s := str.toStr(n)
  ##       defer delete(tuck_s)
  ##       return tuck_s          // <- freed, then returned
  ##     }
  ##
  ## A use-after-free that prints garbage, found by review rather than by any
  ## assertion: every `str` in the corpus is consumed where it is built.
  if t == nil: return true                 # unknown: assume it could
  case t.kind
  of tkNamed: t.name notin ["int", "bool", "float", "void",
                            "u8", "u16", "u32", "u64",
                            "i8", "i16", "i32", "i64", "f32", "f64"]
  else: true

proc holdsAStr(res: Resolution, e: Expr): bool = holdsAStrType(res.typeFor(e))

proc sealsFor(res: Resolution, procs: seq[string], n: Expr, sealed: bool): bool =
  ## Does this node put whatever is inside it beyond this scope's reach?
  ##
  ## WHAT THE DESTINATION CAN HOLD is the test at every seal, not the node
  ## kind. A `return` of an int, or a call that answers one, cannot be
  ## carrying our string away — and `acc = acc + s.len` is exactly that
  ## shape, so sealing on the kind alone made every string in every fold look
  ## as though it escaped.
  if sealed or n.kind == exkSend: return true   # a message outlives us
  if n.kind in {exkReturn, exkRaise}:
    return n.returnVal == nil or holdsAStr(res, n.returnVal)
  if n.kind == exkCall:
    # A call that ALLOCATES its result does not carry an argument out: what
    # comes back is fresh storage, so passing our string in does not let it
    # escape. That is the exemption `holdsAStrType` used to make for the type
    # as a whole, which was too wide by exactly one case — `return s`.
    if ownedStrCall(res, procs, n): return false
    return holdsAStr(res, n)
  false

proc strEscapes(res: Resolution, procs: seq[string], body: Expr, name: string): bool =
  ## Does this local's value leave the body, by any route whose end the
  ## emitter cannot see?
  ##
  ## CONSERVATIVE AND LISTED, because each of these is a use-after-free if it
  ## is wrong and only a leak if it is too strict: a `return`, a `send`
  ## payload, a construction that could be holding it, and an assignment to
  ## anything but this same local.
  ##
  ## An ordinary call ARGUMENT is not an escape: the callee cannot keep a
  ## `str` beyond the call except by returning it — and a call result is only
  ## freed when the callee is on the backend's list, which allocates rather than
  ## passing one through.
  if body == nil: return false
  var stack = @[(body, false)]
  while stack.len > 0:
    let (n, sealed) = stack.pop()
    if n == nil: continue
    if n.kind == exkVar and n.name == name and sealed: return true
    let seals = sealsFor(res, procs, n, sealed)
    if n.kind == exkAssign:
      let toElsewhere = n.target != nil and pathOf(n.target) != name
      stack.add((n.assignVal,
                 if toElsewhere: holdsAStr(res, n.target) else: seals))
      stack.add((n.target, seals))
      continue
    for ch in n.children: stack.add((ch, seals))
  false

proc collectDecls(body: Expr, assigned: var CountTable[string],
                  decls: var Table[string, Expr]) =
  ## Every name this body assigns, how many times, and the value each was
  ## DECLARED with.
  var stack = @[body]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil: continue
    for ch in n.children: stack.add(ch)
    if n.kind != exkAssign or n.target == nil or n.target.kind != exkVar:
      continue
    assigned.inc(n.target.name)
    if n.isDecl: decls[n.target.name] = n.assignVal

proc isOwnedStrLocal(res: Resolution, procs: seq[string], d: Decl,
                     name: string, val: Expr,
                     assigned: CountTable[string]): bool =
  ## ASSIGNED EXACTLY ONCE is the restriction that makes the `defer` correct
  ## with no further analysis: one version, no phi, no reassignment, so the
  ## name and the allocation are the same thing for the whole scope and
  ## `defer delete` at the declaration fires exactly once on exactly it.
  if assigned[name] != 1: return false
  let t = res.typeFor(val)
  if t == nil or t.kind != tkNamed or t.name != "str": return false
  if not ownedStrCall(res, procs, val): return false
  not strEscapes(res, procs, d.fnBody, name)

proc ownedStrLocals*(res: Resolution, procs: seq[string], d: Decl): seq[string] =
  ## Which of this fn's locals hold a `str` it allocated and never lets go.
  ## `procs` is the backend's list of runtime calls that hand back storage
  ## the caller owns (backend_prepare.ownedStrProcs); empty, nothing is.
  if d.fnBody == nil or procs.len == 0: return
  var assigned: CountTable[string]
  var decls: Table[string, Expr]
  collectDecls(d.fnBody, assigned, decls)
  for name, val in decls:
    if isOwnedStrLocal(res, procs, d, name, val, assigned): result.add(name)
