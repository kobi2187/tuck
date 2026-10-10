## Rule G's Odin printer. Placement is NOT decided here: callers request
## type-derived operations, then print them at the elaborator's sites.
## Drop/reset require an owned value: static/borrowed strings must first
## be cloned at a sink. Never enable these alongside shallow copies.
import std/[tables, strutils]
import ast, ownership_glue, codegen_odin_ctx

type GlueNames* = tuple[copy, drop, reset: string]

type Bodies = tuple[copy, drop: string]

proc emit(ctx: var OdinCodegenCtx, g: Glue, typ: string): GlueNames

proc sequenceBodies(ctx: var OdinCodegenCtx, g: Glue, typ: string): Bodies =
  let elem = g.children[0].node
  var child: GlueNames
  if elem.owns: child = ctx.emit(elem, ctx.odinType(elem.typ))
  result.copy = "\tout := value\n"
  if g.kind == gSequence:
    result.copy = "\tout: G\n\tresize(&out, len(value))\n"
  if elem.owns:
    result.copy.add "\tfor item, i in value { out[i] = " & child.copy & "(item) }\n"
    result.drop.add "\tfor item in value { " & child.drop & "(item) }\n"
  elif g.kind == gSequence:
    result.copy.add "\tcopy(out[:], value[:])\n"
  if g.kind == gSequence: result.drop.add "\tdelete(value)\n"
  result.copy.add "\treturn out\n"

proc recordBodies(ctx: var OdinCodegenCtx, g: Glue): Bodies =
  result.copy = "\tout := value\n"
  for field in g.children:
    if not field.node.owns: continue
    let child = ctx.emit(field.node, ctx.odinType(field.node.typ))
    result.copy.add "\tout." & field.name & " = " & child.copy & "(value." & field.name & ")\n"
    result.drop.add "\t" & child.drop & "(value." & field.name & ")\n"
  result.copy.add "\treturn out\n"

proc resultBodies(ctx: var OdinCodegenCtx, g: Glue): Bodies =
  let payload = g.children[0].node
  let child = ctx.emit(payload, ctx.odinType(payload.typ))
  result.copy = "\tout := value\n\tif value.status == .Ok {\n\t\tout.value = " &
    child.copy & "(value.value)\n\t} else { out.value = {} }\n\treturn out\n"
  result.drop = "\tif value.status == .Ok { " & child.drop & "(value.value) }\n"

proc sumBodies(ctx: var OdinCodegenCtx, g: Glue, typ: string): Bodies =
  result.copy = "\tout: G\n\tswitch payload in value {\n"
  result.drop = "\tswitch payload in value {\n"
  for variant in g.children:
    let variantType = typ & "_" & variant.name
    let child = ctx.emit(variant.node, variantType)
    result.copy.add "\tcase " & variantType & ": out = " & child.copy & "(payload)\n"
    result.drop.add "\tcase " & variantType & ": " & child.drop & "(payload)\n"
  result.copy.add "\t}\n\treturn out\n"
  result.drop.add "\t}\n"

proc bodies(ctx: var OdinCodegenCtx, g: Glue, typ: string): Bodies =
  if not g.owns: return ("\treturn value\n", "")
  case g.kind
  of gString: ("\treturn rt.tuckStrOwned(value)\n", "\tdelete(value)\n")
  of gSequence, gArray: ctx.sequenceBodies(g, typ)
  of gRecord: ctx.recordBodies(g)
  of gResult: ctx.resultBodies(g)
  of gSum: ctx.sumBodies(g, typ)
  of gPlain: ("\treturn value\n", "")
  of gPolymorphic:
    ("\treturn rt.tuckCopyValue(value)\n", "\trt.tuckDropValue(value)\n")

proc emit(ctx: var OdinCodegenCtx, g: Glue, typ: string): GlueNames =
  if typ in ctx.glueNames: return ctx.glueNames[typ]
  let prefix = "tuckG_" & ctx.modPrefix & $ctx.glueNames.len
  result = (prefix & "_copy", prefix & "_drop", prefix & "_reset")
  ctx.glueNames[typ] = result # Before descent: recursive edges reuse this.
  let body = ctx.bodies(g, typ)
  ctx.hoisted.add result.copy & " :: proc(value: $G) -> G" &
                  " {\n" & body.copy & "}\n" &
                  result.drop & " :: proc(value: $G) {\n" & body.drop & "}\n" &
                  result.reset & " :: proc(value: ^$G" &
                  ") { " & result.drop & "(value^); value^ = {} }\n"

proc odinGlue*(ctx: var OdinCodegenCtx, t: Type): GlueNames =
  let typ = ctx.odinType(t)
  if typ in ctx.glueNames: return ctx.glueNames[typ]
  let graph = glueFor(ctx.module, t)
  ctx.emit(graph, typ)
