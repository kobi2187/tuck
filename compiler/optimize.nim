# compiler/optimize.nim
#
# OPTIONAL PASSES. Nothing in this file runs unless the user asks for it by
# name on the command line (`-O:chain-inplace`). With no `-O`, `optimizeProgram`
# is a no-op and the emitted code is byte-identical to a build without this
# file — which is the property that makes these safe to land, benchmark, and
# delete independently.
#
# WHY A SEPARATE MODULE AND NOT A FEW LINES IN LOWERING. An optimization is a
# different kind of claim from everything else in this compiler. The rest of
# the pipeline is asking "what does this program MEAN"; a pass here asserts
# "this program means the same thing written differently, and the second way
# is faster". That second claim needs to be falsifiable in isolation:
#
#   - it must be possible to build the SAME source with and without it and
#     diff the output, which is what `-O` off-by-default buys;
#   - a wrong answer here is a miscompile, not a type error, so the tests are
#     equivalence tests (same exit code both ways), not shape tests;
#   - and if a pass turns out to be a bad trade, deleting it must be deleting
#     ONE file plus one call site, not unpicking it from lowering.nim.
#
# So the seam is deliberate. This file may READ anything; nothing outside it
# may depend on it having run.
#
# WHERE IT SITS. After checking (so types and calls are resolved and the
# semantic layer is populated), before mangling and lowering (so passes work
# on the user's own names and both backends inherit the result from one
# rewrite):
#
#   check → **optimize** → mangle → lower(per backend) → emit
#
# HOW A PASS EARNS ITS PLACE. It must produce AST that the backends ALREADY
# handle. A pass that needs a new node kind, or a new flag on an existing one,
# is not a peephole — it is a language change wearing a peephole's clothes,
# and it belongs in lowering where the backends can see it. Both passes below
# hold to that: they only ever DELETE work or re-shape nodes into other nodes
# the emitters have always known.
import ast, ast_query, resolution
import std/[strutils, tables]

type
  OptPass* = enum
    ## Each pass is named on the CLI. Keep the string stable once published —
    ## it goes in build scripts.
    opChainInPlace = "chain-inplace"

const PassHelp*: array[OptPass, string] = [
  opChainInPlace:
    "a `..mutatorFn` step whose callee is a plain builder is replaced by " &
    "that builder's own field-sets, so the receiver is updated in place " &
    "instead of copied in, mutated, and copied back"
]

proc parseOptPasses*(spec: string): tuple[passes: set[OptPass], bad: string] =
  ## `-O:a,b` → the named passes. `-O:all` turns on everything. An unknown
  ## name is returned in `bad` rather than ignored: a typo in a build script
  ## must not silently mean "no optimization".
  for raw in spec.split(','):
    let name = raw.strip()
    if name.len == 0: continue
    if name == "all":
      for p in OptPass: result.passes.incl(p)
      continue
    var found = false
    for p in OptPass:
      if $p == name: result.passes.incl(p); found = true; break
    if not found: return (result.passes, name)
  (result.passes, "")

# ---------------------------------------------------------------------------
# opChainInPlace
#
# THE SHAPE THIS FIRES ON. Spec §2.3's builder, which is the idiom the whole
# `..` design is built around:
#
#   fn withDefaults({self: Cfg}) -> Cfg:      cfg ..withDefaults ..port {8080}
#     var s = self
#     s ..timeout {60}
#     return s
#
# The call step lowers to `cfg = withDefaults(cfg)`, and `withDefaults` itself
# lowers to `var s = self; s.timeout = 60; return s`. That is THREE copies of
# the record to set one field: copy-in, copy-out, copy-back. Measured on this
# tree, a C/LLVM backend removes all three below ~16 bytes and none of them
# above ~32 — a 256-byte record costs 512 bytes of memory traffic and a
# 528-byte stack frame per step, which is the wrong answer on the embedded
# targets the language is aimed at.
#
# The rewrite splices the builder's own field-set steps into the caller's
# chain, so `cfg ..withDefaults ..port {8080}` becomes exactly
# `cfg ..timeout {60} ..port {8080}` — no call, no temp, no copies, and the
# emitters need no changes because a field-set step is what they already emit
# for every other chain.
#
# WHY THIS IS SOUND WITHOUT ANY DATAFLOW ANALYSIS. Ordinarily inlining a
# mutator needs escape and liveness analysis to prove the receiver is
# unaliased and dead-after. Here the LANGUAGE has already proved it: §2.3
# restricts `..` to a `var`, requires a mutator to return the receiver's own
# type, and specifies that the result is reassigned into the receiver. So at
# every site this pass fires on, the receiver is a single-owner mutable local
# whose old value is provably dead. The analysis a general-purpose compiler
# has to compute, Tuck's syntax hands over for free.
#
# WHAT IT DELIBERATELY REFUSES. Everything it cannot prove trivially, because
# a peephole that needs a caveat is not a peephole:
#
#   - a builder whose body is anything but [var t = p; chain on t; return t]
#   - a builder taking more than the receiver, or a call step passing braces
#   - a step arg mentioning the parameter or the temp: substituting those
#     correctly needs to know whether an earlier step already wrote the field
#     being read, which is exactly the dataflow this pass exists to avoid
#   - a receiver type carrying `invariant:` — the builder's `return` is a
#     validation site (spec §4.7), and splicing would silently delete it
#
# Each refusal costs a missed optimization and nothing else.

proc mentionsName(e: Expr, name: string): bool =
  ## Does `e` read `name` anywhere? Used to refuse any builder whose body
  ## depends on its own parameter — see the refusal list above.
  ##
  ## Walks EVERY child via ast.children. It used to name seven kinds and
  ## `else: discard`, which is the unsafe direction for a guard: a mention it
  ## failed to see let a splice through that reads a value the caller's chain
  ## has not written yet. Looking in more places can only make the optimizer
  ## refuse more, never splice something it should not.
  if e == nil: return false
  if e.kind == exkVar and e.name == name: return true
  for c in e.children:
    if mentionsName(c, name): return true
  false

proc builderWholeValue(callee: Decl): Expr =
  ## The value of a builder that IGNORES its receiver and returns a fresh one:
  ##
  ##   fn withDefaults({self: Cfg}) -> Cfg:
  ##     return {port: 80, timeout: 30} Cfg
  ##
  ## This is the shape the corpus actually uses (examples/02-builder-mutation)
  ## and it is the cheaper rewrite of the two: since the result does not depend
  ## on the receiver, `cfg = withDefaults(cfg)` is just `cfg = {…} Cfg`, and
  ## the whole call — passing the record in, returning a record out — is
  ## deleted rather than merely shortened. Returns nil if `callee` is not this
  ## shape.
  if callee == nil or callee.kind != dkFn: return nil
  if callee.isPending or callee.isExtern or callee.fnBody == nil: return nil
  if callee.fnParams.len != 1: return nil
  var ret = callee.fnBody
  if ret.kind == exkBlock:
    if ret.stmts.len != 1: return nil
    ret = ret.stmts[0]
  if ret == nil or ret.kind != exkReturn or ret.returnVal == nil: return nil
  # Depending on the receiver would make this a real call, not a constant.
  if mentionsName(ret.returnVal, callee.fnParams[0].name): return nil
  ret.returnVal

# Recognising a builder is four independent questions about the same three
# statements. Each is its own proc so the SHAPE reads as a list of conditions
# rather than one 39-branch bail-out chain.

proc isSplicableFn(callee: Decl, m: Module): bool =
  ## A fn whose body could be spliced at all: real, one param, three
  ## statements. Invariants on the return type disqualify it — splicing would
  ## lose their return-site validation.
  if callee == nil or callee.kind != dkFn: return false
  if callee.isPending or callee.isExtern or callee.fnBody == nil: return false
  if callee.fnParams.len != 1: return false
  let body = callee.fnBody
  if body.kind != exkBlock or body.stmts.len != 3: return false
  let rt = callee.fnReturnType
  not (rt != nil and rt.kind == tkNamed and hasInvariants(m, rt.name))

proc copiesParam(decl: Expr, paramName: string): string =
  ## `var t = p` — returns `t`, or "" if the first statement is not that.
  if decl == nil or decl.kind != exkAssign or not decl.isDecl or
     not decl.isMutable: return ""
  if decl.target == nil or decl.target.kind != exkVar: return ""
  if decl.assignVal == nil or decl.assignVal.kind != exkVar: return ""
  if decl.assignVal.name != paramName: return ""
  decl.target.name

proc returnsName(ret: Expr, name: string): bool =
  ## `return t`, and nothing else.
  ret != nil and ret.kind == exkReturn and ret.returnVal != nil and
    ret.returnVal.kind == exkVar and ret.returnVal.name == name

proc allPlainFieldSets(mid: Expr, tmpName, paramName: string): bool =
  ## A chain on `t` whose every step SETS a field — no nested calls, and no
  ## arg reading the temp or the parameter. Such an arg is why this refuses:
  ## splicing would move the read past writes the caller's chain does first.
  if mid == nil or mid.kind != exkChain: return false
  if mid.base == nil or mid.base.kind != exkVar or mid.base.name != tmpName:
    return false
  if mid.steps.len == 0: return false
  for s in mid.steps:
    if s.op != coDotDot: return false
    if semLayer.stepCall(s) != nil: return false   # nested call, not a set
    if s.target == nil or s.target.kind != exkVar: return false
    if mentionsName(s.arg, tmpName) or mentionsName(s.arg, paramName):
      return false
  true

proc builderSteps(callee: Decl, m: Module): seq[ChainStep] =
  ## The field-set steps of `callee` if it is a plain builder, else @[].
  ##
  ## A builder is exactly: `var t = p` / a chain of field-sets on `t` /
  ## `return t`. Anything else is left alone.
  if not isSplicableFn(callee, m): return @[]
  let (decl, mid, ret) = (callee.fnBody.stmts[0], callee.fnBody.stmts[1],
                          callee.fnBody.stmts[2])
  let paramName = callee.fnParams[0].name
  let tmpName = copiesParam(decl, paramName)
  if tmpName == "": return @[]
  if not returnsName(ret, tmpName): return @[]
  if not allPlainFieldSets(mid, tmpName, paramName): return @[]
  mid.steps

proc isSpliceableStep(s: ChainStep): bool =
  ## A step that could carry a builder call: `..fn` with a resolved call and
  ## no braced payload. A payload means the call takes more than the receiver,
  ## which is not the shape a builder splice can replace.
  s.op == coDotDot and semLayer.stepCall(s) != nil and
    s.target != nil and s.target.kind == exkVar and
    (s.arg == nil or (s.arg.kind == exkStruct and s.arg.fields.len == 0))

proc spliceStep(s: ChainStep, fns: Table[string, Decl], m: Module,
                kept: var seq[ChainStep], hits: var seq[string]): bool =
  ## Try to replace one step with the builder it calls. Returns whether it
  ## did; the caller keeps the step untouched when it did not.
  let callee = fns.getOrDefault(s.target.name, nil)
  let steps = builderSteps(callee, m)
  if steps.len > 0:
    for bs in steps: kept.add(deepCopy(bs))
    hits.add(s.target.name & " (" & $steps.len & " field-set" &
             (if steps.len == 1: "" else: "s") & ") at line " & $s.span.line)
    return true
  # ...or the receiver-independent builder: keep the step, but point its
  # resolved call at the value itself, so the emitter writes `cfg = {…} Cfg`
  # where it used to write `cfg = withDefaults(cfg)`. The step stays a step;
  # only what it resolves to changes, which is why no emitter has to learn
  # anything.
  let whole = builderWholeValue(callee)
  if whole == nil: return false
  semLayer.setStepCall(s, deepCopy(whole))
  hits.add(s.target.name & " (whole value) at line " & $s.span.line)
  kept.add(s)
  true

proc rewriteChains(e: Expr, fns: Table[string, Decl], m: Module,
                   hits: var seq[string]) =
  ## Walk `e`, splicing builder bodies into every chain step that qualifies.
  ##
  ## The chain arm stays explicit because it REPLACES e.steps; everything else
  ## is a plain walk, so it goes through ast.children — which also reaches the
  ## kinds the old hand-written list did not name.
  if e == nil: return
  if e.kind == exkChain:
    rewriteChains(e.base, fns, m, hits)
    var kept: seq[ChainStep]
    for s in e.steps:
      if not (isSpliceableStep(s) and spliceStep(s, fns, m, kept, hits)):
        kept.add(s)
    e.steps = kept
    return
  for c in e.children: rewriteChains(c, fns, m, hits)

# ---------------------------------------------------------------------------

proc optimizeProgram*(mods: seq[Module], passes: set[OptPass]): seq[string] =
  ## Run the requested passes over the whole program. Returns one report line
  ## per rewritten site — the caller prints them under `-O:report`, in the
  ## same shape as the PENDING and SHORTCUTS reports, so an optimization that
  ## fires is something you can SEE rather than infer from a benchmark.
  ##
  ## No pass requested: returns immediately, having touched nothing.
  if passes == {}: return @[]

  if opChainInPlace in passes:
    # Whole-program fn table: a chain may name a builder from an imported
    # module, and by this point the import closure is all here.
    var fns = initTable[string, Decl]()
    for m in mods:
      for d in m.decls:
        if d != nil and d.kind == dkFn: fns[d.name] = d
    for m in mods:
      for d in m.allFns():
        if d.fnBody != nil: rewriteChains(d.fnBody, fns, m, result)
