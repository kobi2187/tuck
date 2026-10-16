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


# --- the same facts as a Tuck module (`--tuck`) ------------------------------
#
# Flat tables, one row type each: a typed `const` cannot type a `Seq` nested
# inside a record, and a flat table is also what a consumer filters anyway.
# A field row's `owner` is the type, or `Type.Variant` for a payload field; a
# param row's `owner` is the fn.

const TuckPrelude = """type DescType:
  name: str
  kind: str
  invariants: bool

type DescVariant:
  owner: str
  name: str

type DescField:
  owner: str
  name: str
  typ: str

type DescFn:
  name: str
  returns: str
  effects: str
  generic: bool

type DescParam:
  owner: str
  name: str
  typ: str
"""

proc q(s: string): string = "\"" & s.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc table(name, rowType: string, rows: seq[string]): string =
  result = "const " & name & ": Seq[" & rowType & "] = ["
  if rows.len > 0: result.add "\n  " & rows.join(",\n  ") & "\n"
  result.add "]\n"

type Rows = object
  types, variants, fields, fns, params: seq[string]

proc fieldRow(r: var Rows, owner: string, f: FieldDef) =
  r.fields.add "{owner: " & q(owner) & ", name: " & q(f.name) & ", typ: " &
               q(typeText(f.typ)) & "}"

proc typeRows(r: var Rows, m: Module, d: Decl) =
  let b = d.typeBody
  if b == nil: return
  let kind = case b.kind
             of tkRecord: "record"
             of tkSum: "sum"
             else: "alias"
  r.types.add "{name: " & q(d.name) & ", kind: " & q(kind) & ", invariants: " &
              $hasInvariants(m, d.name) & "}"
  if b.kind == tkRecord:
    for f in b.fields: r.fieldRow(d.name, f)
  elif b.kind == tkSum:
    for v in b.variants:
      r.variants.add "{owner: " & q(d.name) & ", name: " & q(v.name) & "}"
      for f in v.fields: r.fieldRow(d.name & "." & v.name, f)

proc fnRows(r: var Rows, d: Decl) =
  var es: seq[string]
  for e in d.fnEffects: es.add effectName(e)
  let ret = if d.fnReturnType != nil: typeText(d.fnReturnType) else: ""
  r.fns.add "{name: " & q(d.name) & ", returns: " & q(ret) & ", effects: " &
            q(es.join(", ")) & ", generic: " & $(d.fnGenerics.len > 0) & "}"
  for p in d.fnParams:
    r.params.add "{owner: " & q(d.name) & ", name: " & q(p.name) & ", typ: " &
                 q(typeText(p.typ)) & "}"

proc describeTuck*(m: Module): string =
  ## The module's types and fns as a Tuck module: row types, then one typed
  ## const table per kind of fact. A tool written in Tuck imports it.
  var r: Rows
  for d in m.decls:
    if d == nil: continue
    if d.kind == dkType: r.typeRows(m, d)
    elif d.kind == dkFn and d.fnBody != nil: r.fnRows(d)
  TuckPrelude & "\n" & table("descTypes", "DescType", r.types) & "\n" &
    table("descVariants", "DescVariant", r.variants) & "\n" &
    table("descFields", "DescField", r.fields) & "\n" &
    table("descFns", "DescFn", r.fns) & "\n" &
    table("descParams", "DescParam", r.params)
