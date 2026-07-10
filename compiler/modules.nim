# compiler/modules.nim — import-closure loading with a msgpack AST cache.
#
# `import http` in foo.tuck loads http.tuck from foo's directory. Imported
# modules are cached as serialized msgpack next to their source
# (<dir>/.tuck-cache/<name>.bin) keyed by compiler build stamp + source hash,
# so unchanged modules skip lex+parse on later compiles (incremental
# compilation groundwork). The cache is best-effort: any mismatch or damage
# falls back to a fresh parse.
import os, strutils, hashes, sets, tables, times
import msgpack4nim
import ast, parser
import ../lexer

type
  ModuleError* = object of ValueError

  LoadedModule* = object
    name*: string   # module name = file base name
    path*: string   # absolute source path
    m*: Module

  CacheEntry = object
    stamp: string
    srcHash: string
    m: Module

# New compiler build invalidates every cache (AST layout may have changed).
const buildStamp = CompileDate & " " & CompileTime

proc parseTuckFile*(path: string): Module =
  let source = readFile(path)
  var lex = Lexer(source: source, position: 0, line: 1, column: 1, indentStack: @[0])
  var tokens: seq[Token]
  while true:
    let t = lex.nextToken()
    tokens.add(t)
    if t.kind == tkEOF: break
  var p = Parser(source: source, tokens: tokens, cursor: 0)
  p.parseModule()

proc cachePathFor(path: string): string =
  path.parentDir / ".tuck-cache" / extractFilename(path).changeFileExt("bin")

proc loadModuleCached(path: string): Module =
  let source = readFile(path)
  let srcHash = $hash(source)
  let cp = cachePathFor(path)
  if fileExists(cp):
    try:
      var entry: CacheEntry
      unpack(readFile(cp), entry)
      if entry.stamp == buildStamp and entry.srcHash == srcHash:
        return entry.m
    except CatchableError:
      discard  # stale or damaged cache: reparse below
  result = parseTuckFile(path)
  try:
    createDir(cp.parentDir)
    writeFile(cp, pack(CacheEntry(stamp: buildStamp, srcHash: srcHash, m: result)))
  except CatchableError:
    discard  # cache write is best-effort

proc importsOf*(m: Module): seq[string] =
  for d in m.decls:
    if d != nil and d.kind == dkImport:
      result.add(d.name)

# ---------- signature index ----------
# One msgpack table per directory (.tuck-cache/index.bin): module name →
# source hash, signatures, deps (+ their hashes at index time), cache time.
# `check` resolves unchanged imports from here — no AST deserialization, no
# reparse, no body re-check. Entries are written only after a whole-program
# check passed, so trusting a fresh entry is sound.

type
  IndexEntry* = object
    srcHash*: string
    cachedAt*: int64                      # unix seconds, informational
    deps*: seq[tuple[name, hash: string]] # dep set at index time
    sigs*: seq[SigInfo]

  SigIndex = object
    stamp: string   # compiler build stamp; mismatch = whole index stale
    entries: Table[string, IndexEntry]

proc indexPathFor(dir: string): string =
  dir / ".tuck-cache" / "index.bin"

proc loadIndex*(dir: string): Table[string, IndexEntry] =
  let ip = indexPathFor(dir)
  if fileExists(ip):
    try:
      var idx: SigIndex
      unpack(readFile(ip), idx)
      if idx.stamp == buildStamp:
        return idx.entries
    except CatchableError:
      discard  # damaged index: treat as empty
  initTable[string, IndexEntry]()

proc srcHashOf(path: string): string =
  $hash(readFile(path))

# Entry is trustworthy iff its module's source is unchanged AND every dep it
# was checked against is itself still valid (a changed dep changes the sigs
# this module was checked against).
proc entryValid(idx: Table[string, IndexEntry], dir, name: string,
                seen: var HashSet[string]): bool =
  if name in seen: return true  # cycle guard; load path errors on real cycles
  seen.incl(name)
  if not idx.hasKey(name): return false
  let path = dir / (name & ".tuck")
  if not fileExists(path): return false
  let e = idx[name]
  if e.srcHash != srcHashOf(path): return false
  for (dep, h) in e.deps:
    if not idx.hasKey(dep) or idx[dep].srcHash != h: return false
    if not entryValid(idx, dir, dep, seen): return false
  true

proc entryValid*(idx: Table[string, IndexEntry], dir, name: string): bool =
  var seen: HashSet[string]
  entryValid(idx, dir, name, seen)

# Refresh index entries for the given fully-loaded modules. `sigsOf` is
# injected by the driver (typecheck.moduleSigs) to keep this file free of
# checker dependencies. Call only after the program checked clean.
proc updateIndex*(dir: string, mods: seq[LoadedModule],
                  sigsOf: proc(m: Module): seq[SigInfo]) =
  var idx = SigIndex(stamp: buildStamp, entries: loadIndex(dir))
  for lm in mods:
    var deps: seq[tuple[name, hash: string]]
    for imp in importsOf(lm.m):
      let ipath = lm.path.parentDir / (imp & ".tuck")
      if fileExists(ipath):
        deps.add((imp, srcHashOf(ipath)))
    idx.entries[lm.name] = IndexEntry(
      srcHash: srcHashOf(lm.path),
      cachedAt: getTime().toUnix,
      deps: deps,
      sigs: sigsOf(lm.m))
  try:
    createDir(indexPathFor(dir).parentDir)
    writeFile(indexPathFor(dir), pack(idx))
  except CatchableError:
    discard  # index is an accelerator, never a blocker

# Import resolution: the importer's directory first, then the stdlib
# (TUCK_STDLIB env var, or std/ next to the compiler binary / repo root).
proc resolveImport*(importerPath, module: string): string =
  var candidates = @[importerPath.parentDir / (module & ".tuck")]
  let envStd = getEnv("TUCK_STDLIB")
  if envStd != "":
    candidates.add(envStd / (module & ".tuck"))
  candidates.add(getAppDir() / "std" / (module & ".tuck"))
  candidates.add(getAppDir() / ".." / "std" / (module & ".tuck"))
  for c in candidates:
    if fileExists(c): return c
  raise newException(ModuleError,
    "imported module '" & module & "' not found: tried " & candidates.join(", "))

proc loadProgram*(entryPath: string): seq[LoadedModule] =
  ## Parse the entry file and its whole import closure. Dep-first order,
  ## entry module last. Diamond imports collapse; cycles are errors.
  var visiting, done: HashSet[string]
  var order: seq[LoadedModule]

  proc visit(path: string, isEntry: bool) =
    let ap = absolutePath(path)
    if ap in done: return
    if ap in visiting:
      raise newException(ModuleError, "import cycle through " & extractFilename(ap))
    visiting.incl(ap)
    # the entry module is always parsed fresh (it's what's being worked on)
    let m = if isEntry: parseTuckFile(ap) else: loadModuleCached(ap)
    for imp in importsOf(m):
      visit(resolveImport(ap, imp), false)
    visiting.excl(ap)
    done.incl(ap)
    order.add(LoadedModule(name: extractFilename(ap).changeFileExt(""), path: ap, m: m))

  visit(entryPath, true)
  order

proc loadProgramIndexed*(entryPath: string):
    tuple[full: seq[LoadedModule], sigOnly: Table[string, IndexEntry]] =
  ## `check`-path loading: an import with a fresh index entry contributes
  ## only its signatures — no reparse, no AST deserialization, no body
  ## re-check (it checked clean when indexed). Everything else loads in
  ## full. The entry module always loads in full.
  let dir = absolutePath(entryPath).parentDir
  let idx = loadIndex(dir)
  var visiting, done: HashSet[string]
  var full: seq[LoadedModule]
  var sigOnly = initTable[string, IndexEntry]()

  proc visit(path: string, isEntry: bool) =
    let ap = absolutePath(path)
    if ap in done: return
    if ap in visiting:
      raise newException(ModuleError, "import cycle through " & extractFilename(ap))
    visiting.incl(ap)
    let m = if isEntry: parseTuckFile(ap) else: loadModuleCached(ap)
    for imp in importsOf(m):
      let ipath = resolveImport(ap, imp)
      if absolutePath(ipath) notin done and entryValid(idx, dir, imp):
        sigOnly[imp] = idx[imp]
      else:
        visit(ipath, false)
    visiting.excl(ap)
    done.incl(ap)
    full.add(LoadedModule(name: extractFilename(ap).changeFileExt(""), path: ap, m: m))

  visit(entryPath, true)
  (full, sigOnly)
