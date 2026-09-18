# compiler/codegen_odin_emit.nim
#
# Whole-module orchestration for the Odin backend: walk a module's decls by
# kind, calling genOdinDecl on each, then stitch together imports/link
# flags/entry point into one Odin source file. The public entry points
# (`emitOdin`/`emitOdinModule`) sit above genOdinDecl/genOdinExpr in the
# import order, same shape as codegen_emit.nim for the Nim backend.
import ast, strutils, tables, options
import resolution
import ast_query
import codegen_common
import codegen_odin_ctx
import codegen_odin_util

# Odin refuses a compound literal for a `[dynamic]T` unless the file opts in:
# "Compound literals of dynamic types are disabled by default". Tuck's `Seq[T]`
# IS `[dynamic]T`, so `{items: [3, 4]} Bag` — a Seq literal in any record
# field — did not compile on this backend at all. The corpus never caught it
# because no example builds a Seq inside a record. The directive must lead the
# file, before `package`.
const odinFeatures = "#+feature dynamic-literals\n"

from mangle import mangleName
import ./codegen_odin_decl
import ./codegen_odin

proc emitBody*(ctx: var OdinCodegenCtx, m: Module): tuple[types, mains: string] =
  var body = ""
  var mainStmts: seq[string]
  for d in m.decls:
    if d != nil and d.kind == dkExpr:
      let oldIndent = ctx.indent
      ctx.indent = 2
      var stmtCode = ctx.genOdinExpr(d.expr)
      ctx.indent = oldIndent
      if stmtCode != "":
        if d.expr != nil and d.expr.kind in {exkIf, exkFor, exkWhile, exkBlock}:
          mainStmts.add(stmtCode)
        else:
          mainStmts.add("        " & stmtCode & ";")
    else:
      let code = ctx.genOdinDecl(d)
      if code != "":
        body.add(code & "\n")
  (body, mainStmts.join("\n"))

proc mainDecl*(m: Module): Decl =
  ## The program's entry fn, if it has one.
  let tuckMain = mangleName("main")
  for d in m.decls:
    if d != nil and d.kind == dkFn and d.name == tuckMain and not d.isPending:
      return d
  nil

proc runtimeUsers*(m: Module, actorNames: var seq[string],
                  hasTasks: var bool) =
  ## Which declarations make the program need the scheduler.
  for d in m.decls:
    if d == nil: continue
    # actorHasMessages, not `is an actor`: one with no handlers has no drain
    # to start, exactly as genOdinActor declines to emit one (#61).
    if d.kind == dkActor and actorHasMessages(d): actorNames.add(d.name)
    elif d.kind == dkTask: hasTasks = true

proc emitOdinModule*(name: string, m: Module, res: Resolution,
                     realModules = initTable[string, Module]()): string =
  let pkg = name.replace("-", "_")
  var ctx = newOdinCtx(m, realModules, name, res, modPrefix = pkg & "_")
  let (body, _) = ctx.emitBody(m)
  # Odin package names are GLOBAL, not scoped to their directory, so a Tuck
  # module called `io` or `os` would collide with core:io / core:os. The
  # emitted package carries a tuck_ prefix; the import alias at the use site
  # keeps the Tuck name, so qualified calls still read as `io.printLine`.
  var res = odinFeatures & "package tuck_" & pkg & "\n\n"
  # This file lives in mod_<pkg>/, so siblings are one level up.
  var imports: seq[string]
  if "fmt." in body: imports.add("import \"core:fmt\"")
  if "rt." in body: imports.add("import rt \"../tuckrt\"")
  for modName in realModules.keys:
    let dep = modName.replace("-", "_")
    if dep != pkg and (dep & ".") in body:
      imports.add("import " & dep & " \"../mod_" & dep & "\"")
  # C libraries bound by extern blocks. `foreign import` is only legal at
  # package top level, so the emitter collects the names during emitBody and
  # declares them here — this is what makes the binding link.
  for alias, spec in ctx.foreignLibs:
    imports.add("foreign import " & alias & " \"" & odinLibSpec(spec) & "\"")
  # `impl: odin "..."` packages — the forwarders emitted above call <alias>.<fn>
  for alias, spec in ctx.implMods:
    imports.add("import " & alias & " \"" & spec & "\"")
  if imports.len > 0:
    res.add(imports.join("\n") & "\n\n")
  for h in ctx.hoisted:
    res.add(h & "\n\n")
  res.add(body)
  res

proc shouldImportFmt(body, mains: string): bool =
  ## Check if fmt import is needed.
  "fmt." in body or "fmt." in mains

proc shouldImportOs(m: Module, body: string): bool =
  ## Check if os import is needed.
  let mainFn = mainDecl(m)
  (mainFn != nil and mainFn.returnsValue) or "os." in body

proc shouldImportRt(m: Module, body, mains: string): bool =
  ## Check if runtime import is needed.
  var actorNames: seq[string]
  var hasTasks = false
  runtimeUsers(m, actorNames, hasTasks)
  actorNames.len > 0 or hasTasks or "rt." in body or "rt." in mains

proc odinImports*(ctx: OdinCodegenCtx, m: Module, body, mains: string,
                 realModules: Table[string, Module]): seq[string] =
  ## Only import what the emitted body actually uses — Odin rejects unused
  ## imports, so an unconditional header would fail to compile on any program
  ## that happens not to touch the runtime.
  ##
  ## The runtime boot emits rt.* calls of its own, so the decision reads the
  ## DECLARATIONS too, not just the already-emitted body.
  if shouldImportFmt(body, mains):
    result.add("import \"core:fmt\"")
  if shouldImportOs(m, body):
    result.add("import \"core:os\"")
  if shouldImportRt(m, body, mains):
    result.add("import rt \"./tuckrt\"")
  # Imported Tuck modules are sibling packages (mod_<name>/), referenced
  # qualified as `<name>.fn` — import each one the body actually calls. The
  # alias keeps the Tuck name even when it shadows an Odin core package (a
  # module called `io` is fine as long as core:io isn't also imported).
  for modName in realModules.keys:
    let pkg = modName.replace("-", "_")
    if (pkg & ".") in body or (pkg & ".") in mains:
      result.add("import " & pkg & " \"./mod_" & pkg & "\"")
  # C libraries bound by extern blocks — see emitOdinModule for why these are
  # hoisted here rather than emitted beside the `foreign` block.
  for alias, spec in ctx.foreignLibs:
    result.add("foreign import " & alias & " \"" & odinLibSpec(spec) & "\"")
  # `impl: odin "..."` packages — the forwarders emitted call <alias>.<fn>
  for alias, spec in ctx.implMods:
    result.add("import " & alias & " \"" & spec & "\"")

proc genEntryPoint*(ctx: OdinCodegenCtx, m: Module, mains: string): string =
  ## Tuck's `fn main` is a plain proc; Odin's entry point calls it. Static
  ## asserts fold into the same entry (Odin has #assert for compile-time, but
  ## these are runtime-checked in the Beef path too).
  ##
  ## Runtime boot mirrors the Nim entry (tuck.nim): init the scheduler and
  ## reactor, start every actor's drain coroutine, run main, then drive the
  ## loop so spawned tasks and actors get to finish.
  result = "main :: proc() {\n"
  for a in ctx.staticAsserts:
    result.add("\tassert(" & a & ")\n")
  var actorNames: seq[string]
  var hasTasks = false
  runtimeUsers(m, actorNames, hasTasks)
  if actorNames.len > 0 or hasTasks:
    result.add("\trt.tuckAsyncInit()\n")
    # The slot is KEPT: `Actor.waitUntil` names the actor at the call site, so
    # the emitted call needs a handle to hand the predicate to.
    for a in actorNames:
      result.add("\t" & actorSlotName(a) & " = rt.tuckStartActor(drain_" &
                 a & ")\n")
  if mains != "": result.add(mains & "\n")
  # A value-returning `fn main` IS the process exit code (mirrors tuck.nim).
  let mainFn = mainDecl(m)
  let mainReturns = mainFn != nil and mainFn.returnsValue
  if mainFn != nil:
    let tuckMain = mangleName("main")
    result.add(if mainReturns: "\tmainRc := " & tuckMain & "()\n"
               else: "\t" & tuckMain & "()\n")
  # Drive the loop only when TASKS exist. Actors are daemons whose drain loops
  # never finish, so running the scheduler for them would spin forever —
  # tuck.nim gates on hasTasks for exactly this reason.
  if hasTasks: result.add("\trt.tuckRun()\n")
  # Wait for every actor to empty its mailbox before exiting: an actor thread
  # is detached, so without this a `send` races the process teardown.
  if actorNames.len > 0: result.add("\trt.tuckDrainActors()\n")
  # §7.4's close-all, AFTER the loop is driven so anything a task acquired is
  # still registered when the tables close, and BEFORE os.exit — which is
  # `_exit` and runs no finalizer, so an `@(fini)` hook would never fire. The
  # entry point already owns the lifecycle (it boots the scheduler); this is
  # the other end of it.
  if declaresResources(m): result.add("\t" & ResourceShutdownProc & "()\n")
  if mainReturns: result.add("\tos.exit(mainRc)\n")
  result.add("}\n")

# Odin errors on unused imports, so the header is assembled from what the
# body actually referenced rather than emitted wholesale.
const odinPackage = odinFeatures & "package main\n\n"

proc emitOdin*(m: Module, res: Resolution,
               realModules = initTable[string, Module](),
               moduleName = "main"): string =
  ## `res` is the semantic layer typechecking produced. Taking it as an
  ## argument is the point: this stage cannot run before the one that fills
  ## it, and now the signature says so instead of a comment on checkOrDie.
  var ctx = newOdinCtx(m, realModules, moduleName, res)
  let (body, mains) = ctx.emitBody(m)
  result = odinPackage
  let imports = ctx.odinImports(m, body, mains, realModules)
  if imports.len > 0:
    result.add(imports.join("\n") & "\n\n")
  for h in ctx.hoisted:
    result.add(h & "\n\n")
  result.add(body)
  result.add(ctx.genEntryPoint(m, mains))
