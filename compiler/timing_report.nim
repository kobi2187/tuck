## timing_report — the `tuck timing` static report.
##
## Two reports from the checked tree, no execution:
##   - worst-case CRITICAL-SECTION nesting per fn (embedded ISR budget);
##   - worst-case STACK per fn along the call graph (small-SRAM budget).
##
## This is the Layer-2 (REPORT) layer of the embedded vision. Output goes
## through the same conventions as `tuck audit`: human text, structured JSON,
## and SARIF 2.1.0 whose rule ids are permanent TK-XXNN codes.
##
## Stack numbers are deliberately approximate (a frame estimate plus the
## deepest resolved call path). They exist to flag order-of-magnitude budget
## problems, never to size a real stack — the text output says so.

import std/[tables, json, strutils, algorithm]
import ast, ast_ops, ast_query, typecheck_util, report_format, resolution,
       diagnostics

type
  CriticalReport* = object
    fnName*: string          ## display signature only; identity is fnId
    fnId*: NodeId
    site*: Span              ## deepest critical block in this fn
    depth*: int              ## nesting depth there (1-based)

  StackReport* = object
    fnName*: string
    fnId*: NodeId
    site*: Span
    bytes*: int              ## approximate worst-case stack for this fn
    path*: seq[string]       ## the call path that produces it (display names)

  TimingReport* = object
    critical*: seq[CriticalReport]
    stack*: seq[StackReport]

proc sigFor(d: Decl): string =
  ## Display signature. The name is shown to the human, never used as a key.
  var parts: seq[string]
  for p in d.fnParams:
    parts.add p.name & ": " & typeName(p.typ)
  writtenName(d) &
    (if parts.len == 0: "()" else: "({" & parts.join(", ") & "})")

proc ownerName(d: Decl): string =
  ## The display name for the declaration that owns a body. Only display —
  ## the report keys on `d.id`.
  case d.kind
  of dkFn, dkTask: sigFor(d)
  of dkSelect: "on select"
  else: writtenName(d)

proc criticalOf*(m: Module): seq[CriticalReport] =
  ## Deepest `critical:` nesting per body-owning declaration, with the block's
  ## span. `allDecls` + `ownExprs` reach fn and task bodies, `on select` arm
  ## bodies, const values and actor field initialisers — the hand-rolled
  ## `decls` + `dkFn` walk missed every one of those.
  var rep: seq[CriticalReport]
  proc walk(e: Expr, name: string, id: NodeId, depth: var int,
            bestDepth: var int, best: var CriticalReport) =
    if e == nil: return
    case e.kind
    of exkCritical:
      inc depth
      if depth > bestDepth:
        bestDepth = depth
        best = CriticalReport(fnName: name, fnId: id,
                              site: e.span, depth: depth)
      walk(e.criticalBody, name, id, depth, bestDepth, best)
      dec depth
    else:
      for ch in e.children:
        walk(ch, name, id, depth, bestDepth, best)
  for d in m.allDecls:
    if d == nil: continue
    for body in d.ownExprs:
      if body == nil: continue
      var depth = 0
      var bestDepth = 0
      var best = CriticalReport()
      walk(body, ownerName(d), d.id, depth, bestDepth, best)
      if bestDepth > 0: rep.add best
  result = rep
  result.sort(proc (a, b: CriticalReport): int = cmp(b.depth, a.depth))

proc frameSize(d: Decl): int =
  ## Rough per-frame budget: 4-byte frame header + 8 bytes/param + locals.
  4 + d.fnParams.len * 8 + 24

proc stackOf(res: Resolution, m: Module): seq[StackReport] =
  ## Approximate worst-case stack: a fn's frame plus the deepest CalleeDecl
  ## path. Edges come from the checker's recorded resolutions — never from a
  ## callee NAME. Cycles stop at the first repeat on the current path.
  ##
  ## The path carries the Decl itself, so a callee in another module still
  ## gets its display signature; nothing is looked up by name.
  type Path = tuple[bytes: int, decls: seq[Decl]]
  var memo: Table[NodeId, Path]
  proc worst(d: Decl, stack: var seq[NodeId]): Path =
    let id = d.id
    if id in memo: return memo[id]
    if id in stack: return (frameSize(d), @[d])    # cycle: frame, stop
    stack.add id
    var best: Path = (frameSize(d), @[d])          # this frame alone
    for n in d.fnBody.nodes:
      if n.kind != exkCall: continue
      let c = calleeDecl(res, m, n)
      if c == nil or c.kind != dkFn or c.fnBody == nil: continue
      # A call path's cost is the SUM of frames along it, not the largest.
      let sub = worst(c, stack)
      let through = frameSize(d) + sub.bytes
      if through > best.bytes:
        best = (through, @[d] & sub.decls)
    discard stack.pop
    memo[id] = best
    best
  var rep: seq[StackReport]
  for d in m.allDecls:
    if d == nil or d.kind notin {dkFn, dkTask} or d.fnBody == nil: continue
    var stack: seq[NodeId]
    let p = worst(d, stack)
    var display: seq[string]
    for pd in p.decls: display.add sigFor(pd)
    rep.add StackReport(fnName: sigFor(d), fnId: d.id,
                        site: d.span, bytes: p.bytes, path: display)
  result = rep
  result.sort(proc (a, b: StackReport): int = cmp(b.bytes, a.bytes))

proc timingOf*(res: Resolution, m: Module): TimingReport =
  result.critical = criticalOf(m)
  result.stack = stackOf(res, m)

proc renderText*(rep: TimingReport, path: string, stackLimit = 10): string =
  result.add "Critical-section nesting (deepest per fn):\n"
  if rep.critical.len == 0:
    result.add "  none — no `critical:` blocks in " & path & ".\n"
  else:
    var nested = false
    for c in rep.critical:
      let note = if c.depth > 1: "  <- nested; one block is enough" else: ""
      if c.depth > 1: nested = true
      result.add "  " & $c.depth & "x  " & c.fnName &
                 "  (" & path & ":" & $c.site.line & ")" & note & "\n"
    if nested:
      result.add "  Why: `critical:` already disables interrupts for everything\n"
      result.add "  inside it, so a nested block adds nothing and hides the real\n"
      result.add "  bound. Fix: keep one block per protected region, or split the\n"
      result.add "  outer one so each section is flat.\n"
  result.add "\nWorst-case stack (approximate; call graph, ~bytes):\n"
  if rep.stack.len == 0:
    result.add "  none.\n"
  else:
    for i in 0 ..< min(rep.stack.len, stackLimit):
      let s = rep.stack[i]
      result.add "  ~" & $s.bytes & "B  " & s.fnName &
                 "  (" & path & ":" & $s.site.line & ")\n"
      if s.path.len > 1:
        result.add "         via " & s.path[1 .. ^1].join(" -> ") & "\n"
    if rep.stack.len > stackLimit:
      result.add "  ... " & $(rep.stack.len - stackLimit) & " more fn(s)\n"
    result.add "\n  A call path's stack is the SUM of its frames. Overflowing it\n"
    result.add "  silently corrupts the memory below the stack. Shrink the deepest\n"
    result.add "  path, move large locals to a pool/arena, or raise the reserved\n"
    result.add "  stack in the linker script.\n"
  result.add "  Estimates only — the runtime high-water mark is authoritative.\n"

proc renderJson*(rep: TimingReport, path: string): string =
  ## Structured JSON: two arrays, so a script can read either without
  ## flattening a stack budget into a diagnostic finding.
  var crit = newJArray()
  for c in rep.critical:
    crit.add %*{"fn": c.fnName, "fnId": $c.fnId, "depth": c.depth,
                "path": path, "line": c.site.line, "col": c.site.col}
  var stack = newJArray()
  for s in rep.stack:
    stack.add %*{"fn": s.fnName, "fnId": $s.fnId, "bytesApprox": s.bytes,
                 "callPath": s.path, "path": path,
                 "line": s.site.line, "col": s.site.col}
  pretty(%*{"critical": crit, "stack": stack})

proc toFindings*(rep: TimingReport, path: string,
                 stackLimit = 5): seq[Finding] =
  ## SARIF view. Only genuine issues become results: `critical:` nesting
  ## deeper than one (one block already disables interrupts), plus the few
  ## worst stack paths as budget notes. A flat inventory is text/JSON only.
  for c in rep.critical:
    if c.depth < 2: continue
    result.add Finding(code: $dcTmCriticalNest,
      msg: c.fnName & " nests " & $c.depth & " `critical:` block(s); one is enough",
      path: path, line: c.site.line, col: c.site.col)
  for i in 0 ..< min(rep.stack.len, stackLimit):
    let s = rep.stack[i]
    result.add Finding(code: $dcTmStackDepth,
      msg: s.fnName & " worst-case stack ~" & $s.bytes & "B (approximate)",
      path: path, line: s.site.line, col: s.site.col)
