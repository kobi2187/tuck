# compiler/modules.nim — import-closure loading with a msgpack AST cache.
#
# STAGE 3 OF THE PIPELINE — find the rest of the program.
#
# `import time` means the compiler now needs std/time.tuck too, and whatever
# THAT imports, and so on. This file walks the import graph and loads the whole
# closure before any checking starts, because you cannot typecheck a call to
# something you have not read yet.
#
# THE IDEA WORTH STEALING: checking a program does not need the full BODIES of
# its imports — only their SIGNATURES, the names and types of what they export.
# So a signature index is kept on disk, and `tuck check` loads signatures
# instead of re-parsing entire files. `tuck build` asks for real bodies,
# because now it genuinely has to emit code for them. Same walk, two depths,
# and the cheap one is what you run on every keystroke.
#
# `import http` in foo.tuck loads http.tuck from foo's directory. Imported
# modules are cached as serialized msgpack next to their source
# (<dir>/.tuck-cache/<name>.bin) keyed by compiler build stamp + source hash,
# so unchanged modules skip lex+parse on later compiles (incremental
# compilation groundwork). The cache is best-effort: any mismatch or damage
# falls back to a fresh parse.
#
# ---------------------------------------------------------------------------
# TWO CACHES, DOING DIFFERENT JOBS
#
# 1. THE AST CACHE (.tuck-cache/<name>.bin) — skips lex+parse.
#    A whole parsed Module, msgpack-serialized, keyed on compiler build stamp
#    + source hash. Deserializing beats re-parsing, and the key means a
#    recompiled compiler or an edited source invalidates it automatically.
#    Saves the ~43% of compile time that lexing and parsing cost.
#
# 2. THE SIGNATURE INDEX (.tuck-cache/index.bin) — skips the imports entirely.
#    This is the bigger win by far. Checking a module needs its imports'
#    SIGNATURES — exported names, their params and return types — not their
#    bodies. The index stores just that, so `tuck check` never walks the
#    interior of an imported module at all: no typechecking it, no effect
#    verification, no lowering.
#
# The asymmetry is deliberate. `tuck check` runs on every save and asks for
# signatures. `tuck build` runs when you actually want a binary and asks for
# bodies, because now it has to emit code for them. Same loader, two depths.
#
# WHY THIS BEATS OPTIMIZING THE PASSES. Per-phase tuning is worth a few percent
# (see benches/bench_phases.nim: no single phase exceeds ~30% of the total).
# Not loading the import closure at all is worth however large that closure
# is — unbounded, and it grows with the project rather than the file. The
# fastest pass is the one that does not run.
#
# CORRECTNESS OVER SPEED, ALWAYS. Every cache here is best-effort: a stamp
# mismatch, a hash mismatch, a truncated or unreadable file all fall back to a
# fresh parse rather than trusting stale data. A cache that can serve a wrong
# answer is worse than no cache, because the failure surfaces later as a
# baffling type error in code the user did not touch.
# ---------------------------------------------------------------------------
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
        # A cached module carries the ids it had when it was written, which
        # would collide with the ids handed out this run. Renumber into the
        # current program's space.
        result = entry.m
        clearIds(result)
        assignIds(result)
        return result
    except CatchableError, Defect:
      # msgpack raises Defects (ObjectConversionDefect) on layout changes,
      # which the stamp check never gets to see — treat both as stale
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
    except CatchableError, Defect:
      discard  # damaged index (incl. msgpack layout Defects): treat as empty
  initTable[string, IndexEntry]()

proc srcHashOf(path: string): string =
  $hash(readFile(path))

proc resolveImport*(importerPath, module: string): string  # defined below

# The source path an import resolves to FROM `dir` — its own directory, the
# --root project, or the stdlib (same search resolveImport uses at load time).
# A module imported as `import sys` lives under std/, NOT dir/sys.tuck, so the
# cache must hash it where it actually is or std imports never validate.
# Returns "" when the module can't be found.
proc resolvedImportPath(dir, name: string): string =
  try: resolveImport(dir / "_.tuck", name)
  except ModuleError: ""

# Entry is trustworthy iff its module's source is unchanged AND every dep it
# was checked against is itself still valid (a changed dep changes the sigs
# this module was checked against).
proc entryValid(idx: Table[string, IndexEntry], dir, name: string,
                seen: var HashSet[string]): bool =
  if name in seen: return true  # cycle guard; load path errors on real cycles
  seen.incl(name)
  if not idx.hasKey(name): return false
  let path = resolvedImportPath(dir, name)
  if path == "" or not fileExists(path): return false
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
      let ipath = resolvedImportPath(lm.path.parentDir, imp)
      if ipath != "" and fileExists(ipath):
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

# A project root passed explicitly on the CLI (`--root:DIR`). Set once at
# startup; searched before the ambient getAppDir() locations so a moved
# binary (test runner, installed tuck) still finds std/ and sibling modules.
var projectRoot*: string = ""

# Import resolution: the importer's directory first, then the stdlib
# (--root flag, TUCK_STDLIB env var, or std/ next to the compiler binary).
proc resolveImport*(importerPath, module: string): string =
  var candidates = @[importerPath.parentDir / (module & ".tuck")]
  if projectRoot != "":
    candidates.add(projectRoot / (module & ".tuck"))
    candidates.add(projectRoot / "std" / (module & ".tuck"))
  let envStd = getEnv("TUCK_STDLIB")
  if envStd != "":
    candidates.add(envStd / (module & ".tuck"))
  candidates.add(getAppDir() / "std" / (module & ".tuck"))
  candidates.add(getAppDir() / ".." / "std" / (module & ".tuck"))
  for c in candidates:
    if fileExists(c): return c
  raise newException(ModuleError,
    "imported module '" & module & "' not found: tried " & candidates.join(", "))

# Imported TYPES are visible unqualified in the importer (user ruling —
# composition must read clean: `type Player = Playback + Cache`). Inject
# imported type decls into each importer, marked so codegen skips re-emitting
# them (Nim's own import brings the real definitions in).
# `import time` makes time's TYPES usable unqualified — you write `Milliseconds`,
# not `time::Milliseconds`. Rather than teach every lookup in the checker to
# search imported modules, the imported type declarations are copied into the
# importer's own decl list, tagged with ImportedTypeMarker so later stages can
# still tell them apart (codegen skips them: the target's own import already
# brings them in).
proc injectImportedTypes*(prog: var seq[LoadedModule]) =
  ## Make each module's imported types visible unqualified in the importer.
  var typesByName = initTable[string, seq[Decl]]()
  for lm in prog:
    var own: seq[Decl]
    for d in lm.m.decls:
      if d != nil and d.kind == dkType and not d.span.file.startsWith(ImportedTypeMarker):
        own.add(d)
    typesByName[lm.name] = own
  for i in 0 ..< prog.len:
    for imp in importsOf(prog[i].m):
      for td in typesByName.getOrDefault(imp):
        let marked = Decl(kind: dkType, name: td.name, generics: td.generics,
                          typeBody: td.typeBody, typeMembers: td.typeMembers,
                          span: Span(line: td.span.line, col: td.span.col,
                                     file: ImportedTypeMarker & ":" & imp))
        prog[i].m.decls.insert(marked, 0)

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
