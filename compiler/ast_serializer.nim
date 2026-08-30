# compiler/ast_serializer.nim
#
# The AST as JSON — a debugging window, not part of the pipeline.
#
# `tuck p file.tuck --ast` prints the tree this produces. That is the fastest
# way to answer "what did the parser actually build?", and the fastest way to
# see what a pass rewrote, since you can diff the tree before and after.
#
# jsony walks the type, so this cannot drift out of sync with ast.nim the way
# a hand-written serializer does — the previous one had silently stopped
# emitting 7 ExprKinds and 9 DeclKinds, which is worst precisely when you
# reach for a dump. It also dumps `span` and the inherited node id, which the
# hand-written version dropped.
import std/json
import jsony
import ast
import ast_query
import resolution

proc toJson*(m: Module): JsonNode =
  ## Parsed back into a JsonNode so callers can `pretty()` it — these dumps are
  ## read by people. jsony emits compact JSON in one pass; the reparse is only
  ## for formatting.
  parseJson(jsony.toJson(m))

proc semEntry(e: Expr): JsonNode =
  ## One node's semLayer entry, or nil if the checker recorded nothing for
  ## it. `toJson` above dumps the TREE only — types, resolved calls and
  ## async marks live in the side-table (compiler/resolution.nim),
  ## invisible to that dump. Right after parsing vs right after typecheck
  ## would look almost identical without this: the tree shape barely
  ## changes, and the whole POINT of typechecking is in the side-table.
  var obj = newJObject()
  let t = semLayer.typeFor(e)
  if t != nil: obj["type"] = parseJson(jsony.toJson(t))
  if semLayer.hasCall(e):
    let c = semLayer.call(e)
    let decl = if c != nil: semLayer.declFor(c) else: nil
    if decl != nil: obj["call"] = %decl.name
  if semLayer.isAsync(e): obj["async"] = %true
  if obj.len == 0: return nil
  obj["id"] = %($e.id)
  obj

proc walkSemEntries(e: Expr, into: var seq[JsonNode]) =
  if e == nil: return
  let entry = semEntry(e)
  if entry != nil: into.add(entry)
  for c in e.children: walkSemEntries(c, into)

proc semLayerJson*(mods: seq[Module]): JsonNode =
  ## Every node with a recorded semLayer entry, across every module, as a
  ## flat sparse array keyed by NodeId — a SEPARATE array alongside the
  ## tree's own JSON, not merged into it. Cross-referencing by `id` against
  ## the tree dump is left to the reader; a richer inline-annotated view is
  ## a deliberate follow-up, not v1.
  var entries: seq[JsonNode]
  for m in mods:
    for fn in m.allFns(): walkSemEntries(fn.fnBody, entries)
    for d in m.decls(dkTask): walkSemEntries(d.taskBody, entries)
    for d in m.decls(dkExpr): walkSemEntries(d.expr, entries)
  %entries
