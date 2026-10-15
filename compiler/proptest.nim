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
# carrying an invariant, call each with generated integer/bool arguments, and
# let the invariant fire. This module only finds the targets and writes the
# harness program; the driver in tuck.nim builds it and reads the result.
import ast, ast_ops, ast_query
import std/[strutils, random]

type
  Target* = object
    name*: string
    params*: seq[tuple[name, typ: string]]
    returns*: string

const Domains = [
  # name, lowest, highest generated. A signed type starts one above its true
  # minimum: the literal `-128` does not fit i8 (the minus is applied after).
  ("int", -2000, 2000), ("i64", -2000, 2000), ("i32", -2000, 2000),
  ("i16", -32767, 32767), ("i8", -127, 127),
  ("u8", 0, 255), ("u16", 0, 65535), ("u32", 0, 2000), ("u64", 0, 2000)]

proc domainOf(typ: string): tuple[ok: bool, lo, hi: int] =
  for (n, lo, hi) in Domains:
    if n == typ: return (true, lo, hi)

proc isTargetType(m: Module, t: Type): bool =
  t != nil and t.kind == tkNamed and hasInvariants(m, t.name)

proc paramsOk(d: Decl): bool =
  for p in d.fnParams:
    if p.typ == nil or p.typ.kind != tkNamed: return false
    if p.typ.name != "bool" and not domainOf(p.typ.name).ok: return false
  true

proc targetsOf*(m: Module): seq[Target] =
  ## Top-level fns with no capability effects, integer/bool parameters and a
  ## return type that carries an invariant.
  for d in m.decls:
    if d == nil or d.kind != dkFn or d.fnBody == nil or d.name == "main": continue
    if d.fnGenerics.len > 0 or d.fnParams.len == 0: continue
    if emIo in d.fnEffects or emMayBlock in d.fnEffects: continue
    if not d.paramsOk or not m.isTargetType(d.fnReturnType): continue
    var t = Target(name: d.name, returns: d.fnReturnType.name)
    for p in d.fnParams: t.params.add (p.name, p.typ.name)
    result.add t

proc pick(typ: string, r: var Rand, edges: bool): string =
  if typ == "bool": return (if r.rand(1) == 0: "false" else: "true")
  let (_, lo, hi) = domainOf(typ)
  let candidates = [lo, hi, 0, 1, -1, 2, 3, 7, 10, 100]
  if edges:
    let v = candidates[r.rand(candidates.high)]
    return $max(lo, min(hi, v))
  $r.rand(lo .. hi)

proc inputsFor*(t: Target, cases: int, seed: int64): seq[string] =
  ## Argument payloads, e.g. `{total: 7, parts: 3}`. A deterministic stream:
  ## the same seed gives the same cases. Half lean on edge values.
  var r = initRand(seed)
  for i in 0 ..< cases:
    var fields: seq[string]
    for p in t.params:
      fields.add p.name & ": " & pick(p.typ, r, i mod 2 == 0)
    result.add "{" & fields.join(", ") & "}"

proc harnessFor*(importName: string, t: Target, cases: int, seed: int64): string =
  ## A program that calls `t` once per generated input, announcing each call
  ## first so a failure can name its input.
  result = "import " & importName & "\nimport console\n\nfn main() -> int [io]:\n"
  var n = 0
  for payload in inputsFor(t, cases, seed):
    result.add "  {text: \"CASE " & t.name & " " & payload & "\"} printLine\n"
    result.add "  let r" & $n & " = " & payload & " " & t.name & "\n"
    inc n
  result.add "  return 0\n"
