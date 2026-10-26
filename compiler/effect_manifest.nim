# compiler/effect_manifest.nim
#
# THE EFFECT MANIFEST (issue #63): every callable's DECLARED effects and
# resource kinds, one line each, sorted, for the whole program.
#
# A fn that used to be pure and now does IO is a real semantic change, and in
# most languages it is invisible in a review. Committing this file makes it a
# diff: "this change gave three previously-pure fns IO" is one line in
# `git diff`, and `tuck effects FILE --check:PATH` fails CI on it.
#
# Declared, never inferred: the effect discipline requires declaration
# (ROADMAP "Effects §3.7"), so the file restates the source and cannot drift
# from it. The whole import closure is listed, because the case that matters
# is a DEPENDENCY quietly gaining the ability to write to disk. Lines carry no
# position and no timestamp, so moving code is not a change.
import algorithm, strutils, sets
import ast, ast_ops, modules

proc markerList(d: Decl): string =
  ## `[io: net, no_alloc]`, sorted; `[]` for none.
  var names: seq[string]
  for m in d.fnEffects: names.add effectName(m)
  names.sort()
  "[" & names.join(", ") & "]"

proc kindOf(d: Decl, inExtern: bool): string =
  if d.kind == dkTask: "task"
  elif inExtern or d.isExtern: "extern"
  elif d.isOnHandler: "handler"
  elif d.fnBody == nil: "pending"
  else: "fn"

proc lineFor(module, owner: string, d: Decl, inExtern: bool): string =
  let name = module & "." & (if owner != "": owner & "." else: "") & writtenName(d)
  result = name & "  " & kindOf(d, inExtern) & "  " & markerList(d)
  if d.fnResourceKinds.len > 0:
    var kinds = d.fnResourceKinds
    kinds.sort()
    result.add "  resource: " & kinds.join(", ")

proc linesOf(module, owner: string, d: Decl, inExtern: bool,
             into: var seq[string]) =
  ## `d` if it is callable, and the callables nested in it.
  if d == nil: return
  case d.kind
  of dkFn, dkTask: into.add lineFor(module, owner, d, inExtern)
  of dkExtern:
    for m in d.mixinMembers: linesOf(module, owner, m, true, into)
  of dkObject, dkActor, dkMixin, dkPending, dkWhen, dkInterface, dkGroup, dkType:
    let inner = if d.kind in {dkPending, dkWhen}: owner else: writtenName(d)
    for m in d.childDecls: linesOf(module, inner, m, inExtern, into)
  of dkConst, dkExpr, dkStaticAssert, dkSelect, dkRegistry, dkPool, dkSlab,
     dkArena, dkRegister, dkImport, dkFnSig, dkSatisfies, dkResources,
     dkErrors, dkPublic:
    discard

proc manifestOf*(prog: seq[LoadedModule]): string =
  ## The manifest text: a header line, then one line per callable, sorted.
  var lines: seq[string]
  for lm in prog:
    for d in lm.m.decls:
      if d != nil and d.origin == NoModule: linesOf(lm.name, "", d, false, lines)
  lines.sort()
  result = "# tuck effect manifest: declared effects per callable (issue #63)\n"
  for l in lines: result.add l & "\n"

proc manifestChanges*(old, now: string): seq[string] =
  ## What changed between two manifests, as `- line` / `+ line`, removals
  ## first; empty when they agree. Comment lines are not compared.
  proc entries(text: string): seq[string] =
    for l in text.splitLines:
      if l.len > 0 and not l.startsWith("#"): result.add l
  let a = entries(old)
  let b = entries(now)
  let inA = toHashSet(a)
  let inB = toHashSet(b)
  for l in a:
    if l notin inB: result.add "- " & l
  for l in b:
    if l notin inA: result.add "+ " & l
