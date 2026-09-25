# compiler/tree_invariants.nim
#
# WHAT MUST BE TRUE OF THE TREE BETWEEN STAGES — asserted, not assumed.
#
# Each check here is a property some later pass silently relies on, where a
# violation does not crash: it produces a plausible, wrong answer somewhere
# downstream. A node without an id drops out of the semantic layer and reads
# as "untyped". Two nodes with one id cross-wire it, so one reads the other's
# type or resolved call. A named type without its declaration edge sends every
# consumer back to scanning the decl list by name (#21).
#
# They run under `--verify-stages`, which is on by default, from
# `pipeline.nim`. A unit test covers the shapes someone thought of; these run
# over every program the compiler is ever given.
import tables, sets, strutils
import ast, ast_ops
import resolution

type Census = object
  ## Every node seen, by id, and what went wrong.
  holder: Table[NodeId, pointer]  ## the OBJECT that holds each id
  what: Table[NodeId, string]     ## ...and how to name it in a report
  bad: seq[string]

proc where(sp: Span): string =
  (if sp.file.len > 0: sp.file & ":" else: "") & $sp.line & ":" & $sp.col

proc note(c: var Census, id: NodeId, obj: pointer, what: string) =
  if not id.isSet:
    c.bad.add what & " has no id"
    return
  if id notin c.holder:
    c.holder[id] = obj
    c.what[id] = what
  elif c.holder[id] != obj:
    # The SAME object reached twice is sharing — a tree position reused, which
    # lowering does on purpose. Two DIFFERENT objects under one id is the bug:
    # they will read each other's facts out of the semantic layer.
    c.bad.add "id " & $uint32(id) & " is held by two nodes: " & c.what[id] &
              " and " & what

proc walk(c: var Census, e: Expr) =
  var stack = @[e]
  while stack.len > 0:
    let n = stack.pop()
    if n == nil: continue
    c.note(n.id, cast[pointer](n), $n.kind & " at " & where(n.span))
    if n.kind == exkChain:
      for i in 0 ..< n.steps.len:
        c.note(n.steps[i].id, addr n.steps[i],
               "chain step " & $i & " at " & where(n.span))
    for ch in n.children: stack.add ch

proc walk(c: var Census, d: Decl) =
  if d == nil: return
  c.note(d.id, cast[pointer](d), $d.kind & " " & d.name & " at " & where(d.span))
  for e in d.ownExprs: c.walk(e)
  for m in d.childDecls: c.walk(m)

proc idErrors*(mods: seq[Module]): seq[string] =
  ## Every declaration, expression and chain step has an id, and no two
  ## distinct nodes share one — across the whole program, because ids are
  ## program-wide (ast_ops.globalNodeCounter) and one Resolution spans every
  ## module.
  var c: Census
  for m in mods:
    for d in m.decls: c.walk(d)
  c.bad

proc declaredTypeNames(m: Module): HashSet[string] =
  for d in m.decls:
    if d != nil and d.kind in {dkType, dkObject}: result.incl d.name

proc typeEdgeErrors*(res: Resolution, mods: seq[Module]): seq[string] =
  ## #21, program-wide: every named type a declaration mentions, whose name is
  ## a type this module can see, carries the edge to that declaration.
  ##
  ## Lowering asserts the same at the one place it looks; this looks
  ## everywhere, right after the checker, which is where the edges are made.
  for m in mods:
    let names = declaredTypeNames(m)
    var stack: seq[Decl]
    for d in m.decls: stack.add d
    while stack.len > 0:
      let d = stack.pop()
      if d == nil: continue
      for m2 in d.childDecls: stack.add m2
      var ts: seq[Type]
      for t in d.ownTypes: ts.add t
      while ts.len > 0:
        let t = ts.pop()
        if t == nil: continue
        for ch in t.children: ts.add ch
        if t.kind == tkNamed and t.name in names and res.declForType(t) == nil:
          result.add "type '" & t.name & "' in " & $d.kind & " " & d.name &
                     " at " & where(t.span) & " has no declaration edge (#21)"

proc report*(stage: string, bad: seq[string]) =
  ## One exception naming the first few, so the report points somewhere.
  if bad.len == 0: return
  raise newException(ValueError,
    "pipeline: " & stage & ": " & $bad.len & " violation(s) — " &
    bad[0 .. min(4, bad.high)].join("; "))
