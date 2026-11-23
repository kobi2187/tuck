# compiler/name_fold.nim
#
# TWO NAMES NIM WOULD READ AS ONE ARE REFUSED (M17/M12).
#
# Nim compares identifiers by their first character exactly and the rest
# ignoring case and `_`: `my_val` and `myVal` are one name, and so are
# `Foo_bar` and `FooBar`. The mangler keeps names of different KINDS apart
# (name_prefix.nim), but two fns, two types, two fields of one record, two
# params of one fn or two locals of one body keep the spelling the user
# wrote — and the Nim build failed with "redefinition" (or "implementation
# expected") while Odin and D, which compare names exactly, built and ran the
# same program.
#
# A program is either Tuck or not on every backend, so the rule is the
# language's, checked here before any backend sees the program: in one scope,
# two different spellings that fold to one Nim identifier are an error, and
# the author renames one. Ruled with the rest of the collisions: an explicit
# error, never a silent rename of what the user wrote.
#
# The scopes are the ones that reach a Nim identifier unchanged in kind:
# a module's top-level declarations of one kind, one record's fields, one
# fn's params, and one body's locals (its `let`/`var` bindings, loop
# variables and match bindings).
import tables, strutils
import ast, ast_ops, ast_query
import name_prefix
import diagnostics
import semantics   # inModule: an error names its own module's file
import typecheck_util
import resolution   # the generated names: poolHandleName, slabRefName, ...
import modules      # LoadedModule, importsOf

proc nimFolded*(name: string): string =
  ## The name as Nim compares it: the first character, then the rest in
  ## lower case without underscores.
  if name.len == 0: return name
  result = $name[0]
  for c in name[1 .. ^1]:
    if c != '_': result.add c.toLowerAscii

type FoldScope = object
  ## Names already seen in one scope, by their folded spelling.
  what: string
  seen: Table[string, string]

proc note(s: var FoldScope, name: string, span: Span) =
  ## Records `name`, failing when another spelling already folded to it.
  if name.len == 0 or "::" in name or '.' in name: return
  let key = nimFolded(name)
  let prior = s.seen.getOrDefault(key)
  if prior == "":
    s.seen[key] = name
  elif prior != name:
    fail(dcTyFoldedName, "'" & name & "' and '" & prior & "' are one name to " &
         "Nim (it ignores case and `_` after the first character), and both " &
         "are " & s.what & ". Fix: rename one", span)

proc checkFields(fields: seq[FieldDef], what: string) =
  ## One record's fields.
  var s = FoldScope(what: what)
  for f in fields: s.note(f.name, f.span)

proc checkTypeFields(t: Type) =
  ## A record type's fields, and each sum variant's payload fields.
  if t == nil: return
  case t.kind
  of tkRecord: checkFields(t.fields, "fields of one record")
  of tkSum:
    for v in t.variants: checkFields(v.fields, "fields of variant " & v.name)
  else: discard

proc noteBound(s: var FoldScope, p: Pattern) =
  ## The names a pattern binds.
  if p == nil: return
  case p.kind
  of pkVar, pkBind: s.note(p.name, p.span)
  of pkTuple:
    for el in p.elems: s.noteBound(el)
  of pkTypeTest: s.note(p.bindAs, p.span)
  else: discard

proc checkBody(d: Decl) =
  ## One fn's params, then the locals its body binds.
  var params = FoldScope(what: "params of " & d.name)
  for p in d.fnParams: params.note(p.name, p.span)
  var locals = FoldScope(what: "locals of " & d.name)
  if d.fnBody == nil: return
  for n in d.fnBody.nodes:
    case n.kind
    of exkAssign:
      if n.isDecl and n.target != nil and n.target.kind == exkVar:
        locals.note(n.target.name, n.target.span)
    of exkFor: locals.noteBound(n.iter)
    of exkMatch:
      for arm in n.arms: locals.noteBound(arm.pattern)
    else: discard

proc checkNameFolding*(m: Module) =
  ## Every scope of `m` (see the header).
  var tops: Table[NameKind, FoldScope]
  for d in m.decls:
    if d == nil or isImportedCopy(d) or d.kind notin {dkFn, dkTask, dkType,
       dkObject, dkActor, dkFnSig, dkInterface, dkConst, dkPool, dkSlab,
       dkArena, dkRegister, dkRegistry}: continue
    let k = declKind(d)
    tops.mgetOrPut(k, FoldScope(what: "top-level names of one kind")).note(d.name, d.span)
  for d in m.allDecls:
    if isImportedCopy(d): continue
    case d.kind
    of dkFn, dkTask: checkBody(d)
    of dkObject: checkFields(d.objFields, "fields of " & d.name)
    of dkActor: checkFields(d.actorFields, "fields of " & d.name)
    of dkType: checkTypeFields(d.typeBody)
    else: discard

proc checkModuleFolding*(mods: openArray[LoadedModule]) =
  ## The program's module names are one scope: each is a Nim module and an
  ## import alias (`tuckˑmodˑa_b`), so `a_b` and `ab` — or `a-b`, whose
  ## hyphen becomes `_` — were one ambiguous alias to Nim (M17). Reported at
  ## the import that brings the second spelling in.
  var seen: Table[string, string]
  for lm in mods:
    inModule(lm.path):
      for imp in lm.m.decls(dkImport):
        let key = nimFolded(imp.name.replace("-", "_"))
        let prior = seen.getOrDefault(key)
        if prior == "":
          seen[key] = imp.name
        elif prior != imp.name:
          fail(dcTyFoldedName, "modules '" & imp.name & "' and '" & prior &
               "' are one name to Nim (it ignores case and `_` after the first " &
               "character, and a module's `-` is spelled `_`). Fix: rename one " &
               "module's file", imp.span)

proc generatedTypeNames(m: Module): Table[string, string] =
  ## The type names the compiler makes for `m`'s own declarations, each with
  ## what made it: `<Pool>Handle`, `<Slab>Ref`, `<Arena>Ref`, `<Kind>Handle`.
  for d in m.decls:
    if d == nil or isImportedCopy(d): continue
    case d.kind
    of dkPool: result[poolHandleName(d.name)] = "pool " & d.name
    of dkSlab: result[slabRefName(d.name)] = "slab " & d.name
    of dkArena: result[arenaRefName(d.name)] = "arena " & d.name
    of dkResources:
      for k in d.resKinds: result[resourceHandleName(k.name)] = "resource kind " & k.name
    else: discard

proc checkGeneratedNames*(prog: openArray[LoadedModule]) =
  ## A type the user declares under a name the compiler makes for a pool, a
  ## slab, an arena or a resource kind it can see — `type SessionsHandle`
  ## beside `pool Sessions` — was silently replaced by the generated one, so
  ## `{mine: 3} SessionsHandle` built the pool's handle (M23). Refused: the
  ## author renames the type.
  var made: Table[string, Table[string, string]]
  for lm in prog: made[lm.name] = generatedTypeNames(lm.m)
  for lm in prog:
    inModule(lm.path):
      var visible = made[lm.name]
      for imp in importsOf(lm.m):
        for k, v in made.getOrDefault(imp): visible[k] = v
      if visible.len == 0: continue
      for d in lm.m.decls:
        if d == nil or isImportedCopy(d) or
           d.kind notin {dkType, dkObject, dkInterface, dkFnSig, dkActor}: continue
        if d.name in visible:
          fail(dcTyGeneratedName, "'" & d.name & "' is the type the compiler " &
               "makes for " & visible[d.name] & ", so this declaration and that " &
               "type would be one name. Fix: rename this one", d.span)
