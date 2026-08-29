# compiler/typecheck_conformance.nim
#
# Interface conformance (spec §5.2).
#
# `satisfies I` is a promise; this is where it is kept. An object must
# implement every fn the interface requires, with matching parameters and
# return type, and may declare FEWER effects but never more.
#
# Why this lifts out of typecheck.nim: conformance compares two DECLARED
# signatures against each other. It never synthesizes an expression type, so
# it never calls back into the synth core — the same rule typecheck_flow.nim
# follows. It took a `tc` parameter in typecheck.nim to match its sibling
# checkers' shape and never read it; the parameter is dropped here rather than
# carried along dead, exactly as typecheck_transitions.nim did.
import ast, ast_query, tables, strutils
import typecheck_util

proc sameType(a, b: Type): bool

proc sameTypes(a, b: seq[Type]): bool =
  ## Pairwise, same length — the shape four of sameType's arms share.
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if not sameType(a[i], b[i]): return false
  true

proc sameFields(a, b: seq[FieldDef]): bool =
  ## Pairwise by name AND type, in order. A record's field ORDER is part of
  ## its identity here: two records with the same fields in a different order
  ## are not the same type.
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i].name != b[i].name or not sameType(a[i].typ, b[i].typ): return false
  true

proc sameType(a, b: Type): bool =
  ## Structural equality — deliberately NOT `compatible`, which is lenient by
  ## design (Unknown, void, unit and Self match everything, so a conformance
  ## check built on it would accept an impl returning void where the contract
  ## says !str).
  if a == nil or b == nil: return a == nil and b == nil
  if a.kind != b.kind: return false
  case a.kind
  of tkNamed: a.name == b.name
  of tkApp:  sameType(a.base, b.base) and sameTypes(a.args, b.args)
  of tkTuple: sameTypes(a.elems, b.elems)
  of tkRecord: sameFields(a.fields, b.fields)
  of tkFunc: sameTypes(a.params, b.params) and sameType(a.result, b.result)
  else: typeName(a) == typeName(b)

proc substSelf(t: Type, objName: string): Type =
  ## `Self` in a required signature means the implementing type.
  if t == nil: return nil
  if t.kind == tkNamed and t.name == "Self":
    return Type(span: t.span, kind: tkNamed, name: objName)
  if t.kind == tkApp:
    var args: seq[Type]
    for a in t.args: args.add(substSelf(a, objName))
    return Type(span: t.span, kind: tkApp, base: substSelf(t.base, objName),
                args: args)
  t

proc effectName(e: EffectMarker): string =
  ## `emIo` reads as "io" in a diagnostic.
  ($e)[2 .. ^1].toLowerAscii

proc sigText(d: Decl): string =
  ## One line naming a signature, for both halves of a mismatch report.
  var ps: seq[string]
  for p in d.fnParams: ps.add(p.name & ": " & typeName(p.typ))
  var effs: seq[string]
  for e in d.fnEffects: effs.add(effectName(e))
  result = "fn " & d.name & "({" & ps.join(", ") & "})"
  if d.fnReturnType != nil: result.add(" -> " & typeName(d.fnReturnType))
  if effs.len > 0: result.add(" [" & effs.join(", ") & "]")

proc failConformance(objName, iname: string, want, got: Decl, why: string) =
  fail("Conformance Error: object '" & objName & "' does not satisfy '" &
       iname & "'\n  contract   " & sigText(want) &
       "\n  implements " & sigText(got) & "\n  " & why, got.span)

proc checkParamMatch(want, got: Decl, objName, iname: string) =
  ## Parameters match by count, by NAME, and by type. The name is part of the
  ## contract because payload fields bind by name.
  if want.fnParams.len != got.fnParams.len:
    failConformance(objName, iname, want, got,
      "takes " & $got.fnParams.len & " parameter(s), the contract declares " &
      $want.fnParams.len)
  for i in 0 ..< want.fnParams.len:
    let w = want.fnParams[i]
    let g = got.fnParams[i]
    if w.name != g.name:
      failConformance(objName, iname, want, got,
        "parameter " & $(i + 1) & " is named '" & g.name &
        "', the contract calls it '" & w.name &
        "' (payload fields bind by name, so the name is part of the contract)")
    if not sameType(substSelf(w.typ, objName), g.typ):
      failConformance(objName, iname, want, got,
        "parameter '" & w.name & "' is " & typeName(g.typ) &
        ", the contract declares " & typeName(substSelf(w.typ, objName)))

proc checkEffectSubset(want, got: Decl, objName, iname: string) =
  ## Effects may be a SUBSET: an implementation may do less than the contract
  ## permits, never more. Same direction as the caller/callee effect budget.
  for e in got.fnEffects:
    if e notin want.fnEffects:
      failConformance(objName, iname, want, got,
        "declares effect [" & effectName(e) &
        "], which the contract does not permit (an implementation may do " &
        "LESS than the contract allows, never more)")

proc checkSigMatch(want, got: Decl, objName, iname: string) =
  ## One required signature against the member that implements it.
  checkParamMatch(want, got, objName, iname)
  if not sameType(substSelf(want.fnReturnType, objName), got.fnReturnType):
    failConformance(objName, iname, want, got,
      "returns " & typeName(got.fnReturnType) & ", the contract declares " &
      typeName(substSelf(want.fnReturnType, objName)))
  checkEffectSubset(want, got, objName, iname)

proc whyNotAnObject(m: Module, name: string): string =
  ## Why this name cannot carry a contract — the half of the message that
  ## ends the search.
  ##
  ## The old message said only "not a declared object in scope", which fits a
  ## TYPO and nothing else: a reader who wrote `satisfies int: Hashable`
  ## deliberately goes looking for a declaration they never omitted. What the
  ## author needs is which of the four cases they are in, and the way forward
  ## for that case. Classifying by what the name IS costs no new table — the
  ## module already holds every declaration.
  for d in m.decls:
    if d == nil or d.name != name: continue
    case d.kind
    of dkInterface:
      return "'" & name & "' is an interface. A contract is attached to the " &
             "object that IMPLEMENTS it, not to another contract."
    of dkType:
      return "'" & name & "' is a `type`, which declares data but no " &
             "members, so there is nothing for the contract to check. " &
             "Fix: declare it as an `object` instead."
    of dkActor:
      return "'" & name & "' is an actor. Actors are reached through their " &
             "mailbox, never through interface dispatch."
    else: discard
  # Undeclared. Primitives are the lowercase closed set and never declared;
  # anything else at this point is a name that was never brought into scope.
  if name.len > 0 and name[0] in {'a'..'z'}:
    return "'" & name & "' is a primitive. Primitives have no declaration to " &
           "record the promise on. Fix: wrap it in an object with '" & name &
           "' as a field, or take a `fnsig` slot instead of a contract."
  return "'" & name & "' is not declared in this module. Fix: check the " &
         "spelling, or import the module that declares it."

proc applySatisfiesDecls(m: Module) =
  ## Fold every top-level `Obj satisfies Iface` into that object's own
  ## `satisfies` list, BEFORE conformance runs.
  ##
  ## Doing it here rather than teaching each later pass about dkSatisfies is
  ## the whole point: conformance checking, interface wrapping and both
  ## backends' satisfiersOf all read `dkObject.satisfies`, so after this merge
  ## an attached contract is indistinguishable from a declared one — which is
  ## exactly the intent. Attaching widens WHERE a promise may be stated, never
  ## what the promise means.
  ##
  ## Re-stating a contract the object already declares is a NO-OP, not an
  ## error: a calling module cannot be expected to know what the library
  ## already promised, and demanding it check would defeat the feature.
  var objs = initTable[string, Decl]()
  for d in m.decls:
    if d != nil and d.kind == dkObject: objs[d.name] = d
  for d in m.decls:
    if d == nil or d.kind != dkSatisfies: continue
    if d.name notin objs:
      # No "Conformance Error:" prefix here — `withCode` supplies the category
      # word. The uncoded sites in this file still write their own.
      fail(dcCoNotAnObject,
           "`" & d.name & " satisfies ...` needs an object, and " &
           whyNotAnObject(m, d.name), d.span)
    let obj = objs[d.name]
    for iname in d.satisfyTargets:
      if iname notin obj.satisfies:
        obj.satisfies.add(iname)

proc implementationOf(obj: Decl, want: Decl): Decl =
  ## The member that implements a required fn. A body-less member is a
  ## signature, not an implementation — there would be no code to run.
  for have in obj.members():
    if have.kind == dkFn and have.name == want.name and have.fnBody != nil:
      return have
  nil

proc checkSatisfiesIface(obj: Decl, iface: Decl, iname: string) =
  ## Every fn the interface requires must be implemented, and match.
  for want in iface.ifaceMembers:
    if want == nil or want.kind != dkFn: continue
    let got = implementationOf(obj, want)
    if got == nil:
      fail("Conformance Error: object '" & obj.name & "' satisfies '" &
           iname & "' but does not implement\n    " & sigText(want) &
           "\n  (add it as a member fn, or drop the `satisfies " & iname &
           "` line)", obj.span)
    checkSigMatch(want, got, obj.name, iname)

proc checkConformance*(m: Module) =
  ## Every `satisfies I` on an object is verified against interface I —
  ## whether the object declared it or a later module attached it.
  applySatisfiesDecls(m)
  var ifaces = initTable[string, Decl]()
  for d in m.decls:
    if d != nil and d.kind == dkInterface: ifaces[d.name] = d
  for d in m.decls:
    if d == nil or d.kind != dkObject or d.satisfies.len == 0: continue
    for iname in d.satisfies:
      if iname notin ifaces:
        fail("Conformance Error: object '" & d.name & "' satisfies '" & iname &
             "' but no interface by that name is declared", d.span)
      checkSatisfiesIface(d, ifaces[iname], iname)
