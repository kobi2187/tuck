# compiler/escape.nim
#
# Escape analysis, as a standalone solver. Imports NOTHING from the compiler —
# no ast, no typecheck — so it can be reasoned about and tested on its own.
#
# THE QUESTION IT ANSWERS: given some facts about where values flow, which ones
# outlive the frame that created them?
#
# The caller supplies the facts and interprets the answer. This module knows
# only about opaque integer ids and two kinds of fact:
#
#   note(id, state)   a direct observation — "this one reaches a return"
#   flow(src, dst)    "src's value reaches dst", so dst's fate bounds src's
#
# and then solves to a fixed point.
#
# WHY A LATTICE. Escape is three-valued, ordered:
#
#   esNone  <  esArg  <  esGlobal
#
#   esNone    never leaves the frame — safe on the stack
#   esArg     reaches a parameter, so the CALLER decides (needed for the
#             interprocedural layer; a leaf analysis can treat it as escaping)
#   esGlobal  reaches a return, a field, a global, or code we cannot see
#
# A value's state is the MAXIMUM over everything it flows into, which is what
# makes the fixed point well-defined: states only ever rise, the lattice has
# three levels, so the worklist terminates in at most 3n steps.
#
# CONSERVATIVE BY CONSTRUCTION. An id this module has never been told about
# answers `escapes = true`. A wrong "escapes" costs a promotion that was not
# needed; a wrong "does not escape" is a dangling pointer. The default has to
# be the one that is merely wasteful, and callers must opt IN to stack
# placement by proving it, never opt out.
import tables, sets

type
  EscapeState* = enum
    esNone                   ## never leaves the frame
    esArg                    ## reaches a parameter — the caller decides
    esGlobal                 ## reaches a return, a field, or unknown code

  EscapeGraph* = object
    states: Table[int, EscapeState]
    ## `edges[a] = @[b, ...]` means a's value reaches b, so a is at least as
    ## escaped as b. Stored in this direction because the solver pushes a
    ## rise in b back to a.
    edges: Table[int, seq[int]]
    ## The same edges reversed. Kept explicitly so the solver can find "who
    ## flows into me" in O(1) — without it, each rise costs a scan of every
    ## edge list, which is the difference between linear and quadratic on a
    ## function with many locals.
    rev: Table[int, seq[int]]
    known: HashSet[int]      ## ids the caller has actually mentioned

proc initEscapeGraph*(): EscapeGraph =
  EscapeGraph(states: initTable[int, EscapeState](),
              edges: initTable[int, seq[int]](),
              rev: initTable[int, seq[int]](),
              known: initHashSet[int]())

proc note*(g: var EscapeGraph, id: int, s: EscapeState) =
  ## Record a direct observation. States only rise: noting esNone over an
  ## existing esGlobal does NOT lower it, because the earlier observation was
  ## also true and the maximum is what holds.
  g.known.incl(id)
  let cur = g.states.getOrDefault(id, esNone)
  if s > cur: g.states[id] = s
  elif id notin g.states: g.states[id] = cur

proc flow*(g: var EscapeGraph, src, dst: int) =
  ## `src`'s value reaches `dst` — assignment, an argument, a field store, an
  ## element of a collection. Whatever happens to dst happens to src.
  ##
  ## Self-flow is dropped: it says nothing and would just spin the worklist.
  if src == dst: return
  g.known.incl(src)
  g.known.incl(dst)
  if src notin g.states: g.states[src] = esNone
  if dst notin g.states: g.states[dst] = esNone
  g.edges.mgetOrPut(src, @[]).add(dst)
  g.rev.mgetOrPut(dst, @[]).add(src)

proc solve*(g: var EscapeGraph) =
  ## Propagate to a fixed point: every id is at least as escaped as everything
  ## its value reaches.
  ##
  ## Worklist over the flow edges. Each id can rise at most twice (None -> Arg
  ## -> Global), so at most 2n rises happen and the loop terminates even on a
  ## cyclic graph — which is what makes a loop like `x = f(x)` safe to feed in.
  var work: seq[int] = @[]
  for id in g.known: work.add(id)
  while work.len > 0:
    let id = work.pop()
    let mine = g.states.getOrDefault(id, esNone)
    for dst in g.edges.getOrDefault(id, @[]):
      let theirs = g.states.getOrDefault(dst, esNone)
      if theirs > mine:
        g.states[id] = theirs
        # this id rose, so anything flowing INTO it may rise too
        for other in g.rev.getOrDefault(id, @[]): work.add(other)
        break

proc stateOf*(g: EscapeGraph, id: int): EscapeState =
  ## An id never mentioned is esGlobal: silence is not evidence of safety.
  if id notin g.known: return esGlobal
  g.states.getOrDefault(id, esNone)

proc escapes*(g: EscapeGraph, id: int): bool =
  ## Does this value outlive its frame? esArg counts as escaping here — a leaf
  ## analysis cannot see what the caller does with it. The interprocedural
  ## layer, when it exists, asks stateOf directly and resolves esArg against
  ## the callee's summary.
  g.stateOf(id) != esNone

proc mayStayOnStack*(g: EscapeGraph, id: int): bool =
  ## The positive form, for callers who prefer to read it that way. Only ever
  ## true for an id the caller told us about AND that nothing escaped.
  not g.escapes(id)
