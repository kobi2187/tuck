# compiler/mock_surface.nim
#
# THE MOCK SURFACE (issue #70): every extern a fn can reach on the call graph.
#
# "What do I have to stub to test this?" has a mechanical answer in Tuck,
# because an effect originates in exactly one place: a declared signature, and
# the only signatures with no Tuck body behind them are externs. So the things
# that touch the world, from any fn, are the externs reachable from it. This
# pass walks the checked call graph from a root and keeps that answer.
#
# Two uses read it. `tuck mock FILE` prints it: the exact list a fake has to
# implement. `--mock` on a build makes it runnable: each reachable extern the
# program declares itself (not the stdlib's) becomes a `pending` stub, the
# body-less signature every backend already emits as "log the call, return the
# zero value" — so an app whose C header does not exist yet builds and runs,
# and its output is the record of what it asked the world for.
import algorithm, os, sets, strutils, tables
import ast, ast_ops, ast_query, modules, resolution, typecheck_util

type
  MockEntry* = object
    module*: string
    decl*: Decl
    own*: bool   ## declared under the entry file's directory, not the stdlib's

  Owned = tuple[module: string, decl: Decl]

  Graph = object
    byName: Table[string, Table[string, Decl]]  ## module -> name -> callable
    externs: HashSet[int]                      ## ids of extern members
    moduleOf: Table[int, string]               ## decl id -> its module
    imports: Table[string, seq[string]]
    prog: seq[LoadedModule]

proc key(d: Decl): int = cast[int](d)

proc collect(g: var Graph, module: string, d: Decl, inExtern: bool) =
  if d == nil or d.origin != NoModule: return
  case d.kind
  of dkFn, dkTask:
    if not g.byName[module].hasKey(d.name): g.byName[module][d.name] = d
    g.moduleOf[key(d)] = module
    if inExtern or d.isExtern: g.externs.incl key(d)
  of dkExtern:
    for m in d.mixinMembers: g.collect(module, m, true)
  of dkObject, dkActor, dkMixin, dkPending, dkWhen, dkInterface, dkGroup, dkType:
    for m in d.childDecls: g.collect(module, m, inExtern)
  of dkConst, dkExpr, dkStaticAssert, dkSelect, dkRegistry, dkPool, dkSlab,
     dkArena, dkRegister, dkImport, dkFnSig, dkSatisfies, dkResources,
     dkErrors, dkPublic:
    discard

proc graphOf(prog: seq[LoadedModule]): Graph =
  result.prog = prog
  for lm in prog:
    result.byName[lm.name] = initTable[string, Decl]()
    result.imports[lm.name] = importsOf(lm.m)
    for d in lm.m.decls: result.collect(lm.name, d, false)

proc lookup(g: Graph, module, name: string): Decl =
  ## `name` as `module` sees it: its own, then an import's.
  if g.byName.getOrDefault(module).hasKey(name): return g.byName[module][name]
  for imp in g.imports.getOrDefault(module):
    if g.byName.getOrDefault(imp).hasKey(name): return g.byName[imp][name]

proc moduleNamed(g: Graph, name: string): Module =
  for lm in g.prog:
    if lm.name == name: return lm.m

proc calleeOf(g: Graph, module: string, n: Expr): Decl =
  ## The callable a node reaches, or nil: a call by name (bare, qualified, or
  ## a nullary name the checker stamped as a call), or a member call.
  let call = if n.kind == exkCall: n
             elif semLayer.hasCall(n): semLayer.call(n)
             else: nil
  if call == nil or call.callee == nil: return nil
  let member = memberCallDecl(semLayer, g.moduleNamed(module), call)
  if member != nil: return member
  case call.callee.kind
  of exkVar: g.lookup(module, call.callee.name)
  of exkQualified:
    if call.callee.modulePath.len > 0:
      g.lookup(call.callee.modulePath[^1], call.callee.qualName)
    else: nil
  else: nil

proc reach(g: Graph, root: Owned): seq[Owned] =
  ## Every extern reachable from `root`, in the order first reached.
  var seen: HashSet[int]
  var work = @[root]
  while work.len > 0:
    let (module, d) = work.pop()
    if d == nil or key(d) in seen: continue
    seen.incl key(d)
    if key(d) in g.externs:
      result.add (module, d)
      continue
    if d.fnBody == nil: continue
    for n in d.fnBody.nodes:
      let callee = g.calleeOf(module, n)
      if callee != nil:
        work.add (g.moduleOf.getOrDefault(key(callee), module), callee)

proc mockSurface*(prog: seq[LoadedModule], entryPath, root: string): seq[MockEntry] =
  ## The externs reachable from `root` in the entry module (every top-level
  ## fn and task of it when `root` is empty), sorted by module then name.
  let g = graphOf(prog)
  let entry = prog[^1]
  var roots: seq[Owned]
  if root != "":
    let d = g.byName[entry.name].getOrDefault(root)
    if d == nil: raise newException(ValueError, "no fn '" & root & "' in " & entry.path)
    roots.add (entry.name, d)
  else:
    for d in entry.m.decls:
      if d != nil and d.kind in {dkFn, dkTask} and d.origin == NoModule:
        roots.add (entry.name, d)
  let home = parentDir(absolutePath(entryPath))
  var seen: HashSet[int]
  for r in roots:
    for (module, d) in g.reach(r):
      if key(d) in seen: continue
      seen.incl key(d)
      var path = ""
      for lm in prog:
        if lm.name == module: path = lm.path
      result.add MockEntry(module: module, decl: d,
                           own: absolutePath(path).startsWith(home & DirSep))
  result.sort(proc (a, b: MockEntry): int =
    result = cmp(a.module, b.module)
    if result == 0: result = cmp(a.decl.name, b.decl.name))

proc signature(d: Decl): string =
  var params: seq[string]
  for p in d.fnParams: params.add p.name & ": " & typeName(p.typ)
  result = writtenName(d) &
           (if params.len == 0: "()" else: "({" & params.join(", ") & "})")
  if d.fnReturnType != nil: result.add " -> " & typeName(d.fnReturnType)
  if d.fnEffects.len > 0:
    var names: seq[string]
    for m in d.fnEffects: names.add effectName(m)
    result.add " [" & names.join(", ") & "]"

proc formatSurface*(entries: seq[MockEntry], root: string): string =
  ## `tuck mock`'s text: one extern per line, the program's own first-class,
  ## the stdlib's marked as such (`--mock` leaves those real).
  let start = if root == "": "the entry module" else: "'" & root & "'"
  result = "# mock surface of " & start & ": " & $entries.len &
           " extern(s) reachable\n"
  for e in entries:
    result.add e.module & "  " & signature(e.decl) &
               (if e.own: "" else: "  # stdlib, kept real by --mock") & "\n"

var mockedExterns*: HashSet[string]
  ## `--mock`'s choice, as `module.name`: set from a first check's surface,
  ## applied by the driver to the freshly loaded program of the second, so the
  ## checker sees each one as the `pending:` signature it now is.

proc mockedOf*(entries: seq[MockEntry]): HashSet[string] =
  for e in entries:
    if e.own: result.incl e.module & "." & e.decl.name

proc stubMockedExterns*(prog: var seq[LoadedModule]): int =
  ## Each extern named in `mockedExterns` moves out of its `extern` block into
  ## a `pending:` block of its own, exactly as if the author had written it
  ## there. Returns how many.
  if mockedExterns.len == 0: return 0
  for lm in prog.mitems:
    var stubs: seq[Decl]
    for d in lm.m.decls:
      if d == nil or d.kind != dkExtern: continue
      var kept: seq[Decl]
      for m in d.mixinMembers:
        if m == nil or lm.name & "." & m.name notin mockedExterns:
          kept.add m
          continue
        m.isExtern = false
        m.externHeader = ""
        m.externLib = ""
        m.externEmit = ""
        m.externImpl = @[]
        m.isPending = true
        stubs.add m
      d.mixinMembers = kept
    if stubs.len > 0:
      lm.m.decls.add Decl(id: newNodeId(), span: stubs[0].span, kind: dkPending,
                          name: "pending", mixinMembers: stubs)
      result += stubs.len
