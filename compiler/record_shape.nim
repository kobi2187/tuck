# compiler/record_shape.nim
#
# What a record COMBINATOR produces, decided once, for every backend.
#
# `bake` / `with` / `alias` / `merge` all answer the same three questions —
# which fields does the result have and in what order, where does each field's
# value come from, and what constructor does the value go through — and then
# each backend spells the answer in its own syntax:
#
#     Nim    (a: 1, b: x.b)          or  tuck_Task(a: 1, b: x.b)
#     Odin   TRec_a_b_643C{a = 1, b = x.b}
#     D      TRec_a_b_2128(a: 1, b: x.b)
#
# Until this module the DECISIONS were written out three times too, in twelve
# near-identical procs (genBake/genOdinBake/genDBake, and so on). They drifted
# exactly as you would expect: `<uninit>[T]` has to be erased at each backend's
# type boundary, and only the Nim one did it — Odin emitted
# `op: <uninit>(tuck_BinOp)` and D refused the type application outright. One
# rule, three chances to forget it, two forgotten. 17 of the last 41 codegen
# commits had to touch two or three backends at once.
#
# So the shape is a VALUE, not text. A backend reads it and renders; it makes
# no decisions of its own beyond how a constructor call and a field access are
# spelled in its target. Nothing here knows what any target looks like — the
# test for belonging in this module is the same one codegen_common states:
# a QUERY about the tree belongs here, an EMITTER does not.

import ast, ast_query, lowering, codegen_common, resolution

type
  ValueSrc* = enum
    vsExpr      ## emit this expression as the field's value
    vsProject   ## emit a receiver, then read one of its fields

  ShapeField* = object
    ## One field of the RESULT. `name` is the name it has in the result,
    ## which `alias` makes differ from the name it is read from.
    name*: string
    case src*: ValueSrc
    of vsExpr:
      value*: Expr
    of vsProject:
      fromExpr*: Expr
      fromField*: string

  CtorKind* = enum
    ckNamedType    ## rebuild through the receiver's own declared type
    ckStructural   ## an anonymous shape: a Nim tuple, or a synthesized struct
    ckPassThrough  ## nothing to build — emit the receiver unchanged

  RecordShape* = object
    fields*: seq[ShapeField]
    ctor*: CtorKind
    typeName*: string           ## ckNamedType — the declared type's name
    namedType*: Type            ## ckNamedType — carries a generic instantiation
    declFields*: seq[FieldDef]  ## ckStructural — names the synthesized struct
    invariantsOwed*: bool       ## a production site: validate before it flows on
    passThrough*: Expr          ## ckPassThrough — the expression to emit
    receivers*: seq[Expr]       ## every receiver read more than once, in order;
                                ## a backend that binds temps binds these

proc project(name: string, recv: Expr, field: string): ShapeField =
  ShapeField(name: name, src: vsProject, fromExpr: recv, fromField: field)

proc overrideWith(name: string, value: Expr): ShapeField =
  ShapeField(name: name, src: vsExpr, value: value)

proc overrideFor(payload: Expr, fname: string): Expr =
  ## The payload's value for `fname`, or nil when it does not name it.
  if payload == nil: return nil
  for (name, valExpr) in payload.fields.items:
    if name == fname: return valExpr
  nil

proc passThrough(e: Expr): RecordShape =
  RecordShape(ctor: ckPassThrough, passThrough: e)

proc structuralFields(m: Module, res: Resolution, recvT: Type, payload: Expr,
                      names: seq[string]): seq[FieldDef] =
  ## The declared field list a synthesized struct is named after. Known
  ## receiver fields first, then anything the payload supplies that the
  ## receiver has not got — which only happens for a SKETCH receiver, since
  ## the checker rejects a widening bake or with (TK-TY21).
  result = getFieldsForType(res, m, recvT)
  for n in names:
    var known = false
    for f in result:
      if f.name == n: known = true
    if known: continue
    var ft = inferLitType(overrideFor(payload, n))
    if ft == nil: raise newException(ValueError, "record shape field has no type")
    result.add FieldDef(name: n, typ: ft)

proc updateShape*(m: Module, res: Resolution, e: Expr,
                  preserveType: bool): RecordShape =
  ## `recv with {…}` and `recv bake {…}` — the same shape. Both replace the
  ## values of fields the receiver already declares (widening is `merge`'s
  ## job), so they differ in exactly one thing, and it is this flag: `with`
  ## rebuilds through the receiver's own type because its result must still BE
  ## that type, and `bake` does not. Spelled as a parameter rather than as two
  ## implementations so the difference is one word, and so making bake preserve
  ## its type too — now that it provably cannot widen — is a one-word change
  ## rather than a second rewrite.
  let recvT = res.typeFor(e.combRecv)
  var names = recordFieldNames(res, m, recvT)
  let named = preserveType and names.len > 0 and recvT.kind == tkNamed and
              isRecordType(m, recvT.name)
  if names.len == 0:                 # sketch receiver: the payload is all
    for (name, _) in e.combArg.fields.items: names.add(name)
  if names.len == 0: return passThrough(e.combRecv)

  for fname in names:
    let ov = overrideFor(e.combArg, fname)
    result.fields.add(if ov != nil: overrideWith(fname, ov)
                      else: project(fname, e.combRecv, fname))
  result.receivers = @[e.combRecv]
  if named:
    result.ctor = ckNamedType
    result.typeName = recvT.name
    result.namedType = recvT
    result.invariantsOwed = hasInvariants(m, recvT.name)
  else:
    result.ctor = ckStructural
    result.declFields = structuralFields(m, res, recvT, e.combArg, names)

proc aliasShape*(m: Module, res: Resolution, e: Expr): RecordShape =
  ## `recv alias(old: new, …)` — the same values under renamed fields. The
  ## result is always a new shape, so never the receiver's own type.
  let recvT = res.typeFor(e.combRecv)
  let recvFields = getFieldsForType(res, m, recvT)
  for (oldName, newExpr) in e.combArg.fields.items:
    if newExpr == nil or newExpr.kind != exkVar: return passThrough(e.combRecv)
    var ft: Type = nil
    for rf in recvFields:
      if rf.name == oldName: ft = rf.typ
    if ft == nil: return passThrough(e.combRecv)
    result.fields.add project(newExpr.name, e.combRecv, oldName)
    result.declFields.add FieldDef(name: newExpr.name, typ: ft, span: e.span)
  result.ctor = ckStructural
  result.receivers = @[e.combRecv]

proc mergeShape*(m: Module, res: Resolution, e: Expr): RecordShape =
  ## `{a, b} merge` — the union of the members' fields, flattened. Collisions
  ## are the checker's problem; by here the names are known distinct.
  for (_, mexpr) in e.combRecv.fields.items:
    let mt = res.typeFor(mexpr)
    for f in getFieldsForType(res, m, mt):
      result.fields.add project(f.name, mexpr, f.name)
      result.declFields.add f
    result.receivers.add mexpr
  if result.fields.len == 0: return passThrough(e.combRecv)  # sketch members
  result.ctor = ckStructural

proc shapeOf*(m: Module, res: Resolution, e: Expr): RecordShape =
  ## The one entry point. Exhaustive on CombKind, so a new combinator stops
  ## the build here rather than silently producing nothing.
  case e.comb
  of ckWith:  updateShape(m, res, e, preserveType = true)
  of ckBake:  updateShape(m, res, e, preserveType = false)
  of ckAlias: aliasShape(m, res, e)
  of ckMerge: mergeShape(m, res, e)
