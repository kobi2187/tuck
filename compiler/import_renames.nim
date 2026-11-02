# compiler/import_renames.nim
#
# RENAMING AT THE IMPORT: `import iter {find -> iterFind}`.
#
# Tuck has no overloading (ruled 2026-08-24), so two imports that both export
# `find` collide, and a call must say which. The ruling of 2026-10-27: write
# it qualified (`iter::find`), or rename it where it comes in. This pass is
# the rename: in the importing module every use of `iterFind` — a call
# (`{...} iterFind`, `{} iterFind`) or a `:iterFind` fn reference — becomes
# `iter::find`, the qualified spelling every later stage already resolves
# (`ast_ops.callKey`, `ast_query.calleeDecl`). Nothing downstream learns that
# renames exist. A bare `iterFind` with no `{}` is not rewritten: a local may
# share the name.
#
# The spelling is Tuck's one rename form, `{old -> new}`, as composition and
# `satisfies` write it. Fns only, for now: a type that collides is qualified
# (`mod::Type`, A88), and renaming one is refused with that advice.
import tables, sets
import ast, ast_ops, ast_query, modules

type RenameError* = object of ValueError
  ## A rename that cannot mean anything, with its source position.
  line*, col*: int

proc refuse(path, msg: string, sp: Span) =
  var e = newException(RenameError, path & ":" & $sp.line & ":" & $sp.col &
                       ": Import Error: " & msg)
  e.line = sp.line
  e.col = sp.col
  raise e

proc exportedFn(m: Module, name: string): bool =
  let (restricted, allowed) = exportedNames(m)
  if restricted and name notin allowed: return false
  for d in m.decls:
    if d != nil and d.kind == dkFn and d.name == name and d.origin == NoModule:
      return true
  for d in m.decls(dkExtern):
    for mem in d.mixinMembers:
      if mem != nil and mem.kind == dkFn and mem.name == name: return true

proc exportedType(m: Module, name: string): bool =
  for d in m.decls:
    if d != nil and d.kind in {dkType, dkObject, dkInterface, dkActor} and
       d.name == name and d.origin == NoModule:
      return true

proc declares(m: Module, name: string): bool =
  for d in m.decls:
    if d != nil and d.origin == NoModule and d.kind != dkImport and d.name == name:
      return true

proc renamesOf(lm: LoadedModule, byName: Table[string, LoadedModule]):
               Table[string, tuple[module, name: string]] =
  ## `new -> (module, old)` for every rename `lm`'s imports declare, checked.
  for imp in lm.m.decls(dkImport):
    for (old, renamed) in imp.importRenames:
      let known = imp.name in byName
      let target = byName.getOrDefault(imp.name)
      if not known or not target.m.exportedFn(old):
        if known and target.m.exportedType(old):
          refuse(lm.path, "'" & old & "' is a type of " & imp.name & "; a type is not " &
                 "renamed at the import. Fix: write it qualified, `" &
                 imp.name & "::" & old & "`", imp.span)
        refuse(lm.path, "module '" & imp.name & "' exports no fn '" & old &
               "' to rename", imp.span)
      if lm.m.declares(renamed) or renamed in result:
        refuse(lm.path, "'" & renamed & "' is already a name in this module; the " &
               "rename would hide it. Fix: choose another name", imp.span)
      result[renamed] = (imp.name, old)

proc qualified(n: Expr, to: tuple[module, name: string]): Expr =
  Expr(id: n.id, span: n.span, kind: exkQualified, modulePath: @[to.module],
       qualName: to.name)

proc rewriteBody(body: Expr, renames: Table[string, tuple[module, name: string]]) =
  ## A call or a fn reference naming a renamed fn names the original instead.
  for n in body.nodes:
    if n.kind == exkCall and n.callee != nil and n.callee.kind == exkVar and
       n.callee.name in renames:
      n.callee = qualified(n.callee, renames[n.callee.name])
    elif n.kind == exkQualified and n.modulePath.len == 0 and
         n.qualName in renames:
      # `:iterFind` — a fn named as a value
      let to = renames[n.qualName]
      n.modulePath = @[to.module]
      n.qualName = to.name

proc applyImportRenames*(prog: var seq[LoadedModule]) =
  ## Run on the loaded program, before anything resolves a name.
  var byName = initTable[string, LoadedModule]()
  for lm in prog: byName[lm.name] = lm
  for lm in prog.mitems:
    let renames = renamesOf(lm, byName)
    if renames.len == 0: continue
    for body in lm.m.bodies: rewriteBody(body, renames)
