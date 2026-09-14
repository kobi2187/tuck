# compiler/codegen_decl.nim
#
# Declaration codegen for the Nim backend: genDecl's dispatch (one arm per
# DeclKind) and everything it calls — fn/object/actor/registry/register/
# mixin/decision-table/err-handler. Calls INTO codegen.nim's genExpr for fn
# bodies (one-way: genExpr never calls back into anything here).
import ast, strutils, sets, tables
import mangle   # mangleName — a requirement's emitted spelling, for `mixin`
import resolution
import ast_query
import codegen_common, codegen_type, codegen_table
import codegen_ctx
import ./codegen

proc genDecl*(ctx: var CodegenCtx, d: Decl): string
  ## Forward-declared: genRecordType (manager-type member fns) recurses
  ## into it before its own definition.

proc genPendingStub*(d: Decl): string =
  # Tuck call sites pass one whole payload struct; the Tuck checker already
  # verified its shape against the pending signature. The Nim stub is generic
  # so any payload representation is absorbed.
  let fnNameSanitized = d.name.replace(".", "_").replace("::", "_")
  let retTypeStr = if d.fnReturnType != nil: genType(d.fnReturnType) else: "void"
  let paramStr = if d.fnParams.len > 0: "[T](payload: T)" else: "()"
  return "proc " & fnNameSanitized & "*" & paramStr & ": " & retTypeStr &
         " =\n  stderr.writeLine(\"TUCK PENDING: " & d.name & " invoked (not implemented)\")\n"

proc decisionRows*(ctx: var CodegenCtx, d: Decl): (seq[seq[string]], seq[string]) =
  ## The table's rows as (pattern strings per column, emitted body).
  var pats: seq[seq[string]]
  var bodies: seq[string]
  for s in d.fnBody.stmts:
    if s.kind != exkMatch or s.arms.len == 0: continue
    let pat = s.arms[0].pattern
    var row: seq[string]
    for el in (if pat != nil and pat.kind == pkTuple: pat.elems else: @[pat]):
      row.add(genPatternStr(el))
    pats.add(row)
    bodies.add(ctx.genExpr(s.arms[0].body))
  (pats, bodies)

proc genPackedTable*(ctx: var CodegenCtx, d: Decl, header: string,
                    domains: seq[seq[string]], comboCount: int): string =
  ## Bitmask/packed path (spec 6.1): when every column is enumerable the whole
  ## table becomes one `case` over an integer key — no comparison chains at
  ## runtime. The last group is the `else`, so the case is total.
  let (rowPats, bodies) = ctx.decisionRows(d)
  let groups = groupByOutcome(domains, comboCount, rowPats, bodies)
  var lines = @["  case " & packedKeyExpr(d, domains, comboCount) &
                "   # packed decision key"]
  for gi, g in groups:
    if gi == groups.len - 1:
      lines.add("  else: return " & g.outcome)
    else:
      var ks: seq[string]
      for k in g.keys: ks.add($k)
      lines.add("  of " & ks.join(", ") & ": return " & g.outcome)
  header & "\n" & lines.join("\n") & "\n"

proc genConditionChain*(ctx: var CodegenCtx, d: Decl, header: string): string =
  ## Fallback when some column is not enumerable: an if/elif chain comparing
  ## each param against its pattern. A row of all-`_` becomes the `else`.
  var lines: seq[string]
  for idx, s in d.fnBody.stmts:
    let arm = s.arms[0]
    var conds: seq[string]
    for i, pat in arm.pattern.elems:
      let patStr = genPatternStr(pat)
      if patStr != "_": conds.add(d.fnParams[i].name & " == " & patStr)
    let body = ctx.genExpr(arm.body)
    if conds.len == 0:
      lines.add("  else:\n    return " & body)
    else:
      let prefix = if idx == 0: "if " else: "elif "
      lines.add("  " & prefix & conds.join(" and ") & ":\n    return " & body)
  header & "\n" & lines.join("\n") & "\n"

proc genDecisionFn*(ctx: var CodegenCtx, d: Decl, fnNameSanitized: string): string =
  ## A decision table compiles to one of two shapes: a packed `case` when
  ## every column is enumerable, an if/elif chain otherwise.
  var params: seq[string]
  for p in d.fnParams:
    params.add(p.name & ": " & genType(p.typ))
  let retTypeStr = if d.fnReturnType != nil: genType(d.fnReturnType) else: "void"
  let header = "proc " & fnNameSanitized & "*(" & params.join(", ") & "): " &
               retTypeStr & " ="
  let (domains, allEnum, comboCount) = columnDomains(ctx.module, d)
  if allEnum and comboCount > 0 and comboCount <= MaxPackedCombos:
    return ctx.genPackedTable(d, header, domains, comboCount)
  ctx.genConditionChain(d, header)

proc fnHeaderNim*(name, genericStr: string, params: seq[string],
                  retTypeStr, inlineStr: string, exported = true): string =
  ## A fn's Nim signature, without the trailing ` =`. Shared by the definition
  ## and by the forward declaration emitNim writes ahead of the body, so the
  ## two cannot drift — Nim rejects a forward declaration whose signature
  ## differs from its definition by so much as a pragma.
  ##
  ## `exported` is the `public:` block reaching the emitted artifact (spec
  ## 2.3c): a name the module does not export gets no `*`, so it is invisible
  ## outside the emitted Nim module too, not merely to the Tuck checker.
  ## Defaults true — a module with no public block exports everything.
  "proc " & name & (if exported: "*" else: "") & genericStr &
    "(" & params.join(", ") & "): " & retTypeStr & inlineStr

proc nimFnParams*(res: Resolution, m: Module, d: Decl): seq[string] =
  ## The emitted parameter list, built ONCE — genFnDecl and fnForwardDecls
  ## both need it and Nim requires them to agree exactly, so a `sink` added
  ## to one and not the other is "type mismatch" on the forward declaration.
  ##
  ## PARAMS ARE NEVER `var`. In Nim, `var` on a parameter is not write
  ## permission — it is a by-reference pass — so emitting it for every record
  ## param meant a callee could write through to the CALLER's record, which
  ## spec §7.1 says is impossible. A fn that read like a preview
  ## (`{acct, fee} afterFee`) silently withdrew the money. Dropping it is
  ## free: verified in the emitted C, a `var Big` param and a plain `Big`
  ## param have byte-identical signatures (both `Big*`). The exception is
  ## `self` in an object member, emitted by genMemberFn below.
  ##
  ## `sink` is not write permission either: it says the CALLER is finished
  ## with the value, so the callee may move out of it rather than copy. Which
  ## parameters qualify is our own analysis's answer (analysis_lastuse), not
  ## Nim's inference — Odin and D are handed the same fact.
  for p in d.fnParams:
    let move = if paramIsMovable(res, m, d.fnBody, p): "sink " else: ""
    result.add(p.name & ": " & move & genType(p.typ))

proc groupMixins(ctx: CodegenCtx, d: Decl): string =
  ## `mixin` for every requirement a group-bounded generic may call.
  ##
  ## Nim binds symbols in a generic body at DEFINITION scope. A group's whole
  ## point is that the satisfying fn arrives from somewhere the abstraction
  ## does not know — so the module declaring `fn smallerOf[T: Sortable]` has
  ## no `compare` in scope and Nim answers "undeclared identifier". `mixin`
  ## marks the name open: resolution moves to each INSTANTIATION site, where
  ## the concrete type's provider is visible. That is exactly what a group
  ## bound means, so the mapping is one-to-one.
  ##
  ## Deliberately NOT the Odin/D approach of importing the provider's module.
  ## Importing works for them, but it makes the abstraction depend on its
  ## implementations, and it CANNOT work when the provider imports the
  ## abstraction back — a plain arrangement (`compare` needs the group's
  ## `Order`) that Odin rejects outright as a cyclic import. `mixin` adds no
  ## import at all, so it is correct in both shapes.
  if d.kind != dkFn or d.fnGenericBounds.len == 0: return ""
  var names: seq[string]
  for bounds in d.fnGenericBounds:
    for b in bounds:
      let gname = groupNameOf(b)
      if gname == "": continue
      var g = ctx.module.findDecl(dkGroup, gname)
      if g == nil:
        for _, im in ctx.realModules:
          g = im.findDecl(dkGroup, gname)
          if g != nil: break
      if g == nil: continue
      for want in g.groupMembers:
        if want == nil or want.kind != dkFn: continue
        let n = mangleName(want.name)
        if n notin names: names.add(n)
  if names.len == 0: return ""
  "  mixin " & names.join(", ") & "\n"

proc genFnDecl*(ctx: var CodegenCtx, d: Decl): string =
    if d.isPending:
      return genPendingStub(d)
    ctx.currentParams = @[]
    for p in d.fnParams:
      ctx.currentParams.add(FieldDef(name: p.name, typ: p.typ, span: p.span))
    let fnNameSanitized = d.name.replace(".", "_")
    if d.isDecision or d.isDecisionTable():
      return ctx.genDecisionFn(d, fnNameSanitized)

    let params = nimFnParams(ctx.res, ctx.module, d)
    let retTypeStr = if d.fnReturnType != nil: genType(d.fnReturnType) else: "void"
    # Generic fns pass their type params straight through — Nim monomorphizes
    let genericStr = if d.fnGenerics.len > 0: "[" & d.fnGenerics.join(", ") & "]" else: ""
    let inlineStr = if d.isInline: " {.inline.}" else: ""
    let header = fnHeaderNim(fnNameSanitized, genericStr, params, retTypeStr,
                             inlineStr,
                             isExportedDecl(ctx.module, d)) & " ="
    let oldVars = ctx.definedVars
    for p in d.fnParams:
      ctx.definedVars.incl(p.name)
    let oldIndent = ctx.indent
    let (bw, binner, binnerT) = bangInfo(d.fnReturnType)
    ctx.retWrapped = bw
    ctx.retAbsentCapable = absentCapable(d.fnReturnType)
    ctx.retInnerNim = binner
    ctx.retInnerT = binnerT
    ctx.retInvName =
      if not bw and d.fnReturnType != nil and d.fnReturnType.kind == tkNamed and
         ctx.hasInvariantsFast(d.fnReturnType.name): d.fnReturnType.name
      else: ""
    injectTailReturn(d.fnBody, retTypeStr)
    let bodyStr = ctx.genFnBody(d.fnBody, "  ".repeat(ctx.indent))
    ctx.indent = oldIndent
    ctx.retWrapped = false
    ctx.retAbsentCapable = false
    ctx.definedVars = oldVars
    return header & "\n" & groupMixins(ctx, d) & bodyStr & "\n"

proc genMemberFn*(ctx: var CodegenCtx, m: Decl, objName: string): string =
  ## lowering.normalizeSelf has already given the member its `self`
  ## parameter and resolved `Self` to the object. What is left here is the
  ## one thing that is a NIM question: self is mutable, spelled `var T`, so
  ## a mutation reaches the caller's value.
  var params = m.fnParams
  for i in 0 ..< params.len:
    if params[i].name == "self":
      params[i].typ = Type(span: m.span, kind: tkNamed,
                           name: "var " & objName)
  # QUALIFIED, like Odin and D. Nim overloads on the self parameter's type so
  # a bare `noise` compiled, but a bare name also collided with a top-level
  # `noise` at mangling time and silently called the wrong one (#50). One
  # naming rule across the three makes that collision impossible instead of
  # resolving it by precedence.
  let copy = Decl(span: m.span, kind: dkFn,
                  name: memberProcName(objName, m.name), fnParams: params,
                  fnReturnType: m.fnReturnType, fnBody: m.fnBody,
                  fnEffects: m.fnEffects, fnGenerics: m.fnGenerics)
  ctx.genFnDecl(copy)

proc genTransitionProcs*(d: Decl, kindName: string, hasPayload: bool): string =
      var canLines: seq[string]
      canLines.add("proc canTransition*(frm, to: " & kindName & "): bool =")
      canLines.add("  case frm")
      for v in d.typeBody.variants:
        let allowed = allowedTransitions(d.typeBody, v.name)
        if allowed.len > 0:
          canLines.add("  of " & v.name & ": to in {" & allowed.join(", ") & "}")
        else:
          canLines.add("  of " & v.name & ": false")
      var res = canLines.join("\n") & "\n"
      let kindOf = if hasPayload: ".kind" else: ""
      res.add("proc transitionTo*(self: var " & d.name & ", target: " & d.name & ") =\n" &
              "  if not canTransition(self" & kindOf & ", target" & kindOf & "):\n" &
              "    raise newException(ValueError, \"Invalid transition \" & $self" & kindOf &
              " & \" -> \" & $target" & kindOf & ")\n" &
              "  self = target\n")
      return res

proc genSumEquality(d: Decl): string =
  ## `==` for a payload sum.
  ##
  ## Nim's structural `==` for objects walks `fields`, and that iterator does
  ## not work over a CASE object: comparing two of them reported "parallel
  ## 'fields' iterator does not work for 'case' objects", pointing into
  ## Nim's system.nim. So `a == b` on any payload sum failed to build — with
  ## or without recursion, and on this backend alone. Odin compares its
  ## tagged union natively and D its tagged struct, so this compiled on two
  ## backends out of three.
  ##
  ## Same tag, then the ACTIVE payload only. Comparing the inactive branches
  ## is what Nim refuses and would be meaningless anyway — a union's other
  ## arms hold whatever was last written there.
  ## `{.noSideEffect.}` is explicit because Nim cannot INFER it through
  ## recursion, and a recursive sum's `==` is recursive by construction:
  ## comparing two `Add`s compares their `seq[Expr]` edges, which compares
  ## two more Exprs. Without the pragma that reported "'==' can have side
  ## effects" from inside Nim's own comparisons.nim.
  result = "\nproc `==`*(a, b: " & d.name & "): bool {.noSideEffect.} =\n" &
           "  if a.kind != b.kind: return false\n" &
           "  case a.kind\n"
  for v in d.typeBody.variants:
    if v.fields.len == 0:
      result.add("  of " & v.name & ": true\n")
    else:
      let f = sumPayloadField(v.name)
      result.add("  of " & v.name & ": a." & f & " == b." & f & "\n")

proc genSumType*(ctx: var CodegenCtx, d: Decl): string =
      let hasPayload = sumHasPayload(d.typeBody)
      let hasTransitions = d.typeBody.transitions.len > 0
      if not hasPayload and not hasTransitions:
        # plain enum (also what decision tables key over)
        var tags: seq[string]
        for v in d.typeBody.variants:
          tags.add(if v.value != "": v.name & " = " & v.value else: v.name)
        return "type " & d.name & "* = enum " & tags.join(", ") & "\n"

      var res = ""
      var kindName = d.name
      if hasPayload:
        # tagged union: kind enum + object variant; each variant's payload is
        # a tuple field named after the variant (no cross-branch name clashes)
        kindName = d.name & "Kind"
        var tags: seq[string]
        for v in d.typeBody.variants: tags.add(v.name)
        res.add("type " & kindName & "* = enum " & tags.join(", ") & "\n")
        res.add("type " & d.name & "* = object\n  case kind*: " & kindName & "\n")
        for v in d.typeBody.variants:
          if v.fields.len == 0:
            res.add("  of " & v.name & ": discard\n")
          else:
            var parts: seq[string]
            for f in v.fields:
              parts.add(f.name & ": " & genType(f.typ))
            res.add("  of " & v.name & ": " & sumPayloadField(v.name) &
                    "*: tuple[" & parts.join(", ") & "]\n")
      else:
        res.add("type " & d.name & "* = enum ")
        var tags: seq[string]
        for v in d.typeBody.variants: tags.add(v.name)
        res.add(tags.join(", ") & "\n")

      if hasPayload:
        res.add(genSumEquality(d))
      if hasTransitions:
        # transition matrix: pure predicate + checked assignment
        res.add(genTransitionProcs(d, kindName, hasPayload))
      return res

proc genRecordType*(ctx: var CodegenCtx, d: Decl): string =
      var fieldsStr: seq[string]
      for f in d.typeBody.fields:
        fieldsStr.add("  " & f.name & "*: " & ctx.fieldType(d.name, f))
      let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: "  discard"
      let tGen = if d.generics.len > 0: "[" & d.generics.join(", ") & "]" else: ""
      # A C struct (declared inside `extern [c, header: ...]`) must DECLARE the
      # foreign type, not define a second one: Nim #includes the header, so a
      # plain object would be a distinct C type with identical layout and the
      # C compiler rejects the call ("cannot convert struct <anonymous>").
      # Mirrors how Nim's own posix module binds `struct timespec`. `bycopy`
      # keeps it passed by value, which is the C signature's contract.
      if d.typeExternHeader != "":
        # A FIELDLESS extern type is an opaque handle: `typedef struct Foo Foo;`
        # with no definition in the header. Its size is unknown, so it can only
        # ever be held as a pointer — `bycopy` would ask C for a size it does
        # not have ("unknown type size"). The alias is what callers name.
        if d.typeBody.fields.len == 0:
          return "type " & d.name & "Obj {.importc: \"" & d.name & "\", header: \"" &
                 d.typeExternHeader & "\", incompleteStruct.} = object\n" &
                 "type " & d.name & "* = ptr " & d.name & "Obj\n"
        return "type " & d.name & "* {.importc: \"" & d.name & "\", header: \"" &
               d.typeExternHeader & "\", bycopy.} = object\n" & fieldsBody & "\n"
      # Tier 1 records are value types (spec §7.1) — plain object, not ref
      var res = "type " & d.name & "*" & tGen & " = object\n" & fieldsBody & "\n"
      var invariantChecks: seq[string]
      var checkCtx = CodegenCtx(definedVars: initHashSet[string](),
                                fieldVars: initHashSet[string](), indent: 0,
                                res: ctx.res)
      for f in d.typeBody.fields:
        checkCtx.fieldVars.incl(f.name)
      for member in d.typeMembers:
        if member.kind == dkExpr:
          let condStr = checkCtx.genExpr(member.expr)
          # NOT `assert`: `-d:release` strips it outright, which is exactly
          # the build where a violated invariant means corrupt data.
          # ROADMAP's 2026-08-25 ruling 5 says invariants stay on in release,
          # opt-out only — `tuckNoInvariants` is that opt-out, independent of
          # `release`/`danger` (mirrors the D backend's `tuckNoInvariants`).
          invariantChecks.add("  if not (" & condStr & "): tuckInvariantFailed(\"" &
                              condStr.replace("\"", "'") & "\", \"" & d.name & "\")")
      if invariantChecks.len > 0:
        res.add("\nproc validate*(self: " & d.name & ") =\n  when not defined(tuckNoInvariants):\n" &
                invariantChecks.join("\n").indent(2) & "\n")
      # manager types carry functionality: member fns join the catalog
      for member in d.typeMembers:
        if member.kind == dkFn:
          res.add("\n" & ctx.genDecl(member) & "\n")
      return res

proc genAliasType*(d: Decl): string =
      let typeBodyStr = genType(d.typeBody)
      if isDistinctAlias(d.typeBody):
        # Nim distinct + borrowed ops: same bits, incompatible type
        var res = "type " & d.name & "* = distinct " & typeBodyStr & "\n"
        # `div`/`mod` are INTEGER ops in Nim — borrowing them for a float
        # base makes the type fail to compile the moment it is declared,
        # which is what blocked the language's own recommended unit-safety
        # pattern (`distinct Miles = f64`, mirroring std/time's u32 units)
        # for every non-integer unit.
        let isFloat = typeBodyStr in ["float32", "float64", "float"]
        let arith = if isFloat: @["+", "-", "*"]
                    else: @["+", "-", "*", "div", "mod"]
        for op in arith:
          res.add("proc `" & op & "`*(a, b: " & d.name & "): " & d.name & " {.borrow.}\n")
        for op in ["==", "<", "<="]:
          res.add("proc `" & op & "`*(a, b: " & d.name & "): bool {.borrow.}\n")
        res.add("proc `$`*(a: " & d.name & "): string {.borrow.}\n")
        return res
      let aGen = if d.generics.len > 0: "[" & d.generics.join(", ") & "]" else: ""
      return "type " & d.name & "*" & aGen & " = " & typeBodyStr & "\n"

proc genMsgTypes*(handlers: seq[ActorMsgHandler], hasShutdown: bool,
                 msgEnumName, msgTypeName: string): string =
  ## The message-kind enum + the message envelope object. Handler params ride
  ## in the envelope, deduped by name across handlers.
  var enumVariants: seq[string]
  for h in handlers:
    enumVariants.add("msg" & h.name.capitalize())
  if hasShutdown:
    enumVariants.add("msgShutdown")   # sent as `Actor send shutdown {}`
  var msgFields: seq[string]
  var seen = initHashSet[string]()
  for h in handlers:
    for p in h.params:
      if p.name notin seen:
        seen.incl(p.name)
        msgFields.add("  " & p.name & "*: " & genType(p.typ))
  let enumStr = "type " & msgEnumName & "* = enum " & enumVariants.join(", ") & "\n"
  let envelopeStr = "type " & msgTypeName & "* = object\n  " & TagField &
                    "*: " & msgEnumName & "\n" &
                    (if msgFields.len > 0: msgFields.join("\n") & "\n" else: "")
  enumStr & envelopeStr

proc genActorState*(ctx: var CodegenCtx, d: Decl, msgTypeName, queueSize: string,
                   hasShutdown: bool): string =
  ## The actor's ref-object state: declared fields + mailbox (+ `finished` flag,
  ## which the shutdown arm sets to make the drain go inert).
  var fieldsStr: seq[string]
  for f in d.actorFields:
    fieldsStr.add("  " & f.name & "*: " & ctx.fieldType(d.name, f))
  fieldsStr.add("  mailbox*: Mailbox[" & msgTypeName & ", " & queueSize & "]")
  if hasShutdown:
    fieldsStr.add("  finished*: bool")
  "type " & d.name & "* = ref object\n" & fieldsStr.join("\n") & "\n"

proc genActorDispatch*(ctx: CodegenCtx, d: Decl, msgTypeName: string,
                      handlers: seq[ActorMsgHandler], shutdownBody: Expr,
                      hasShutdown: bool): string =
  ## The `handleMsg` proc: a case over the message kind. Runs in its own ctx so
  ## handler bodies see the actor's fields as field vars; realModules/module are
  ## inherited so qualified calls (e.g. sys::exit) resolve as `module.fn`.
  var hctx = CodegenCtx(definedVars: initHashSet[string](),
                        fieldVars: initHashSet[string](), indent: 2,
                        realModules: ctx.realModules, module: ctx.module,
                        moduleName: ctx.moduleName, res: ctx.res)
  for f in d.actorFields:
    hctx.fieldVars.incl(f.name)
  # a block body self-indents; a single-expression arm body needs the arm indent
  proc armBody(e: Expr): string =
    let raw = hctx.genExpr(e)
    if e != nil and e.kind == exkBlock: raw else: "    " & raw
  var handlerCases: seq[string]
  for h in handlers:
    var caseBody = ""
    for p in h.params:
      caseBody.add("    let " & p.name & " = msg." & p.name & "\n")
    handlerCases.add("  of msg" & h.name.capitalize() & ":\n" & caseBody & armBody(h.body))
  if hasShutdown:
    # run the shutdown body, then mark finished so the drain goes inert; a
    # `return` in the arm body is a no-op statement here.
    handlerCases.add("  of msgShutdown:\n" & armBody(shutdownBody) & "\n    self.finished = true")
  "proc handleMsg*(self: " & d.name & ", msg: " & msgTypeName & ") =\n  case msg." & TagField & "\n" &
    handlerCases.join("\n") & "\n"

proc genActorDrain*(msgTypeName, drainName, singleton: string, hasShutdown: bool): string =
  ## The drain closure: dequeue every pending msg, dispatch, report progress.
  ## The scheduler registers this; it never sees the concrete Msg type.
  result =
    "proc " & drainName & "(): bool {.gcsafe.} =\n" &
    "  {.cast(gcsafe).}:\n" &
    "    result = false\n"
  if hasShutdown:
    result.add("    if " & singleton & ".finished: return\n")
  result.add(
    "    var m: " & msgTypeName & "\n" &
    "    while dequeue(" & singleton & ".mailbox, m):\n" &
    "      handleMsg(" & singleton & ", m)\n" &
    "      result = true\n")

proc genActor*(ctx: var CodegenCtx, d: Decl): string =
  let queueSize = actorQueueSize(d)
  let (handlers, shutdownBody, hasShutdown) = collectHandlers(d)
  let msgEnumName = d.name & "MsgKind"
  let msgTypeName = d.name & "Msg"

  if handlers.len == 0 and not hasShutdown:
    # No handlers: an empty enum is invalid Nim. Emit just the state object.
    var bareFields: seq[string]
    for f in d.actorFields:
      bareFields.add("  " & f.name & "*: " & ctx.fieldType(d.name, f))
    let bareBody = if bareFields.len > 0: bareFields.join("\n") else: "  discard"
    return "type " & d.name & "* = ref object\n" & bareBody & "\n"

  let singleton = actorSingletonName(d.name)   # spec §9: one global per actor
  let drainName = "drain" & d.name
  let msgTypes = genMsgTypes(handlers, hasShutdown, msgEnumName, msgTypeName)
  let stateStr = genActorState(ctx, d, msgTypeName, queueSize, hasShutdown)
  let dispatchStr = genActorDispatch(ctx, d, msgTypeName, handlers, shutdownBody, hasShutdown)
  let singletonStr = "let " & singleton & "* = " & d.name & "()\n"
  let drainStr = genActorDrain(msgTypeName, drainName, singleton, hasShutdown)
  # auto-registration hook: main's prologue calls registerActors()
  let registerStr = "proc registerActor" & d.name & "*() =\n" &
                    "  tuckStartActor(" & drainName & ")\n"

  msgTypes & "\n" & stateStr & "\n" & singletonStr & "\n" & dispatchStr & "\n" &
    drainStr & "\n" & registerStr

proc genRegistry*(ctx: var CodegenCtx, d: Decl): string =
    let msgEnumName = d.name & "Kind"
    var enumVariants: seq[string]
    var fieldsStr: seq[string]
    var seenFields = initHashSet[string]()
    for v in d.variants:
      enumVariants.add(v.name)
      for f in v.fields:
        if f.name notin seenFields:
          seenFields.incl(f.name)
          fieldsStr.add("  " & f.name & "*: " & genType(f.typ))

    let enumStr = "type " & msgEnumName & "* = enum " & enumVariants.join(", ") & "\n"
    let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: ""
    # TWO spaces, matching the payload fields built above. This line used to
    # indent `kind*` by four while every payload field used two, which nim
    # rejects outright ("invalid indentation") — so ANY registry whose event
    # carries a payload emitted Nim that could not compile. Invisible because
    # no registry example has an `fn main`, making `tuck build` a library
    # build that never hands the output to nim.
    let typeStr = "type " & d.name & "* = ref object\n  " & TagField &
                  "*: " & msgEnumName & "\n" & fieldsBody & "\n"
    let globalVarStr = "var latest" & d.name & "*: " & d.name & "\n\n"

    # NO forward declarations for the handlers HERE. A handler is an ordinary
    # top-level fn and the file's own forward-declaration block already
    # declares it; emitting a second one made the proc declared TWICE, which
    # the emitted file's `{.experimental: "codeReordering".}` rejects —
    # "implementation of 'tuck_SystemEvents_PlaybackStarted' expected", with
    # the implementation sitting further down the same file.
    var raiseProcsStr = ""
    for v in d.variants:
      var params: seq[string]
      var assignParts: seq[string]
      for f in v.fields:
        params.add(f.name & ": " & genType(f.typ))
        assignParts.add(f.name & ": " & f.name)
      let paramStr = params.join(", ")
      let assignStr = if assignParts.len > 0: ", " & assignParts.join(", ") else: ""

      let handlerName = d.name & "." & v.name
      let handlerNameSanitized = d.name & "_" & v.name
      var handlerCalls: seq[string]
      for decl in ctx.module.decls:
        if decl.kind == dkFn and decl.name == handlerName:
          var argNames: seq[string]
          for f in v.fields: argNames.add(f.name)
          handlerCalls.add("  " & handlerNameSanitized & "(" & argNames.join(", ") & ")")

      let handlerInvokes = if handlerCalls.len > 0: handlerCalls.join("\n") else: "  discard"
      raiseProcsStr.add("proc raise_" & d.name & "_" & v.name & "*(" & paramStr & ") =\n  latest" & d.name & " = " & d.name & "(" & TagField & ": " & v.name & assignStr & ")\n" & handlerInvokes & "\n\n")

    return enumStr & typeStr & "\n" & globalVarStr & raiseProcsStr

proc genObjectDecl*(ctx: var CodegenCtx, d: Decl): string =
  ## A manager object: its fields land in the type section, its members and
  ## anything composed into it come back as top-level procs.
  var fields: seq[string]
  for f in d.objFields:
    fields.add("  " & f.name & "*: " & ctx.fieldType(d.name, f))
  var members = ""
  for member in d.objMembers:
    # lowering.composeObject has already merged every RESOLVED `+ X`. What
    # can still reach here is one that named nothing declared — a sketch.
    if isCompositionEntry(member):
      members.add("# + " & compositionTargetName(member) & " (undeclared — sketch)\n")
    elif member.kind == dkFn:
      members.add(ctx.genMemberFn(member, d.name) & "\n")
    else:
      members.add(ctx.genDecl(member) & "\n")
  let body = if fields.len > 0: fields.join("\n") else: "  discard"
  # manager objects hold var state but are Tier 1 value types too
  ctx.typeSection.add("type " & d.name & "* = object\n" & body)
  members

proc genTaskDecl*(ctx: var CodegenCtx, d: Decl): string =
  ## A task is a fn whose body runs on the scheduler: inside it, [io] calls
  ## become async yields (ctx.inTask), which is the only reason it is not
  ## just genFnDecl.
  ctx.currentParams = @[]
  var params: seq[string]
  for p in d.taskParams:
    ctx.currentParams.add(FieldDef(name: p.name, typ: p.typ, span: p.span))
    params.add(p.name & ": " & genType(p.typ))
  let retTypeStr = if d.taskReturnType != nil: genType(d.taskReturnType) else: "void"
  let header = "proc " & d.name & "*(" & params.join(", ") & "): " &
               retTypeStr & " ="
  let oldVars = ctx.definedVars
  for p in d.taskParams: ctx.definedVars.incl(p.name)
  let oldIndent = ctx.indent
  let oldInTask = ctx.inTask
  (ctx.retWrapped, ctx.retInnerNim, ctx.retInnerT) = bangInfo(d.taskReturnType)
  ctx.retAbsentCapable = absentCapable(d.taskReturnType)
  injectTailReturn(d.taskBody, retTypeStr)
  ctx.inTask = true
  # A task lowers to a proc, so its body needs no scope of its own either.
  let bodyStr = ctx.genFnBody(d.taskBody, "  ".repeat(ctx.indent))
  ctx.inTask = oldInTask
  ctx.indent = oldIndent
  ctx.retWrapped = false
  ctx.retAbsentCapable = false
  ctx.definedVars = oldVars
  header & "\n" & bodyStr & "\n"

proc bitAccessMode*(f: FieldDef): string =
  ## An unmarked field is readable AND writable; marking one direction opts
  ## out of the other.
  var hasRead, hasWrite = false
  for a in f.attrs:
    if a.name == "read": hasRead = true
    elif a.name == "write": hasWrite = true
  if hasRead and not hasWrite: "ReadOnly"
  elif hasWrite and not hasRead: "WriteOnly"
  else: "ReadWrite"

proc nimBitConsts*(bf: BitFieldInfo): string =
  ## The shift, and for a range the width and mask. `const` so they fold away.
  result = "const " & bf.prefix & "_SHIFT = " & bf.loBit & "\n"
  if bf.isRange:
    result.add("const " & bf.prefix & "_WIDTH = " & bf.hiBit & " - " &
               bf.loBit & " + 1\n")
    result.add("const " & bf.prefix & "_MASK = (1'u32 shl " & bf.prefix &
               "_WIDTH) - 1\n")

proc nimBitGetter*(bf: BitFieldInfo, regName: string): string =
  ## A range reads as a masked uint32; a single bit reads as a bool.
  let body = if bf.isRange:
               "  (" & regName & "[] shr " & bf.prefix & "_SHIFT) and " &
                 bf.prefix & "_MASK\n"
             else:
               "  (" & regName & "[] and (1'u32 shl " & bf.prefix &
                 "_SHIFT)) != 0\n"
  let retT = if bf.isRange: "uint32" else: "bool"
  "proc " & bf.prefix & "_get*(): " & retT & " {.inline.} =\n" & body

proc nimBitSetter*(bf: BitFieldInfo, regName: string): string =
  ## A range clears its mask before OR-ing the shifted value in; a single bit
  ## sets or clears one mask.
  if bf.isRange:
    return "proc " & bf.prefix & "_set*(value: uint32) {.inline.} =\n" &
           "  let shifted = (value and " & bf.prefix & "_MASK) shl " &
             bf.prefix & "_SHIFT\n" &
           "  " & regName & "[] = (" & regName & "[] and not (" & bf.prefix &
             "_MASK shl " & bf.prefix & "_SHIFT)) or shifted\n"
  "proc " & bf.prefix & "_set*(value: bool) {.inline.} =\n" &
    "  let mask = 1'u32 shl " & bf.prefix & "_SHIFT\n" &
    "  if value: " & regName & "[] = " & regName & "[] or mask\n" &
    "  else: " & regName & "[] = " & regName & "[] and not mask\n"

proc genRegister*(d: Decl): string =
  ## A memory-mapped register (spec 8.1): named shift constants plus
  ## accessors reading and writing through a typed pointer at the MMIO
  ## address — the SAME lowering Odin and D use, sharing
  ## ast_query.decodeBitField; only the spelling is here.
  ##
  ## This used to hand the layout to a `registerMMIO` macro in the runtime,
  ## and the two halves disagreed about what they produced: the macro made
  ## standalone procs and a FIELD-LESS ref object while codegen emitted a
  ## field access, so every read or write of a register field failed to
  ## compile with "undeclared field". Ruling 2026-09-12: drop the macro, emit
  ## ordinary code like the other two backends. One shape to understand, and
  ## the call sites are shared.
  var consts: seq[string]
  var accessors: seq[string]
  for f in d.regFields:
    let bf = decodeBitField(d.name, f)
    consts.add(nimBitConsts(bf))
    if bf.canRead: accessors.add(nimBitGetter(bf, d.name))
    if bf.canWrite: accessors.add(nimBitSetter(bf, d.name))
  # `var`, not `let`: Nim lowers a `let` pointer to a const one in C, and
  # writing through it is "assignment of read-only location". The pointee is
  # hardware — Odin's `:=` and D's `__gshared` are mutable for the same
  # reason.
  "var " & d.name & " = cast[ptr uint32](" & d.regAddress & ")\n" &
    consts.join("") & accessors.join("")

proc declaredErrNames*(ctx: CodegenCtx): seq[string] =
  ## Every "module/Enum.Variant" this module declares. Error enums are
  ## FIELDLESS sums; one with payload fields is an ordinary sum type.
  for td in ctx.module.decls:
    if td == nil or td.kind != dkType: continue
    if td.typeBody == nil or td.typeBody.kind != tkSum: continue
    var fieldless = true
    for v in td.typeBody.variants:
      if v.fields.len > 0: fieldless = false
    if not fieldless: continue
    for v in td.typeBody.variants:
      result.add(errNameFor(ctx.module, ctx.moduleName, td.writtenName, v.name))

proc genErrNameTable*(errNames: seq[string]): string =
  ## A reverse table (hash -> "module/Enum.Variant") so a report can name the
  ## error rather than print its code.
  result = "proc tuckErrName*(code: uint16): string =\n  case code\n"
  for n in errNames:
    result.add("  of errCode(\"" & n & "\"): \"" & n & "\"\n")
  result.add("  else: \"code \" & $code\n")

proc genErrHandlerBody*(ctx: var CodegenCtx, handler: Decl): string =
  ## The user's handler body, with `code` and `site` in scope as its params.
  let savedVars = ctx.definedVars
  ctx.definedVars.incl("code")
  ctx.definedVars.incl("site")
  # A handler body is a PROC body — genFnBody, not genIndented, so it does not
  # get the `if true:` scope that a nested block needs.
  result = ctx.genFnBody(handler.fnBody, "  ".repeat(ctx.indent))
  ctx.definedVars = savedVars
  if result.strip() == "" or result.strip() == "discard": result = ""

proc genErrHandler*(ctx: var CodegenCtx, d: Decl): string =
  ## Global handler: rt logger first (errors are always visible), then the
  ## user's handler body.
  let errNames = ctx.declaredErrNames()
  if errNames.len > 0: result.add(genErrNameTable(errNames))
  result.add("proc tuck_unhandled*(code: uint16, site: string) =\n" &
             "  tuckReportUnhandled(code, site)\n")
  if errNames.len > 0:
    result.add("  stderr.writeLine(\"TUCK ERROR NAME: \" & tuckErrName(code))\n")
  if d.errHandler != nil and d.errHandler.fnBody != nil:
    let body = ctx.genErrHandlerBody(d.errHandler)
    if body != "": result.add(body & "\n")

proc genImportcBinding*(m: Decl): string =
  ## A C-imported fn. [emit: "c_fn"] sets the importc name; else the Tuck name.
  var params: seq[string]
  for prm in m.fnParams:
    params.add(prm.name & ": " & genType(prm.typ))
  let retStr = if m.fnReturnType != nil: genType(m.fnReturnType) else: "void"
  let cName = if m.externEmit != "": m.externEmit else: m.name
  "proc " & m.name & "*(" & params.join(", ") & "): " & retStr &
    " {.importc: \"" & cName & "\", header: \"" & m.externHeader & "\".}\n"

proc genMixinMember*(ctx: var CodegenCtx, m: Decl): string =
  ## One member of a mixin/extern/pending block.
  if m.kind in {dkType, dkFnSig}:
    # a C struct or callback signature declared in the extern block — genDecl
    # routes them to the importc/header and cdecl forms
    return ctx.genDecl(m) & "\n"
  if m.kind != dkFn: return ""
  if m.isPending: return genPendingStub(m) & "\n"
  if not m.isExtern:
    # interface contract (sig only, no body): nothing to emit — the
    # implementing types provide the code
    if m.fnBody == nil or takesSelf(m): return ""
    # a mixin is a named bucket of functions (spec 5.1) — emit them
    return ctx.genDecl(m) & "\n"
  if m.externHeader != "": return genImportcBinding(m)
  ""   # rt-implemented: tuck_rt provides it, nothing to emit here

proc genMixinBlock*(ctx: var CodegenCtx, d: Decl): string =
  ## All three kinds carry members and emit per-member. dkPending emits stubs;
  ## dkExtern emits nothing for rt-implemented fns (tuck_rt provides them) and
  ## importc bindings for C-imported ones; a real mixin's fns are materialised
  ## onto the objects that compose it.
  for m in d.mixinMembers:
    result.add(ctx.genMixinMember(m))

proc genDecl*(ctx: var CodegenCtx, d: Decl): string =
  if d == nil: return ""
  if d.kind == dkType and d.span.file.startsWith(ImportedTypeMarker):
    return ""  # defined in its own module; the Nim import brings it in
  case d.kind
  of dkFn:
    return ctx.genFnDecl(d)
  of dkType:
    if d.typeBody != nil:
      if d.typeBody.kind == tkSum:
        return ctx.genSumType(d)
      elif d.typeBody.kind == tkRecord:
        return ctx.genRecordType(d)
      else:
        return genAliasType(d)
    return ""
  of dkObject:
    return ctx.genObjectDecl(d)
  of dkActor:
    return ctx.genActor(d)
  of dkTask:
    return ctx.genTaskDecl(d)

  of dkExpr:
    return ctx.genExpr(d.expr)
  of dkConst:
    # explicit static block: the backend evaluates the initializer at
    # compile time (pure computation — the checker already enforced purity)
    return "const " & d.name & " = static:\n  " & ctx.genExpr(d.constVal)
  of dkRegister: return genRegister(d)
  of dkRegistry:
    return ctx.genRegistry(d)
  of dkPool:
    # spec 7.2: one static instance; acquire/release are the rt's generic
    # procs, reached as `Pool.acquire` -> `acquire(Pool)`.
    # No per-pool handle type is emitted: the CHECKER keeps two pools' handles
    # apart, so the target needs only the runtime's one `PoolHandle`, which
    # each backend's type mapper answers with. Same shape as a group bound —
    # resolved and discarded before codegen.
    return "var " & d.name & "* = ObjectPool[" & genType(d.poolElem) & ", " &
           $d.poolCount & "]()"
  of dkImport:
    return ""  # emitNim adds the Nim import line
  of dkStaticAssert:
    return "static: assert(" & ctx.genExpr(d.assertExpr) & ")"
  of dkErrors: return ctx.genErrHandler(d)
  of dkResources:
    # spec §7.4. The registry TABLES land with the runtime (Phase 3); this arm
    # exists so the dispatch stays exhaustive and the declaration is a no-op in
    # emitted code rather than a silent gap in a backend that forgot it.
    return ""
  of dkMixin, dkExtern, dkPending: return ctx.genMixinBlock(d)
  of dkFnSig:
    # `fnsig NAME = {params} -> ret` → a Nim closure proc type. Named delegate
    # for slots/callbacks; call shape already checked by the type checker.
    var params: seq[string]
    for prm in d.sigParams:
      params.add(prm.name & ": " & genType(prm.typ))
    let retStr = if d.sigReturn != nil and not
                    (d.sigReturn.kind == tkNamed and d.sigReturn.name == "void"):
                   genType(d.sigReturn)
                 else: "void"
    # A C callback must be a BARE function pointer with the C calling
    # convention. Nim's default {.closure.} is a (proc, env) pair — the C
    # compiler rejects it outright ("cannot convert struct <anonymous> to
    # int (*)(int, int)"), and a captured environment has nowhere to live on
    # the C side anyway, so C callbacks are necessarily non-capturing.
    let conv = if d.sigIsCCallback: "{.cdecl.}" else: "{.closure.}"
    let sGen = if d.sigGenerics.len > 0: "[" & d.sigGenerics.join(", ") & "]" else: ""
    return "type " & d.name & "*" & sGen & " = proc(" & params.join(", ") &
           "): " & retStr & " " & conv & "\n"
  of dkInterface:
    # An interface value is a VARIANT over the types that satisfy it: a tag
    # plus the object itself, copied in (spec §5.3). Copy, not a pointer to
    # the original — that is the same rule as every other value in Tuck, and
    # it is what makes returning one, storing one in a field, and collecting
    # them all just work with no lifetime questions.
    #
    # A variant rather than `array[max(sizeof), byte]` + copyMem: Tuck objects
    # hold `str` and `Seq`, which the backend manages, and a byte blit never
    # adjusts the refcount — the source's destructor would free the payload out
    # from under the copy. The variant lets Nim generate the right copy and
    # destroy per branch.
    #
    # The tag replaces the function table entirely: dispatch is a `case`
    # calling the concrete member fn directly, so there are no thunks and the
    # optimizer can see through it.
    let sats = ctx.satisfiersOf(d.name)
    if sats.len == 0:
      # Declared but nothing satisfies it — still a legal declaration, and
      # there is no value to represent.
      return "# interface " & d.name & ": no satisfying types\n"
    var tags: seq[string]
    var branches: seq[string]
    for s in sats:
      let tag = d.name & "_is_" & s.name
      tags.add(tag)
      branches.add("  of " & tag & ": " & s.name & "Val*: " & s.name)
    result = "type " & d.name & "Tag* = enum " & tags.join(", ") & "\n\n"
    result.add("type " & d.name & "* = object\n" &
               "  case tag*: " & d.name & "Tag\n" &
               branches.join("\n") & "\n")
    return result
  else:
    return "# [codegen] ignored decl kind " & $d.kind & "\n"

proc sumEqForwardDecls*(m: Module): string =
  ## The generated `==` operators, forward-declared for the same reason the
  ## fns below are: two sums that hold each other need each other's `==`, and
  ## whichever is emitted second is undeclared at the first one's use. Mutual
  ## recursion between TYPES made this reachable the moment `==` was
  ## generated at all.
  for d in m.decls(dkType):
    if d == nil or d.typeBody == nil or d.typeBody.kind != tkSum: continue
    if not sumHasPayload(d.typeBody): continue
    result.add("proc `==`*(a, b: " & d.name & "): bool {.noSideEffect.}\n")
  if result.len > 0: result.add("\n")

proc fnForwardDecls*(m: Module): string =
  ## Forward-declare every top-level fn, so a call may precede its definition.
  ##
  ## `{.experimental: "codeReordering".}` was carrying this, and it does NOT
  ## carry mutually recursive PROCS: `isEven` calling `isOdd` declared below it
  ## reported `undeclared identifier: 'tuck_isOdd'`. Odin and D resolve
  ## top-level declarations order-independently and never had the problem, so
  ## a pair of mutually recursive fns compiled on two backends out of three.
  ##
  ## The pragma stays for TYPES, which is what emitNim's comment there is
  ## about, and which it does handle.
  for d in m.decls(dkFn):
    if d == nil or d.isPending or d.isDecision or d.isDecisionTable(): continue
    if d.isExtern: continue
    let params = nimFnParams(semLayer, m, d)
    let ret = if d.fnReturnType != nil: genType(d.fnReturnType) else: "void"
    let gen = if d.fnGenerics.len > 0: "[" & d.fnGenerics.join(", ") & "]"
              else: ""
    let inl = if d.isInline: " {.inline.}" else: ""
    result.add(fnHeaderNim(d.name.replace(".", "_"), gen, params, ret, inl,
                           isExportedDecl(m, d)) & "\n")
  if result.len > 0: result.add("\n")
