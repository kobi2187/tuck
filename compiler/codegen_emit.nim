# compiler/codegen_emit.nim
#
# Whole-module orchestration for the Nim backend: walk a module's decls by
# kind, calling genDecl on each, then stitch together imports/link flags/
# entry point into one Nim source file. The public entry point
# (`emitNim`) — imported by tuck.nim, not codegen.nim, since genDecl (and
# transitively genExpr) has to sit BELOW this in the import order.
import ast, strutils, tables
import resolution
import ast_query
import codegen_common
import codegen_ctx
import ./codegen_decl

proc genDeclsOfKind*(ctx: var CodegenCtx, m: Module, kinds: set[DeclKind]): string =
  for d in m.decls:
    if d == nil or d.kind notin kinds: continue
    let code = ctx.genDecl(d)
    if code != "": result.add(code & "\n")

proc genDeclsExcept*(ctx: var CodegenCtx, m: Module, kinds: set[DeclKind]): string =
  for d in m.decls:
    if d == nil or d.kind in kinds: continue
    let code = ctx.genDecl(d)
    if code != "": result.add(code & "\n")

proc genRtExport*(m: Module): string =
  ## rt-implemented extern fns: importers reach them as <module>.<fn>, so the
  ## module re-exports the runtime that actually defines them. tuck_rt is the
  ## single facade — it re-exports tuck_async, so async externs (waitUntil,
  ## openSource, ...) resolve through this one export.
  for mem in m.externFns():
    if mem.externHeader == "": return "export tuck_rt\n"
  ""

proc genImplImports*(m: Module): string =
  ## `impl: nim "..."` — a header-less extern whose bodies live somewhere
  ## other than tuck_rt. Imported AND re-exported for the same reason tuck_rt
  ## is: importers reach these fns as <module>.<fn>. This is what lets the
  ## stdlib grow without editing the compiler's own runtime.
  ##
  ## Nim exports by MODULE NAME, not by path: `export std/strutils` is a
  ## syntax error, `export strutils` is what re-exports it.
  var seen: seq[string]
  for mem in m.externFns():
    if mem.externHeader != "": continue
    for (backend, module) in mem.externImpl:
      if backend != "nim" or module in seen: continue
      seen.add(module)
      result.add("import " & module & "\nexport " &
                 module.rsplit('/', 1)[^1] & "\n")

proc linkPragma*(lib: string): string =
  ## Vendored C source uses {.compile.}, which places the object WITH the rest
  ## so it links regardless of order — a static .a through {.passL.} does NOT
  ## work, because Nim emits passL flags ahead of the object files and an
  ## archive only contributes members resolving already-pending symbols.
  ## A path links verbatim; a bare name gets -l.
  if lib.endsWith(".c"): "{.compile: \"" & lib & "\".}\n"
  elif '/' in lib or lib.endsWith(".a") or lib.endsWith(".so"):
    "{.passL: \"" & lib & "\".}\n"
  else: "{.passL: \"-l" & lib & "\".}\n"

proc genModuleImports*(m: Module, realModules: Table[string, Module]): string =
  for d in m.decls:
    if d != nil and d.kind == dkImport and d.name in realModules:
      result.add("import " & d.name & "\n")

proc genOrderedDecls*(ctx: var CodegenCtx, m: Module): string =
  ## Nim needs decl-before-use; Tuck is order-independent. So: type
  ## declarations first, then everything else in source order — object type
  ## headers land in ctx.typeSection during that pass and join the type block.
  ##
  ## Interfaces come LAST in the type block: an interface variant names the
  ## object types it wraps, and those headers only reach typeSection during
  ## the body pass.
  var typePart = ctx.genDeclsOfKind(m, {dkType, dkFnSig})
  let body = ctx.genDeclsExcept(m, {dkType, dkFnSig, dkInterface})
  for ts in ctx.typeSection:
    typePart.add(ts & "\n\n")
  typePart.add(ctx.genDeclsOfKind(m, {dkInterface}))
  typePart & body

proc genLinkFlags*(m: Module): string =
  ## C-extern link flags. `{.passL.}` is a module pragma, so linking is
  ## settled in the emitted source — the driver needs no per-library plumbing.
  var seen: seq[string]
  for mem in m.externFns():
    let lib = mem.externLib
    if lib == "" or lib in seen: continue
    seen.add(lib)
    result.add(linkPragma(lib))

proc emitNim*(m: Module, rtImport = "../compiler/tuck_rt",
              realModules = initTable[string, Module](),
              moduleName = "main"): string =
  var ctx = newCodegenCtx(m, realModules, moduleName)
  let body = ctx.genOrderedDecls(m)
  # Nim resolves mutual type references only within ONE `type` block, and each
  # emit site writes its own — so `type A = {b: Seq[B]}` + `type B = {a: Seq[A]}`
  # (finite and legal, Seq is a handle) failed with `undeclared identifier`.
  # Odin and D resolve module-wide and never had this.
  # ponytail: one pragma instead of merging 11 emit sites into a single block;
  # do that if codeReordering ever bites.
  result = "{.experimental: \"codeReordering\".}\n"
  result.add("import " & rtImport & "\n")
  result.add(genRtExport(m))
  result.add(genImplImports(m))
  result.add(genLinkFlags(m))
  result.add(genModuleImports(m, realModules))
  result.add("\n")
  for h in ctx.hoisted:
    result.add(h & "\n")
  if ctx.hoisted.len > 0: result.add("\n")
  result.add(body)
