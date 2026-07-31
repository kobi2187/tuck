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

proc toJson*(m: Module): JsonNode =
  ## Parsed back into a JsonNode so callers can `pretty()` it — these dumps are
  ## read by people. jsony emits compact JSON in one pass; the reparse is only
  ## for formatting.
  parseJson(jsony.toJson(m))
