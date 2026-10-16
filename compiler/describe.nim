# compiler/describe.nim
#
# `tuck describe file.tuck`: the declarations of one module as plain INI-style
# text, for tools written outside the compiler (a property tester, a doc
# generator). Tuck has no reflection and gives its users none; this is the
# compiler binary answering "what fields does this type have?" for a tool.
#
#   [type Span]
#   kind = record
#   invariants = yes
#   field = lo: int
#
#   [fn spanOf]
#   returns = Span
#   effects = io
#   param = a: int
import ast, ast_ops, ast_query, proptest
import std/strutils

proc fieldLine(f: FieldDef): string = f.name & ": " & typeText(f.typ)

proc describeType(m: Module, d: Decl): string =
  let b = d.typeBody
  if b == nil: return ""
  result = "[type " & d.name & "]\n"
  case b.kind
  of tkRecord:
    result.add "kind = record\n"
    for f in b.fields: result.add "field = " & fieldLine(f) & "\n"
  of tkSum:
    result.add "kind = sum\n"
    for v in b.variants:
      var ps: seq[string]
      for f in v.fields: ps.add fieldLine(f)
      result.add "variant = " & v.name &
                 (if ps.len > 0: "(" & ps.join(", ") & ")" else: "") & "\n"
  else:
    result.add "kind = alias\ntarget = " & typeText(b) & "\n"
  if hasInvariants(m, d.name): result.add "invariants = yes\n"

proc describeFn(d: Decl): string =
  result = "[fn " & d.name & "]\n"
  if d.fnReturnType != nil: result.add "returns = " & typeText(d.fnReturnType) & "\n"
  if d.fnGenerics.len > 0: result.add "generic = yes\n"
  var es: seq[string]
  for e in d.fnEffects: es.add effectName(e)
  if es.len > 0: result.add "effects = " & es.join(", ") & "\n"
  for p in d.fnParams: result.add "param = " & p.name & ": " & typeText(p.typ) & "\n"

proc describeModule*(m: Module): string =
  ## Every top-level type and fn, one INI section each, blank-line separated.
  var parts: seq[string]
  for d in m.decls:
    if d == nil: continue
    if d.kind == dkType: parts.add describeType(m, d)
    elif d.kind == dkFn and d.fnBody != nil: parts.add describeFn(d)
  parts.join("\n")
