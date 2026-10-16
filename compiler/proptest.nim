# compiler/proptest.nim
#
# `tuck test file.tuck --properties` (issue #68). The user has usually written
# both halves of a property test already, for other reasons:
#
#   - an EFFECT-FREE fn is safe to call with arbitrary input: deterministic,
#     in-process, nothing to set up or mock;
#   - a return type's `invariant:` block is the property, and it is already
#     compiled into a validator that runs when a value of that type is built.
#
# So the test is: pick the fns with no capability effects that return a type
# carrying an invariant, call each with generated arguments, and let the
# invariant fire. This module finds the targets, generates the argument
# values and writes the harness program; the driver in tuck.nim builds it,
# runs it case by case and writes the report.
#
# Argument values are generated FREELY. A parameter type's own invariant is
# not used to choose them: if a generated value breaks it, constructing the
# value fails, which is the program's own bug being found, as it should be.
import ast, ast_ops, ast_query
import std/[strutils, random, sets]

type
  Target* = object
    name*: string
    params*: seq[tuple[name: string, typ: Type]]
    returns*: string

  Value = object
    expr: string      ## what the call passes: a literal, or a `let` name
    display: string   ## the same value written out in full, for the report

  Gen = object
    m: Module
    r: Rand
    edges: bool       ## this case leans on edge values
    pre: seq[string]  ## `let` lines the case needs before the call
    n: int            ## counter for the let names

const IntDomains = [
  # name, lowest, highest generated. A signed type starts one above its true
  # minimum: the literal `-128` does not fit i8 (the minus is applied after).
  ("int", -2000, 2000), ("i64", -2000, 2000), ("i32", -2000, 2000),
  ("i16", -32767, 32767), ("i8", -127, 127),
  ("u8", 0, 255), ("u16", 0, 65535), ("u32", 0, 2000), ("u64", 0, 2000)]

const Strings = ["", "a", "ab", "0", "-1", "hello world", "x,y,z", "CamelCase",
                 "  padded  ", "ünï"]

proc intDomain(typ: string): tuple[ok: bool, lo, hi: int] =
  for (n, lo, hi) in IntDomains:
    if n == typ: return (true, lo, hi)

proc isFloat(typ: string): bool = typ in ["f64", "f32"]

proc wrapperArg(t: Type, wrapper: string): Type =
  ## `T` of `T?` / `Seq[T]`, or nil when `t` is not that wrapper.
  if t != nil and t.kind == tkApp and t.base != nil and t.base.kind == tkNamed and
     t.base.name == wrapper and t.args.len == 1: t.args[0]
  else: nil

proc typeText(t: Type): string =
  ## A type as it is written in a `let x: T`.
  if t == nil: return "int"
  case t.kind
  of tkNamed: t.name
  of tkApp:
    if t.base != nil and t.base.name == "?" and t.args.len == 1:
      typeText(t.args[0]) & "?"
    else:
      var a: seq[string]
      for x in t.args: a.add typeText(x)
      (if t.base != nil: t.base.name else: "") & "[" & a.join(", ") & "]"
  else: "int"

proc declBody(m: Module, name: string): Type =
  let d = m.findDecl(dkType, name)
  if d == nil: nil else: d.typeBody

proc supported(m: Module, t: Type, seen: seq[string], inSeq = false): bool =
  ## Can a value of `t` be generated? Scalars, str, enums, records and payload
  ## sums of those, and `Seq`/`?` of them. A type that contains itself is not
  ## (the generator would never stop).
  if t == nil: return false
  let el = wrapperArg(t, "Seq")
  if el != nil: return not inSeq and supported(m, el, seen, true)
  let opt = wrapperArg(t, "?")
  if opt != nil: return supported(m, opt, seen, inSeq)
  if t.kind != tkNamed: return false
  if t.name == "bool" or t.name == "str" or isFloat(t.name) or
     intDomain(t.name).ok: return true
  if t.name in seen: return false
  let body = declBody(m, t.name)
  if body == nil: return false
  let deeper = seen & @[t.name]
  case body.kind
  of tkRecord:
    if inSeq: return false   # a record is built by a call, as a payload sum is
    for f in body.fields:
      if not supported(m, f.typ, deeper, inSeq): return false
    true
  of tkSum:
    for v in body.variants:
      if inSeq and v.fields.len > 0: return false   # a sum is built by a call
      for f in v.fields:
        if not supported(m, f.typ, deeper, inSeq): return false
    true
  else: false

proc targetsOf*(m: Module, skip: HashSet[string]): seq[Target] =
  ## Top-level fns with no capability effects, parameters of generatable types
  ## and a return type that carries an invariant. `skip` is the `--except` list.
  for d in m.decls:
    if d == nil or d.kind != dkFn or d.fnBody == nil or d.name == "main": continue
    if d.name in skip or d.fnGenerics.len > 0 or d.fnParams.len == 0: continue
    if emIo in d.fnEffects or emMayBlock in d.fnEffects: continue
    let rt = d.fnReturnType
    if rt == nil or rt.kind != tkNamed or not hasInvariants(m, rt.name): continue
    var ok = true
    for p in d.fnParams:
      if not supported(m, p.typ, @[]): ok = false
    if not ok: continue
    var t = Target(name: d.name, returns: rt.name)
    for p in d.fnParams: t.params.add (p.name, p.typ)
    result.add t

proc gen(g: var Gen, t: Type, depth = 0): Value

proc genInt(g: var Gen, typ: string): Value =
  let (_, lo, hi) = intDomain(typ)
  let edgeVals = [lo, hi, 0, 1, -1, 2, 3, 7, 10, 100]
  let v = if g.edges: max(lo, min(hi, edgeVals[g.r.rand(edgeVals.high)]))
          else: g.r.rand(lo .. hi)
  Value(expr: $v, display: $v)

proc genFloat(g: var Gen): Value =
  let edgeVals = [0.0, 1.0, -1.0, 0.5, -0.5, 100.25, -100.25, 0.001]
  let v = if g.edges: edgeVals[g.r.rand(edgeVals.high)]
          else: g.r.rand(-1000.0 .. 1000.0)
  let s = formatFloat(v, ffDecimal, 3)
  Value(expr: s, display: s)

proc genFields(g: var Gen, fields: seq[FieldDef], depth: int): tuple[expr, display: string] =
  var ex, di: seq[string]
  for f in fields:
    let v = g.gen(f.typ, depth + 1)
    ex.add f.name & ": " & v.expr
    di.add f.name & ": " & v.display
  ("{" & ex.join(", ") & "}", "{" & di.join(", ") & "}")

proc genSeq(g: var Gen, el: Type, depth: int): Value =
  ## A `Seq[T]` is bound with its type stated (an empty `[]` cannot say what
  ## it holds), so the case needs a `let` line.
  let len = if g.edges: g.r.rand(1) else: g.r.rand(4)
  var parts: seq[string]
  for i in 0 ..< len: parts.add g.gen(el, depth + 1).display
  let lit = "[" & parts.join(", ") & "]"
  let name = "s" & $g.n
  inc g.n
  g.pre.add "let " & name & ": Seq[" & typeText(el) & "] = " & lit
  Value(expr: name, display: lit)

proc genSum(g: var Gen, name: string, body: Type, depth: int): Value =
  let v = body.variants[if g.edges: (if g.r.rand(1) == 0: 0 else: body.variants.high)
                        else: g.r.rand(body.variants.high)]
  if v.fields.len == 0:
    let s = name & "." & v.name
    return Value(expr: s, display: s)
  # A variant with a payload is built by a call, and a call cannot sit inside
  # a payload: it is bound first.
  let (ex, di) = g.genFields(v.fields, depth)
  let call = ex & " " & name & "." & v.name
  let vn = "v" & $g.n
  inc g.n
  g.pre.add "let " & vn & " = " & call
  Value(expr: vn, display: di & " " & name & "." & v.name)

proc gen(g: var Gen, t: Type, depth = 0): Value =
  let el = wrapperArg(t, "Seq")
  if el != nil: return g.genSeq(el, depth)
  let opt = wrapperArg(t, "?")
  if opt != nil:
    if g.r.rand(2) == 0: return Value(expr: "none", display: "none")
    return g.gen(opt, depth)
  case t.name
  of "bool":
    let s = if g.r.rand(1) == 0: "false" else: "true"
    return Value(expr: s, display: s)
  of "str":
    let s = "\"" & Strings[g.r.rand(Strings.high)] & "\""
    return Value(expr: s, display: s)
  of "f64", "f32": return g.genFloat()
  else: discard
  if intDomain(t.name).ok: return g.genInt(t.name)
  let body = declBody(g.m, t.name)
  if body.kind == tkSum: return g.genSum(t.name, body, depth)
  # A named record is built by a call too (an anonymous literal would not be
  # the named type), so it is bound first like a payload variant.
  let (ex, di) = g.genFields(body.fields, depth)
  let rn = "p" & $g.n
  inc g.n
  g.pre.add "let " & rn & " = " & ex & " " & t.name
  Value(expr: rn, display: di & " " & t.name)

type Case* = object
  display*: string   ## the call written out, e.g. `{a: 1, b: 2} spanOf`
  lines*: seq[string] ## the harness statements for it

proc casesFor*(m: Module, t: Target, cases: int, seed: int64): seq[Case] =
  ## A deterministic stream of calls: the same seed gives the same cases. Half
  ## of them lean on edge values.
  var g = Gen(m: m, r: initRand(seed))
  for i in 0 ..< cases:
    g.edges = i mod 2 == 0
    g.pre = @[]
    var ex, di: seq[string]
    for p in t.params:
      let v = g.gen(p.typ)
      ex.add p.name & ": " & v.expr
      di.add p.name & ": " & v.display
    var c = Case(display: "{" & di.join(", ") & "} " & t.name)
    c.lines = g.pre
    c.lines.add "let r = {" & ex.join(", ") & "} " & t.name
    result.add c

proc harnessFor*(importName: string, cs: seq[Case]): string =
  ## One program holding every case. It runs the case numbered by its argument
  ## COUNT, so the driver can run them one by one and a failing case does not
  ## hide the ones after it.
  result = "import " & importName & "\nimport console\nimport sys\n\n" &
           "fn main() -> int [io]:\n  let n = {} argCount\n"
  for i, c in cs:
    result.add "  if n.count == " & $(i + 1) & ":\n"
    for l in c.lines: result.add "    " & l & "\n"
  result.add "  return 0\n"
