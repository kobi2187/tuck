# compiler/call_args.nim
#
# THE ARGUMENTS A CALL IS PRINTED WITH — decided once, from the tree, and
# checked after every pass that can build a call.
#
# A payload call `{a: 1, b: 2} f` is printed positionally, `f(1, 2)`, in the
# callee's PARAMETER order. Two facts decide the list:
#   * which params the callee declares (`knownParams`), and
#   * which payload field feeds each: the checker's choice where it made one
#     (`argFieldsFor`, a by-type match), else the field of the param's name.
# A field the callee does not declare is the payload's own business, so
# `{a: 1, b: 2, c: 3} f` against `f({a})` is `f(1)`, and against a callee
# that declares nothing, `g()`.
#
# EVERY PARAM HAS A VALUE. Tuck has no default parameters, and the checker
# rejects a payload that lacks one. But the checker runs BEFORE lowering, and
# lowering builds and rewrites calls, so completeness is asserted again after
# it (`assertCallsComplete`, step 8 of backend_prepare) — and once more where
# the list is built. The backends used to fill a gap three ways — Nim `nil`,
# Odin the zero value `{}`, D a refusal — so one program meant three things.
#
# FROM THE TREE, NOT FROM THE PRINTED TEXT. The emitters passed their own
# spelling of the callee (a package prefix, a member's qualified name, a
# twin's) into the lookup, so whether a callee's params were found depended
# on how one backend printed it.
import options, tables
import ast, ast_ops, ast_query, resolution

proc knownParams*(res: Resolution, m: Module, real: Table[string, Module],
                  e: Expr): Option[seq[string]] =
  ## The params the callee declares, in order — or none when the compiler
  ## never resolved it: pending stubs, distinct-type constructors,
  ## combinators and runtime intrinsics, whose payload is printed as written
  ## (#22).
  ##
  ## NONE IS NOT EMPTY. A callee that takes no params is `some(@[])` and gets
  ## no arguments. The two used to be one empty list, which handed
  ## `{a: 1, b: 2} g` to a `g()` as `g(1, 2)` on every backend.
  if e.callee != nil and e.callee.kind == exkQualified and
     e.callee.modulePath.len > 0 and e.callee.modulePath[0] in real:
    let d = real[e.callee.modulePath[0]].findFn(e.callee.qualName)
    return if d == nil: none(seq[string]) else: some(d.paramNames())
  let recorded = res.knownCallParams(e)
  if recorded.isSome: return recorded
  # A MEMBER call is never looked up by its bare name: a top-level fn may
  # share it (#50), and `findFn` would answer with that one's params.
  if e.callee == nil or e.callee.kind != exkVar or
     memberCallee(res, m, e) != "":
    return none(seq[string])
  let d = m.findFn(e.callee.name)
  if d == nil: none(seq[string]) else: some(d.paramNames())

proc isPayloadCall*(e: Expr): bool =
  ## `{fields} f` — one argument, and it is a payload literal.
  e != nil and e.kind == exkCall and e.args.len == 1 and e.args[0] != nil and
    e.args[0].kind == exkStruct

proc fieldFor*(res: Resolution, e: Expr, i: int, param: string): string =
  ## The payload field that feeds param `i`.
  let chosen = res.argFieldsFor(e)
  if i < chosen.len and chosen[i].len > 0: chosen[i] else: param

proc fieldValue(payload: Expr, name: string): Expr =
  for f in payload.fields:
    if f.name == name: return f.value
  nil

proc calleeText(e: Expr): string =
  ## The callee as the source named it, for a message.
  if e.callee == nil: return "?"
  case e.callee.kind
  of exkVar: e.callee.name
  of exkQualified: e.callee.qualName
  else: "a " & $e.callee.kind

proc missingParam(res: Resolution, m: Module, real: Table[string, Module],
                  e: Expr): string =
  ## The first param this payload call has no value for, or "".
  let known = knownParams(res, m, real, e)
  if known.isNone: return ""
  for i, p in known.get:
    if fieldValue(e.args[0], fieldFor(res, e, i, p)) == nil: return p
  ""

proc incompleteMessage(e: Expr, param: string): string =
  "call_args: the call to " & calleeText(e) & " at line " & $e.span.line &
    " has no value for its parameter '" & param & "'. The checker rejects " &
    "such a call, so a pass after it built this one"

proc argsFor*(res: Resolution, e: Expr, params: seq[string]): seq[Expr] =
  ## A payload call's values for `params`, in order — asserted complete.
  ## `params` empty is a callee that takes none, so no arguments at all.
  for i, param in params:
    let v = fieldValue(e.args[0], fieldFor(res, e, i, param))
    doAssert v != nil, incompleteMessage(e, param)
    result.add v

proc payloadArgs*(res: Resolution, m: Module, real: Table[string, Module],
                  e: Expr): seq[Expr] =
  ## A payload call's arguments, in the callee's parameter order; with the
  ## callee unresolved, the payload's field values as written. What every
  ## backend prints, each in its own syntax.
  let known = knownParams(res, m, real, e)
  if known.isSome: return argsFor(res, e, known.get)
  for f in e.args[0].fields: result.add f.value

proc assertCallsComplete*(res: Resolution, m: Module,
                          real: Table[string, Module]) =
  ## After lowering: every payload call has a value for each param its
  ## callee declares. Visits the calls the checker STAMPED beside the tree
  ## (`res.call`) as well as the tree's own — the stamped one is what an
  ## emitter prints.
  for body in m.bodies:
    for n in body.nodes:
      for c in [n, (if res.hasCall(n): res.call(n) else: nil)]:
        if not c.isPayloadCall: continue
        let p = missingParam(res, m, real, c)
        doAssert p == "", incompleteMessage(c, p)
