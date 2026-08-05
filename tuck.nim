# tuck.nim — Tuck compiler CLI.
# Fail fast: every stage stops at the first error with file:line:col context.
#
#   tuck lex     file.tuck        (l)   tokens to stdout
#   tuck parse   file.tuck        (p)   syntax check; --ast dumps JSON
#   tuck check   file.tuck        (ch)  effects + types + PENDING report
#   tuck compile file.tuck        (c)   check + emit .nim (--odin for .odin too)
#
# THE DRIVER — this is where the pipeline is actually sequenced. If you want to
# see the whole compiler in one screen, read `checkProgram` below:
#
#   load          modules.nim      pull in the import closure
#   inject types  modules.nim      imported types become visible unqualified
#   typecheck     typecheck.nim    do the types work out?
#   verify        semantics.nim    do the effects add up?
#   index         modules.nim      cache signatures for next time
#   report                         list what is still `pending:`
#
# and then, for `compile`/`build` only:
#
#   mangle        mangle.nim       tuck_ prefix so emitted names cannot collide
#   lower         lowering.nim     rewrite fancy constructs into dull ones
#   emit          codegen*.nim     print Nim source, and Odin if asked
#
# TWO ORDERING FACTS THAT ARE EASY TO GET WRONG:
#
#   Typecheck BEFORE effects. Typechecking resets the shared semantic layer, so
#   running the effect pass first would wipe its async call-site marks before
#   codegen could read them. Commented on `checkOrDie`.
#
#   Each backend lowers its OWN deepCopy. Lowering and mangling mutate the tree
#   in place, so two backends sharing one tree means the second lowers
#   already-lowered code.
#
# WHY THE `pending:` REPORT EXISTS. Tuck lets you declare a function's
# signature with no body. The compiler emits a stub and lists it as
# unimplemented, so the program still compiles AND runs. You can sketch an
# entire design in types, run it end to end, then fill in bodies one at a time.
# The PENDING block printed after a check is that list.
import os, strutils, times, tables, std/json, osproc
import lexer
import compiler/ast
import compiler/parser
import compiler/semantics
import compiler/typecheck
import compiler/lowering
import compiler/mangle
import compiler/codegen
import compiler/codegen_odin
import compiler/ast_serializer
import compiler/modules

proc usage() =
  stderr.writeLine """tuck — the Tuck compiler

usage: tuck <command> <file.tuck> [options]

commands:
  lex, l        tokenize and print the token stream
  parse, p      parse; prints OK or the first syntax error
  check, ch     parse + effect check + type check + pending report
  compile, c    check + transpile to Nim (and Odin with --odin)
  build, b      compile + nim c to a binary (fn main runs at start)

options:
  --ast         (parse) dump the AST as JSON to stdout
  --odin        (compile) also emit .odin files
  -o:DIR        (compile/build) output directory (default: next to source)
  --root:DIR    import search base for std/ and sibling modules (any command);
                lets imports resolve regardless of cwd or binary location
  --nim:FLAGS   (build) extra nim flags, e.g. --nim:"--os:standalone --cpu:arm""""
  quit(2)

proc die(msg: string) =
  stderr.writeLine msg
  quit(1)

proc elapsedMs(t0: float): string =
  formatFloat((epochTime() - t0) * 1000, ffDecimal, 1) & " ms"

# Pick the quickest C backend available that can build the runtime.
proc pickFastCC(): string =
  # THE SCHEDULER is single-threaded and cooperative, and stays that way: tasks
  # and actors are coroutines, one resume per tick, no preemption (spec §9.4).
  # But a BLOCKING extern (readLine, readFile) cannot be made to yield — a
  # regular file is always "ready" to epoll, so the reactor structurally cannot
  # await it. Those run on the runtime's blocking thread and signal completion
  # through a pipe the reactor already watches (tuck_async.tuckSubmitBlocking),
  # which needs --threads:on.
  #
  # That rules tcc out: it lacks the atomic builtins Nim's threaded runtime
  # needs, and fails with "undeclared identifier: 'atomicStoreN'". tcc built
  # this ~0.2s faster per program; a `readLine` that stops every timer and
  # actor in the process until the user hits enter is the thing being bought.
  if findExe("clang") != "": " --cc:clang --threads:on "
  else: " --threads:on "

# Every backend reports the same two numbers after a successful build, so
# `--nim` vs `--odin` is a fair comparison rather than a vibe.
proc reportBuild(binPath: string, buildMs: float): string =
  var sizeStr = "?"
  try:
    let bytes = getFileSize(binPath)
    sizeStr = if bytes >= 1024 * 1024:
                formatFloat(bytes.float / (1024 * 1024), ffDecimal, 1) & " MB"
              else:
                formatFloat(bytes.float / 1024, ffDecimal, 1) & " KB"
  except OSError, IOError:
    discard
  "(" & formatFloat(buildMs, ffDecimal, 0) & " ms, " & sizeStr & ")"

proc rebaseImplPaths(lm: LoadedModule, backend, outDir: string) =
  ## Rewrite `impl: <backend> "..."` module paths from source-relative (what the
  ## author wrote, and the only frame of reference they have) to output-relative
  ## (what the emitted import needs). `-o:` moves the output around, so this is
  ## the compiler's job rather than something the author tracks.
  ##
  ## Only ./ and ../ forms are paths. "std/strutils" and "core:strings" are
  ## module names in the backend's own namespace and pass through untouched —
  ## the same distinction Nim and Odin themselves draw.
  let srcDir = parentDir(absolutePath(lm.path))
  for d in lm.m.decls:
    if d == nil or d.kind != dkExtern: continue
    for mem in d.mixinMembers:
      if mem.kind != dkFn or not mem.isExtern: continue
      for i in 0 ..< mem.externImpl.len:
        if mem.externImpl[i].backend != backend: continue
        let module = mem.externImpl[i].module
        if not (module.startsWith("./") or module.startsWith("../")): continue
        let abs = normalizedPath(srcDir / module)
        var rel = relativePath(abs, outDir).replace('\\', '/')
        # Keep an explicit relative marker. relativePath returns a BARE name
        # for a sibling ("shim"), and Odin reads a bare import path as a
        # COLLECTION name (like "core:"), not a directory — it fails with
        # "Path does not exist". Nim accepts either, so ./ is right for both.
        if not (rel.startsWith("./") or rel.startsWith("../")): rel = "./" & rel
        mem.externImpl[i].module = rel

proc lexTokens(source: string): seq[Token] =
  var lex = Lexer(source: source, position: 0, line: 1, column: 1, indentStack: @[0])
  while true:
    let t = lex.nextToken()
    result.add(t)
    if t.kind == tkEOF: break

proc parseSource(source: string): Module =
  var p = Parser(source: source, tokens: lexTokens(source), cursor: 0)
  p.parseModule()

# check stage over the whole import closure; returns the loaded program
# (dep-first, entry module last) so compile can continue with it.
# needBodies=false (check): unchanged imports resolve from the signature
# index — no AST load at all. needBodies=true (compile): full ASTs.
proc loadOrDie(path: string, needBodies: bool):
    (seq[LoadedModule], Table[string, IndexEntry]) =
  ## Load the program and its import closure. Without bodies the signature
  ## index answers for the imports, which is what makes `check` cheap.
  var sigOnly = initTable[string, IndexEntry]()
  try:
    if needBodies: return (loadProgram(path), sigOnly)
    return loadProgramIndexed(path)
  except ModuleError as err:
    die(path & ": " & err.msg)

proc importedEffects(loaded: seq[LoadedModule],
                     sigOnly: Table[string, IndexEntry]):
                       Table[string, seq[EffectMarker]] =
  ## Effects of everything visible from OUTSIDE the module being checked, from
  ## both places an import can come from: modules loaded with bodies, and
  ## modules resolved to signatures only from the cached index. Keyed bare and
  ## qualified, because a call may name either (`readFile` or `fs::readFile`).
  for lm in loaded:
    for d in lm.m.decls:
      if d == nil or d.kind != dkFn: continue
      result[d.name] = d.fnEffects
      result[lm.name & "::" & d.name] = d.fnEffects
  for modName, entry in sigOnly:
    for si in entry.sigs:
      if "::" in si.name: continue
      result[si.name] = si.effects
      result[modName & "::" & si.name] = si.effects

proc checkOrDie(path: string, loaded: seq[LoadedModule],
                sigOnly: Table[string, IndexEntry]): seq[string] =
  ## Typecheck, then verify effects. Order matters: typecheckProgram resets
  ## the semantic layer, so the effect pass must run AFTER it or its async
  ## call-site marks are wiped before codegen reads them.
  var mods: seq[tuple[name, path: string, m: Module]]
  for lm in loaded: mods.add((lm.name, lm.path, lm.m))
  var preSigs = initTable[string, seq[SigInfo]]()
  for name, e in sigOnly: preSigs[name] = e.sigs
  let imported = importedEffects(loaded, sigOnly)
  try:
    result = typecheckProgram(mods, preSigs)
    for lm in loaded: verifyModuleEffects(lm.m, imported)
  except SemanticError as err:
    # typecheckProgram errors already carry file:line:col; effects errors don't
    if ".tuck:" in err.msg: die(err.msg)
    else: die(path & ":" & $err.line & ":" & $err.col & ": " & err.msg)

proc pendingEntries(loaded: seq[LoadedModule],
                    sigOnly: Table[string, IndexEntry]): seq[string] =
  ## Every unimplemented fn across the program, qualified when it lives in an
  ## imported module rather than the one being checked.
  for lm in loaded:
    for entry in pendingReport(lm.m):
      if lm.path != loaded[^1].path: result.add(lm.name & "::" & entry)
      else: result.add(entry)
  for name, e in sigOnly:
    for si in e.sigs:
      if si.isPending: result.add(name & "::" & sigLine(si))

proc report(title, noun: string, entries: seq[string]) =
  ## One `TITLE (n noun):` block with its indented entries, or nothing at all.
  if entries.len == 0: return
  echo title, " (", entries.len, " ", noun, "):"
  for entry in entries: echo "  ", entry

proc checkProgram(path: string, needBodies = false): seq[LoadedModule] =
  var sigOnly: Table[string, IndexEntry]
  (result, sigOnly) = loadOrDie(path, needBodies)
  injectImportedTypes(result)  # imported types are visible unqualified
  let shortcuts = checkOrDie(path, result, sigOnly)
  # program checked clean: refresh the signature index for future checks
  updateIndex(parentDir(absolutePath(path)), result, moduleSigs)
  report("PENDING", "unimplemented", pendingEntries(result, sigOnly))
  report("SHORTCUTS", "routed to the global error handler", shortcuts)

when isMainModule:
  if paramCount() < 2: usage()
  let cmd = paramStr(1)
  let path = paramStr(2)
  if not fileExists(path): die("tuck: no such file: " & path)
  let source = readFile(path)
  var opts: seq[string]
  for i in 3 .. paramCount(): opts.add(paramStr(i))
  # `--root:DIR` sets the import search base explicitly, so imports resolve
  # regardless of cwd or where the binary sits (see modules.resolveImport).
  for o in opts:
    if o.startsWith("--root:"): projectRoot = o[7 .. ^1]
  let t0 = epochTime()

  case cmd
  of "lex", "l":
    for t in lexTokens(source):
      echo t.line, ":", t.column, "\t", t.kind, "\t", t.value
    echo "OK (", elapsedMs(t0), ")"
  of "parse", "p":
    let m = parseSource(source)
    if "--ast" in opts:
      echo pretty(toJson(m))
    echo "OK — ", m.decls.len, " top-level declarations (", elapsedMs(t0), ")"
  of "check", "ch":
    discard checkProgram(path)
    echo "OK (", elapsedMs(t0), ")"
  of "compile", "c", "build", "b":
    let prog = checkProgram(path, needBodies = true)
    var outDir = parentDir(path)
    for o in opts:
      if o.startsWith("-o:"): outDir = o[3 .. ^1]
    if outDir == "": outDir = "."
    createDir(outDir)
    let base = extractFilename(path).changeFileExt("")
    # import path from the output dir back to the runtime module
    let rtDir = getAppDir() / "compiler"
    let rtImport = relativePath(rtDir / "tuck_rt", outDir).replace('\\', '/')
    var realModules = initTable[string, Module]()
    for lm in prog[0 ..< prog.high]:
      realModules[lm.name] = lm.m
    # Mangling runs ONCE over the WHOLE IMPORT CLOSURE and the shared
    # Resolution, BEFORE the per-backend copies. Whole-program because a
    # qualified reference names a decl in another module — `http::get` is a
    # user fn and gets the prefix, `fs::readFile` is an extern and does not —
    # which one module alone cannot distinguish. Before the copies because
    # the Resolution is global; renaming it per-copy would leave the other
    # backends looking up names that no longer exist.
    var progMods: seq[Module]
    for lm in prog: progMods.add(lm.m)
    mangleProgram(progMods)
    # Each backend lowers its OWN copy: lowering and the emitters both mutate
    # the tree (injectTailReturn), so a shared one would hand Beef whatever
    # Nim's pass left behind. Node ids survive the copy, so the Resolution
    # built during checking stays reachable from either clone.
    var nimProg: seq[LoadedModule]
    for lm in prog: nimProg.add(LoadedModule(name: lm.name, path: lm.path,
                                             m: deepCopy(lm.m)))
    var nimReal = initTable[string, Module]()
    for lm in nimProg[0 ..< nimProg.high]: nimReal[lm.name] = lm.m
    # `impl: nim "./shim/x"` — the author writes the path relative to their OWN
    # .tuck file, which is the only place they can see it from. The emitted
    # import has to be relative to the OUTPUT dir instead, and -o: moves that
    # around, so rebase here rather than making the author think about it.
    # A leading ./ or ../ marks a path; anything else ("std/strutils",
    # "core:strings") is a target-language module name and rides through.
    for lm in nimProg: rebaseImplPaths(lm, "nim", outDir)
    # imported modules first (each its own Nim file), entry module last
    for lm in nimProg:
      lowerModule(lm.m)
      let isEntry = lm.path == nimProg[^1].path
      let outName = if isEntry: base else: lm.name
      let nimPath = outDir / (outName & ".nim")
      writeFile(nimPath, emitNim(lm.m, rtImport, nimReal, outName))
      echo "wrote ", nimPath
    if "--odin" in opts:
      var odProg: seq[LoadedModule]
      for lm in prog: odProg.add(LoadedModule(name: lm.name, path: lm.path,
                                              m: deepCopy(lm.m)))
      var odReal = initTable[string, Module]()
      for lm in odProg[0 ..< odProg.high]: odReal[lm.name] = lm.m
      for lm in odProg: rebaseImplPaths(lm, "odin", outDir)
      for lm in odProg:
        lowerModule(lm.m)
      for lm in odProg[0 ..< odProg.high]:
        # Odin packages are DIRECTORIES: an imported module becomes
        # mod_<name>/<name>.odin so `import fs "./mod_fs"` resolves.
        let modDir = outDir / ("mod_" & lm.name.replace("-", "_"))
        createDir(modDir)
        let modOdPath = modDir / (lm.name.replace("-", "_") & ".odin")
        writeFile(modOdPath, emitOdinModule(lm.name, lm.m, odReal))
        echo "wrote ", modOdPath
      let odPath = outDir / (base & ".odin")
      writeFile(odPath, emitOdin(odProg[^1].m, odReal, base))
      echo "wrote ", odPath
      # The emitted package imports `./tuckrt`, so the runtime rides along.
      let rtSrc = getAppDir() / "compiler" / "tuckrt"
      if dirExists(rtSrc):
        let rtDst = outDir / "tuckrt"
        createDir(rtDst)
        # the WHOLE runtime package, not just tuck_rt.odin: tuck_coro.odin
        # defines tuckAsyncInit/tuckRun/tuckSpawn, which the emitted entry
        # point calls for any program with tasks or actors, plus the minicoro
        # archive it links against.
        for f in walkFiles(rtSrc / "*.odin"):
          copyFile(f, rtDst / extractFilename(f))
        if fileExists(rtSrc / "minicoro.a"):
          copyFile(rtSrc / "minicoro.a", rtDst / "minicoro.a")
      # C sources an extern block binds with `lib: "path/to.c"`. Nim takes the
      # .c directly via {.compile.}; Odin cannot compile C, so it links the
      # object — build it here, next to where the emitted `foreign import`
      # expects it.
      for d in odProg[^1].m.decls:
        if d == nil or d.kind != dkExtern: continue
        for mem in d.mixinMembers:
          if mem.kind != dkFn or not mem.isExtern: continue
          if not mem.externLib.endsWith(".c"): continue
          let cSrc = parentDir(path) / mem.externLib
          if not fileExists(cSrc): continue
          let obj = outDir / mem.externLib.changeFileExt("o")
          createDir(obj.parentDir())
          if execShellCmd("cc -c -fPIC " & quoteShell(cSrc) & " -o " &
                          quoteShell(obj)) != 0:
            die("tuck: failed to compile C source " & cSrc)
    let m = prog[^1].m
    if cmd in ["build", "b"]:
      # entry point: `fn main` runs when the binary starts. No main =
      # library build: the emitted code IS the artifact, no binary.
      var hasMain = false
      var mainReturns = false
      var actorNames: seq[string]
      var hasTasks = false
      for d in m.decls:
        # `m` was mangled above, so `fn main` is now tuck_main here.
        if d != nil and d.kind == dkFn and d.name == mangleName("main"):
          hasMain = true
          mainReturns = d.fnReturnType != nil and
            not (d.fnReturnType.kind == tkNamed and d.fnReturnType.name in ["void", "unit"])
        if d != nil and d.kind == dkActor:
          # `m` is the ORIGINAL tree; each backend mangled its own deepCopy,
          # so the emitted symbol carries the prefix and this must match.
          actorNames.add(mangleName(d.name))
        if d != nil and d.kind == dkTask:
          hasTasks = true
      if not hasMain:
        echo "library (no fn main): emitted code only, no binary"
        echo "OK (", elapsedMs(t0), ")"
        quit(0)
      let mainNim = outDir / (base & ".nim")
      # ONE Tuck runtime (compiler/tuck_async, arsenal engine): actors AND tasks
      # are cooperative coroutines. Any program with actors or tasks imports it,
      # inits it, registers its actor singletons before main, and — for tasks —
      # drives to completion after main. Actors are daemons; main owns the
      # lifecycle and waits on public state via scheduler::waitUntil.
      let usesRuntime = actorNames.len > 0 or hasTasks
      var boot = ""
      var asyncInit = ""
      var asyncDrive = ""
      if usesRuntime:
        let asyncImp = relativePath(getAppDir() / "compiler" / "tuck_async", outDir).replace('\\', '/')
        writeFile(mainNim, "import " & asyncImp & "\n" & readFile(mainNim))
        asyncInit = "  tuckAsyncInit()\n"
        for a in actorNames: boot.add("  registerActor" & a & "()\n")
        if hasTasks: asyncDrive = "\n  tuckRun()"
      # a value-returning main IS the process exit code. When the runtime drives
      # tasks after main, keep main's return as the exit code via mainRc.
      # `fn main` is mangled like every other user fn, so the entry calls the
      # prefixed symbol.
      let tuckMain = mangleName("main") & "()"
      let mainCall =
        if hasTasks and mainReturns: "let mainRc = " & tuckMain
        elif mainReturns: "quit(" & tuckMain & ")"
        else: tuckMain
      let asyncExit = if hasTasks and mainReturns: "\n  quit(mainRc)" else: ""
      writeFile(mainNim, readFile(mainNim) &
        "\nwhen isMainModule:\n" & asyncInit & boot & "  " & mainCall &
        asyncDrive & asyncExit & "\n")
      # nim flags passthrough for cross/bare-metal: --nim:"--os:standalone ..."
      var nimFlags = ""
      for o in opts:
        if o.startsWith("--nim:"): nimFlags = o[6 .. ^1]
      # Nim module names can't start with a digit or contain dashes
      var binBase = base.replace("-", "_")
      if binBase.len > 0 and binBase[0] in {'0' .. '9'}: binBase = "m_" & binBase
      let binNim = outDir / (binBase & ".nim")
      if binNim != mainNim: copyFile(mainNim, binNim)
      let binPath = outDir / binBase
      # Async programs need Nim's stack-walker OFF (it corrupts the switched
      # coroutine stack — mandatory, see tuck_async). tuck_rt is the single
      # facade and imports tuck_async, so EVERY build needs these flags even
      # for a pure program (the async paths are linked, just not used).
      # No --path: the coroutine engine is vendored in compiler/tuck_coro.nim.
      let asyncFlags = " --stackTrace:off --lineTrace:off "
      # Default to the FAST path, not the fast-binary path: -d:release and
      # -d:danger cost seconds of optimisation the edit/run loop never wants.
      # `--opt:none` plus a quick C compiler is the shortest route to a
      # runnable binary; `--release` opts into the slow, fast-code build.
      let wantRelease = "--release" in opts
      let speedFlags =
        if wantRelease: " -d:release "
        else: " --opt:none -d:tuckFast " & pickFastCC()
      # Nim derives its cache dir from the MODULE NAME, so two tuck builds of
      # different programs that happen to share a basename (every `t.tuck` in
      # a test suite) collide in ~/.cache/nim/t_d — one build's C output
      # answering the other's link, nondeterministically, only under
      # concurrency. Pin the cache next to the output instead: unique per
      # build by construction, and it makes `tuck build` self-contained.
      let nimCache = outDir / ".nimcache" / binBase
      let nimCmd = "nim c --hints:off --warnings:off " & nimFlags & asyncFlags &
                   speedFlags & " --nimcache:" & quoteShell(nimCache) &
                   " -o:" & quoteShell(binPath) & " " &
                   quoteShell(binNim)
      let nimT0 = epochTime()
      let rc = execShellCmd(nimCmd)
      let buildMs = (epochTime() - nimT0) * 1000
      if rc != 0: die("tuck: nim compilation failed")
      echo "built ", binPath, "  ", reportBuild(binPath, buildMs)
      if "--odin" in opts:
        let odinExe = if findExe("odin") != "": findExe("odin")
                      elif fileExists("/home/kl/apps/Odin/odin"): "/home/kl/apps/Odin/odin"
                      else: ""
        if odinExe == "":
          echo "tuck: odin not found on PATH — skipping Odin build"
        else:
          # Odin builds a DIRECTORY (the package), not a single file, and
          # wants the entry file named after nothing in particular — the
          # emitted <base>.odin plus tuckrt/ and mod_*/ are already there.
          let odinBin = outDir / (binBase & "_odin")
          # -o:none is Odin's fastest path; -o:speed is the release build.
          let odinOpt = if wantRelease: "-o:speed" else: "-o:none"
          let odinCmd = quoteShell(odinExe) & " build " & quoteShell(outDir) &
                        " " & odinOpt & " -out:" & quoteShell(odinBin)
          let odT0 = epochTime()
          let odRc = execShellCmd(odinCmd)
          let odMs = (epochTime() - odT0) * 1000
          if odRc != 0:
            echo "tuck: odin compilation failed"
          else:
            echo "built ", odinBin, "  ", reportBuild(odinBin, odMs)
    echo "OK (", elapsedMs(t0), ")"
  else:
    usage()
