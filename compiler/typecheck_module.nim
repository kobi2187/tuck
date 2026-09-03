# compiler/typecheck_module.nim
#
# Module-level shape validation (duplicate decls/fields/members, shadowed
# top-level fns, stray top-level statements) and const-purity checking. Runs
# from typecheckModule's setup and cleanup, never from synthesizeKind's
# recursive dispatch — bindConsts/constCheck kick off tc.synthesize on a
# const's value, but that is a one-way call OUT to the exported proc, never
# a call back INTO this file from the dispatch itself.
#
# CONST PURITY: a `const` initialiser must be computable without running the
# program — no io, no calls that could. Small recursive walk, no coupling to
# synthesis.
import ast, tables, sets, strutils
import ast_query, lowering
import typecheck_state
import typecheck_util

proc constCheck*(tc: TypeChecker, m: Module, cname: string, e: Expr, sp: Span)
  ## Forward-declared: constCheckField/constCheckCall below recurse into it
  ## before its own definition.

proc declaredEffects*(tc: TypeChecker, fnName: string): seq[EffectMarker]
  ## Forward-declared: isIoFn below uses it ahead of its own definition
  ## (moved here from typecheck.nim's core, which still calls it — one-way,
  ## via this file's own re-export back through typecheck.nim's import).

proc isIoFn*(tc: TypeChecker, name: string): bool =
  ## Reads the signature table, so an imported [io] fn counts too.
  emIo in tc.declaredEffects(name)

proc constCheckField*(tc: TypeChecker, m: Module, cname: string, e: Expr,
                     sp: Span) =
  ## Unit sugar (5.ms) and field reads over const sub-expressions.
  if e.receiver == nil: return
  constCheck(tc, m, cname, e.receiver, sp)
  if e.receiver.kind == exkLit and tc.isIoFn(e.fieldName):
    fail("Const Error: 'const " & cname & "' must be pure — '" &
         e.fieldName & "' is [io]", sp)

proc constCheckCallee*(tc: TypeChecker, m: Module, cname, callee: string,
                      sp: Span) =
  ## What a const's call may name: a compile-time combinator, a distinct base
  ## conversion, or a declared pure fn.
  if callee in ["bake", "merge", "alias"]: return
  if tc.distinctNames.contains(callee): return  # base conversion
  if tc.typeDecls.hasKey(callee) and tc.typeDecls[callee].kind == tkRecord:
    fail("Const Error: 'const " & cname & "' cannot hold a record " &
         "construction (records are reference values) — use a plain struct " &
         "literal", sp)
  if tc.isIoFn(callee):
    fail("Const Error: 'const " & cname & "' must be pure — '" & callee &
         "' is [io]", sp)
  if m.findDecl(dkFn, callee) == nil and not tc.typeDecls.hasKey(callee):
    fail("Const Error: 'const " & cname & "' needs declared pure fns — '" &
         callee & "' is unknown", sp)

proc constCheckCall*(tc: TypeChecker, m: Module, cname: string, e: Expr,
                    sp: Span) =
  ## A call in a const: its arguments and, for a named callee, the callee
  ## itself. `{payload} Type.Variant` names a field — sum variants are value
  ## objects, which are fine.
  for a in e.args: constCheck(tc, m, cname, a, sp)
  if e.callee != nil and e.callee.kind == exkVar:
    constCheckCallee(tc, m, cname, e.callee.name, sp)

proc constCheck*(tc: TypeChecker, m: Module, cname: string, e: Expr, sp: Span) =
  ## Reject what a const cannot be. Nim-static semantics: arbitrary PURE
  ## computation, evaluated at compile time by the backend's const evaluator,
  ## so this forbids only what would break there — [io] calls, record-type
  ## constructions (records are reference values), and unknown callees.
  if e == nil: return
  case e.kind
  of exkLit, exkQualified: discard  # literals; :fn refs
  of exkStruct:
    for f in e.fields: constCheck(tc, m, cname, f.value, sp)
  of exkList:
    for it in e.items: constCheck(tc, m, cname, it, sp)
  of exkUnary: constCheck(tc, m, cname, e.operand, sp)
  of exkBinary:
    constCheck(tc, m, cname, e.left, sp)
    constCheck(tc, m, cname, e.right, sp)
  of exkField: constCheckField(tc, m, cname, e, sp)
  of exkCall: constCheckCall(tc, m, cname, e, sp)
  else:
    fail("Const Error: 'const " & cname & "' must be a pure " &
         "compile-time expression", sp)

proc newModuleChecker*(m: Module, externSigs: Table[string, FnSig],
                      externPending: Table[string, Span]): TypeChecker =
  ## A checker seeded with what this module's imports export.
  result = TypeChecker(module: m,
                       fnSigs: externSigs,
                       pendingFns: externPending,
                       typeDecls: initTable[string, Type](),
                       distinctNames: initHashSet[string](),
                       errPolicy: "strict")
  for qualName in externSigs.keys:
    if "::" in qualName:
      result.knownModules.incl(qualName.split("::")[0])


proc failIfFieldShadowsDeclaredFn*(tc: TypeChecker, m: Module) =
  ## Either/or namespace: a declared field name may not shadow a declared fn —
  ## `.name` resolves by lookup, so a clash would silently change meaning.
  for d in m.decls:
    if d == nil: continue
    for f in d.declaredFields():
      if tc.fnSigs.hasKey(f.name):
        fail("Type Error: field '" & f.name & "' of '" & d.name & "' has the " &
             "same name as a declared fn — rename one; fields and fns share " &
             "the call namespace", d.span)

proc declaredName*(d: Decl): string =
  ## The name a declaration introduces into the module's namespace, or "" for
  ## one that introduces none (an expression, an import, the errors block).
  case d.kind
  of dkFn, dkType, dkObject, dkActor, dkTask, dkConst, dkRegistry, dkPool,
     dkFnSig, dkInterface, dkRegister: d.name
  else: ""

proc failIfDuplicateDecl*(m: Module) =
  ## A name may be declared once per module.
  ##
  ## Without this a duplicate reached CODEGEN and emitted invalid target code
  ## — two `proc tuck_f*(): int` in one Nim module — so the user got an error
  ## about generated code they never wrote. Fns and types share one namespace
  ## because they share the call syntax: `{x: 1} F` cannot mean both
  ## "construct F" and "call F".
  var seen = initTable[string, Span]()
  for d in m.decls:
    if d == nil: continue
    let name = declaredName(d)
    if name == "": continue
    if seen.hasKey(name):
      fail("Structure Error: '" & name & "' is declared twice in this module" &
           " (first at line " & $seen[name].line & ") — every top-level name " &
           "is declared once; fns and types share one namespace because they " &
           "share the call syntax", d.span)
    seen[name] = d.span

proc failIfDuplicateMember*(what, owner: string, names: seq[(string, Span)]) =
  ## A field, variant or parameter name may appear once per declaration.
  var seen = initTable[string, Span]()
  for (name, span) in names:
    if seen.hasKey(name):
      fail("Structure Error: " & what & " '" & name & "' appears twice in '" &
           owner & "' (first at line " & $seen[name].line & ")", span)
    seen[name] = span

proc fieldNames*(fields: seq[FieldDef]): seq[(string, Span)] =
  for f in fields: result.add((f.name, f.span))

proc failIfComposedCollision*(owner: string, fields: seq[FieldDef], sp: Span) =
  ## Composition is SET UNION (spec 4.5), and a name contributed by two members
  ## is a compile error. No automatic resolution: the compiler does not pick a
  ## winner, shadow one, or invent a name. The user renames, or it does not
  ## compile.
  ##
  ## Accepted silently, both fields reached the same target object and the user
  ## got `Error: attempt to redefine: 'x'` naming generated code they never
  ## wrote — the failure class tests/suites/duplicates.nim exists to prevent.
  var seen = initTable[string, Span]()
  for f in fields:
    if seen.hasKey(f.name):
      fail(dcTyComposedCollision,
           "composed field '" & f.name & "' is contributed twice " &
           "to '" & owner & "' (first at line " & $seen[f.name].line &
           "). Rename one at the composition site: " &
           "`type C = A + B {oldName -> newName}` (spec 2.5)", sp)
    seen[f.name] = f.span

proc paramNames*(params: seq[Param]): seq[(string, Span)] =
  for p in params: result.add((p.name, p.span))

proc failIfDuplicateTypeMembers*(m: Module, d: Decl) =
  ## A type's own members, by the shape of its body: a union flattens to a field
  ## set, a record has one directly, a sum has variants.
  if d.typeBody == nil: return
  if d.typeBody.kind in {tkUnion, tkRename}:
    # `type C = A + B`, and the rename form that resolves a collision —
    # getFieldsForType flattens both, applying renames on the way
    failIfComposedCollision(d.name, getFieldsForType(m, d.typeBody), d.span)
  elif d.typeBody.kind == tkRecord:
    failIfDuplicateMember("field", d.name, fieldNames(d.typeBody.fields))
  elif d.typeBody.kind == tkSum:
    var vs: seq[(string, Span)]
    for v in d.typeBody.variants: vs.add((v.name, v.span))
    failIfDuplicateMember("variant", d.name, vs)

proc failIfDuplicateMembers*(m: Module) =
  ## The same rule one level down: inside a type, object, actor or fn.
  for d in m.decls:
    if d == nil: continue
    case d.kind
    of dkFn:
      failIfDuplicateMember("parameter", d.name, paramNames(d.fnParams))
    of dkTask:
      failIfDuplicateMember("parameter", d.name, paramNames(d.taskParams))
    of dkObject:
      failIfDuplicateMember("field", d.name, fieldNames(d.objFields))
      # `+ Record` members merge fields in, so the union is what must be unique
      failIfComposedCollision(d.name, composedFields(m, d), d.span)
    of dkActor:
      failIfDuplicateMember("field", d.name, fieldNames(d.actorFields))
    of dkType:
      failIfDuplicateTypeMembers(m, d)
    of dkRegistry, dkPool, dkMixin, dkExtern, dkPending, dkExpr, dkConst,
       dkRegister, dkStaticAssert, dkErrors, dkImport, dkInterface,
       dkSelect, dkFnSig, dkSatisfies:
      discard  # no field/param set of their own to check
    of dkWhen:
      discard  # never reaches here — resolveWhenBlocks runs before typecheck

proc failIfTopLevelStatement*(d: Decl) =
  ## Module top level is declarations only — the runnable program lives in
  ## `fn main`. (User ruling 2026-07-13: no top-level statements, not even
  ## pure lets; `tuck build` without main = library.)
  if d != nil and d.kind == dkExpr:
    fail("Structure Error: top-level statements are not allowed — move this " &
         "into `fn main` (a module is declarations; main is the program)",
         d.span)

proc reportUnhandled*(tc: TypeChecker, m: Module): seq[string] =
  ## Under `strict` a dropped fallible result is an error; the other policies
  ## hand the sites to codegen, which routes them to the handler.
  if tc.errPolicy == "strict" and tc.unhandledSites.len > 0:
    fail("Type Error: " & $tc.unhandledSites.len & " unhandled error result(s)" &
         " — bind, pass on, or propagate with '?' (policy: strict):\n  " &
         tc.unhandledSites.join("\n  "), m.span)
  if tc.errPolicy in ["continue", "exit"]: tc.unhandledSites else: @[]

proc declaredEffects*(tc: TypeChecker, fnName: string): seq[EffectMarker] =
  ## The effects declared on `fnName`, empty if it has none or is unknown.
  ## Reads the signature table rather than scanning declarations, so this
  ## answers for imported fns too — their effects ride in through the index.
  if tc.fnSigs.hasKey(fnName): tc.fnSigs[fnName].effects else: @[]
