# compiler/ssa_ir.nim
#
# THE SSA VALUE GRAPH — types only. Construction is `ssa_build.nim`; the
# questions asked of it are `ssa_query.nim`.
#
# ---------------------------------------------------------------------------
# WHAT THIS IS, AND HOW IT RELATES TO Resolution
# ---------------------------------------------------------------------------
#
# The same shape as `Resolution`: a side structure that ACCOMPANIES the AST
# and knows more about it. It is not a copy of the tree and does not own one —
# every `Def` holds the NodeId that produced it and, where a consumer needs to
# ask a question rather than merely identify a node, the `Expr` itself.
#
# It differs from Resolution in the one way that matters for memory:
#
#   Resolution answers a question about a NODE      — what type is this?
#   this answers a question about a VALUE           — which buffer is this?
#
# and one name holds many values over its life. `xs` in
#
#     var xs = [0]
#     for i < n:
#       xs = {items: xs, value: i} push
#
# is one name, one declaration node, and n+1 distinct buffers. Ask Resolution
# and you get one answer, because there is one node. Ownership needs to know
# whether THIS buffer is still reachable, which is a question the node cannot
# hold the answer to.
#
# `byNode` is nonetheless the primary index, because that is how every
# consumer arrives: an emitter is at a node and wants to know what it is
# looking at. Place-and-version is the internal organising principle; the node
# map is the front door.
#
# ---------------------------------------------------------------------------
# VARIABLES ARE ACCESS PATHS
# ---------------------------------------------------------------------------
#
# Braun's algorithm versions "variables". Tuck's are PLACES — `b`, `b.ask`,
# `b.bid` — because the ownership question is per field: a record can hand one
# field back to its caller and free the other two. Versioning `b` as a whole
# answers "is any of it live", which is the wrong question and the reason
# `analysis_liveness` was path-granular too.
#
# A write to `b` kills every `b.*` currently live: the record was replaced, so
# a version of `b.ask` from before it describes nothing.
#
# ---------------------------------------------------------------------------
# BLOCKS ARE FIRST CLASS
# ---------------------------------------------------------------------------
#
# The previous mirror encoded control flow as a '/'-joined STRING —
# `"L3/A7:then"` — and answered "can these two reads both happen" by splitting
# it apart again at query time. A tree, serialised and re-parsed per question.
#
# Here a block is a node with a predecessor list, which is what Braun's
# construction needs anyway, and it buys three things the string could not:
# the query is a set operation rather than string surgery; a block is a name
# for a SCOPE, so SSA over a chosen region is expressible; and `sealed` has
# somewhere to live, which is how loops stop being a special case.
import ast, tables, sets, strutils

type
  ValueId* = distinct int32
  BlockId* = distinct int32

  Place* = string
    ## An access path: `b`, `b.ask`. "" means the walk could not NAME this
    ## location — an index, a call result — which is different from it not
    ## having one, and the caller falls back to the root.

  DefKind* = enum
    ## Where a value came from. The ownership pass reads this to decide
    ## whether this body could have allocated the buffer.
    dkEntry      ## live on entry: a parameter, an actor field, a const, a
                 ## name from an enclosing scope
    dkLiteral    ## a list or scalar literal — this body's own storage
    dkConstruct  ## a record construction
    dkCall       ## a call's result
    dkProject    ## read out of another value: `b.ask` given `b`
    dkAlias      ## another NAME for a value: `let a = s`.
                 ##
                 ## Whether that copies or aliases is a question about the
                 ## TYPE, not the syntax — on Odin `let a = s` copies a `Seq`
                 ## and aliases a `str` — so the graph records the edge and
                 ## leaves the reading to whoever knows the type.
    dkPhi        ## a join of two or more values
    dkUndef      ## Braun's Undef: a phi with no reachable operand. Should not
                 ## survive a well-formed body, and is asserted against.
    dkOpaque     ## a shape the builder does not model. Always the safe
                 ## answer, never mistaken for one of the above.

  FreeKind* = enum
    ## Where a value's storage is released, once the ownership pass has
    ## decided. Recorded ON THE VALUE so that "freed twice" and "used after
    ## free" are checkable rather than reviewable.
    fkNotFreed
    fkScopeExit
    fkOverwrite
    fkTwinParam

  Def* = object
    kind*: DefKind
    at*: NodeId          ## the expression that produced it; unset for phis
    src*: Expr           ## ...and that expression, for a consumer that needs
                         ## to ask about it rather than identify it
    inputs*: seq[ValueId]  ## phi operands, or the base of a projection

  Use* = object
    at*: NodeId
    blk*: BlockId        ## WHERE the read happens. Replaces the region
                         ## string: "can these two both happen" is now a
                         ## reachability question between two blocks.
    line*, col*: int     ## the read's source position, for `tuck ssa` and
                         ## the goldens — a NodeId means nothing to a reader

  Value* = object
    id*: ValueId
    place*: Place
    version*: int
    def*: Def
    blk*: BlockId        ## the block the DEFINITION sits in
    uses*: seq[Use]
    freedAt*: NodeId     ## where its storage is released, if it is
    freedBy*: FreeKind

  Block* = object
    id*: BlockId
    label*: string       ## human-readable, for `dump` — never parsed
    preds*: seq[BlockId]
    sealed*: bool        ## are all predecessors known?
                         ##
                         ## FALSE for a loop head until its body is built,
                         ## because the back edge does not exist yet. That one
                         ## flag is the whole of Braun's loop handling, and
                         ## its absence is why the previous builder needed a
                         ## special case per construct — and got three of them
                         ## wrong.
    exits*: bool         ## every path through this block leaves the body
                         ## (`return`, `raise`), so nothing after it runs

  SsaFn* = object
    name*: string
    values*: seq[Value]
    blocks*: seq[Block]
    entry*: BlockId
    byNode*: Table[NodeId, ValueId]
      ## THE FRONT DOOR. Every read site, and every definition site, mapped to
      ## the value it names. A consumer holding a node asks here.
    incompletePhis*: Table[BlockId, Table[Place, ValueId]]
      ## phis parked in an unsealed block, filled in when it seals
    deferredRoots*: HashSet[string]
      ## roots a `defer` body reads. A defer runs at SCOPE EXIT, after the
      ## apparent last use of everything it names, so its reads are live
      ## throughout — recorded here because the graph records the read where
      ## it is WRITTEN, which is early.

const
  NoValue* = ValueId(-1)
  NoBlock* = BlockId(-1)

proc `==`*(a, b: ValueId): bool {.borrow.}
proc `==`*(a, b: BlockId): bool {.borrow.}
proc `$`*(v: ValueId): string = "%" & $int32(v)
proc `$`*(b: BlockId): string = "b" & $int32(b)
proc isSet*(v: ValueId): bool = int32(v) >= 0
proc isSet*(b: BlockId): bool = int32(b) >= 0

proc val*(fn: SsaFn, v: ValueId): Value = fn.values[int32(v)]
proc blk*(fn: SsaFn, b: BlockId): Block = fn.blocks[int32(b)]

proc pathOf*(e: Expr): Place =
  ## `b.ask` for a field chain rooted at a name, `b` for a bare name, "" for
  ## anything else.
  if e == nil: return ""
  case e.kind
  of exkVar: e.name
  of exkField:
    let base = pathOf(e.receiver)
    if base.len == 0: "" else: base & "." & e.fieldName
  else: ""

proc rootOf*(p: Place): string =
  let i = p.find('.')
  if i < 0: p else: p[0 ..< i]

proc isUnder*(p, root: Place): bool =
  ## Is `p` this root or a field of it? A write to the root kills all of them.
  p == root or p.startsWith(root & ".")
