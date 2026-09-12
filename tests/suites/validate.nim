## `tuck validate` — the spec-side PEG grammar, cross-checked against the
## parser over the whole corpus.
##
## The guard is AGREEMENT, not acceptance. Either grammar may be wrong; what
## must not happen silently is the two drifting apart, because that is the
## state in which a construct is "supported" by one and unknown to the other.
##
## Coverage has a FLOOR rather than a target. The grammar states declarations,
## signatures and types and defers bodies, so a file can agree while most of
## it went through the escape hatch — the floor is what stops that number
## quietly sliding while the grammar is edited.

import ../harness
import os, strutils, algorithm

const CorpusDirs = ["examples", "std", "stdlib-project/v2"]

proc run*(t: var T) =
  var files: seq[string]
  for d in CorpusDirs:
    let dir = t.root / d
    if not dirExists(dir): continue
    for f in walkFiles(dir / "*.tuck"): files.add(f)
  files.sort()

  var idx: seq[(string, int)]
  for f in files:
    idx.add((f, t.needCmd(@[tuckExe, "validate", f, "--root:" & t.root])))

  if t.phase != pReport: return

  var disagreed: seq[string]
  var known, unknown = 0
  var stmts, stmtEscapes = 0
  for (f, i) in idx:
    if t.skippedCmd(i): continue
    let (rc, outp) = t.resultOf(i)
    if rc != 0 or not outp.contains("AGREE"):
      disagreed.add(extractFilename(f))
      continue
    # "… | N declaration(s) matched a stated rule, M fell to the escape hatch"
    for line in outp.splitLines():
      if "| " notin line: continue
      let parts = line.split('|')
      if parts.len < 2: continue
      let nums = parts[1].split(' ')
      for j, w in nums:
        if w.allCharsInSet({'0'..'9'}) and w.len > 0:
          if j + 1 < nums.len and nums[j + 1].startsWith("declaration"):
            known += parseInt(w)
          elif j + 1 < nums.len and nums[j + 1] == "fell":
            unknown += parseInt(w)
    # "  statements: N stated, M escaped"
    for line in outp.splitLines():
      if not line.contains("statements:"): continue
      let nums = line.strip().split(' ')
      for j, w in nums:
        if w.len == 0 or not w.allCharsInSet({'0'..'9'}): continue
        if j + 1 < nums.len and nums[j + 1] == "stated,": stmts += parseInt(w)
        elif j + 1 < nums.len and nums[j + 1] == "escaped":
          stmtEscapes += parseInt(w)

  if disagreed.len == 0:
    t.ok "the spec grammar and the parser agree across the corpus"
  else:
    t.no "the spec grammar and the parser agree across the corpus",
         "disagree: " & disagreed.join(", ")

  # The floor moves UP by hand, the way the complexity ratchet does. It is set
  # to what the tree states today; a grammar edit that describes less than it
  # did is the thing this catches.
  const CoverageFloor = 100
  let total = known + unknown
  let pct = if total == 0: 0 else: known * 100 div total
  if total == 0:
    t.skip "grammar coverage stays at or above the floor (no corpus)"
  elif pct >= CoverageFloor:
    t.ok "grammar coverage stays at or above the floor (" & $pct & "% of " &
         $total & " declarations, floor " & $CoverageFloor & "%)"
  else:
    t.no "grammar coverage stays at or above the floor",
         $pct & "% of " & $total & " declarations, floor " & $CoverageFloor & "%"

  # The same floor one level down. Statements are where this session's real
  # bugs lived — `:mod::fn` losing its module, `..mod::fn` destroying the
  # receiver — so a body that goes through the escape hatch is exactly the
  # blind spot worth ratcheting.
  const StmtFloor = 100
  let stmtTotal = stmts + stmtEscapes
  let stmtPct = if stmtTotal == 0: 0 else: stmts * 100 div stmtTotal
  if stmtTotal == 0:
    t.skip "statement coverage stays at or above the floor (no corpus)"
  elif stmtPct >= StmtFloor:
    t.ok "statement coverage stays at or above the floor (" & $stmtPct &
         "% of " & $stmtTotal & " statements, floor " & $StmtFloor & "%)"
  else:
    t.no "statement coverage stays at or above the floor",
         $stmtPct & "% of " & $stmtTotal & " statements, floor " &
         $StmtFloor & "%"
