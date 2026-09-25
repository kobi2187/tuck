# compiler/ownership_str.nim
#
# WHICH `str` VALUES A BODY OWNS — the one part of the `str` question that is
# not the `Seq` question.
#
# There used to be a whole second ownership analysis here, and before that in
# the Odin EMITTER: its own once-assigned rule, its own escape walk with its
# own copy of the sealing rules, deciding frees while printing
# (docs/ownership-and-ssa.md §5 M6). Its copy of the rules is the one that
# shipped a use-after-free (M7). Both halves now live in the ownership pass:
# a `str` local is a value with one slot, it dies at scope exit by step 4's
# rule, and whether it escapes is `ownership_escape`'s question, asked with
# the `str` rule below.
#
# WHAT IS LEFT is what genuinely differs: WHICH CALLS HAND BACK STORAGE THE
# CALLER OWNS. That is a fact about each backend's runtime, not about Tuck, so
# it arrives as a list (backend_prepare.ownedStrProcs) — empty on the
# backends whose runtime frees its own.
import strutils, sets
import ast, ast_query, ast_ops
import resolution
import ownership_escape

proc ownedStrCall*(res: Resolution, procs: seq[string], e: Expr): bool =
  ## Is this expression a call to one of the backend's allocating procs — so
  ## what it returns is fresh storage the caller now owns?
  ##
  ## RESOLVED, not read off the syntax: `i.toStr` is an `exkField` in the
  ## tree and only the resolution layer knows it is a call at all. Matching
  ## on the node kind alone answered false for the commonest spelling there
  ## is, which is how this was found.
  if e == nil or procs.len == 0: return false
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

proc strRule*(res: Resolution, procs: seq[string], body: Expr): SealRule =
  ## The escape rule for `str`: a call to an allocating proc returns fresh
  ## storage, so an argument passed in is not carried out by it. Nothing
  ## exempts a BINDING — a `str` assignment shares its buffer on every
  ## backend that needs this analysis.
  result = SealRule(carried: cStr)
  var stack = @[body]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil: continue
    for ch in n.children: stack.add ch
    if n.kind == exkCall and ownedStrCall(res, procs, n):
      result.exemptCalls.incl n.id
