# tests/beef_backend.nim
# Beef backend parity tests. Two layers:
#   1. Feature assertions: every example is compiled through the full
#      pipeline (parse -> typecheck -> lower -> emitBeef) and the emitted
#      Beef source is checked for the constructs the Nim backend guarantees
#      (result auto-wrap, record ctors, actors with payloads, ...).
#   2. Compile check: when a Beef toolchain is available (BeefBuild on PATH,
#      $BEEFBUILD_BIN, or /opt/beef/IDE/dist/BeefBuild), the emitted output
#      of the examples in beefCheckExpected is built as a real Beef project
#      against the Beef runtime (compiler/tuck_rt.bf).
import os, strutils, tables, osproc
import ../lexer
import ../compiler/ast
import ../compiler/parser
import ../compiler/lowering
import ../compiler/codegen_beef
import ../compiler/semantics
import ../compiler/typecheck
import ../compiler/modules

const
  exampleDir = "examples"
  outDir = "tests/beef_out"
  rtBeef = "compiler/tuck_rt.bf"

# --- Layer 1: per-example feature assertions on the emitted Beef source ---
# Keyed by example base name; every listed substring must appear.
const expectSubstrings = {
  # !T auto-wrap, err -> terr, error policy handler, dropped-result routing
  "22-error-policy": @[
    "TuckResult<",                      # !{value:u16} maps to a result type
    "tok(",                             # ok-path auto-wrap
    "terr<",                            # Error.badPort early error return
    "tuck_unhandled(",                  # global policy handler emitted
    "tuckReportUnhandled(",             # rt logger runs first
    ".ok) tuck_unhandled(",             # dropped result routed to handler
  ],
  # distinct type with borrowed operators + unit sugar + named-param reorder
  "23-units": @[
    "struct Milliseconds",              # distinct wrapper type
    "operator+",                        # borrowed arithmetic
    "operator==",                       # borrowed comparison
    "delay(ms(5))",                     # 5.ms postfix sugar + param match
  ],
  # actor message envelope must carry handler params
  "05-actors-effects": @[
    "enum CounterMsgKind",
    "msgIncrement",
    "int n;",                           # param rides in the envelope
    "handleMsg(",
    "let n = msg.n;",                   # dispatch rebinds params
    "sendIncrement(",
    "TUCK PENDING: fetchFeed",          # pending stub logs
  ],
  # payload sum type must not collapse to void
  "04-sum-types-interface": @[
    "enum PodcastPlayerLifecycleKind",
    "class PodcastPlayerLifecycle",
    "kind;",
  ],
  # transitions: predicate + checked assignment (Nim backend shape)
  "07-comments": @[
    "canTransition(",
    "transitionTo(",
  ],
  # packed decision table over enumerable domains
  "21-decision-bitmask": @[
    "packed decision key",
    "switch (",
  ],
  # enumerable columns emit a packed single-switch decision
  "09-decision-table": @[
    "enum Priority",
    "enum Action",
    "packed decision key",
  ],
  # invariants: validate emitted AND called at production sites
  "10-invariants": @[
    "void validate(",
    "Runtime.Assert(",
    "__validated(",                     # construction-site validation
  ],
  # registry: kind enum, carrier, latest global, raise procs
  "19-event-registry": @[
    "Kind",
    "latest",
    "raise_",
  ],
  # task with !T result wraps like a fn
  "14-task": @[
    "TuckResult<",
    "tok(",
  ],
  # qualified stdlib calls resolve through emitted module classes
  "24-stdlib": @[
    "fs.writeFile(",
    "fs.readFile(",
    "io.printLine(",
  ],
  # record-var payload explosion (p advance -> advance(p.position, p.step))
  "01-data-flow": @[
    "TUCK PENDING:",                    # pending block stubs exist
  ],
}.toTable

# Strings that must never appear in any emitted Beef file: each one is a
# known bad lowering from the pre-parity emitter.
const forbiddenEverywhere = [
  "!<",              # ! treated as a generic type ctor
  " u2 ",            # unmapped odd bit width
  " u12 ",
  " str ",           # unmapped str
  "typealias PodcastPlayerLifecycle = void",  # payload sum collapsed
  "Seq<",            # unmapped Seq
]

proc compileToBeef(path: string): tuple[base, code: string] =
  let baseName = extractFilename(path).changeFileExt("")
  var prog = loadProgram(path)
  injectImportedTypes(prog)
  var mods: seq[tuple[name, path: string, m: Module]]
  for lm in prog: mods.add((lm.name, lm.path, lm.m))
  for lm in prog:
    verifyModuleEffects(lm.m)
  discard typecheckProgram(mods)
  for lm in prog:
    lowerModule(lm.m)
  var realModules = initTable[string, Module]()
  for lm in prog[0 ..< prog.high]:
    realModules[lm.name] = lm.m
  # imported modules become sibling static classes in their own .bf files
  # (mod_ prefix: an example and a module may share a base name, e.g. http)
  for lm in prog[0 ..< prog.high]:
    writeFile(outDir / ("mod_" & lm.name & ".bf"),
              emitBeefModule(lm.name, lm.m, realModules))
  let code = emitBeef(prog[^1].m, realModules, baseName)
  writeFile(outDir / (baseName & ".bf"), code)
  (baseName, code)

# --- Layer 2: real Beef compilation of emitted output ---

proc findBeefBuild(): string =
  if existsEnv("BEEFBUILD_BIN") and fileExists(getEnv("BEEFBUILD_BIN")):
    return getEnv("BEEFBUILD_BIN")
  let candidates = ["/opt/beef/IDE/dist/BeefBuild", "/opt/beef/bin/BeefBuild"]
  for c in candidates:
    if fileExists(c): return c
  let (output, rc) = execCmdEx("which BeefBuild")
  if rc == 0: return output.strip()
  return ""

# Examples whose emitted Beef must compile cleanly. Extend as coverage grows.
const beefCheckExpected = [
  "22-error-policy",
  "23-units",
  "05-actors-effects",
  "07-comments",
  "10-invariants",
  "21-decision-bitmask",
  "19-event-registry",
  "14-task",
  "24-stdlib",
  "01-data-flow",
  "06-transitions-example",
  "08-actors_isolated_state",
  "13-arena-mem",
  "15-type-attributes",
  "02-builder-mutation",
  "04-sum-types-interface",
  "18-alias",
  "17-input-merge",
  "09-decision-table",
  "12-transition-the-ctor-exception",
]

proc beefCompileCheck(beefBuild, baseName: string, deps: seq[string]): bool =
  let projDir = outDir / "beefcheck" / baseName.replace("-", "_")
  removeDir(projDir)
  createDir(projDir / "src")
  copyFile(rtBeef, projDir / "src" / "TuckRt.bf")
  copyFile(outDir / (baseName & ".bf"), projDir / "src" / "Program.bf")
  for dep in deps:
    copyFile(outDir / ("mod_" & dep & ".bf"), projDir / "src" / ("mod_" & dep & ".bf"))
  writeFile(projDir / "BeefProj.toml", """
FileVersion = 1

[Project]
Name = "tuckcheck"
TargetType = "BeefConsoleApplication"
StartupObject = "TuckApp.Program"
""")
  writeFile(projDir / "BeefSpace.toml", """
FileVersion = 1
Projects = {tuckcheck = {Path = "."}}

[Workspace]
StartupProject = "tuckcheck"
""")
  let (output, rc) = execCmdEx(quoteShell(beefBuild) & " -workspace=" & quoteShell(projDir))
  if rc != 0:
    echo "  ---- BeefBuild output for ", baseName, " ----"
    for line in output.splitLines():
      if "ERROR" in line or "error" in line.toLowerAscii():
        echo "  ", line
  return rc == 0

when isMainModule:
  createDir(outDir)
  var failures = 0

  # Layer 1
  var emitted = initTable[string, string]()
  var depsOf = initTable[string, seq[string]]()
  for path in walkDir(exampleDir):
    if not path.path.endsWith(".tuck"): continue
    let baseName = extractFilename(path.path).changeFileExt("")
    # record deps (imported modules) for the compile check
    var prog = loadProgram(path.path)
    var deps: seq[string]
    for lm in prog[0 ..< prog.high]: deps.add(lm.name)
    depsOf[baseName] = deps
    let (base, code) = compileToBeef(path.path)
    emitted[base] = code

  for base, code in emitted:
    if base in expectSubstrings:
      for want in expectSubstrings[base]:
        if want notin code:
          echo "  FAIL expect: ", base, ".bf missing: ", want
          failures.inc
    for bad in forbiddenEverywhere:
      if bad in code:
        echo "  FAIL forbid: ", base, ".bf contains: ", bad
        failures.inc

  if failures == 0:
    echo "All Beef feature assertions passed (", emitted.len, " examples)."

  # Layer 2
  let beefBuild = findBeefBuild()
  if beefBuild == "":
    echo "SKIP Beef compile check: BeefBuild not found (set BEEFBUILD_BIN)."
  else:
    echo "Running BeefBuild compile check with: ", beefBuild
    for baseName in beefCheckExpected:
      if beefCompileCheck(beefBuild, baseName, depsOf.getOrDefault(baseName)):
        echo "  PASS beef build: ", baseName
      else:
        echo "  FAIL beef build: ", baseName
        failures.inc

  if failures > 0:
    echo failures, " failure(s)."
    quit(1)
