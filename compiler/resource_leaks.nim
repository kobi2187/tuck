# compiler/resource_leaks.nim
#
# A RESOURCE THAT IS NEVER RELEASED, found at build time (spec §7.4's
# acquire-must-finish, the conservative half).
#
# Declaring a resource kind is about releasing it properly. The runtime already
# says so at exit: OPEN RESOURCES lists every handle nobody finished. This pass
# says the same thing at the line that loses it, before the program runs, and
# asks nothing new of the author — it reads `acquire`, `finish` and the handle
# types they already wrote.
#
# The rule is deliberately narrow, so it never fires on code that does handle
# its resource: a local holding a handle (from `acquire`, or from a call that
# returns one) whose ONLY use in the fn is testing `.ok`. Any other use — a
# `finish`, in a `defer` or not, a `return`, passing it to a call, storing it
# — counts as handling it, because the handle went somewhere a person decided.
# What is left is the shape of a forgotten release: acquire, check, walk away.
#
# A warning, as OPEN RESOURCES is a report and not an error: a program may
# hold a handle until exit on purpose. Only the module being built is checked,
# like the size report: a dependency's leak is its author's to fix.
import ast, ast_ops, resolution, diagnostics

proc handleKind(t: Type, kinds: seq[string]): string =
  ## The kind whose handle `t` is — bare or `?`-wrapped — or "".
  var t = t
  if t != nil and t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
     t.base.name in ["?", "!?"] and t.args.len == 1:
    t = t.args[0]
  if t == nil or t.kind != tkNamed: return ""
  for k in kinds:
    if resourceHandleName(k) == t.name: return k

proc boundHandle(n: Expr, kinds: seq[string]): string =
  ## The kind of the handle a `let`/`var` binds, or "".
  if n.kind != exkAssign or not n.isDecl or n.target == nil or
     n.target.kind != exkVar or n.assignVal == nil: return ""
  if n.assignVal.kind == exkAcquire: return n.assignVal.acquireKind
  handleKind(semLayer.typeFor(n.assignVal), kinds)

proc onlyTested(body: Expr, name: string, binding: Expr): bool =
  ## Is every mention of `name` in `body` the receiver of `.ok`?
  var tested: seq[Expr]
  for n in body.nodes:
    if n.kind == exkField and n.fieldName == "ok" and n.receiver != nil and
       n.receiver.kind == exkVar and n.receiver.name == name:
      tested.add n.receiver
  for n in body.nodes:
    if n.kind == exkVar and n.name == name and n != binding and n notin tested:
      return false
  true

proc checkBody(owner: string, body: Expr, kinds: seq[string]) =
  for n in body.nodes:
    let kind = boundHandle(n, kinds)
    if kind == "" or not onlyTested(body, n.target.name, n.target): continue
    let v = n.target.name
    warn(dcRsUnfinished, "'" & v & "' holds a " & kind & " handle that '" &
         owner & "' never finishes and never hands on, so it stays open " &
         "until exit, where OPEN RESOURCES reports it. Fix: `finish " & v &
         ".value, " & kind & "` once it is done with — in a `defer:` right " &
         "after the `if " & v & ".ok:` guard, so every path releases it",
         n.span.line, n.span.col)

proc warnUnfinishedHandles*(m: Module, kinds: seq[string]) =
  ## Every fn and task body of `m`, members included.
  if kinds.len == 0: return
  for d in m.allDecls:
    if d != nil and d.kind in {dkFn, dkTask} and d.fnBody != nil and
       d.origin == NoModule:
      checkBody(d.name, d.fnBody, kinds)
