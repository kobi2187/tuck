# compiler/codegen_odin_decl.nim
#
# Declaration codegen for the Odin backend: genOdinDecl's dispatch (one arm
# per DeclKind) and everything it calls -- fn/object/actor/registry/
# register/mixin/decision-table/err-handler. Calls INTO codegen_odin.nim's
# genOdinExpr for fn bodies (one-way: genOdinExpr never calls back into
# anything here).
import ast, lowering, strutils, sets, tables, options
import resolution
import ast_query
import codegen_common
import codegen_table
import codegen_odin_ctx
import codegen_odin_util
from mangle import mangleName
import ./codegen_odin

const DefaultMailboxSize = "8"
  ## Messages an actor's ring holds unless `[queue: N]` says otherwise.

proc genOdinDecl*(ctx: var OdinCodegenCtx, d: Decl): string
  ## Forward-declared: genRecordType (manager-type member fns) recurses
  ## into it before its own definition.

type
  BitField* = object
    ## One `bit N` / `bits LO..HI` field of a memory-mapped register, decoded
    ## from its declared type and attributes.
    prefix: string    # <register>_<field>, the name every emitted symbol shares
    loBit, hiBit: string
    isRange: bool     # a multi-bit field, not a single flag
    canRead, canWrite: bool

# Object member fn (or a mixin fn materialized by `+ mixin`): the object
# rides as a `ref self` first parameter (reassignment must reach the
# caller); `Self` resolves to the object. Shallow copy — the shared AST
# stays untouched for the other backend.
# ponytail: call sites don't take the address yet — nothing in the
# examples calls a member fn; wire it when one does.
proc genOdinMemberFn*(ctx: var OdinCodegenCtx, m: Decl, objName: string): string =
  # lowering.normalizeSelf has already given the member its `self` parameter
  # and resolved `Self` to the object. What is left is the ODIN spelling:
  # self is a pointer, `^T`, so a mutation reaches the caller's value.
  var params = m.fnParams
  for i in 0 ..< params.len:
    if params[i].name == "self":
      params[i].typ = Type(span: m.span, kind: tkNamed, name: "^" & objName)
  let copy = Decl(span: m.span, kind: dkFn, name: memberProcName(objName, m.name),
                  fnParams: params,
                  fnReturnType: m.fnReturnType, fnBody: m.fnBody,
                  fnEffects: m.fnEffects, fnGenerics: m.fnGenerics)
  # `self` is a POINTER here, so every mention in the body needs a deref —
  # `self^` reads the value and `self^ = x` writes through to the caller.
  let oldPtrSelf = ctx.ptrSelf
  ctx.ptrSelf = true
  result = ctx.genOdinDecl(copy)
  ctx.ptrSelf = oldPtrSelf

proc genPendingStub*(ctx: var OdinCodegenCtx, d: Decl): string =
  ## Pending stub: logs on invocation, returns the zero value.
  let ind = "  ".repeat(ctx.indent)
  let fnNameSanitized = d.name.replace(".", "_").replace("::", "_")
  let retTypeStr = if d.fnReturnType != nil: ctx.odinType(d.fnReturnType) else: "void"
  let paramStr = if d.fnParams.len > 0: "(payload: $T)" else: "()"
  let retStr = if retTypeStr != "void": " -> " & retTypeStr else: ""
  var res = ind & fnNameSanitized & " :: proc" & paramStr & retStr & " {\n" &
            ind & "\tfmt.println(\"TUCK PENDING: " & d.name &
            " invoked (not implemented)\")\n"
  if retTypeStr != "void":
    res.add(ind & "\treturn {}\n")
  res.add(ind & "}\n")
  return res

proc ensureTrailingReturn*(bodyStr: string, body: Expr, blockIndent: int): string =
  ## Odin rejects non-void procs that can fall off the end; append a
  ## zero-value `return {}` when the last statement doesn't guarantee a
  ## return (the checker enforces the real branch agreement). The block
  ## emitter no longer emits a closing brace, so this appends to the end
  ## of the body.
  if body == nil or body.kind != exkBlock: return bodyStr
  if body.stmts.len > 0 and body.stmts[^1].kind in {exkReturn, exkRaise}:
    return bodyStr
  return bodyStr & "\n" & "  ".repeat(blockIndent) & "  return {}"

proc decisionHeader*(ctx: var OdinCodegenCtx, d: Decl, ind: string): string =
  ## The proc signature a decision table compiles to.
  var params: seq[string]
  for p in d.fnParams:
    params.add(p.name & ": " & ctx.odinType(p.typ))
  let retT = if d.fnReturnType != nil: ctx.odinType(d.fnReturnType) else: "void"
  let retStr = if retT != "void": " -> " & retT else: ""
  ind & d.name.replace(".", "_") & " :: proc(" & params.join(", ") & ")" &
    retStr & " {"

proc columnOrdinal*(domain: seq[string], paramName: string): string =
  ## A column's ordinal. NOT packedKeyExpr — that emits Nim's `ord()`; Odin
  ## needs int() and a bool ternary, which is the one part of this that is
  ## genuinely syntax.
  if domain == @["false", "true"]: "(" & paramName & " ? 1 : 0)"
  else: "int(" & paramName & ")"

proc packedKey*(d: Decl, domains: seq[seq[string]], comboCount: int): string =
  ## Mixed radix over the ordinal of each column.
  var parts: seq[string]
  var stride = comboCount
  for c in 0 ..< domains.len:
    stride = stride div domains[c].len
    let ordExpr = columnOrdinal(domains[c], d.fnParams[c].name)
    parts.add(if stride > 1: ordExpr & " * " & $stride else: ordExpr)
  parts.join(" + ")

proc decisionRowPatterns*(s: Expr): seq[string] =
  ## One row's column patterns, as their surface spelling.
  let pat = s.arms[0].pattern
  for el in (if pat != nil and pat.kind == pkTuple: pat.elems else: @[pat]):
    result.add(genPatternStr(el))

proc collectDecisionRows*(ctx: var OdinCodegenCtx, d: Decl,
                         rowPats: var seq[seq[string]],
                         rowBodies: var seq[string]) =
  for s in d.fnBody.stmts:
    if s.kind != exkMatch or s.arms.len == 0: continue
    rowPats.add(decisionRowPatterns(s))
    rowBodies.add(ctx.armValue(s.arms[0].body))

proc genPackedDecision*(ctx: var OdinCodegenCtx, d: Decl,
                       domains: seq[seq[string]], comboCount: int,
                       ind: string): string =
  ## Every column domain is enumerable, so the whole table collapses to one
  ## switch over a packed integer key (spec 6.1).
  var rowPats: seq[seq[string]]
  var rowBodies: seq[string]
  ctx.collectDecisionRows(d, rowPats, rowBodies)
  # first-match outcome for every combination, grouped by outcome
  let groups = groupByOutcome(domains, comboCount, rowPats, rowBodies)
  var lines: seq[string]
  lines.add(ind & "\tswitch " & packedKey(d, domains, comboCount) &
            " {   // packed decision key")
  for gi, g in groups:
    if gi == groups.len - 1:
      lines.add(ind & "\tcase: return " & g.outcome)
    else:
      var ks: seq[string]
      for k in g.keys: ks.add($k)
      lines.add(ind & "\tcase " & ks.join(", ") & ": return " & g.outcome)
  lines.add(ind & "\t}")
  lines.join("\n")

proc decisionRowCondition*(ctx: var OdinCodegenCtx, d: Decl, arm: MatchArm): string =
  ## The guard a row fires under — empty when every column is a wildcard,
  ## which makes it the catch-all.
  let pats = if arm.pattern != nil and arm.pattern.kind == pkTuple:
               arm.pattern.elems
             else: @[arm.pattern]
  var conds: seq[string]
  for i, pat in pats:
    let patStr = genPatternStr(pat)
    if patStr != "_" and i < d.fnParams.len:
      conds.add(d.fnParams[i].name & " == " & ctx.patternValue(patStr))
  conds.join(" && ")

proc genChainedDecision*(ctx: var OdinCodegenCtx, d: Decl, retTypeStr,
                        ind: string): string =
  ## An open column domain cannot be packed, so the rows become guards in
  ## order, and a table with no catch-all needs a zero value to fall out on.
  var lines: seq[string]
  var hasCatchAll = false
  for s in d.fnBody.stmts:
    let arm = s.arms[0]
    let cond = ctx.decisionRowCondition(d, arm)
    let value = ctx.armValue(arm.body)
    if cond == "":
      lines.add(ind & "\treturn " & value)
      hasCatchAll = true
    else:
      lines.add(ind & "\tif " & cond & " do return " & value)
  if not hasCatchAll and retTypeStr != "void":
    lines.add(ind & "\treturn {}")
  lines.join("\n")

proc genDecisionTable*(ctx: var OdinCodegenCtx, d: Decl): string =
  ## Packed when every column is enumerable, chained guards otherwise.
  let ind = "  ".repeat(ctx.indent)
  let header = ctx.decisionHeader(d, ind)
  let retTypeStr = if d.fnReturnType != nil: ctx.odinType(d.fnReturnType)
                   else: "void"
  let (domains, allEnum, comboCount) = columnDomains(ctx.module, d)
  let body = if allEnum and comboCount > 0 and comboCount <= MaxPackedCombos:
               ctx.genPackedDecision(d, domains, comboCount, ind)
             else:
               ctx.genChainedDecision(d, retTypeStr, ind)
  header & "\n" & body & "\n" & ind & "}\n"

proc cCallbackConvention*(ctx: var OdinCodegenCtx, d: Decl): string =
  ## A fn handed to a C function pointer needs the C calling convention. Odin
  ## cannot cast between conventions the way Nim can, so it goes on the
  ## DEFINITION, matched by shape against the module's C-callback fnsig.
  ##
  ## ponytail: shape match, not reference tracking. A same-shape fn that never
  ## crosses the boundary gets "c" harmlessly; tighten if that ever matters.
  for mem in ctx.module.externMembers():
    if mem.kind != dkFnSig or not mem.sigIsCCallback or
       mem.sigParams.len != d.fnParams.len: continue
    var same = true
    for i, sp in mem.sigParams:
      if ctx.odinType(sp.typ) != ctx.odinType(d.fnParams[i].typ): same = false
    if same: return "\"c\" "
  ""

proc fnParamList*(ctx: var OdinCodegenCtx, d: Decl): string =
  ## Records pass BY VALUE. The checker binds every param isVar:true, but a
  ## Tuck mutator returns the updated record and the caller assigns it back
  ## (`server = withDefaults(server)`), so no pointer is needed — and Odin
  ## proc params aren't addressable, so `&arg` at the call site is illegal.
  ##
  ## Generic fns come first: Odin's parametric polymorphism marks type params
  ## with `$`.
  var params: seq[string]
  for g in d.fnGenerics: params.add("$" & g & ": typeid")
  ctx.fnAsParam = true
  for p in d.fnParams:
    params.add(p.name & ": " & ctx.odinType(p.typ))
  ctx.fnAsParam = false
  params.join(", ")

proc fnHeader*(ctx: var OdinCodegenCtx, d: Decl, retTypeStr, ind: string): string =
  ## Names arrive already mangled by the lowering pass (compiler/mangle.nim),
  ## which is also what keeps Tuck's `fn main` from colliding with Odin's entry
  ## point — it is tuck_main by the time it gets here.
  let retStr = if retTypeStr != "void": " -> " & retTypeStr else: ""
  let inlinePrefix = if d.isInline: ind & "@(require_results=false)\n" else: ""
  inlinePrefix & ind & d.name.replace(".", "_") & " :: proc " &
    ctx.cCallbackConvention(d) & "(" & ctx.fnParamList(d) & ")" & retStr & " {"

proc enterReturnContext*(ctx: var OdinCodegenCtx, d: Decl) =
  ## What the body needs to know about the return: whether it auto-wraps into
  ## a !T/?T result, and whether the returned value carries invariants to
  ## validate on the way out.
  let (wrapped, innerOdin, innerT) = ctx.odinBangInfo(d.fnReturnType)
  ctx.retWrapped = wrapped
  ctx.retInnerOdin = innerOdin
  ctx.retInnerT = innerT
  ctx.retInvName =
    if not wrapped and d.fnReturnType != nil and
       d.fnReturnType.kind == tkNamed and
       hasInvariants(ctx.module, d.fnReturnType.name): d.fnReturnType.name
    else: ""

proc leaveReturnContext*(ctx: var OdinCodegenCtx) =
  ctx.retWrapped = false
  ctx.retInnerOdin = ""
  ctx.retInnerT = nil
  ctx.retInvName = ""

proc genFnBody*(ctx: var OdinCodegenCtx, d: Decl, retTypeStr, ind: string): string =
  ## The body, with every return path accounted for: a single-expression body
  ## becomes one `return` line, and a block body gets a trailing return when
  ## the fn owes a value.
  let savedIndent = ctx.indent
  injectTailReturn(d.fnBody, retTypeStr)
  result = ctx.genOdinExpr(d.fnBody)
  if d.fnBody != nil and d.fnBody.kind != exkBlock:
    # single-expression body: `header {` is already open, so just the line
    let kw = if retTypeStr != "void": "return " else: ""
    result = ind & "\t" & kw & result
  elif retTypeStr != "void":
    result = ensureTrailingReturn(result, d.fnBody, savedIndent)
  ctx.indent = savedIndent

proc genOdinFnDecl*(ctx: var OdinCodegenCtx, d: Decl): string =
  ## An ordinary fn. A pending fn is a stub and a decision table has its own
  ## lowering; both leave before any of this runs.
  if d.isPending: return ctx.genPendingStub(d)
  ctx.currentParams = @[]
  for p in d.fnParams:
    ctx.currentParams.add(FieldDef(name: p.name, typ: p.typ, span: p.span))
  if d.isDecision or d.isDecisionTable(): return ctx.genDecisionTable(d)
  let ind = "  ".repeat(ctx.indent)
  let retTypeStr = if d.fnReturnType != nil: ctx.odinType(d.fnReturnType)
                   else: "void"
  let header = ctx.fnHeader(d, retTypeStr, ind)
  let savedVars = ctx.definedVars
  for p in d.fnParams: ctx.definedVars.incl(p.name)
  ctx.enterReturnContext(d)
  let bodyStr = ctx.genFnBody(d, retTypeStr, ind)
  ctx.leaveReturnContext()
  ctx.definedVars = savedVars
  header & "\n" & bodyStr & "\n" & ind & "}\n"

proc genTransitionProcs*(ctx: var OdinCodegenCtx, d: Decl, kindName: string,
                        hasPayload: bool): string =
  let ind = "  ".repeat(ctx.indent)
  # Names are type-qualified: Odin has no overloading or class scoping, so
  # two sum types in one package would otherwise collide.
  let canName = "canTransition_" & d.name
  var canLines: seq[string]
  canLines.add(ind & canName & " :: proc(frm: " & kindName & ", to: " &
               kindName & ") -> bool {")
  canLines.add(ind & "\tswitch frm {")
  for v in d.typeBody.variants:
    let allowed = allowedTransitions(d.typeBody, v.name)
    if allowed.len > 0:
      var conds: seq[string]
      for a in allowed: conds.add("to == ." & a)
      canLines.add(ind & "\tcase ." & v.name & ": return " & conds.join(" || "))
    else:
      canLines.add(ind & "\tcase ." & v.name & ": return false")
  canLines.add(ind & "\t}")
  canLines.add(ind & "\treturn false")
  canLines.add(ind & "}")
  var res = canLines.join("\n") & "\n"
  # A union-typed value carries its own tag, so the payload case assigns the
  # whole value rather than copying slot by slot the way the Beef class does.
  let subject = if hasPayload: "tag_" & d.name & "(self^)" else: "self^"
  let target = if hasPayload: "tag_" & d.name & "(target)" else: "target"
  res.add(ind & "transitionTo_" & d.name & " :: proc(self: ^" & d.name &
          ", target: " & d.name & ") {\n" &
          ind & "\tassert(" & canName & "(" & subject & ", " & target &
          "), \"Invalid transition\")\n" &
          ind & "\tself^ = target\n" & ind & "}\n")
  return res

proc variantTagList*(d: Decl, withValues = false): string =
  ## The variant names, optionally with the explicit ordinals a C enum needs.
  var tags: seq[string]
  for v in d.typeBody.variants:
    tags.add(if withValues and v.value != "": v.name & " = " & v.value
             else: v.name)
  tags.join(", ")

proc genVariantStruct*(ctx: var OdinCodegenCtx, d: Decl, v: VariantDef,
                      ind: string): string =
  ## One variant of a payload union, as its own struct.
  let vName = d.name & "_" & v.name
  if v.fields.len == 0: return ind & vName & " :: struct {}\n"
  var fieldLines: seq[string]
  for f in v.fields:
    fieldLines.add(ind & "\t" & f.name & ": " & ctx.odinType(f.typ) & ",")
  ind & vName & " :: struct {\n" & fieldLines.join("\n") & "\n" & ind & "}\n"

proc genTagProjection*(d: Decl, kindName, ind: string): string =
  ## Transitions compare states, so a payload union also needs a tag enum and
  ## a projection from value to tag.
  result = ind & kindName & " :: enum { " & variantTagList(d) & " }\n"
  result.add(ind & "tag_" & d.name & " :: proc(v: " & d.name & ") -> " &
             kindName & " {\n" & ind & "\tswitch _ in v {\n")
  for v in d.typeBody.variants:
    result.add(ind & "\tcase " & d.name & "_" & v.name & ": return ." &
               v.name & "\n")
  result.add(ind & "\t}\n" & ind & "\treturn ." &
             d.typeBody.variants[0].name & "\n" & ind & "}\n")

proc genPayloadUnion*(ctx: var OdinCodegenCtx, d: Decl, kindName: string,
                     hasTransitions: bool, ind: string): string =
  ## Odin has a real tagged union: each variant becomes its own struct and the
  ## union carries them directly — no hand-rolled kind enum, and
  ## `switch v in value` gets exhaustiveness from the compiler.
  var members: seq[string]
  for v in d.typeBody.variants:
    result.add(ctx.genVariantStruct(d, v, ind))
    members.add(d.name & "_" & v.name)
  result.add(ind & d.name & " :: union {" & members.join(", ") & "}\n")
  if hasTransitions:
    result.add(genTagProjection(d, kindName, ind))

proc genSumType*(ctx: var OdinCodegenCtx, d: Decl): string =
  ## A sum type is a plain enum unless it carries payloads or declares
  ## transitions.
  let ind = "  ".repeat(ctx.indent)
  let hasPayload = sumHasPayload(d.typeBody)
  let hasTransitions = d.typeBody.transitions.len > 0
  if not hasPayload and not hasTransitions:
    # plain enum (also what decision tables key over)
    return ind & d.name & " :: enum { " & variantTagList(d, withValues = true) &
           " }\n"
  let kindName = if hasPayload: d.name & "Kind" else: d.name
  result = if hasPayload:
             ctx.genPayloadUnion(d, kindName, hasTransitions, ind)
           else:
             ind & d.name & " :: enum { " & variantTagList(d) & " }\n"
  if hasTransitions:
    # transition matrix: pure predicate + checked assignment
    result.add(ctx.genTransitionProcs(d, kindName, hasPayload))

proc genRecordType*(ctx: var OdinCodegenCtx, d: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  var fieldsStr: seq[string]
  for f in d.typeBody.fields:
    fieldsStr.add(ind & "\t" & f.name & ": " & ctx.fieldType(d.name, f) & ",")
  let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: ""
  # Odin's parametric structs take `$T: typeid` params
  var tGenParts: seq[string]
  for g in d.generics: tGenParts.add("$" & g & ": typeid")
  let tGen = if tGenParts.len > 0: "(" & tGenParts.join(", ") & ")" else: ""
  # A fieldless extern type is an opaque C handle (`typedef struct Foo Foo;`
  # with no definition): unknown size, only ever held as a pointer.
  if d.typeExternHeader != "" and d.typeBody.fields.len == 0:
    return ind & d.name & " :: rawptr\n"
  # Tier 1 records are value types (spec §7.1) — struct, not a pointer type
  var res = ind & d.name & " :: struct" & tGen & " {\n" &
            (if fieldsBody != "": fieldsBody & "\n" else: "") & ind & "}\n"
  var invariantChecks: seq[string]
  var checkCtx = OdinCodegenCtx(definedVars: initHashSet[string](),
                                fieldVars: initHashSet[string](),
                                fieldPrefix: "self.", indent: 0,
                                module: ctx.module, realModules: ctx.realModules)
  for f in d.typeBody.fields:
    checkCtx.fieldVars.incl(f.name)
  for member in d.typeMembers:
    if member.kind == dkExpr:
      let condStr = checkCtx.genOdinExpr(member.expr)
      invariantChecks.add(ind & "\tassert(" & condStr & ")")
  if invariantChecks.len > 0:
    # Odin has no overloading, so these are type-qualified rather than
    # relying on the parameter type to disambiguate the way Beef does.
    res.add(ind & "validate_" & d.name & " :: proc(self: " & d.name & ") {\n" &
            invariantChecks.join("\n") & "\n" & ind & "}\n")
    # production sites wrap construction/returns in __validated_T(...)
    res.add(ind & "__validated_" & d.name & " :: proc(v: " & d.name & ") -> " &
            d.name & " {\n" & ind & "\tvalidate_" & d.name & "(v)\n" &
            ind & "\treturn v\n" & ind & "}\n")
  # manager types carry functionality: member fns join the catalog
  for member in d.typeMembers:
    if member.kind == dkFn:
      res.add("\n" & ctx.genOdinDecl(member) & "\n")
  return res

proc genAliasType*(ctx: var OdinCodegenCtx, d: Decl): string =
  let ind = "  ".repeat(ctx.indent)
  let typeBodyStr = ctx.odinType(d.typeBody)
  if isDistinctAlias(d.typeBody):
    # Odin has `distinct` natively: same bits, incompatible type, and
    # arithmetic/comparison already work on the distinct type. No wrapper
    # struct or operator overloads needed (the Beef backend hand-rolls both).
    return ind & d.name & " :: distinct " & typeBodyStr & "\n"
  var aGenParts: seq[string]
  for g in d.generics: aGenParts.add("$" & g & ": typeid")
  let aGen = if aGenParts.len > 0: "(" & aGenParts.join(", ") & ")" else: ""
  return ind & d.name & " :: " & (if aGen != "": "struct" & aGen & " { " &
         "using _: " & typeBodyStr & " }" else: typeBodyStr) & "\n"

proc msgVariantName*(handlerName: string): string =
  ## The message-enum tag a handler receives on.
  "msg" & handlerName.capitalize()

proc mailboxSize*(d: Decl): string =
  for attr in d.attrs:
    if attr.name == "queue": return attr.value
  DefaultMailboxSize

proc actorFieldLines*(ctx: var OdinCodegenCtx, d: Decl): seq[string] =
  let ind = "  ".repeat(ctx.indent)
  for f in d.actorFields:
    result.add(ind & "\t" & f.name & ": " & ctx.fieldType(d.name, f) & ",")

proc genInertActor*(ctx: var OdinCodegenCtx, d: Decl, ind: string): string =
  ## No message handlers: an empty enum is invalid. Emit the state, its
  ## singleton, and a drain that just parks — the entry point starts every
  ## declared actor, so the drain has to exist even with nothing to receive.
  let fields = ctx.actorFieldLines(d)
  let body = if fields.len > 0: fields.join("\n") & "\n" else: ""
  ind & d.name & " :: struct {\n" & body & ind & "}\n\n" &
    ind & actorSingletonName(d.name) & ": " & d.name & "\n\n" &
    ind & "drain_" & d.name & " :: proc() {\n" &
    ind & "\tfor { rt.coroYield() }\n" & ind & "}\n"

proc genMsgEnvelope*(ctx: var OdinCodegenCtx, d: Decl, handlers: seq[ActorMsgHandler],
                    variants: seq[string], ind: string): string =
  ## The message enum and the envelope struct. Handler params ride in the
  ## envelope, deduped by name.
  var msgFields: seq[string]
  var seen = initHashSet[string]()
  for h in handlers:
    for p in h.params:
      if p.name in seen: continue
      seen.incl(p.name)
      msgFields.add(ind & "\t" & p.name & ": " & ctx.odinType(p.typ) & ",")
  ind & d.name & "MsgKind :: enum { " & variants.join(", ") & " }\n" &
    ind & d.name & "Msg :: struct {\n" &
    ind & "\tkind: " & d.name & "MsgKind,\n" &
    (if msgFields.len > 0: msgFields.join("\n") & "\n" else: "") &
    ind & "}\n"

proc genActorState*(ctx: var OdinCodegenCtx, d: Decl, hasShutdown: bool,
                   ind: string): string =
  ## The actor's state struct: its own fields, its mailbox, and — when it can
  ## be shut down — the flag the drain checks.
  var fields = ctx.actorFieldLines(d)
  fields.add(ind & "\tmailbox: rt.Mailbox(" & d.name & "Msg, " &
             mailboxSize(d) & "),")
  if hasShutdown:
    fields.add(ind & "\tfinished: bool,")
  ind & d.name & " :: struct {\n" & fields.join("\n") & "\n" & ind & "}\n\n"

proc newHandlerCtx*(ctx: OdinCodegenCtx, d: Decl): OdinCodegenCtx =
  ## Odin has no methods, so the actor rides as a `self` pointer and field
  ## access inside a handler goes through it.
  result = OdinCodegenCtx(definedVars: initHashSet[string](),
                          fieldVars: initHashSet[string](),
                          fieldPrefix: "self.", indent: ctx.indent + 1,
                          module: ctx.module, realModules: ctx.realModules,
                          errPolicy: ctx.errPolicy)
  for f in d.actorFields:
    result.fieldVars.incl(f.name)

proc adoptHandlerCtx*(ctx: var OdinCodegenCtx, hctx: OdinCodegenCtx) =
  ## Anything the handler bodies hoisted belongs to the enclosing file.
  for h in hctx.hoisted:
    if h notin ctx.hoisted: ctx.hoisted.add(h)
  for sig, name in hctx.recShapes:
    if sig notin ctx.recShapes: ctx.recShapes[sig] = name

proc genHandlerCase*(hctx: var OdinCodegenCtx, h: ActorMsgHandler, ind: string): string =
  ## One dispatch arm: unpack the envelope's fields, then run the body.
  var unpack = ""
  for p in h.params:
    hctx.definedVars.incl(p.name)
    unpack.add(ind & "\t\t" & p.name & " := msg." & p.name & "\n")
  ind & "\tcase ." & msgVariantName(h.name) & ":\n" & unpack &
    hctx.genOdinExpr(h.body)

proc genDispatch*(ctx: var OdinCodegenCtx, d: Decl, handlers: seq[ActorMsgHandler],
                 shutdownBody: Expr, hasShutdown: bool, ind: string): string =
  ## The switch that routes an envelope to its handler.
  var hctx = ctx.newHandlerCtx(d)
  var cases: seq[string]
  for h in handlers:
    cases.add(hctx.genHandlerCase(h, ind))
  if hasShutdown:
    # Stops the actor rather than adding a message: run the arm's body, then
    # set the flag the drain checks.
    let sdBody = if shutdownBody != nil: hctx.genOdinExpr(shutdownBody) & "\n"
                 else: ""
    cases.add(ind & "\tcase .msgShutdown:\n" & sdBody &
              ind & "\t\tself.finished = true")
  ctx.adoptHandlerCtx(hctx)
  ind & "handleMsg_" & d.name & " :: proc(self: ^" & d.name & ", msg: " &
    d.name & "Msg) {\n" & ind & "\tswitch msg.kind {\n" & cases.join("\n") &
    "\n" & ind & "\t}\n" & ind & "}\n"

proc genDrain*(d: Decl, hasShutdown: bool, ind: string): string =
  ## The actor's coroutine body. Parks when the mailbox empties;
  ## tuckNotifySend wakes it after a send.
  let singleton = actorSingletonName(d.name)
  let finishedGuard = if hasShutdown:
                        ind & "\t\tif " & singleton & ".finished { return }\n"
                      else: ""
  "\n" & ind & "drain_" & d.name & " :: proc() {\n" &
    ind & "\tfor {\n" & finishedGuard &
    ind & "\t\tmsg: " & d.name & "Msg\n" &
    ind & "\t\tfor rt.dequeue(&" & singleton & ".mailbox, &msg) {\n" &
    ind & "\t\t\thandleMsg_" & d.name & "(&" & singleton & ", msg)\n" &
    ind & "\t\t}\n" & ind & "\t\trt.coroYield()\n" &
    ind & "\t}\n" & ind & "}\n"

proc genSendHelper*(ctx: var OdinCodegenCtx, d: Decl, h: ActorMsgHandler,
                   ind: string): string =
  ## Enqueue an envelope; a full ring drops (spec §9.1).
  var params: seq[string]
  var ctorArgs = "kind = ." & msgVariantName(h.name)
  for p in h.params:
    params.add(p.name & ": " & ctx.odinType(p.typ))
    ctorArgs.add(", " & p.name & " = " & p.name)
  let sep = if params.len > 0: ", " else: ""
  "\n" & ind & "send" & h.name.capitalize() & "_" & d.name & " :: proc(self: ^" &
    d.name & sep & params.join(", ") & ") {\n" &
    ind & "\t_ = rt.enqueue(&self.mailbox, " & d.name & "Msg{" & ctorArgs &
    "})\n" & ind & "}\n"

proc genShutdownSender*(d: Decl, ind: string): string =
  "\n" & ind & "sendShutdown_" & d.name & " :: proc(self: ^" & d.name &
    ") {\n" & ind & "\t_ = rt.enqueue(&self.mailbox, " & d.name &
    "Msg{kind = .msgShutdown})\n" & ind & "}\n"

proc genActor*(ctx: var OdinCodegenCtx, d: Decl): string =
  ## An actor emits its message envelope, state struct, singleton, dispatch,
  ## drain loop and one send helper per handler.
  ##
  ## BOTH forms declare a message: `on add({n: int})` and an
  ## `| add -> {n: int}` select arm. Walking only dkFn made every `on select`
  ## actor take the no-handler path, which emits no enum, no mailbox and no
  ## send procs — while the send SITES still called them, so the package did
  ## not compile.
  let ind = "  ".repeat(ctx.indent)
  let (handlers, shutdownBody, hasShutdown) = collectHandlers(d)
  var variants: seq[string]
  for h in handlers: variants.add(msgVariantName(h.name))
  if hasShutdown:
    variants.add("msgShutdown")   # sent as `Actor send shutdown {}`
  if variants.len == 0:
    return ctx.genInertActor(d, ind)
  result = ctx.genMsgEnvelope(d, handlers, variants, ind)
  result.add(ctx.genActorState(d, hasShutdown, ind))
  # One instance per declared actor (spec §9.1); sends and field reads target
  # it, so `Counter.total` means `counterSingleton.total`.
  result.add(ind & actorSingletonName(d.name) & ": " & d.name & "\n\n")
  result.add(ctx.genDispatch(d, handlers, shutdownBody, hasShutdown, ind))
  result.add(genDrain(d, hasShutdown, ind))
  for h in handlers:
    result.add(ctx.genSendHelper(d, h, ind))
  if hasShutdown:
    result.add(genShutdownSender(d, ind))

proc registryEventStruct*(ctx: var OdinCodegenCtx, d: Decl, ind: string): string =
  ## The event enum and the flat struct carrying every variant's fields,
  ## deduped by name.
  var variants: seq[string]
  var fields: seq[string]
  var seen = initHashSet[string]()
  for v in d.variants:
    variants.add(v.name)
    for f in v.fields:
      if f.name in seen: continue
      seen.incl(f.name)
      fields.add(ind & "\t" & f.name & ": " & ctx.odinType(f.typ) & ",")
  let fieldsBody = if fields.len > 0: fields.join("\n") & "\n" else: ""
  ind & d.name & "Kind :: enum { " & variants.join(", ") & " }\n" &
    ind & d.name & " :: struct {\n" &
    ind & "\tkind: " & d.name & "Kind,\n" & fieldsBody & ind & "}\n"

proc registryHandlerCalls*(ctx: OdinCodegenCtx, d: Decl, v: VariantDef,
                          ind: string): string =
  ## Every declared handler for this event, called with the event's fields.
  let handlerName = d.name & "." & v.name
  var calls: seq[string]
  for decl in ctx.module.decls:
    if decl.kind != dkFn or decl.name != handlerName: continue
    var argNames: seq[string]
    for f in v.fields: argNames.add(f.name)
    calls.add(ind & "\t" & d.name & "_" & v.name & "(" & argNames.join(", ") & ")")
  if calls.len > 0: calls.join("\n") & "\n" else: ""

proc registryRaiseProc*(ctx: var OdinCodegenCtx, d: Decl, v: VariantDef,
                       ind: string): string =
  ## `raise_<Registry>_<Event>` — record the event as latest, then run its
  ## handlers.
  var params: seq[string]
  var assigns: seq[string]
  for f in v.fields:
    params.add(f.name & ": " & ctx.odinType(f.typ))
    assigns.add(f.name & " = " & f.name)
  let assignStr = if assigns.len > 0: ", " & assigns.join(", ") else: ""
  ind & "raise_" & d.name & "_" & v.name & " :: proc(" & params.join(", ") &
    ") {\n" & ind & "\tlatest" & d.name & " = " & d.name & "{kind = ." &
    v.name & assignStr & "}\n" & ctx.registryHandlerCalls(d, v, ind) &
    ind & "}\n\n"

proc genRegistry*(ctx: var OdinCodegenCtx, d: Decl): string =
  ## An event registry: the event type, the latest-event global, and one
  ## raise proc per event.
  ##
  ## Odin resolves package-level declaration order lazily, so the raise procs
  ## may call handlers declared after them — no forward decls needed.
  let ind = "  ".repeat(ctx.indent)
  result = ctx.registryEventStruct(d, ind) & "\n"
  result.add(ind & "latest" & d.name & ": " & d.name & "\n\n")
  for v in d.variants:
    result.add(ctx.registryRaiseProc(d, v, ind))

proc forwarderParamType*(ctx: var OdinCodegenCtx, p: Param, mem: Decl): string =
  ## A bare `fn` param on an extern (std/scheduler's `waitUntil {pred: fn}`)
  ## is a PREDICATE the runtime calls, so it needs a callable proc type —
  ## `rawptr` would not convert at the rt boundary.
  ##
  ## Odin marks a polymorphic param at the DECLARATION site: `value: $T`, not
  ## `value: T`. Without the sigil T is an undeclared name, so any generic
  ## extern forwarder (std/str's toStr) failed to compile.
  let named = p.typ != nil and p.typ.kind == tkNamed
  if named and p.typ.name == "fn": return "proc() -> bool"
  result = ctx.odinType(p.typ)
  if named and p.typ.name in mem.fnGenerics: result = "$" & result

proc recordFromFields*(ctx: var OdinCodegenCtx, fields: seq[FieldDef],
                      source: string): string =
  ## Rebuild a record from `source`'s same-named fields — the runtime's shape
  ## and this module's hoisted shape agree on names, not on identity.
  var args: seq[string]
  for f in fields: args.add(f.name & " = " & source & "." & f.name)
  recStructName(ctx, fields) & "{" & args.join(", ") & "}"

proc forwardWrappedRecord*(ctx: var OdinCodegenCtx, innerT: Type,
                          callStr, retTypeStr, ind: string): string =
  ## Convert TuckResult(RuntimeShape) -> TuckResult(ModuleShape) field by field.
  ind & "\tr := " & callStr & "\n" &
    ind & "\tres: " & retTypeStr & "\n" &
    ind & "\tres.status = r.status\n" &
    ind & "\tres.err = r.err\n" &
    ind & "\tif r.status == .Ok {\n" &
    ind & "\t\tres.value = " & ctx.recordFromFields(innerT.fields, "r.value") &
    "\n" & ind & "\t}\n" & ind & "\treturn res\n"

proc forwardRecord*(ctx: var OdinCodegenCtx, retT: Type,
                   callStr, ind: string): string =
  ## Plain record return: the runtime returns the single raw value, whose
  ## fields carry the same names as this module's hoisted shape.
  ind & "\traw := " & callStr & "\n" &
    ind & "\treturn " & ctx.recordFromFields(retT.fields, "raw") & "\n"

proc implAlias*(module: string): string =
  ## Package alias for an `impl: odin "..."` spec. Odin import paths use both
  ## ':' (collection separator, "core:strings") and '/' (subdirectories), and
  ## the last segment is the package name: "core:strings" -> strings,
  ## "./tuckrt/zlib_shim" -> zlib_shim.
  result = module
  if ':' in result: result = result.rsplit(':', 1)[^1]
  if '/' in result: result = result.rsplit('/', 1)[^1]

proc genRtForwarder*(ctx: var OdinCodegenCtx, mem: Decl, alias = "rt"): string =
  ## `alias` is the package the bodies live in: the runtime (`rt`) by default,
  ## or an `impl: odin "..."` package. Only the call prefix differs — the shape
  ## conversions below are the same either way, so they are not duplicated.
  let ind = "  ".repeat(ctx.indent)
  var params: seq[string]
  var argNames: seq[string]
  for p in mem.fnParams:
    params.add(p.name & ": " & ctx.forwarderParamType(p, mem))
    argNames.add(p.name)
  let callStr = alias & "." & mem.name & "(" & argNames.join(", ") & ")"
  let (bw, _, binnerT) = ctx.odinBangInfo(mem.fnReturnType)
  let retTypeStr = if mem.fnReturnType != nil: ctx.odinType(mem.fnReturnType)
                   else: "void"
  let retStr = if retTypeStr != "void": " -> " & retTypeStr else: ""
  let header = ind & mem.name & " :: proc(" & params.join(", ") & ")" &
               retStr & " {\n"
  let body =
    if bw and binnerT != nil and binnerT.kind == tkRecord:
      ctx.forwardWrappedRecord(binnerT, callStr, retTypeStr, ind)
    elif mem.fnReturnType != nil and mem.fnReturnType.kind == tkRecord:
      ctx.forwardRecord(mem.fnReturnType, callStr, ind)
    elif retTypeStr == "void":
      ind & "\t" & callStr & "\n"
    else:
      ind & "\treturn " & callStr & "\n"
  header & body & ind & "}\n"

proc genObjectDecl*(ctx: var OdinCodegenCtx, d: Decl, ind: string): string =
  ## A manager object: fields become an Odin struct, members and anything
  ## composed into it come back as package-level procs.
  var fields: seq[string]
  for f in d.objFields:
    fields.add(ind & "\t" & f.name & ": " & ctx.fieldType(d.name, f) & ",")
  var members = ""
  for member in d.objMembers:
    # lowering.composeObject has already merged every RESOLVED `+ X`. What
    # can still reach here is one that named nothing declared — a sketch.
    if isCompositionEntry(member):
      members.add(ind & "// + " & compositionTargetName(member) &
                  " (undeclared — sketch)\n")
    elif member.kind == dkFn:
      members.add(ctx.genOdinMemberFn(member, d.name) & "\n")
    else:
      members.add(ctx.genOdinDecl(member) & "\n")
  let body = if fields.len > 0: fields.join("\n") & "\n" else: ""
  # manager objects hold var state but are Tier 1 value types too
  ind & d.name & " :: struct {\n" & body & ind & "}\n\n" & members

proc genTaskDecl*(ctx: var OdinCodegenCtx, d: Decl, ind: string): string =
  ## ponytail: a task emits as a plain proc and runs INLINE, so suspension
  ## points do not suspend. The coroutine runtime itself is real and wired
  ## (tuckrt/tuck_coro.odin over minicoro — 28-async-task exits 42 and
  ## 26-actor-run drains its mailbox to 55); what is missing is spawning the
  ## task body ONTO it. Anything relying on a yield behaves synchronously.
  ctx.currentParams = @[]
  var params: seq[string]
  for p in d.taskParams:
    ctx.currentParams.add(FieldDef(name: p.name, typ: p.typ, span: p.span))
    params.add(p.name & ": " & ctx.odinType(p.typ))
  let retTypeStr =
    if d.taskReturnType != nil: ctx.odinType(d.taskReturnType) else: "void"
  let retStr = if retTypeStr != "void": " -> " & retTypeStr else: ""
  let header = ind & d.name & " :: proc(" & params.join(", ") & ")" &
               retStr & " {"
  let oldVars = ctx.definedVars
  for p in d.taskParams: ctx.definedVars.incl(p.name)
  let oldIndent = ctx.indent
  (ctx.retWrapped, ctx.retInnerOdin, ctx.retInnerT) =
    ctx.odinBangInfo(d.taskReturnType)
  injectTailReturn(d.taskBody, retTypeStr)
  var bodyStr = ctx.genOdinExpr(d.taskBody)
  if d.taskBody != nil and d.taskBody.kind != exkBlock:
    let kw = if retTypeStr != "void": "return " else: ""
    bodyStr = ind & "\t" & kw & bodyStr
  elif retTypeStr != "void":
    bodyStr = ensureTrailingReturn(bodyStr, d.taskBody, oldIndent)
  ctx.indent = oldIndent
  ctx.retWrapped = false
  ctx.retInnerOdin = ""
  ctx.retInnerT = nil
  ctx.definedVars = oldVars
  header & "\n" & bodyStr & "\n" & ind & "}\n"

proc isBlank*(code: string): bool =
  ## Does this emitted body amount to nothing? A handler whose body generated
  ## only whitespace or an empty block adds no statements.
  for c in code:
    if c notin {' ', '\n', '\t', '{', '}'}: return false
  true

proc genErrHandlerBody*(ctx: var OdinCodegenCtx, handler: Decl): string =
  ## The user's handler body, with `code` and `site` in scope as its params.
  let savedVars = ctx.definedVars
  ctx.definedVars.incl("code")
  ctx.definedVars.incl("site")
  result = ctx.genIndented(handler.fnBody)
  ctx.definedVars = savedVars
  if isBlank(result): result = ""

proc genErrHandler*(ctx: var OdinCodegenCtx, d: Decl, ind: string): string =
  ## Global handler: rt logger first (errors are always visible), then the
  ## user's handler body.
  result = ind & "tuck_unhandled :: proc(code: u16, site: string) {\n" &
           ind & "\trt.tuckReportUnhandled(code, site)\n"
  if d.errHandler != nil and d.errHandler.fnBody != nil:
    let body = ctx.genErrHandlerBody(d.errHandler)
    if body != "": result.add(body & "\n")
  result.add(ind & "}\n")

proc genCBinding*(ctx: var OdinCodegenCtx, m: Decl): string =
  ## One `foreign` entry. `-> ret` is omitted entirely for void; "void" is
  ## Tuck's internal sentinel, not an Odin type. [emit: "c_name"] names the
  ## real C symbol; else the Tuck name — externs are not mangled
  ## (mangle.nim:48), so m.name IS the foreign symbol.
  var params: seq[string]
  for prm in m.fnParams:
    params.add(prm.name & ": " & ctx.odinType(prm.typ))
  let retT = if m.fnReturnType != nil: ctx.odinType(m.fnReturnType) else: "void"
  let retStr = if retT == "void": "" else: " -> " & retT
  let cName = if m.externEmit != "": m.externEmit else: m.name
  "\t" & cName & " :: proc(" & params.join(", ") & ")" & retStr & " ---"

proc genImplForwarders*(ctx: var OdinCodegenCtx, m: Decl): string =
  ## `impl: odin "..."` — the bodies live in a named Odin package rather than
  ## the runtime. Odin has no unqualified import, so a bare call to the
  ## extern's name can never resolve; emit a local forwarder into the aliased
  ## package instead, which keeps call sites identical to Nim's.
  ##
  ## An `impl:` naming only `nim` leaves nothing to emit here: that block is
  ## Nim-backend-only and Odin fails at the undeclared call, which is the
  ## honest outcome.
  for (backend, module) in m.externImpl:
    if backend != "odin": continue
    let alias = implAlias(module)
    ctx.implMods[alias] = module
    result.add(ctx.genRtForwarder(m, alias) & "\n")

proc foreignLibAlias*(cLib: string): string =
  ## A path (vendored `.a`) cannot double as the Odin alias, so the alias is
  ## derived from the file stem and the path rides along as the import spec.
  ## ".../libpoint.a" -> "point".
  if cLib == "": return "c"
  if '/' notin cLib and '.' notin cLib: return cLib
  var stem = cLib.rsplit('/', 1)[^1]
  if stem.startsWith("lib"): stem = stem[3 .. ^1]
  stem.rsplit('.', 1)[0]

proc genForeignBlock*(ctx: var OdinCodegenCtx, bindings: seq[string],
                     cLib: string): string =
  ## `foreign import <alias> "<spec>"` — mirrors tuck_coro.odin's minicoro.a.
  ## The import line itself is hoisted to the file header by emitOdin, since
  ## it is only legal at package top level.
  let libAlias = foreignLibAlias(cLib)
  ctx.foreignLibs[libAlias] = cLib
  "@(default_calling_convention=\"c\")\n" &
    "foreign " & libAlias & " {\n" & bindings.join("\n") & "\n}\n"

proc genMixinMember*(ctx: var OdinCodegenCtx, m: Decl, cBindings: var seq[string],
                    cLib: var string): string =
  ## One member of a mixin/extern/pending block. A C binding is collected
  ## rather than emitted, because Odin wants ONE `foreign <lib> { ... }` block
  ## rather than a pragma per proc the way Nim's importc works.
  if m.kind in {dkType, dkFnSig}:
    # a C struct or callback signature declared in the extern block. Odin needs
    # no pragma for the struct: it never sees the C header, it links object
    # code, so a plain struct with matching fields IS the ABI declaration. The
    # callback does need `proc "c"` — see genOdinDecl.
    return ctx.genOdinDecl(m) & "\n"
  if m.kind != dkFn: return ""
  if m.isPending: return ctx.genPendingStub(m) & "\n"
  if not m.isExtern:
    # interface contract (sig only): nothing to emit
    if m.fnBody == nil or takesSelf(m): return ""
    # a mixin is a named bucket of functions (spec 5.1) — emit them
    return ctx.genOdinDecl(m) & "\n"
  if m.externHeader != "":
    cBindings.add(ctx.genCBinding(m))
    if m.externLib != "": cLib = m.externLib
    return ""
  if m.externImpl.len > 0: return ctx.genImplForwarders(m)
  # rt-implemented (no header, no impl): forward to the runtime. Used to be
  # gated on modPrefix != "" — a library module needs the forwarder so a
  # CROSS-module caller has something to qualify (`console.printLine`
  # reaches a real proc); the entry module was assumed never to declare its
  # own rt-implemented extern, since std/* modules normally carry those.
  # Examples 29/30 declare one directly (`openSource`, a demo async source)
  # and broke that assumption: with no forwarder, the entry module's own
  # bare call to it names nothing Odin has ever declared. The forwarder is
  # harmless here too — a plain top-level proc in package main, same as any
  # other top-level fn.
  ctx.genRtForwarder(m) & "\n"

proc genMixinBlock*(ctx: var OdinCodegenCtx, d: Decl): string =
  ## Pending blocks parse as a mixin named "pending"; emit stubs for members.
  ## Extern blocks: rt-implemented fns forward to the Odin runtime (library
  ## modules) or emit nothing (entry module); C-imported fns become an Odin
  ## `foreign` block with concrete param types.
  var cBindings: seq[string]
  var cLib = ""
  for m in d.mixinMembers:
    result.add(ctx.genMixinMember(m, cBindings, cLib))
  if cBindings.len > 0:
    result.add(ctx.genForeignBlock(cBindings, cLib))

proc decodeBitField*(regName: string, f: FieldDef): BitField =
  ## `bits 3..7` is a multi-bit FIELD: shift by the low bit and mask the width.
  ## A single `bit N` is the one-bit case of the same shape.
  let bitVal = f.typ.name.replace("bit ", "").replace("bits ", "")
  let dotPos = bitVal.find("..")
  result.loBit = if dotPos >= 0: bitVal[0 ..< dotPos].strip() else: bitVal
  result.hiBit = if dotPos >= 0: bitVal[dotPos + 2 .. ^1].strip() else: bitVal
  result.isRange = dotPos >= 0 and result.loBit != result.hiBit
  result.prefix = regName & "_" & f.name
  var hasRead, hasWrite = false
  for a in f.attrs:
    if a.name == "read": hasRead = true
    elif a.name == "write": hasWrite = true
  # An unmarked field is readable AND writable; marking one direction opts out
  # of the other.
  result.canRead = hasRead or not hasWrite
  result.canWrite = hasWrite or not hasRead

proc bitConsts*(bf: BitField, ind: string): seq[string] =
  ## The shift, and for a range the width and mask.
  result.add(ind & bf.prefix & "_SHIFT :: " & bf.loBit)
  if bf.isRange:
    result.add(ind & bf.prefix & "_WIDTH :: " & bf.hiBit & " - " & bf.loBit &
               " + 1")
    result.add(ind & bf.prefix & "_MASK :: u32(1 << u32(" & bf.prefix &
               "_WIDTH)) - 1")

proc bitGetter*(bf: BitField, regName, ind: string): string =
  ## A range reads as a masked u32; a single bit reads as a bool.
  let body = if bf.isRange:
               "return (" & regName & "^ >> u32(" & bf.prefix & "_SHIFT)) & " &
                 bf.prefix & "_MASK"
             else:
               "return (" & regName & "^ & (u32(1) << u32(" & bf.prefix &
                 "_SHIFT))) != 0"
  let retT = if bf.isRange: "u32" else: "bool"
  ind & bf.prefix & "_get :: proc() -> " & retT & " {\n" &
    ind & "\t" & body & "\n" & ind & "}\n"

proc bitSetter*(bf: BitField, regName, ind: string): string =
  ## A range clears its mask before OR-ing the shifted value in; a single bit
  ## sets or clears one mask.
  if bf.isRange:
    return ind & bf.prefix & "_set :: proc(value: u32) {\n" &
           ind & "\tshifted := (value & " & bf.prefix & "_MASK) << u32(" &
             bf.prefix & "_SHIFT)\n" &
           ind & "\t" & regName & "^ = (" & regName & "^ &~ (" & bf.prefix &
             "_MASK << u32(" & bf.prefix & "_SHIFT))) | shifted\n" &
           ind & "}\n"
  ind & bf.prefix & "_set :: proc(on: bool) {\n" &
    ind & "\tmask := u32(1) << u32(" & bf.prefix & "_SHIFT)\n" &
    ind & "\tif on { " & regName & "^ |= mask } else { " & regName &
      "^ &~= mask }\n" & ind & "}\n"

proc genRegister*(ctx: OdinCodegenCtx, d: Decl, ind: string): string =
  ## Memory-mapped register. Nim emits a `registerMMIO` macro call and Beef an
  ## attribute; Odin has neither, so the bits become named masks plus a typed
  ## pointer at the MMIO address — the accessors read/write through it.
  var consts: seq[string]
  var accessors: seq[string]
  for f in d.regFields:
    let bf = decodeBitField(d.name, f)
    consts.add(bitConsts(bf, ind))
    if bf.canRead: accessors.add(bitGetter(bf, d.name, ind))
    if bf.canWrite: accessors.add(bitSetter(bf, d.name, ind))
  ind & d.name & " := cast(^u32)(uintptr(" & d.regAddress & "))\n" &
    consts.join("\n") & "\n" & accessors.join("")

proc genOdinDecl*(ctx: var OdinCodegenCtx, d: Decl): string =
  if d == nil: return ""
  if d.kind == dkType and d.span.file.startsWith(ImportedTypeMarker):
    return ""  # defined in its own module; that module's Odin file has it
  let ind = "  ".repeat(ctx.indent)
  case d.kind
  of dkFn:
    return ctx.genOdinFnDecl(d)
  of dkType:
    if d.typeBody != nil:
      if d.typeBody.kind == tkSum:
        return ctx.genSumType(d)
      elif d.typeBody.kind == tkRecord:
        return ctx.genRecordType(d)
      else:
        return ctx.genAliasType(d)
    return ""
  of dkObject:
    return ctx.genObjectDecl(d, ind)
  of dkActor:
    return ctx.genActor(d)
  of dkTask:
    return ctx.genTaskDecl(d, ind)
  of dkConst:
    # A literal is a true compile-time constant (`::`); structured data
    # becomes a package-level var, still one-time and immutable in intent.
    if d.constVal != nil and d.constVal.kind == exkLit:
      return ind & d.name & " :: " & ctx.genOdinExpr(d.constVal)
    return ind & d.name & " := " & ctx.genOdinExpr(d.constVal)
  of dkExpr:
    return ctx.genOdinExpr(d.expr)
  of dkRegister: ctx.genRegister(d, ind)
  of dkRegistry:
    return ctx.genRegistry(d)
  of dkImport:
    return ""  # emitOdin has no import lines; same project, same namespace
  of dkStaticAssert:
    ctx.staticAsserts.add(ctx.genOdinExpr(d.assertExpr))
    return ""
  of dkErrors: ctx.genErrHandler(d, ind)
  of dkMixin, dkExtern, dkPending: ctx.genMixinBlock(d)
  of dkPool:
    # spec 7.2: one package-level instance; acquire/release are the runtime's
    # generic procs, reached as `Pool.acquire` -> `rt.acquire(&Pool)`.
    # The Beef backend has no arm for this — parity is with codegen.nim.
    return ind & d.name & ": rt.ObjectPool(" & ctx.odinType(d.poolElem) &
           ", " & $d.poolCount & ")\n"
  of dkFnSig:
    # `fnsig NAME = {params} -> ret` → a named Odin proc type, used for
    # callback slots. The Beef backend has no arm for this at all.
    #
    # Generic (`fnsig NAME[T, ...]`): Odin's proc TYPES are not parametric
    # the way Nim's `proc(...): U {.closure.}` type alias is — there is no
    # direct equivalent to emit yet (Odin's own generics are `$T` parapoly
    # procs, a different mechanism). Die loudly rather than emit the bare
    # `T`/`U` names as if they were real, undeclared types.
    if d.sigGenerics.len > 0:
      discard odinUnsupported("a generic fnsig ('" & d.name & "')")
    var params: seq[string]
    for prm in d.sigParams:
      params.add(prm.name & ": " & ctx.odinType(prm.typ))
    let retStr =
      if d.sigReturn != nil and not (d.sigReturn.kind == tkNamed and
                                     d.sigReturn.name == "void"):
        " -> " & ctx.odinType(d.sigReturn)
      else: ""
    # A C callback is a bare function pointer using the C calling convention:
    # `proc "c" (...)`. Odin's default convention differs, so passing a plain
    # proc to a C function pointer would be an ABI mismatch.
    let conv = if d.sigIsCCallback: "\"c\" " else: ""
    return ind & d.name & " :: proc " & conv & "(" & params.join(", ") & ")" &
           retStr & "\n"
  of dkInterface:
    # A VARIANT over the satisfying types, copied in — mirrors the Nim backend
    # (spec §5.3). Odin's tagged union does what Nim's case-object does: the
    # payload is the object itself, so the value owns its data and there is no
    # lifetime question.
    let sats = ctx.satisfiersOf(d.name)
    if sats.len == 0:
      return ind & "// interface " & d.name & ": no satisfying types\n"
    var tags: seq[string]
    var fields: seq[string]
    for st in sats:
      tags.add(d.name & "_is_" & st.name)
      fields.add(ind & "\t" & st.name & "Val: " & st.name & ",")
    result = ind & d.name & "Tag :: enum { " & tags.join(", ") & " }\n\n"
    result.add(ind & d.name & " :: struct {\n" &
               ind & "\ttag: " & d.name & "Tag,\n" &
               fields.join("\n") & "\n" & ind & "}\n")
    return result
  else:
    return ""
