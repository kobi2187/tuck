# compiler/type_identity.nim
#
# TWO MODULES MAY DECLARE A TYPE OF ONE NAME (A88, ruled 2026-10-22).
#
# Every later stage knows a type by its NAME: the checker's tables, the
# mangler's, `moduleDeclaringType`, every backend's emitted identifier. So two
# `type Entry` declarations in one program used to be one type to all of them:
# an importer of both got whichever copy was injected first, and read the other
# module's values against the wrong fields.
#
# This pass gives each such type a name of its own before anything else looks:
# `Entry` declared by module `cli` becomes `cli::Entry`, everywhere it is meant —
# its declaration, the references inside `cli`, and the references in every
# module that sees it, written bare (one import provides it) or qualified
# (`cli::Entry`). A bare name that two imports both provide is ambiguous, and
# is refused where it is written (TK-TY47): the user qualifies it. The mangler
# spells `cli::Entry` as an identifier of its own (`tuckˑtypeˑcliˑEntry`), so
# nothing downstream has to learn a second way of naming a type.
#
# Only names that DO collide are touched: a program in which every type name is
# declared once is left exactly as it was written.
import tables, sets, strutils
import ast, ast_ops, ast_query, modules, typecheck_util, diagnostics, semantics

type View = object
  ## What a bare type name means in one module.
  owner: string          ## the module it resolves to; "" when none or ambiguous
  owners: seq[string]    ## every import providing it, when ambiguous

proc collidingTypeNames(prog: seq[LoadedModule]): HashSet[string] =
  ## The type names more than one module declares.
  var seen = initTable[string, string]()
  for lm in prog:
    for d in lm.m.decls:
      if d == nil or d.kind != dkType or d.origin != NoModule: continue
      if d.name in seen and seen[d.name] != lm.name: result.incl d.name
      else: seen[d.name] = lm.name

proc declaresType(lm: LoadedModule, name: string): bool =
  for d in lm.m.decls:
    if d != nil and d.kind == dkType and d.origin == NoModule and d.name == name:
      return true

proc providesType(lm: LoadedModule, name: string): bool =
  ## Does `lm` declare `name` and let an importer see it?
  if not lm.declaresType(name): return false
  let (restricted, allowed) = exportedNames(lm.m)
  not restricted or name in allowed

proc viewOf(lm: LoadedModule, byName: Table[string, LoadedModule],
            name: string): View =
  if lm.declaresType(name): return View(owner: lm.name)
  for imp in importsOf(lm.m):
    if imp in byName and byName[imp].providesType(name):
      result.owners.add imp
  if result.owners.len == 1: result.owner = result.owners[0]

proc failAmbiguous(lm: LoadedModule, name: string, owners: seq[string], sp: Span) =
  ## TK-TY47, reported against the module where the bare name is written.
  var shown: seq[string]
  for o in owners: shown.add "`" & o & "::" & name & "`"
  try:
    fail(dcTyAmbiguousType, "'" & name & "' is a type of " & owners.join(" and ") &
         ", both imported here, and nothing says which. Fix: qualify it, " &
         shown.join(" or "), sp)
  except SemanticError as err:
    err.msg = lm.path & ":" & $err.line & ":" & $err.col & ": " & err.msg
    raise err

proc qualifyType(lm: LoadedModule, byName: Table[string, LoadedModule],
                 names: HashSet[string], t: Type) =
  ## Every colliding name under `t` becomes the qualified name it means.
  if t == nil: return
  for c in t.children: qualifyType(lm, byName, names, c)
  if t.kind != tkNamed or t.name notin names: return
  if t.qualifier.len > 0:
    # Written `mod::Name`: that module's type, if it really provides it;
    # otherwise the checker's own qualified-name check says why not.
    let q = t.qualifier[^1]
    if q == lm.name and lm.declaresType(t.name) or
       q in byName and q in importsOf(lm.m) and byName[q].providesType(t.name):
      t.name = q & "::" & t.name
      t.qualifier = @[]
    return
  let v = viewOf(lm, byName, t.name)
  if v.owner != "": t.name = v.owner & "::" & t.name
  elif v.owners.len > 1: failAmbiguous(lm, t.name, v.owners, t.span)

proc qualifiedRef(lm: LoadedModule, byName: Table[string, LoadedModule],
                  names: HashSet[string], e: Expr): Expr =
  ## A type name in an expression — a construction's callee or the receiver of
  ## `Type.Variant` — made the qualified name it means: a bare name is renamed
  ## in place; a written `mod::Name` comes back as the node to put in its
  ## place (nil otherwise).
  if e == nil: return nil
  if e.kind == exkQualified and e.modulePath.len == 1 and e.qualName in names:
    let q = e.modulePath[0]
    if q == lm.name and lm.declaresType(e.qualName) or
       q in byName and q in importsOf(lm.m) and byName[q].providesType(e.qualName):
      # It takes the qualified node's place, and its id with it.
      return Expr(id: e.id, span: e.span, kind: exkVar, name: q & "::" & e.qualName)
    return nil
  if e.kind != exkVar or e.name notin names: return nil
  let v = viewOf(lm, byName, e.name)
  if v.owner != "": e.name = v.owner & "::" & e.name
  elif v.owners.len > 1: failAmbiguous(lm, e.name, v.owners, e.span)
  nil

proc qualifyExprs(lm: LoadedModule, byName: Table[string, LoadedModule],
                  names: HashSet[string], body: Expr) =
  ## The places an expression names a type: a callee, a receiver, and the
  ## types a binding, a cast and a send state.
  for n in body.nodes:
    if n.kind == exkCall:
      let q = qualifiedRef(lm, byName, names, n.callee)
      if q != nil: n.callee = q
    elif n.kind == exkField:
      let q = qualifiedRef(lm, byName, names, n.receiver)
      if q != nil: n.receiver = q
    elif n.kind == exkAssign: qualifyType(lm, byName, names, n.declType)
    elif n.kind == exkCast: qualifyType(lm, byName, names, n.castType)
    elif n.kind == exkSend:
      for t in n.sendActorArgs: qualifyType(lm, byName, names, t)

proc qualifyReferences(lm: LoadedModule, byName: Table[string, LoadedModule],
                       names: HashSet[string]) =
  ## Every type reference in `lm`, in its declarations and its bodies.
  for d in lm.m.allDecls:
    for t in d.ownTypes: qualifyType(lm, byName, names, t)
  for body in lm.m.bodies: qualifyExprs(lm, byName, names, body)

proc qualifyDeclarations(lm: LoadedModule, names: HashSet[string]) =
  ## `lm`'s own declarations of a colliding name, and the `public:` entries
  ## that export them.
  for d in lm.m.decls:
    if d != nil and d.kind == dkType and d.origin == NoModule and d.name in names:
      d.name = lm.name & "::" & d.name
  for d in lm.m.decls(dkPublic):
    for n in d.publicNames.mitems:
      if n in names and lm.declaresType(lm.name & "::" & n):
        n = lm.name & "::" & n

proc qualifyCollidingTypes*(prog: var seq[LoadedModule]) =
  ## Run on the loaded program, before imported types are injected.
  let names = collidingTypeNames(prog)
  if names.len == 0: return
  var byName = initTable[string, LoadedModule]()
  for lm in prog: byName[lm.name] = lm
  for lm in prog: qualifyReferences(lm, byName, names)
  # The declarations last: every reference above was resolved by the names
  # as written.
  for lm in prog: qualifyDeclarations(lm, names)
