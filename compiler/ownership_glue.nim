# Rule G: derive a graph once for each instantiated type. Recursive edges
# point back to the same node; ownership is a least fixed point, not a
# depth-limited field scan. This module has no backend or analysis imports.
import std/[tables, sets, strutils, algorithm]
import ast

type
  GlueKind* = enum
    gPlain, gString, gSequence, gArray, gRecord, gSum, gResult
  Glue* = ref object
    kind*: GlueKind
    typ*: Type
    owns*: bool
    children*: seq[tuple[name: string, node: Glue]]
  Builder = object
    m: Module
    cache: Table[string, Glue]
    nodes: seq[Glue]
    aliases: seq[tuple[node, target: Glue]]

proc paramName(t: Type): string =
  if t == nil or t.kind != tkNamed: return ""
  if t.name.startsWith(NamedTypeParamPrefix) and t.name.endsWith(">"):
    t.name[NamedTypeParamPrefix.len .. ^2]
  else: t.name

proc instantiate(t: Type, sub: Table[string, Type]): Type =
  ## Generic bindings hold arguments already instantiated at the call site.
  if t == nil: return nil
  if t.kind == tkNamed:
    return if paramName(t) in sub: sub[paramName(t)] else: t
  result = Type()
  result[] = t[]
  case t.kind
  of tkApp:
    result.args = @[]
    for arg in t.args: result.args.add instantiate(arg, sub)
  of tkRecord:
    result.fields = @[]
    for f in t.fields:
      var f = f
      f.typ = instantiate(f.typ, sub)
      result.fields.add f
  of tkTuple:
    result.elems = @[]
    for elem in t.elems: result.elems.add instantiate(elem, sub)
  of tkSum:
    result.variants = @[]
    for v in t.variants:
      var variant = v
      variant.fields = @[]
      for f in v.fields:
        var f = f
        f.typ = instantiate(f.typ, sub)
        variant.fields.add f
      result.variants.add variant
  of tkFunc, tkUnion, tkRename, tkEffect: discard
  of tkNamed: discard

proc typeKey(t: Type, sub: Table[string, Type]): string =
  if t == nil: return "?"
  case t.kind
  of tkNamed:
    if paramName(t) in sub: return typeKey(sub[paramName(t)], initTable[string, Type]())
    result = t.qualifier.join("::") & ":" & t.name
  of tkApp:
    result = typeKey(t.base, sub) & "["
    for a in t.args: result.add(typeKey(a, sub) & ",")
    result.add "]"
  else:
    # Inline shapes are immutable AST nodes during this pass. Their identity
    # keeps distinct shapes separate without recursively spelling cycles.
    result = $t.kind & ":" & $cast[uint](t)
    var bindings: seq[string]
    for k, v in sub:
      bindings.add(k & "=" & typeKey(v, initTable[string, Type]()))
    bindings.sort()
    for binding in bindings: result.add(":" & binding)

proc build(b: var Builder, t: Type, sub: Table[string, Type]): Glue

proc fields(b: var Builder, g: Glue, fs: seq[FieldDef],
            sub: Table[string, Type]) =
  for f in fs: g.children.add (f.name, b.build(f.typ, sub))

proc namedDecl(b: Builder, name: string): Decl =
  for d in b.m.decls:
    if d != nil and d.name == name and d.kind in {dkType, dkObject}:
      return d

proc fromDecl(b: var Builder, g: Glue, d: Decl,
              sub: Table[string, Type]) =
  if d.kind == dkObject:
    g.kind = gRecord
    b.fields(g, d.objFields, sub)
  else:
    let body = b.build(d.typeBody, sub)
    # Do not snapshot an unfinished recursive target's placeholder shape.
    b.aliases.add (g, body)

proc genericApplication(b: var Builder, g: Glue, t: Type,
                        sub: Table[string, Type]) =
  let d = b.namedDecl(t.base.name)
  if d == nil or d.kind != dkType: return
  var bindings = initTable[string, Type]()
  for i, p in d.generics:
    if i < t.args.len: bindings[p] = instantiate(t.args[i], sub)
  b.fromDecl(g, d, bindings)

proc application(b: var Builder, g: Glue, t: Type,
                 sub: Table[string, Type]) =
  if t.base == nil or t.base.kind != tkNamed: return
  let name = t.base.name
  case name
  of "Seq":
    g.kind = gSequence
    g.owns = true
    if t.args.len == 1: g.children.add ("element", b.build(t.args[0], sub))
  of "Array", "*":
    g.kind = gArray
    let elem = if name == "Array": 1 else: 0
    if t.args.len > elem: g.children.add ("element", b.build(t.args[elem], sub))
  of "?", "!", "!?":
    g.kind = gResult
    if t.args.len == 1: g.children.add ("value", b.build(t.args[0], sub))
  of UninitName:
    if t.args.len == 1: b.aliases.add (g, b.build(t.args[0], sub))
  else: b.genericApplication(g, t, sub)

proc variants(b: var Builder, g: Glue, t: Type,
              sub: Table[string, Type]) =
  g.kind = gSum
  for v in t.variants:
    let payload = Glue(kind: gRecord)
    b.nodes.add payload
    b.fields(payload, v.fields, sub)
    g.children.add (v.name, payload)

proc build(b: var Builder, t: Type, sub: Table[string, Type]): Glue =
  if t != nil and t.kind == tkNamed and paramName(t) in sub:
    return b.build(sub[paramName(t)], initTable[string, Type]())
  let key = typeKey(t, sub)
  if key in b.cache: return b.cache[key]
  result = Glue(kind: gPlain, typ: instantiate(t, sub))
  b.cache[key] = result
  b.nodes.add result
  if t == nil: return
  case t.kind
  of tkNamed:
    if t.name in ["str", "string"]:
      result.kind = gString
      result.owns = true
    else:
      let d = b.namedDecl(t.name)
      if d != nil: b.fromDecl(result, d, sub)
  of tkApp: b.application(result, t, sub)
  of tkRecord:
    result.kind = gRecord
    b.fields(result, t.fields, sub)
  of tkSum: b.variants(result, t, sub)
  of tkTuple:
    result.kind = gRecord
    for i, elem in t.elems: result.children.add ($i, b.build(elem, sub))
  of tkUnion, tkRename, tkEffect, tkFunc:
    discard  # These are erased/composed before ownership elaboration.

proc glueFor*(m: Module, t: Type): Glue =
  var b = Builder(m: m)
  result = b.build(t, initTable[string, Type]())
  # Alias chains may include back edges. Find the completed shape without
  # unrolling recursive data. A pure alias cycle has no owned storage.
  var targets = initTable[uint, Glue]()
  for alias in b.aliases: targets[cast[uint](alias.node)] = alias.target
  for alias in b.aliases:
    var target = alias.target
    var seen = initHashSet[uint]()
    while cast[uint](target) in targets:
      let id = cast[uint](target)
      if id in seen: break
      seen.incl id
      target = targets[id]
    alias.node.kind = target.kind
    alias.node.owns = target.owns
    alias.node.children = target.children
  var changed = true
  while changed:
    changed = false
    for n in b.nodes:
      if n.owns: continue
      for child in n.children:
        if child.node.owns:
          n.owns = true
          changed = true
          break

proc ownsStorage*(m: Module, t: Type): bool =
  glueFor(m, t).owns
