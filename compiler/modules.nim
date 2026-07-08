# compiler/modules.nim — import-closure loading with a msgpack AST cache.
#
# `import http` in foo.tuck loads http.tuck from foo's directory. Imported
# modules are cached as serialized msgpack next to their source
# (<dir>/.tuck-cache/<name>.bin) keyed by compiler build stamp + source hash,
# so unchanged modules skip lex+parse on later compiles (incremental
# compilation groundwork). The cache is best-effort: any mismatch or damage
# falls back to a fresh parse.
import os, strutils, hashes, sets, tables
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
      let ipath = ap.parentDir / (imp & ".tuck")
      if not fileExists(ipath):
        raise newException(ModuleError,
          "imported module '" & imp & "' not found: expected " & ipath)
      visit(ipath, false)
    visiting.excl(ap)
    done.incl(ap)
    order.add(LoadedModule(name: extractFilename(ap).changeFileExt(""), path: ap, m: m))

  visit(entryPath, true)
  order
