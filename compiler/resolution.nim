# compiler/resolution.nim
# The semantic layer: what the checker concluded, keyed by node identity.
#
# The AST stays a faithful record of syntax. Everything the checker DERIVES
# lives here instead of in the tree, so a later pass may rewrite or clone the
# tree for its target without carrying (or losing) semantic residue: ids
# survive the copy, so these lookups still resolve.

import tables, sets
import ast

type
  Resolution* = object
    ## Sugar that turned out to be a call. One table, because callNode,
    ## varCallNode, brCallNode and brAssignNode were always the same idea:
    ## `x.f`, a bare nullary `f`, `xs[i]` and `xs[i] = v` all resolve to an
    ## ordinary call once the checker knows the types.
    calls*: Table[NodeId, Expr]
    types*: Table[NodeId, Type]        # what the checker inferred
    shortcuts*: Table[NodeId, string]  # errors-policy drop sites
    asyncCalls*: HashSet[NodeId]       # call sites whose callee is [io] —
                                       # codegen awaits/yields them (async)
    # Name resolution, recorded once by the checker and read by every later
    # pass. `decls` is the index — "give me that declaration" — and `declOf`
    # is the edge a reference has to its target: "what does this name mean".
    # Together they replace asking the module "which decl is named X", which
    # is a scan of the declaration list per question.
    decls*: Table[NodeId, Decl]        # id -> the declaration itself
    declOf*: Table[NodeId, NodeId]     # referring node -> declaration id
    # How a call's payload maps onto its callee's parameters, decided once by
    # checkCallArgs. `argFields[i]` names the payload FIELD that satisfies
    # param i — matched by name, or by type when the names differ — and
    # `callParams[i]` is that param's own name. Codegen and lowering read
    # these instead of re-deriving the mapping, which misses by-type matches.
    argFields*: Table[NodeId, seq[string]]
    callParams*: Table[NodeId, seq[string]]

proc ensureId*(e: Expr) =
  ## Nodes minted after the parse boundary (checker-synthesized calls) have
  ## no id yet. Give them one on first use so nothing silently drops out of
  ## the semantic layer.
  if e != nil and not e.id.isSet: e.id = newNodeId()

proc setCall*(r: var Resolution, e: Expr, call: Expr) =
  if e == nil: return
  ensureId(e)
  r.calls[e.id] = call

proc call*(r: Resolution, e: Expr): Expr =
  ## The resolved call for this node, or nil if it did not resolve to one.
  if e == nil or not e.id.isSet: return nil
  if r.calls.hasKey(e.id): r.calls[e.id] else: nil

proc hasCall*(r: Resolution, e: Expr): bool =
  e != nil and e.id.isSet and r.calls.hasKey(e.id)

proc markAsync*(r: var Resolution, e: Expr) =
  ## Flag a call site as async — its callee carries [io], so codegen emits the
  ## suspend/await transform (the effect marker IS the async annotation).
  if e == nil: return
  ensureId(e)
  r.asyncCalls.incl(e.id)

proc isAsync*(r: Resolution, e: Expr): bool =
  e != nil and e.id.isSet and e.id in r.asyncCalls

# The program-wide semantic layer. The compiler processes one program per
# run, so a single instance is the honest model; passing it through every
# signature in checker, lowering and both backends would be pure ceremony.
# Cleared at the start of each check so repeated in-process runs (the test
# suites) never see a previous program's entries.
var semLayer* = Resolution(calls: initTable[NodeId, Expr](),
                            types: initTable[NodeId, Type](),
                            shortcuts: initTable[NodeId, string](),
                            asyncCalls: initHashSet[NodeId](),
                            decls: initTable[NodeId, Decl](),
                            declOf: initTable[NodeId, NodeId](),
                            argFields: initTable[NodeId, seq[string]](),
                            callParams: initTable[NodeId, seq[string]]())

proc resetResolution*() =
  semLayer = Resolution(calls: initTable[NodeId, Expr](),
                            types: initTable[NodeId, Type](),
                            shortcuts: initTable[NodeId, string](),
                            asyncCalls: initHashSet[NodeId](),
                            decls: initTable[NodeId, Decl](),
                            declOf: initTable[NodeId, NodeId](),
                            argFields: initTable[NodeId, seq[string]](),
                            callParams: initTable[NodeId, seq[string]]())

proc setStepCall*(r: var Resolution, s: ChainStep, call: Expr) =
  if s.id.isSet: r.calls[s.id] = call

proc stepCall*(r: Resolution, s: ChainStep): Expr =
  if not s.id.isSet: return nil
  if r.calls.hasKey(s.id): r.calls[s.id] else: nil

# --- types and shortcut sites ----------------------------------------------

proc setType*(r: var Resolution, e: Expr, t: Type) =
  if e == nil: return
  ensureId(e)
  r.types[e.id] = t

proc typeFor*(r: Resolution, e: Expr): Type =
  ## The checker's type for this node, or nil if it was never typed.
  if e == nil or not e.id.isSet: return nil
  if r.types.hasKey(e.id): r.types[e.id] else: nil

# --- name resolution ---------------------------------------------------------

proc indexDecl*(r: var Resolution, d: Decl) =
  ## Register a declaration so references can point at it.
  if d != nil and d.id.isSet: r.decls[d.id] = d

proc resolveTo*(r: var Resolution, e: Expr, d: Decl) =
  ## Record that this expression refers to that declaration. Called where the
  ## checker already resolved the name, so the answer costs nothing to keep.
  if e == nil or d == nil or not d.id.isSet: return
  ensureId(e)
  r.decls[d.id] = d
  r.declOf[e.id] = d.id

proc declFor*(r: Resolution, e: Expr): Decl =
  ## The declaration this expression refers to, or nil if the checker never
  ## resolved it (sketch code, a local, a builtin).
  if e == nil or not e.id.isSet: return nil
  if not r.declOf.hasKey(e.id): return nil
  r.decls.getOrDefault(r.declOf[e.id], nil)

proc resolveTypeTo*(r: var Resolution, t: Type, d: Decl) =
  ## Record that this type reference names that declaration. A tkNamed carries
  ## a name because that is what the user wrote; this is what it MEANS.
  if t == nil or d == nil or not d.id.isSet: return
  if not t.id.isSet: t.id = newNodeId()
  r.decls[d.id] = d
  r.declOf[t.id] = d.id

proc declForType*(r: Resolution, t: Type): Decl =
  ## The declaration a named type refers to, or nil if never resolved.
  if t == nil or not t.id.isSet: return nil
  if not r.declOf.hasKey(t.id): return nil
  r.decls.getOrDefault(r.declOf[t.id], nil)

proc setArgFields*(r: var Resolution, e: Expr, fields: seq[string]) =
  ## Which payload field feeds each param, in param order.
  if e == nil: return
  ensureId(e)
  r.argFields[e.id] = fields

proc argFieldsFor*(r: Resolution, e: Expr): seq[string] =
  ## Empty when the checker recorded no mapping — callers fall back to
  ## matching by param name.
  if e == nil or not e.id.isSet: return @[]
  r.argFields.getOrDefault(e.id, @[])

proc setCallParams*(r: var Resolution, e: Expr, params: seq[string]) =
  ## The callee's parameter names, in declaration order.
  if e == nil: return
  ensureId(e)
  r.callParams[e.id] = params

proc callParamsFor*(r: Resolution, e: Expr): seq[string] =
  ## Empty when the callee was never resolved, or is not one whose payload
  ## may be exploded (a member fn, a task) — callers leave the call alone.
  if e == nil or not e.id.isSet: return @[]
  r.callParams.getOrDefault(e.id, @[])

proc setShortcut*(r: var Resolution, e: Expr, site: string) =
  if e == nil: return
  ensureId(e)
  r.shortcuts[e.id] = site

proc shortcut*(r: Resolution, e: Expr): string =
  ## Non-empty when the errors policy routes this statement's dropped !T
  ## to the global handler.
  if e == nil or not e.id.isSet: return ""
  r.shortcuts.getOrDefault(e.id, "")
