## An interface whose satisfier a module cannot see (R11, A27).
##
## An interface compiles to a union of the types that satisfy it, held BY VALUE
## (spec §5.3). The union is emitted where the interface is declared, so every
## satisfier's data type has to be nameable there. When the satisfier is
## declared in a module that IMPORTS the interface's module, that is an import
## cycle in Nim, Odin and D alike.
##
## The compiler sees the whole program, so it breaks the cycle by moving data:
## the satisfier's fields, and the types those fields mention that would also
## close the cycle, go into one generated module, `iface_variants`, which both
## modules import. Only DATA moves — the members stay beside their object, and
## the interface's module reaches them through a function reference its
## satisfier's module hands over at start-up (the same shape as a registry's
## handlers). A single-module interface is untouched.
##
## What is done to the tree:
##
##  * `iface_variants` gets a data-only copy of each moved type;
##  * the original keeps its members and is marked `hoistedTo`, so no backend
##    emits its struct again and every reference to it names the generated one;
##  * the interface's module gets a shape-only copy of each satisfier (so its
##    union can list it), stamped as imported from the generated module;
##  * every module that is not one of the generated module's own dependencies
##    imports it, so a type that moved is still visible where it was.

import std/[tables, sets, algorithm, sequtils, os]
import ast, ast_ops, ast_query
import modules

type Satisfier = object
  ## An object `obj` in module `home` that satisfies an interface declared in
  ## module `iface`, which cannot import `home`.
  iface, home: string
  obj: Decl

proc importOf(name: string, span: Span): Decl =
  ## `import <name>`, numbered like any parsed node.
  result = Decl(kind: dkImport, name: name, span: span)
  freshIds(result)

proc declOfType(prog: seq[LoadedModule], idx: Table[string, int],
                home, name: string): tuple[d: Decl, module: string] =
  ## The type or object `name` as `home` sees it: its own, else one a direct
  ## import declares.
  var places = @[home]
  for imp in importsOf(prog[idx[home]].m): places.add imp
  for place in places:
    if place notin idx: continue
    for d in prog[idx[place]].m.decls:
      if d != nil and d.kind in {dkType, dkObject} and d.name == name and
         not isImportedCopy(d):
        return (d, place)

proc namesIn(t: Type, acc: var seq[string]) =
  if t == nil: return
  if t.kind == tkNamed: acc.add t.name
  for c in t.children: namesIn(c, acc)

proc fieldTypeNames(d: Decl): seq[string] =
  case d.kind
  of dkObject: (for f in d.objFields: namesIn(f.typ, result))
  of dkType: namesIn(d.typeBody, result)
  else: discard

proc refuse(d: Decl, why: string) =
  raise newException(ModuleError, d.span.file & ":" & $d.span.line &
    ": '" & d.name & "' cannot move to " & VariantsModule & " — " & why)

proc dataOnly(d: Decl, file: string): Decl =
  ## What the generated module holds of `d`: its data and nothing else.
  case d.kind
  of dkObject:
    for m in d.objMembers:
      if m != nil and not (m.kind == dkFn):
        refuse(d, "it composes another declaration (`+ ...`)")
    result = Decl(kind: dkObject, name: d.name, objFields: d.objFields,
                  span: d.span)
  else:
    if d.typeMembers.len > 0:
      refuse(d, "it has member fns, which stay with their module")
    result = Decl(kind: dkType, name: d.name, generics: d.generics,
                  typeBody: d.typeBody, span: d.span)
  result = deepCopy(result)
  freshIds(result)
  # Say where it was written: the generated module's header lists it, and a
  # diagnostic about it names this file.
  result.span.file = file

proc reachers(prog: seq[LoadedModule], start: HashSet[string]): HashSet[string] =
  ## `start` and every module that imports one of them, however indirectly.
  result = start
  var grew = true
  while grew:
    grew = false
    for lm in prog:
      if lm.name in result: continue
      for imp in importsOf(lm.m):
        if imp in result:
          result.incl lm.name
          grew = true
          break

proc depsOf(prog: seq[LoadedModule], idx: Table[string, int],
            start: HashSet[string]): HashSet[string] =
  ## `start` and every module they import, however indirectly.
  result = start
  var work = @(start.toSeq)
  while work.len > 0:
    let n = work.pop()
    if n notin idx: continue
    for imp in importsOf(prog[idx[n]].m):
      if imp notin result:
        result.incl imp
        work.add imp

proc satisfyingObjects(m: Module, iface: string): seq[Decl] =
  ## The objects `m` declares (not copies) that satisfy `iface`.
  for o in m.decls(dkObject):
    if not isImportedCopy(o) and iface in o.satisfies: result.add o

proc satisfiersAcrossCycle(prog: seq[LoadedModule]): seq[Satisfier] =
  for a in prog:
    let visible = importsOf(a.m)
    for iface in a.m.decls(dkInterface):
      if isImportedCopy(iface): continue
      for b in prog:
        if b.name == a.name or b.name in visible: continue
        # The object names the interface, so it must be able to see it.
        if a.name notin importsOf(b.m): continue
        for o in satisfyingObjects(b.m, iface.name):
          result.add Satisfier(iface: a.name, home: b.name, obj: o)

proc dependencyFirst(prog: seq[LoadedModule]): seq[LoadedModule] =
  ## The modules with every import before its importer, otherwise in the order
  ## given — so the entry module stays last.
  var placed = initHashSet[string]()
  var byName = initTable[string, int]()
  for i, lm in prog: byName[lm.name] = i
  proc visit(i: int, prog: seq[LoadedModule], placed: var HashSet[string],
             byName: Table[string, int], ordered: var seq[LoadedModule]) =
    if prog[i].name in placed: return
    placed.incl prog[i].name
    for imp in importsOf(prog[i].m):
      if imp in byName: visit(byName[imp], prog, placed, byName, ordered)
    ordered.add prog[i]
  for i in 0 ..< prog.len: visit(i, prog, placed, byName, result)

type Moved = OrderedTable[string, tuple[d: Decl, module: string]]

proc collectMoved(prog: seq[LoadedModule], idx: Table[string, int],
                  sats: seq[Satisfier]): tuple[moved: Moved, kept: HashSet[string]] =
  ## What has to move: each cross-cycle satisfier, and the types its fields
  ## mention that live in an interface's module or in anything that imports
  ## one (the generated module cannot import those without closing the cycle).
  ## `kept` is the modules the rest of the closure stays in, which the
  ## generated module imports.
  var ifaceModules = initHashSet[string]()
  for s in sats: ifaceModules.incl s.iface
  let above = reachers(prog, ifaceModules)
  var work: seq[tuple[d: Decl, module: string]]
  for s in sats:
    if s.obj.name notin result.moved:
      result.moved[s.obj.name] = (s.obj, s.home)
      work.add (s.obj, s.home)
  while work.len > 0:
    let (d, home) = work.pop()
    for n in fieldTypeNames(d):
      let (td, tm) = declOfType(prog, idx, home, n)
      if td == nil or n in result.moved: continue
      if tm in above:
        result.moved[n] = (td, tm)
        work.add (td, tm)
      else:
        result.kept.incl tm

proc variantsModule(prog: seq[LoadedModule], idx: Table[string, int],
                    moved: Moved, kept: HashSet[string], at: Span): Module =
  ## The generated module: its dependencies, then the data. Marks each original
  ## as moved.
  result = Module(path: @[VariantsModule])
  for dep in kept.toSeq.sorted:
    result.decls.add importOf(dep, at)
  for name, entry in moved:
    result.decls.add dataOnly(entry.d, extractFilename(prog[idx[entry.module]].path))
    entry.d.hoistedTo = VariantsModule

proc hoistSatisfierData*(prog: var seq[LoadedModule]) =
  ## See the module comment. A no-op unless some interface has a satisfier it
  ## cannot see.
  var idx = initTable[string, int]()
  for i, lm in prog: idx[lm.name] = i
  let sats = satisfiersAcrossCycle(prog)
  if sats.len == 0: return
  let (moved, kept) = collectMoved(prog, idx, sats)
  let at = sats[0].obj.span
  var g = variantsModule(prog, idx, moved, kept, at)
  # Everything but the generated module's own dependencies imports it.
  let own = depsOf(prog, idx, kept)
  for lm in prog.mitems:
    if lm.name notin own: lm.m.decls.insert(importOf(VariantsModule, at), 0)
  # The interface's module lists each satisfier in its union from a shape-only
  # copy that names the generated module as its origin.
  for s in sats:
    let copy = importedCopy(s.obj, VariantsModule)
    copy.hoistedTo = VariantsModule
    prog[idx[s.iface]].m.decls.insert(copy, 0)
  g.id = moduleId(VariantsModule)
  prog.add LoadedModule(name: VariantsModule, path: "", m: g)
  prog = dependencyFirst(prog)
