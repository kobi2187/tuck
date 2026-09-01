# tuck.nim — Tuck compiler CLI.
# Fail fast: every stage stops at the first error with file:line:col context.
#
#   tuck lex     file.tuck        (l)   tokens to stdout
#   tuck parse   file.tuck        (p)   syntax check; --ast dumps JSON
#   tuck check   file.tuck        (ch)  effects + types + PENDING report
#   tuck compile file.tuck        (c)   check + emit — one target: Nim by
#                                        default, or --odin, or --dlang
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
#   emit          codegen*.nim     print source for ONE backend: Nim by
#                                  default, or Odin/D if asked
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
import os, strutils, times, tables, std/json, osproc, std/sets
import jsony
import lexer
import compiler/ast
import compiler/parser
import compiler/semantics
import compiler/complexity
import compiler/typecheck
import compiler/lowering
import compiler/mangle
import compiler/codegen
import compiler/codegen_odin
import compiler/codegen_d
import compiler/lowering_d
import compiler/ast_serializer
import compiler/modules
import compiler/optimize
import compiler/pipeline

const CommandHelp = {
  "lex": """tuck lex file.tuck
tuck l file.tuck

Tokenize the file and print each token, one per line, as
line:column  KIND  value

No extra flags. Fails on the first character it cannot tokenize.""",
  "parse": """tuck parse file.tuck [--ast]
tuck p file.tuck [--ast]

Parse the file and print "OK" plus a declaration count, or the first
syntax error with file:line:col.

  --ast    print the parsed tree as JSON instead of the OK line""",
  "check": """tuck check file.tuck
tuck ch file.tuck

Parse, then run the effect checker and type checker, then print a
PENDING report (stub functions still unimplemented) and a size
report. Prints "OK" if everything checks out; otherwise the first
type or effect error with file:line:col.""",
  "compile": """tuck compile file.tuck [--odin | --dlang] [-o:DIR] [options]
tuck c file.tuck [--odin | --dlang] [-o:DIR] [options]

Check, then transpile to source for ONE backend: Nim by default, or
--odin, or --dlang (these two are mutually exclusive — pick one per
run). Writes beside the source file, or into -o:DIR if given.

  --odin       target Odin instead of Nim
  --dlang      target D instead of Nim
  -o:DIR       output directory
  --root:DIR   import search base (for std/ and sibling modules)
  --target:NAME  select which `when TARGET == "NAME":` blocks compile in
  --verify-stages  run extra pipeline-ordering assertions (off by default)
  -O:PASS[,...]  choose optimization passes; `-O:none` disables them all
  --max-complexity:N, --max-fn-lines:N  per-function size budget

See `tuck help build` for the flags shared with build, or run
`tuck` with no arguments for the full option reference.""",
  "build": """tuck build file.tuck [--odin | --dlang] [-o:DIR] [options]
tuck b file.tuck [--odin | --dlang] [-o:DIR] [options]

Everything `tuck compile` does, then invokes the backend's own
compiler (nim c / odin build / dmd) to link a runnable binary.
fn main runs when the binary starts.

Takes every `tuck compile` flag, plus:
  --nim:FLAGS  extra flags passed through to `nim c`, e.g.
               --nim:"--os:standalone --cpu:arm"
  --release    promote the size-budget report to a build failure

Run `tuck help compile` for the rest of the shared flags.""",
  "dump": """tuck dump file.tuck [--stage:X] [--format:X] [options]
tuck d file.tuck [--stage:X] [--format:X] [options]

Run the real compiler pipeline up to one named stage and print the
tree it produced there — useful for seeing what a stage actually
did without running the whole build.

  --stage:X   which stage to stop at: lex, parse, load, inject-types,
              typecheck, verify-effects, mangle, lowering, emitting
              (default: emitting)
  --format:X  json (default, pretty-printed) or text (repr(), for
              trees that do not serialize to JSON)

`lowering` and `emitting` pick a backend the same way `compile`
does: Nim by default, or --odin, or --dlang.""",
  "explain": """tuck explain CODE

Print what a diagnostic code means and how to fix it, e.g.:

  tuck explain TK-TY05

Codes look like TK-XXNN and appear in every type/effect/parse error
tuck prints. This is the one command that takes a CODE, not a file."""
}.toTable

const CommandAliases = {"l": "lex", "p": "parse", "ch": "check",
                         "c": "compile", "b": "build", "d": "dump"}.toTable

proc printCommandHelp(cmd: string, code = 0) =
  let key = CommandAliases.getOrDefault(cmd, cmd)
  if CommandHelp.hasKey(key):
    echo CommandHelp[key]
    quit(code)
  stderr.writeLine "tuck: no such command: '" & cmd & "'"
  stderr.writeLine "  known commands: lex, parse, check, compile, build, dump, explain"
  stderr.writeLine "  run `tuck help` for the full list, or `tuck help <command>` for one of these"
  quit(2)

proc usage(code = 2) =
  stderr.writeLine """tuck — the Tuck compiler

usage: tuck <command> <file.tuck> [options]
       tuck help [command]   detailed usage for one command

commands:
  lex, l        tokenize and print the token stream
  parse, p      parse; prints OK or the first syntax error
  check, ch     parse + effect check + type check + pending report
  compile, c    check + transpile — one target: Nim, or --odin, or --dlang
  build, b      compile + nim c to a binary (fn main runs at start)
  dump, d       run the pipeline up to --stage=X and print the tree
  explain CODE  what a diagnostic code means, e.g. `tuck explain TK-TY05`
  help, -h, --help [command]  this message, or one command's own usage

options:
  --ast         (parse) dump the AST as JSON to stdout
  --odin        (compile/build) target Odin instead of Nim
  --dlang       (compile/build) target D instead of Nim
                (--odin and --dlang are mutually exclusive; Nim is the
                default target when neither is given)
  -o:DIR        (compile/build) output directory (default: next to source)
  --root:DIR    import search base for std/ and sibling modules (any command);
                lets imports resolve regardless of cwd or binary location
  --target:NAME selects which `when TARGET == "NAME":` blocks compile in
                (spec §8.3; any command). Unset = every such block is dropped.
  --verify-stages (compile/build) run diagnostic assertions checking a tree
                carries what the next pipeline stage needs (off by default —
                see compiler/pipeline.nim).
  --stage:X     (dump) which stage to stop at: lex, parse, load,
                inject-types, typecheck, verify-effects, mangle, lowering,
                emitting (default: emitting). lowering/emitting use the
                same --odin/--dlang backend choice as compile/build.
  --format:X    (dump) json (default, pretty-printed) or text (the same
                data, unformatted — repr() does not compile for this tree)
  -O:PASS[,...] (compile/build) optimization passes. ON by default — every
                pass is semantics-preserving. `-O:none` turns them all off,
                which is the first thing to try if emitted code looks wrong.
                Naming passes replaces the default set; `-O:report` lists what
                was rewritten. See compiler/optimize.nim for what each does
                and what it refuses to touch.
  --nim:FLAGS   (build) extra nim flags, e.g. --nim:"--os:standalone --cpu:arm"
  --max-complexity:N  size budget: max independent paths through a fn
                (any command; default 6, `:0` disables). A match/select costs
                nothing for the construct — only what its arms do is counted.
  --max-fn-lines:N    size budget: max source lines a fn may span
                (any command; default 8, `:0` disables). Match/select arm
                bodies and `decision` tables do not count.

  Functions over either budget are REPORTED worst-first, and only fail the
  build under --release."""
  quit(code)

proc die(msg: string) =
  stderr.writeLine msg
  quit(1)

proc dieSyntax(err: ref SyntaxError) {.noreturn.} =
  ## Print a front-end rejection the way the lexer and parser used to print it
  ## themselves, before they were changed to raise. The FORMAT is unchanged —
  ## what moved is who decides to exit. The error names its own stage, so a
  ## lexical error stays labelled one even when `tuck parse` is what surfaced
  ## it.
  let tag = if err.code.len > 0: err.stage & " " & err.code else: err.stage
  stderr.writeLine "\n[" & tag & "] at line " & $err.line & ", column " &
                   $err.col & ":"
  stderr.writeLine "  " & err.msg
  if err.context.len > 0:
    stderr.writeLine ""
    stderr.writeLine "    " & err.context
    stderr.writeLine "    " & repeat(' ', max(err.col - 1, 0)) & "^"
  # The code's own explanation, looked up by the string the error carries.
  if err.code.len > 0:
    stderr.writeLine ""
    stderr.writeLine "  " & explainCode(err.code)
  stderr.writeLine ""
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

proc lexOrDie(source: string): seq[Token] =
  ## `tuck lex` — the tokens, or the diagnostic and exit.
  try: lexSource(source)
  except SyntaxError as err: dieSyntax(err)

proc parseOrDie(source: string): Module =
  ## `tuck parse` — the AST, or the diagnostic and exit.
  try: parseSource(source)
  except SyntaxError as err: dieSyntax(err)

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
  except SyntaxError as err:
    # A malformed source anywhere in the import closure. The stage that found
    # it does not know which FILE it was reading; modules.nim does, and says so
    # by prefixing the path onto the message before re-raising.
    dieSyntax(err)

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

proc typecheckOnly(path: string, loaded: seq[LoadedModule],
                   sigOnly: Table[string, IndexEntry]): seq[string] =
  ## Just the typecheck half of the check pipeline. checkOrDie calls this
  ## once and continues with effects; `tuck dump --stage=typecheck` calls it
  ## and stops, which is the seam that split it out — before this, typecheck
  ## and verify-effects shared one proc with no return point between them.
  var mods: seq[tuple[name, path: string, m: Module]]
  for lm in loaded: mods.add((lm.name, lm.path, lm.m))
  var preSigs = initTable[string, seq[SigInfo]]()
  for name, e in sigOnly: preSigs[name] = e.sigs
  try:
    result = typecheckProgram(mods, preSigs)
  except SemanticError as err:
    if ".tuck:" in err.msg: die(err.msg)
    else: die(path & ":" & $err.line & ":" & $err.col & ": " & err.msg)

proc checkOrDie(path: string, loaded: seq[LoadedModule],
                sigOnly: Table[string, IndexEntry],
                verifyStages = false): seq[string] =
  ## Typecheck, then verify effects. Order matters: typecheckProgram resets
  ## the semantic layer, so the effect pass must run AFTER it or its async
  ## call-site marks are wiped before codegen reads them.
  result = typecheckOnly(path, loaded, sigOnly)
  let imported = importedEffects(loaded, sigOnly)
  try:
    for lm in loaded: verifyModuleEffects(lm.m, imported)
    if verifyStages:
      var loadedMods: seq[Module]
      for lm in loaded: loadedMods.add(lm.m)
      assertAsyncEffectsConsistent(loadedMods)
  except SemanticError as err:
    # typecheckProgram errors already carry file:line:col; effects errors don't
    if ".tuck:" in err.msg: die(err.msg)
    else: die(path & ":" & $err.line & ":" & $err.col & ": " & err.msg)

proc sizeReport(path: string, loaded: seq[LoadedModule]) =
  ## Print every function over the size budget, worst first — and on a release
  ## build, stop.
  ##
  ## Runs AFTER typecheck and effects: size is a style limit, not a correctness
  ## one, so a file that does not compile reports the real error rather than a
  ## size list for code that was never going to build.
  ##
  ## Only the module being checked, never its imports. A dependency's oversized
  ## fn is its author's build to fix — listing fns you cannot edit is not a
  ## work plan, it is noise you learn to scroll past.
  let offenders = measureModule(loaded[^1].m, sizeBudget)
  if offenders.len == 0: return
  let verb = if sizeIsError: "OVER BUDGET" else: "SIZE"
  echo verb, " (", offenders.len, " ",
       (if offenders.len == 1: "function" else: "functions"), "):"
  for o in offenders:
    echo "  ", path, ":", o.span.line, ":", o.span.col, ": ",
         describe(o, sizeBudget)
  # A normal build has now SAID it; a release build stops. Same measurement,
  # different moment — see complexity.sizeIsError.
  if sizeIsError:
    die("tuck: " & $offenders.len & " function(s) over the size budget " &
        "(--release requires them under it; raise with --max-complexity:N / " &
        "--max-fn-lines:N, or :0 to disable)")

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

proc dumpTree(mods: seq[Module], fmt: string, withSem = false) =
  ## `tuck dump`'s output for a stage past parsing: the tree, and — once
  ## something has actually resolved (typecheck onward) — the semLayer
  ## side-table alongside it, keyed by NodeId.
  ##
  ## `--format:text` was meant to be stdlib `repr()` (zero new code) — it
  ## does not compile here: Nim's effect checker rejects `repr` on this
  ## tree's recursive ref-object shape at the CALL SITE ("can raise an
  ## unlisted exception"), a real Nim limitation, not something a
  ## try/except can catch since the rejection is at compile time. `text`
  ## is the same jsony path as `json`, minus the `pretty()` formatting
  ## pass — still zero new dependency, since jsony is already the one
  ## this file uses.
  var arr = newJArray()
  for m in mods: arr.add(toJson(m))
  var obj = newJObject()
  obj["modules"] = arr
  if withSem: obj["semLayer"] = semLayerJson(mods)
  if fmt == "text": echo obj else: echo pretty(obj)

proc checkProgram(path: string, needBodies = false,
                  verifyStages = false): seq[LoadedModule] =
  var sigOnly: Table[string, IndexEntry]
  (result, sigOnly) = loadOrDie(path, needBodies)
  for lm in result.mitems: resolveWhenBlocks(lm.m, buildTarget)  # spec §8.3
  injectImportedTypes(result)  # imported types are visible unqualified
  let shortcuts = checkOrDie(path, result, sigOnly, verifyStages)
  # program checked clean: refresh the signature index for future checks
  updateIndex(parentDir(absolutePath(path)), result, moduleSigs)
  report("PENDING", "unimplemented", pendingEntries(result, sigOnly))
  report("SHORTCUTS", "routed to the global error handler", shortcuts)
  sizeReport(path, result)

when isMainModule:
  # `help`/`-h`/`--help` take an optional COMMAND, never a file — answered
  # before the paramCount check below, which would otherwise treat a bare
  # `tuck help` (no command) as a missing-argument error instead of a request.
  if paramCount() >= 1 and paramStr(1) in ["help", "-h", "--help"]:
    if paramCount() < 2: usage(0)
    else: printCommandHelp(paramStr(2))
  if paramCount() < 2:
    # A known command with no file (`tuck dump`, `tuck compile`, ...) gets its
    # own focused usage rather than the full banner — it already said what it
    # wants to do, it's just missing the argument to do it with.
    if paramCount() == 1 and
       CommandHelp.hasKey(CommandAliases.getOrDefault(paramStr(1), paramStr(1))):
      printCommandHelp(paramStr(1), code = 2)
    usage()
  let cmd = paramStr(1)
  # `explain` takes a CODE, not a file — answered before the file check below.
  if cmd == "explain":
    let dc = parseCode(paramStr(2))
    if dc == dcNone:
      die("tuck: no such diagnostic code: " & paramStr(2) &
          " (codes look like TK-TY05)")
    echo $dc, "  ", categoryName(dc), " Error"
    echo "  ", explanationOf(dc)
    quit(0)
  let path = paramStr(2)
  if not fileExists(path): die("tuck: no such file: " & path)
  let source = readFile(path)
  var opts: seq[string]
  for i in 3 .. paramCount(): opts.add(paramStr(i))
  # `--root:DIR` sets the import search base explicitly, so imports resolve
  # regardless of cwd or where the binary sits (see modules.resolveImport).
  for o in opts:
    if o.startsWith("--root:"): projectRoot = o[7 .. ^1]
  # `--target:NAME` selects which `when TARGET == "...":` blocks (spec §8.3)
  # compile in; see modules.resolveWhenBlocks. Unset = "" = every such block
  # is dropped (fails closed, not toward guessing a platform). Unrelated to
  # backend selection below — this picks embedded/cross-compile targets, not
  # which compiler backend runs.
  for o in opts:
    if o.startsWith("--target:"): buildTarget = o[9 .. ^1]
  # A build targets exactly ONE backend: Nim by default, or --odin, or
  # --dlang — mutually exclusive, never additive. Nim used to emit
  # unconditionally regardless of these flags; getting a second backend's
  # output alongside it now costs a second invocation, not a second flag.
  type Backend = enum bkNim, bkOdin, bkDlang
  var backend = bkNim
  var backendFlagCount = 0
  for o in opts:
    case o
    of "--odin": backend = bkOdin; inc backendFlagCount
    of "--dlang": backend = bkDlang; inc backendFlagCount
    else: discard
  if backendFlagCount > 1:
    die("tuck: --odin and --dlang are mutually exclusive — one target per build")
  # Diagnostic assertions that a tree carries what the next pipeline stage
  # needs (compiler/pipeline.nim). Off by default — they walk the whole
  # tree, and existing builds/tests should see no behavior or perf change.
  let verifyStages = "--verify-stages" in opts
  # Optimization passes (compiler/optimize.nim) are ON by default — a pass
  # that only runs when asked for is a pass nothing exercises, and every one
  # here is required to be semantics-preserving.
  #
  # `-O:none` turns them all off, which is the first step when emitted code
  # looks wrong: if `-O:none` changes the answer, the bug is in a pass.
  # `-O:name[,name]` selects an explicit subset. `-O:report` lists every site
  # a pass rewrote. An unknown pass name is fatal rather than ignored: a typo
  # in a build script must not quietly mean something other than it says.
  var optPasses: set[OptPass]
  for p in OptPass: optPasses.incl(p)
  var optReport = false
  var optExplicit = false      # a -O: naming passes REPLACES the default set
  for o in opts:
    if not o.startsWith("-O:"): continue
    var spec = o[3 .. ^1]
    if spec == "report" or spec.startsWith("report,"):
      optReport = true
      spec = (if spec == "report": "" else: spec["report,".len .. ^1])
    elif spec.endsWith(",report"):
      optReport = true
      spec = spec[0 ..< spec.len - ",report".len]
    if spec == "none":
      optPasses = {}
      optExplicit = true
      continue
    if spec == "": continue                      # bare `-O:report`
    let (ps, bad) = parseOptPasses(spec)
    if bad != "":
      var known: seq[string]
      for p in OptPass: known.add($p)
      die("tuck: no such optimization pass: '" & bad & "'\n" &
          "  available: " & known.join(", ") & ", all, none")
    if not optExplicit:
      optPasses = {}                             # drop the defaults first
      optExplicit = true
    optPasses = optPasses + ps
  # `--max-complexity:N` / `--max-fn-lines:N` — the per-fn size budget
  # (compiler/complexity.nim). `:0` disables that half of the check. A
  # non-number is rejected rather than silently read as 0, which would turn a
  # typo into a disabled check.
  for o in opts:
    for (flag, field) in [("--max-complexity:", 0), ("--max-fn-lines:", 1)]:
      if o.startsWith(flag):
        let raw = o[flag.len .. ^1]
        var n: int
        try: n = parseInt(raw)
        except ValueError:
          die("tuck: " & flag & " needs a number, got: " & raw)
        if n < 0: die("tuck: " & flag & " cannot be negative: " & raw)
        if field == 0: sizeBudget.maxComplexity = n
        else: sizeBudget.maxLines = n
  # `--release` promotes the size report from a list to a failure. Read here
  # rather than in the build arm because the check runs before it.
  sizeIsError = "--release" in opts
  let t0 = epochTime()

  case cmd
  of "lex", "l":
    for t in lexOrDie(source):
      echo t.line, ":", t.column, "\t", t.kind, "\t", t.value
    echo "OK (", elapsedMs(t0), ")"
  of "parse", "p":
    let m = parseOrDie(source)
    if "--ast" in opts:
      echo pretty(toJson(m))
    echo "OK — ", m.decls.len, " top-level declarations (", elapsedMs(t0), ")"
  of "check", "ch":
    discard checkProgram(path)
    echo "OK (", elapsedMs(t0), ")"
  of "dump", "d":
    # Run the pipeline up to --stage=X and print the tree — a thin driver
    # over the SAME procs `tuck c`/`tuck b` call, stopping early. `lex`/
    # `parse` stay single-file, matching `tuck l`/`tuck p`'s existing
    # meaning; `load` onward switches to the real multi-module pipeline,
    # since there is no single-file version of typecheck to fall back to.
    var stageStr = "emitting"
    for o in opts:
      if o.startsWith("--stage:"): stageStr = o[8 .. ^1]
    var fmt = "json"
    for o in opts:
      if o.startsWith("--format:"): fmt = o[9 .. ^1]
    case stageStr
    of "lex":
      let toks = lexOrDie(source)
      let j = parseJson(jsony.toJson(toks))
      if fmt == "text": echo j else: echo pretty(j)
    of "parse":
      let m = parseOrDie(source)
      let j = toJson(m)
      if fmt == "text": echo j else: echo pretty(j)
    of "load", "inject-types", "typecheck", "verify-effects", "mangle",
       "lowering", "emitting":
      var sigOnly: Table[string, IndexEntry]
      var loaded: seq[LoadedModule]
      (loaded, sigOnly) = loadOrDie(path, needBodies = true)
      for lm in loaded.mitems: resolveWhenBlocks(lm.m, buildTarget)
      var mods: seq[Module]
      for lm in loaded: mods.add(lm.m)
      if stageStr == "load":
        dumpTree(mods, fmt)
      else:
        injectImportedTypes(loaded)
        if stageStr == "inject-types":
          dumpTree(mods, fmt)
        elif stageStr == "typecheck":
          discard typecheckOnly(path, loaded, sigOnly)
          dumpTree(mods, fmt, withSem = true)
        else:
          discard checkOrDie(path, loaded, sigOnly)
          if stageStr == "verify-effects":
            dumpTree(mods, fmt, withSem = true)
          else:
            discard optimizeProgram(mods, optPasses)
            mangleProgram(mods)
            if stageStr == "mangle":
              dumpTree(mods, fmt, withSem = true)
            else:
              # lowering / emitting: exactly one backend, same choice as
              # compile/build (default Nim, or --odin/--dlang).
              var bProg: seq[LoadedModule]
              for lm in loaded: bProg.add(LoadedModule(name: lm.name,
                path: lm.path, m: deepCopy(lm.m)))
              var bReal = initTable[string, Module]()
              for lm in bProg[0 ..< bProg.high]: bReal[lm.name] = lm.m
              let backendName = case backend
                of bkNim: "nim"
                of bkOdin: "odin"
                of bkDlang: "d"
              for lm in bProg: rebaseImplPaths(lm, backendName, ".")
              for lm in bProg:
                lowerModule(lm.m)
                if backend == bkDlang: lowerModuleD(lm.m)
              if stageStr == "lowering":
                var bMods: seq[Module]
                for lm in bProg: bMods.add(lm.m)
                dumpTree(bMods, fmt)
              else:
                let dumpBase = extractFilename(path).changeFileExt("")
                case backend
                of bkNim:
                  for lm in bProg: echo emitNim(lm.m, "tuck_rt", bReal, lm.name)
                of bkOdin:
                  for lm in bProg[0 ..< bProg.high]:
                    echo emitOdinModule(lm.name, lm.m, bReal)
                  echo emitOdin(bProg[^1].m, bReal, dumpBase)
                of bkDlang:
                  for lm in bProg[0 ..< bProg.high]:
                    echo emitDModule(lm.name, lm.m, bReal)
                  echo emitD(bProg[^1].m, bReal, dumpBase)
    else:
      die("tuck: no such stage: '" & stageStr & "' (lex, parse, load, " &
          "inject-types, typecheck, verify-effects, mangle, lowering, emitting)")
  of "compile", "c", "build", "b":
    let prog = checkProgram(path, needBodies = true, verifyStages = verifyStages)
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
    # OPTIONAL passes (compiler/optimize.nim), before mangling so they work on
    # the user's own names, and before the per-backend copies so one rewrite
    # serves both. With no `-O` this is a no-op returning an empty seq — the
    # emitted code is then byte-identical to a build of a tree without that
    # file at all, which is what makes each pass independently testable.
    let optHits = optimizeProgram(progMods, optPasses)
    if optReport:
      report("OPTIMIZED", "site(s) rewritten", optHits)
    mangleProgram(progMods)
    if verifyStages: assertMangleIdempotent(progMods)
    # Each backend lowers its OWN copy: lowering and the emitters both mutate
    # the tree (injectTailReturn), so a shared one would hand Beef whatever
    # Nim's pass left behind. Node ids survive the copy, so the Resolution
    # built during checking stays reachable from either clone.
    case backend
    of bkNim:
      var nimProg: seq[LoadedModule]
      for lm in prog: nimProg.add(LoadedModule(name: lm.name, path: lm.path,
                                               m: deepCopy(lm.m)))
      var nimReal = initTable[string, Module]()
      for lm in nimProg[0 ..< nimProg.high]: nimReal[lm.name] = lm.m
      # `impl: nim "./shim/x"` — the author writes the path relative to their
      # OWN .tuck file, which is the only place they can see it from. The
      # emitted import has to be relative to the OUTPUT dir instead, and -o:
      # moves that around, so rebase here rather than making the author think
      # about it. A leading ./ or ../ marks a path; anything else
      # ("std/strutils", "core:strings") is a target-language module name and
      # rides through.
      for lm in nimProg: rebaseImplPaths(lm, "nim", outDir)
      # imported modules first (each its own Nim file), entry module last
      for lm in nimProg:
        lowerModule(lm.m)
        let isEntry = lm.path == nimProg[^1].path
        let outName = if isEntry: base else: lm.name
        let nimPath = outDir / (outName & ".nim")
        writeFile(nimPath, emitNim(lm.m, rtImport, nimReal, outName))
        echo "wrote ", nimPath
      if verifyStages:
        var nimMods: seq[Module]
        for lm in nimProg: nimMods.add(lm.m)
        assertNoChainFedCalls(nimMods)
    of bkOdin:
      var odProg: seq[LoadedModule]
      for lm in prog: odProg.add(LoadedModule(name: lm.name, path: lm.path,
                                              m: deepCopy(lm.m)))
      var odReal = initTable[string, Module]()
      for lm in odProg[0 ..< odProg.high]: odReal[lm.name] = lm.m
      for lm in odProg: rebaseImplPaths(lm, "odin", outDir)
      for lm in odProg:
        lowerModule(lm.m)
      if verifyStages:
        var odMods: seq[Module]
        for lm in odProg: odMods.add(lm.m)
        assertNoChainFedCalls(odMods)
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
    of bkDlang:
      # Third backend, same discipline: its own deepCopy (lowering mutates),
      # one .d file per module (D modules are files, unlike Odin's package
      # directories), runtime rides along as a sibling tuck_rt.d.
      var dProg: seq[LoadedModule]
      for lm in prog: dProg.add(LoadedModule(name: lm.name, path: lm.path,
                                             m: deepCopy(lm.m)))
      var dReal = initTable[string, Module]()
      for lm in dProg[0 ..< dProg.high]: dReal[lm.name] = lm.m
      for lm in dProg: rebaseImplPaths(lm, "d", outDir)
      for lm in dProg:
        lowerModule(lm.m)
        # ...then the D backend's OWN lowering, on its private copy. Target
        # semantics that differ from Tuck's (a D slice aliases where a Tuck
        # Seq copies) are settled here as tree marks, so the emitter is left
        # printing rather than deciding.
        lowerModuleD(lm.m)
      if verifyStages:
        var dMods: seq[Module]
        for lm in dProg: dMods.add(lm.m)
        assertNoChainFedCalls(dMods)
      for lm in dProg[0 ..< dProg.high]:
        let modDPath = outDir / ("mod_" & lm.name.replace("-", "_") & ".d")
        writeFile(modDPath, emitDModule(lm.name, lm.m, dReal))
        echo "wrote ", modDPath
      let dPath = outDir / (base & ".d")
      writeFile(dPath, emitD(dProg[^1].m, dReal, base))
      echo "wrote ", dPath
      # A vendored `.c` an extern block binds: compile it to an object the
      # dmd link step picks up. Same step the Odin path takes above — dmd,
      # like odin, does not compile C itself.
      for d in dProg[^1].m.decls:
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
      let rtSrcD = getAppDir() / "compiler" / "tuckrt_d"
      if dirExists(rtSrcD):
        for f in walkFiles(rtSrcD / "*.d"):
          copyFile(f, outDir / extractFilename(f))
      # The coroutine engine is the SAME vendored C library all three
      # backends drive (compiler/vendor/minicoro), prebuilt as minicoro.a —
      # that is what keeps concurrency semantics and performance shape from
      # depending on which backend built the program.
      let mcoSrc = getAppDir() / "compiler" / "tuckrt" / "minicoro.a"
      if fileExists(mcoSrc):
        copyFile(mcoSrc, outDir / "minicoro.a")
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
      # Nim module names can't start with a digit or contain dashes. Hoisted
      # here (backend-agnostic, needed by all three build arms below) rather
      # than computed once per backend.
      let wantRelease = "--release" in opts
      var binBase = base.replace("-", "_")
      if binBase.len > 0 and binBase[0] in {'0' .. '9'}: binBase = "m_" & binBase
      case backend
      of bkNim:
        let mainNim = outDir / (base & ".nim")
        # ONE Tuck runtime (compiler/tuck_async, arsenal engine): actors AND
        # tasks are cooperative coroutines. Any program with actors or tasks
        # imports it, inits it, registers its actor singletons before main,
        # and — for tasks — drives to completion after main. Actors are
        # daemons; main owns the lifecycle and waits on public state via
        # scheduler::waitUntil.
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
        # a value-returning main IS the process exit code. When the runtime
        # drives tasks after main, keep main's return as the exit code via
        # mainRc. `fn main` is mangled like every other user fn, so the entry
        # calls the prefixed symbol.
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
        let binNim = outDir / (binBase & ".nim")
        if binNim != mainNim: copyFile(mainNim, binNim)
        let binPath = outDir / binBase
        # Async programs need Nim's stack-walker OFF (it corrupts the
        # switched coroutine stack — mandatory, see tuck_async). tuck_rt is
        # the single facade and imports tuck_async, so EVERY build needs
        # these flags even for a pure program (the async paths are linked,
        # just not used). No --path: the coroutine engine is vendored in
        # compiler/tuck_coro.nim.
        let asyncFlags = " --stackTrace:off --lineTrace:off "
        # Default to the FAST path, not the fast-binary path: -d:release and
        # -d:danger cost seconds of optimisation the edit/run loop never
        # wants. `--opt:none` plus a quick C compiler is the shortest route
        # to a runnable binary; `--release` opts into the slow, fast-code
        # build.
        let speedFlags =
          if wantRelease: " -d:release "
          else: " --opt:none -d:tuckFast " & pickFastCC()
        # Nim derives its cache dir from the MODULE NAME, so two tuck builds
        # of different programs that happen to share a basename (every
        # `t.tuck` in a test suite) collide in ~/.cache/nim/t_d — one
        # build's C output answering the other's link, nondeterministically,
        # only under concurrency. Pin the cache next to the output instead:
        # unique per build by construction, and it makes `tuck build`
        # self-contained.
        #
        # TUCK_NIMCACHE overrides that for callers who can guarantee no
        # concurrent build shares it. The runtime (tuck_rt, tuck_async,
        # tuck_coro, vendored minicoro) is identical for every program, so
        # compiling it once instead of per build takes a hello-world from
        # 0.85s to 0.27s. The test suite sets this PER SCRIPT: builds within
        # one script are sequential, so they share safely, while concurrent
        # scripts keep separate caches and the collision above stays
        # impossible.
        let sharedCache = getEnv("TUCK_NIMCACHE")
        let nimCache = if sharedCache != "": sharedCache
                       else: outDir / ".nimcache" / binBase
        let nimCmd = "nim c --hints:off --warnings:off " & nimFlags & asyncFlags &
                     speedFlags & " --nimcache:" & quoteShell(nimCache) &
                     " -o:" & quoteShell(binPath) & " " &
                     quoteShell(binNim)
        let nimT0 = epochTime()
        let rc = execShellCmd(nimCmd)
        let buildMs = (epochTime() - nimT0) * 1000
        if rc != 0: die("tuck: nim compilation failed")
        echo "built ", binPath, "  ", reportBuild(binPath, buildMs)
      of bkOdin:
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
      of bkDlang:
        let dmdExe = findExe("dmd")
        if dmdExe == "":
          echo "tuck: dmd not found on PATH — skipping D build"
        else:
          let dBin = outDir / (binBase & "_d")
          # -i compiles imported modules (mod_*.d, tuck_rt.d) automatically;
          # -O -release is the fast-code build, default is the fast build.
          let dOpt = if wantRelease: " -O -release" else: ""
          # Objects built from vendored C sources ride on the command line:
          # dmd's pragma(lib) is for SYSTEM libraries and would turn a path
          # into a -l<path> the linker cannot resolve.
          #
          # Only the objects THIS driver compiled from an `extern ... lib:
          # "x.c"` — collected by name, not by sweeping the output tree. A
          # walkDirRec over outDir also picked up Nim's .nimcache objects and
          # any stale build product, which made the dmd link fail with
          # duplicate and foreign symbols (observed, not theorised).
          # One `extern [... lib: "x.c"]:` block commonly declares several
          # fns sharing that one C source (point.c's counterBump AND
          # counterFree, say) — collect by unique OBJECT PATH, not once per
          # matching fn, or the same .o rides the dmd command line twice and
          # the linker sees every symbol in it twice ("multiple definition").
          var seenObjs: HashSet[string]
          var cObjs = ""
          for d in m.decls:
            if d == nil or d.kind != dkExtern: continue
            for mem in d.mixinMembers:
              if mem.kind != dkFn or not mem.isExtern: continue
              if not mem.externLib.endsWith(".c"): continue
              let obj = outDir / mem.externLib.changeFileExt("o")
              if obj in seenObjs: continue
              if fileExists(obj):
                seenObjs.incl(obj)
                cObjs.add(" " & quoteShell(obj))
          # The coroutine engine's C archive, linked when it is present —
          # dmd -i pulls in tuck_coro.d, whose extern(C) declarations this
          # resolves.
          let mcoA = outDir / "minicoro.a"
          let mcoArg = if fileExists(mcoA): " " & quoteShell(mcoA) else: ""
          # `impl: d "..."` modules. Unlike Nim's `import ./shim/x` or
          # Odin's `import "./shim"` (both a path baked into the import
          # itself), a D `import` is a bare module name resolved only
          # through `-I` search paths — so the shim's directory rides the
          # dmd command line instead of anything rebased or copied. `m` here
          # is the pre-rebase tree (shared across all three backends' build
          # phase), so `module` is still author-relative to `path`, exactly
          # like `externLib` above.
          var implDirs: HashSet[string]
          for d in m.decls:
            if d == nil or d.kind != dkExtern: continue
            for mem in d.mixinMembers:
              if mem.kind != dkFn or not mem.isExtern: continue
              for (backend, module) in mem.externImpl:
                if backend != "d": continue
                implDirs.incl(parentDir(path) / module.parentDir())
          var implIArgs = ""
          for dir in implDirs: implIArgs.add(" -I" & quoteShell(dir))
          let dCmd = quoteShell(dmdExe) & " -i" & dOpt &
                     " -I" & quoteShell(outDir) & implIArgs &
                     " -of=" & quoteShell(dBin) & " " &
                     quoteShell(outDir / (base & ".d")) & cObjs & mcoArg
          let dT0 = epochTime()
          let dRc = execShellCmd(dCmd)
          let dMs = (epochTime() - dT0) * 1000
          if dRc != 0:
            echo "tuck: dmd compilation failed"
          else:
            echo "built ", dBin, "  ", reportBuild(dBin, dMs)
    echo "OK (", elapsedMs(t0), ")"
  else:
    usage()
