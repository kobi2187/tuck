# compiler/codegen_d_emit.nim
#
# Whole-module orchestration for the D backend: walk a module's decls by
# kind, calling genDDecl on each, then stitch together imports/link flags/
# entry point into one D source file. The public entry points
# (`emitD`/`emitDModule`) sit above genDDecl/genDExpr in the import order,
# same shape as codegen_emit.nim / codegen_odin_emit.nim.
import ast, strutils, tables, sets
import resolution
import ast_query
import codegen_common
import codegen_d_ctx
from mangle import mangleName
import ./codegen_d_decl
import ./codegen_d

proc emitDBody*(ctx: var DCodegenCtx, m: Module): tuple[body, mains: string] =
  var body = ""
  var mainStmts: seq[string]
  for d in m.decls:
    if d != nil and d.kind == dkExpr:
      let oldIndent = ctx.indent
      ctx.indent = 1
      let stmtCode = ctx.genDStmt(d.expr)
      ctx.indent = oldIndent
      if stmtCode != "": mainStmts.add(stmtCode)
    else:
      let code = ctx.genDDecl(d)
      if code != "": body.add(code & "\n")
  (body, mainStmts.join(""))

proc dModuleName*(base: string): string =
  ## A D module name must be a valid identifier; example files are named
  ## like `01-data-flow`. Hyphens become underscores and a leading digit
  ## gets a prefix — the FILE keeps its own name (only imported modules
  ## need name==file, and those are mod_<name> which never start digital).
  result = dAlias(base)
  if result.len > 0 and result[0] in {'0' .. '9'}: result = "_" & result

proc usesSymbol*(code, sym: string): bool =
  ## Does the emitted text call or qualify `sym`? Both spellings, because a
  ## symbol may be invoked (`writeln(x)`) or reached through (`stderr.x`).
  (sym & "(") in code or (sym & ".") in code

proc mainDeclD*(m: Module): Decl =
  let tuckMain = mangleName("main")
  for d in m.decls:
    if d != nil and d.kind == dkFn and d.name == tuckMain and not d.isPending:
      return d
  nil

proc dBootSequence*(m: Module, hasTasks: bool): string =
  ## What runs BEFORE main: the scheduler, then every actor as a daemon.
  ## An actor is a singleton service alive for the whole program, not
  ## something main spawns — but one with no messages has no drain to start
  ## (actorHasMessages), so it is skipped here exactly as it is skipped in
  ## genDActor.
  var daemons: seq[string]
  for d in m.decls:
    if d != nil and d.kind == dkActor and actorHasMessages(d):
      daemons.add("    rt.tuckStartActor(&drain_" & d.name & ");\n")
  if not hasTasks and daemons.len == 0: return ""
  "    rt.tuckAsyncInit();\n" & daemons.join("")

proc dImports*(ctx: DCodegenCtx, body, mains: string,
              inModuleDir = false): seq[string] =
  ## Only import what the emitted code references — same policy as the Odin
  ## backend (and D warns on unused imports under -w).
  let code = body & mains
  # The entry point always calls rt.tuckSetArgs, so an entry module always
  # needs the runtime; a library module only if its own body reached for it.
  if usesSymbol(code, "rt") or not inModuleDir:
    result.add("import rt = tuck_rt;")
  # C libraries bound by an extern block. `pragma(lib, "z")` is a SYSTEM
  # library — dmd turns it into -lz. An object file is not: dmd would emit
  # `-lcffi/point.o` and the linker would hunt for a library by that name
  # (verified). Objects go on the dmd command line instead, which the driver
  # builds — see tuck.nim's --dlang build step.
  for lib in ctx.cLibs:
    if not (lib.endsWith(".o") or lib.endsWith(".a") or "/" in lib):
      result.add("pragma(lib, \"" & lib & "\");")
  var stdioSyms: seq[string]
  for sym in ["writeln", "stderr"]:
    if usesSymbol(code, sym): stdioSyms.add(sym)
  if stdioSyms.len > 0:
    result.add("import std.stdio : " & stdioSyms.join(", ") & ";")
  for modName in ctx.realModules.keys:
    let alias = dAlias(modName)
    if usesSymbol(code, alias):
      result.add("import " & alias & " = mod_" & alias & ";")
  # `impl: d "..."` modules — a bare module name, unlike Nim's/Odin's own
  # relative-path imports, so tuck.nim's build step resolves it with an
  # extra dmd `-I` rather than anything rebased or copied here.
  for alias in ctx.implMods.keys:
    if usesSymbol(code, alias):
      result.add("import " & alias & ";")

proc genDEntryPoint*(ctx: DCodegenCtx, m: Module, mains: string): string =
  ## Tuck's `fn main` is a plain fn; D's entry point calls it. A
  ## value-returning `fn main` IS the process exit code — D's `int main`
  ## says exactly that natively (the Nim backend needs quit(), Odin
  ## os.exit(); this is the identical-construct rule paying off).
  var hasTasks = false
  for d in m.decls:
    if d != nil and d.kind == dkTask: hasTasks = true
  let mainFn = mainDeclD(m)
  if mainFn == nil and mains == "": return ""
  let tuckMain = mangleName("main")
  # The command line reaches std/sys through the runtime, which cannot read
  # it for itself in D (no global argv the way Nim's os module has one), so
  # the entry point hands it over. Emitted always: whether a program calls
  # argCount is not knowable from the entry point alone, and the call is
  # one assignment.
  let seedArgs = "    rt.tuckSetArgs(args);\n"
  # A program with tasks boots the scheduler before main and drives it
  # after, so anything main spawned and did not await still runs to
  # completion. Mirrors tuck.nim's Nim entry and the Odin one.
  let boot = dBootSequence(m, hasTasks)
  # Drive the loop only when TASKS exist. Actors are daemons whose drain
  # loops never finish, so running the scheduler for them after main would
  # spin forever — main owns the lifecycle and ends the program itself.
  let drive = if hasTasks: "    rt.tuckRun();\n" else: ""
  let head = "(string[] args) {\n" & seedArgs & boot & mains
  if mainFn != nil and mainFn.returnsValue:
    # The exit code is main's result, but tasks still get to finish first.
    result = "int main" & head &
             "    auto mainRc = " & tuckMain & "();\n" & drive &
             "    return cast(int) mainRc;\n}\n"
  elif mainFn != nil:
    result = "void main" & head & "    " & tuckMain & "();\n" & drive & "}\n"
  else:
    result = "void main" & head & drive & "}\n"

proc emitDModule*(name: string, m: Module,
                  realModules = initTable[string, Module]()): string =
  ## A library module (import target): file mod_<name>.d, module mod_<name>.
  ## The import alias at the use site keeps the Tuck name, so calls read
  ## `console.printLine` — and the mod_ prefix keeps a Tuck module called
  ## `std` or `core` from colliding with D's own top-level packages.
  let alias = dAlias(name)
  var ctx = newDCtx(m, realModules, name, modPrefix = alias & "_")
  let (body, _) = ctx.emitDBody(m)
  result = "module mod_" & alias & ";\n\n"
  let imports = ctx.dImports(body, "", inModuleDir = true)
  if imports.len > 0:
    result.add(imports.join("\n") & "\n\n")
  for h in ctx.hoisted:
    result.add(h & "\n\n")
  result.add(body)

proc emitD*(m: Module, realModules = initTable[string, Module](),
            moduleName = "main"): string =
  ## The entry module: declarations, then D's own `main` calling tuck_main.
  var ctx = newDCtx(m, realModules, moduleName)
  let (body, mains) = ctx.emitDBody(m)
  result = "module " & dModuleName(moduleName) & ";\n\n"
  let imports = ctx.dImports(body, mains)
  if imports.len > 0:
    result.add(imports.join("\n") & "\n\n")
  for h in ctx.hoisted:
    result.add(h & "\n\n")
  result.add(body)
  result.add(ctx.genDEntryPoint(m, mains))
