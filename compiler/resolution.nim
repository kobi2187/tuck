# compiler/resolution.nim
# The semantic layer: what the checker concluded, keyed by node identity.
#
# The AST stays a faithful record of syntax. Everything the checker DERIVES
# lives here instead of in the tree, so a later pass may rewrite or clone the
# tree for its target without carrying (or losing) semantic residue: ids
# survive the copy, so these lookups still resolve.

import tables
import ast

type
  Resolution* = object
    ## Sugar that turned out to be a call. One table, because callNode,
    ## varCallNode, brCallNode and brAssignNode were always the same idea:
    ## `x.f`, a bare nullary `f`, `xs[i]` and `xs[i] = v` all resolve to an
    ## ordinary call once the checker knows the types.
    calls*: Table[NodeId, Expr]

proc setCall*(r: var Resolution, e: Expr, call: Expr) =
  if e != nil and e.id.isSet:
    r.calls[e.id] = call

proc call*(r: Resolution, e: Expr): Expr =
  ## The resolved call for this node, or nil if it did not resolve to one.
  if e == nil or not e.id.isSet: return nil
  r.calls.getOrDefault(e.id, nil)

proc hasCall*(r: Resolution, e: Expr): bool =
  e != nil and e.id.isSet and r.calls.hasKey(e.id)

# The program-wide semantic layer. The compiler processes one program per
# run, so a single instance is the honest model; passing it through every
# signature in checker, lowering and both backends would be pure ceremony.
# Cleared at the start of each check so repeated in-process runs (the test
# suites) never see a previous program's entries.
var current* = Resolution(calls: initTable[NodeId, Expr]())

proc resetResolution*() =
  current = Resolution(calls: initTable[NodeId, Expr]())

proc setStepCall*(r: var Resolution, s: ChainStep, call: Expr) =
  if s.id.isSet: r.calls[s.id] = call

proc stepCall*(r: Resolution, s: ChainStep): Expr =
  if not s.id.isSet: return nil
  r.calls.getOrDefault(s.id, nil)
