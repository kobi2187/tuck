# compiler/codegen_d_decl.nim
#
# Declaration codegen for the D backend: genDDecl's dispatch (one arm per
# DeclKind) and everything it calls -- fn/object/actor/registry/register/
# mixin/decision-table/err-handler. Calls INTO codegen_d.nim's genDExpr for
# fn bodies (one-way: genDExpr never calls back into anything here).
import ast, strutils, sets, tables, options
import resolution
import ast_query
import codegen_common
import codegen_table
import codegen_d_ctx
from codegen_odin_util import odinErrCode, enumTagOwner
from mangle import mangleName
from lowering_d import needsDup, recordDupFields
import ./codegen_d

proc dColumnOrdinal*(ctx: var DCodegenCtx, domain: seq[string],
                    paramName: string): string =
  ## A column's ordinal for the packed key. NOT packedKeyExpr — that emits
  ## Nim's `ord()`; D spells it as a cast on the enum value, and a bool
  ## column casts the same way.
  if domain == @["false", "true"]: "cast(long)(" & paramName & ")"
  else: "cast(long)(" & paramName & ")"

proc dDecisionRowPatterns*(s: Expr): seq[string] =
  let pat = s.arms[0].pattern
  for el in (if pat != nil and pat.kind == pkTuple: pat.elems else: @[pat]):
    result.add(genPatternStr(el))

proc dRowCondition*(ctx: var DCodegenCtx, d: Decl, arm: MatchArm): string =
  ## The guard a row fires under — empty when every column is a wildcard,
  ## which makes it the catch-all.
  let pats = if arm.pattern != nil and arm.pattern.kind == pkTuple:
               arm.pattern.elems
             else: @[arm.pattern]
  var conds: seq[string]
  for i, pat in pats:
    let patStr = genPatternStr(pat)
    if patStr != "_" and i < d.fnParams.len:
      let tag = ctx.qualifyEnumTag(patStr)
      conds.add(d.fnParams[i].name & " == " &
                (if tag != "": tag else: patStr))
  conds.join(" && ")

proc dCallConv*(ctx: var DCodegenCtx, d: Decl): string =
  ## `extern (C)` when this fn is used as a C CALLBACK — a D function
  ## pointer and a C one are different types, so a plain fn's address cannot
  ## be handed to C.
  ##
  ## Matched by SHAPE against the C callback signatures the module declares,
  ## which is what the Odin backend does for the same reason.
  ## ponytail: shape match, not reference tracking. A same-shape fn that
  ## never crosses the boundary gets extern(C) harmlessly; tighten if that
  ## ever matters.
  for mem in ctx.module.externMembers():
    if mem.kind != dkFnSig or not mem.sigIsCCallback or
       mem.sigParams.len != d.fnParams.len: continue
    var same = true
    for i, sp in mem.sigParams:
      if ctx.dType(sp.typ) != ctx.dType(d.fnParams[i].typ): same = false
    if same: return "extern (C) "
  ""

proc dTrailingReturn*(body: Expr, retStr: string, indent: int): string =
  ## D rejects a value-returning function that can fall off the end, so a
  ## body the checker left open (a `...` pending hole, or a tail the checker
  ## already proved exhaustive by other means) gets a zero-value return.
  ## `typeof(return)` names the type without repeating it, so this works for
  ## a carrier, a record or a scalar alike. Odin needs the same thing and
  ## spells it `return {}` (codegen_odin ensureTrailingReturn).
  if retStr == "void": return ""
  if body != nil and body.kind == exkBlock and body.stmts.len > 0 and
     body.stmts[^1].kind in {exkReturn, exkRaise}: return ""
  "    ".repeat(indent) & "return typeof(return).init;\n"

proc dBitConsts*(bf: BitFieldInfo): string =
  ## The shift, and for a range the width and mask. D's `enum` is a real
  ## compile-time constant, so these fold away entirely.
  result = "enum " & bf.prefix & "_SHIFT = " & bf.loBit & ";\n"
  if bf.isRange:
    result.add("enum " & bf.prefix & "_WIDTH = " & bf.hiBit & " - " &
               bf.loBit & " + 1;\n")
    result.add("enum uint " & bf.prefix & "_MASK = (1u << " & bf.prefix &
               "_WIDTH) - 1;\n")

proc dBitGetter*(bf: BitFieldInfo, regName: string): string =
  ## A range reads as a masked uint; a single bit reads as a bool.
  let body = if bf.isRange:
               "return (*" & regName & " >> " & bf.prefix & "_SHIFT) & " &
                 bf.prefix & "_MASK;"
             else:
               "return (*" & regName & " & (1u << " & bf.prefix &
                 "_SHIFT)) != 0;"
  let retT = if bf.isRange: "uint" else: "bool"
  retT & " " & bf.prefix & "_get() {\n    " & body & "\n}\n"

proc dBitSetter*(bf: BitFieldInfo, regName: string): string =
  ## A range clears its mask before OR-ing the shifted value in; a single bit
  ## sets or clears one mask.
  if bf.isRange:
    return "void " & bf.prefix & "_set(uint value) {\n" &
           "    uint shifted = (value & " & bf.prefix & "_MASK) << " &
             bf.prefix & "_SHIFT;\n" &
           "    *" & regName & " = (*" & regName & " & ~(" & bf.prefix &
             "_MASK << " & bf.prefix & "_SHIFT)) | shifted;\n}\n"
  "void " & bf.prefix & "_set(bool value) {\n" &
    "    if (value) *" & regName & " |= (1u << " & bf.prefix & "_SHIFT);\n" &
    "    else *" & regName & " &= ~(1u << " & bf.prefix & "_SHIFT);\n}\n"

proc genDInterface*(ctx: var DCodegenCtx, d: Decl): string =
  ## An interface is a COPYING TAGGED VARIANT over every type that satisfies
  ## it (spec 5.3) — not a vtable, not a pointer to a base. This is not OOP:
  ## the concrete value is copied in, tag and all, so it owns its data and
  ## there is no lifetime question.
  ##
  ## The satisfier set is closed and resolved WHOLE-PROGRAM, which is why
  ## satisfiersOf takes realModules: a type in another module can satisfy an
  ## interface it never heard of (retroactive `satisfies`).
  ##
  ## Shape follows the ODIN backend's — a struct with the tag and one field
  ## per satisfier — because D, like Odin, has no case-object. Verified
  ## against both reference backends before writing this: a wrap copies, a
  ## later wrap sees the newer value, and dispatch picks the arm for the
  ## stored tag (scratchpad/iface-playground/FINDINGS.md).
  let sats = ctx.satisfiersOfD(d.name)
  if sats.len == 0:
    return "// interface " & d.name & ": no satisfying types\n"
  var tags: seq[string]
  for st in sats: tags.add(d.name & "_is_" & st.name)
  result = "enum " & d.name & "Tag { " & tags.join(", ") & " }\n\n"
  result.add("struct " & d.name & " {\n")
  result.add("    " & d.name & "Tag tag;\n")
  for st in sats:
    result.add("    " & st.name & " " & st.name & "Val;\n")
  result.add("}\n")

proc genDErrHandler*(ctx: var DCodegenCtx, d: Decl): string =
  ## The `errors [policy: ...]` block's `on unhandled({code, site})` handler
  ## (spec 4.9) — an ordinary function the drop sites call.
  ##
  ## Most of this feature is STATIC: `strict` is a compile error listing
  ## every unhandled site, so a strict program reaches codegen with no drop
  ## sites at all, and the SHORTCUTS report is the checker's. What is left
  ## here is the handler itself and the call to it.
  let handler = d.errHandler
  if handler == nil: return ""   # strict: no handler, and no drop sites
  ctx.definedVars.incl("code")
  ctx.definedVars.incl("site")
  ctx.indent = 1
  var body = ctx.genDStmtOrBlock(handler.fnBody).strip()
  ctx.indent = 0
  ctx.definedVars.clear()
  # A `...` placeholder body means "report it and carry on" — the same
  # default the Nim backend forwards to.
  if body == "" or body == ";":
    body = "rt.tuckReportUnhandled(code, site);"
  # Mangled deliberately: the handler is emitted here but CALLED from every
  # drop site (genDDroppedResult), and the two must agree. The decl arrives
  # unmangled because it hangs off the errors block rather than the module's
  # top-level fn list.
  "void " & mangleName(handler.name) & "(ushort code, string site) {\n    " &
    body & "\n}\n"

proc dRegistryEventStruct*(ctx: var DCodegenCtx, d: Decl): string =
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
      fields.add("    " & ctx.dType(f.typ) & " " & f.name & ";")
  let fieldsBody = if fields.len > 0: fields.join("\n") & "\n" else: ""
  "enum " & d.name & "Kind { " & variants.join(", ") & " }\n\n" &
    "struct " & d.name & " {\n    " & d.name & "Kind kind;\n" &
    fieldsBody & "}\n"

proc dRegistryHandlerCalls*(ctx: DCodegenCtx, d: Decl,
                           v: VariantDef): string =
  ## Every declared handler for this event, called with the event's fields.
  ## The checker requires at least one — an event nothing listens to is a
  ## signal that silently goes nowhere (spec Part 10).
  let handlerName = d.name & "." & v.name
  var calls: seq[string]
  for decl in ctx.module.decls:
    if decl == nil or decl.kind != dkFn or decl.name != handlerName: continue
    var argNames: seq[string]
    for f in v.fields: argNames.add(f.name)
    calls.add("    " & dHandlerFnName(handlerName) & "(" &
              argNames.join(", ") & ");")
  if calls.len > 0: calls.join("\n") & "\n" else: ""

proc msgVariantName*(handlerName: string): string =
  ## The message-enum tag a handler receives on. Same rule as the Odin
  ## backend's (private there) — a one-line naming convention that both
  ## envelopes must agree on; worth sharing if a third consumer appears.
  "msg" & handlerName.capitalize()

proc dActorFieldLines*(ctx: var DCodegenCtx, d: Decl): seq[string] =
  for f in d.actorFields:
    result.add("    " & ctx.dFieldType(d.name, f) & " " & f.name & ";")

proc genDMsgEnvelope*(ctx: var DCodegenCtx, d: Decl,
                     handlers: seq[ActorMsgHandler],
                     variants: seq[string]): string =
  ## The message enum and the envelope struct. Handler params ride in the
  ## envelope, deduped by name.
  var msgFields: seq[string]
  var seen = initHashSet[string]()
  for h in handlers:
    for p in h.params:
      if p.name in seen: continue
      seen.incl(p.name)
      msgFields.add("    " & ctx.dType(p.typ) & " " & p.name & ";")
  "enum " & d.name & "MsgKind { " & variants.join(", ") & " }\n\n" &
    "struct " & d.name & "Msg {\n" &
    "    " & d.name & "MsgKind kind;\n" &
    (if msgFields.len > 0: msgFields.join("\n") & "\n" else: "") & "}\n\n"

proc actorHasMessages*(d: Decl): bool =
  ## Whether this actor has anything to receive. A specimen actor
  ## (`actor X: ...`) has no handlers and no shutdown, so it gets no
  ## envelope type, no mailbox and no drain — and the entry point must not
  ## try to start one. Both sites ask THIS, so they cannot disagree.
  let (handlers, _, hasShutdown) = collectHandlers(d)
  handlers.len > 0 or hasShutdown

proc genDDrain*(d: Decl, hasShutdown: bool): string =
  ## The actor's coroutine body, as a DrainProc: drain what is waiting and
  ## report whether any work happened. The runtime parks the coroutine when
  ## it returns false and tuckNotifySend wakes it after a send.
  ##
  ## Shape differs from the Odin backend deliberately: there the drain loops
  ## forever and yields itself, here the runtime owns the loop, so this
  ## returns a bool. Same behaviour, one less place to get the yield wrong.
  let singleton = actorSingletonName(d.name)
  let finishedGuard = if hasShutdown:
                        "    if (" & singleton & ".finished) return false;\n"
                      else: ""
  "bool drain_" & d.name & "() {\n" & finishedGuard &
    "    bool did = false;\n" &
    "    " & d.name & "Msg msg;\n" &
    "    while (rt.dequeue(" & singleton & ".mailbox, msg)) {\n" &
    "        handleMsg_" & d.name & "(" & singleton & ", msg);\n" &
    "        did = true;\n    }\n    return did;\n}\n\n"

proc dExternTodo*(mem: Decl): string =
  ## Why this extern cannot emit a binding yet, or "" when it can. A TODO
  ## comment is visible in the output, and the D compiler names the missing
  ## symbol only if a call site actually references it — loud where it
  ## matters, without blocking every program that merely imports the module.
  ##
  ## THREE KINDS OF EXTERN, and they are not interchangeable:
  ##   1. runtime  — no header, no impl: implemented by tuck_rt (forwarder)
  ##   2. C FFI    — `header:` names a real C header: a native binding
  ##   3. shim     — `impl: <backend> "module"`: a BACKEND-LANGUAGE module
  ## Only the third is still unhandled here, and only when it names no `d`
  ## module — there is nothing for this backend to point at.
  if mem.externImpl.len > 0:
    var hasD = false
    for (backend, _) in mem.externImpl:
      if backend == "d": hasD = true
    if not hasD:
      return "// D backend TODO: extern " & mem.name &
             " needs an `impl: d \"...\"` module\n"
  ""

proc genDCBinding*(ctx: var DCodegenCtx, mem: Decl): string =
  ## A real C symbol (spec: `extern [c, header: "zlib.h"]`). D declares the
  ## prototype with the C calling convention and the linker resolves it —
  ## the identical construct to Nim's {.importc, header.} and Odin's
  ## `foreign` block, and simpler than either: D needs no header include,
  ## because the declaration IS the binding.
  ##
  ## `[emit: "c_fn"]` names the C symbol when it differs from the Tuck name;
  ## `pragma(mangle)` is what keeps the D-side name while linking against
  ## the C one.
  var params: seq[string]
  for prm in mem.fnParams:
    params.add(ctx.dType(prm.typ) & " " & prm.name)
  let retStr = ctx.dType(mem.fnReturnType)
  # The library this symbol lives in, collected for a top-level pragma(lib).
  # A vendored `.c` is compiled to an object by the driver (as the Nim
  # backend takes it via {.compile.}), so link the object.
  if mem.externLib != "":
    ctx.cLibs.incl(if mem.externLib.endsWith(".c"):
                     mem.externLib[0 ..< mem.externLib.len - 2] & ".o"
                   else: mem.externLib)
  let cName = if mem.externEmit != "": mem.externEmit else: mem.name
  let mangle = if cName != mem.name:
                 " pragma(mangle, \"" & cName & "\")"
               else: ""
  "extern (C)" & mangle & " " & retStr & " " & mem.name & "(" &
    params.join(", ") & ");\n"

proc externShapeArg*(ctx: var DCodegenCtx, ret: Type, retStr: string): string =
  ## A record-returning extern hands the runtime the shape to FILL, as a
  ## template argument: the struct was hoisted by this module, so the
  ## runtime cannot name it (see tuck_rt.d's tuckRec). "" when the return
  ## carries no record and the runtime's own type suffices.
  if ret != nil and ret.kind == tkRecord:
    return "!(" & retStr & ")"
  let payload = bangInner(ret)
  if payload != nil and payload.kind == tkRecord:
    return "!(rt.TuckResult!(" & ctx.dType(payload) & "))"
  ""

proc genDImplFwd*(ctx: var DCodegenCtx, mem: Decl, module: string): string =
  ## `impl: d "..."` — the bodies live in a named D module rather than the
  ## runtime. Mirrors genImplForwarders (codegen_odin.nim): a local
  ## forwarder into the aliased module, so call sites read exactly like
  ## Nim's/Odin's own bare-name reach. `tuck.nim`'s D build step adds the
  ## module's directory as an extra dmd `-I`, since a D `import` is a bare
  ## module name, not a path — there is nothing to rebase or copy here.
  let alias = dImplAlias(module)
  ctx.implMods[alias] = module
  let retStr = ctx.dType(mem.fnReturnType)
  var args: seq[string]
  for p in mem.fnParams: args.add(p.name)
  let call = alias & "." & mem.name & "(" & args.join(", ") & ")"
  let body = if retStr == "void": call else: "return " & call
  retStr & " " & mem.name & "(" & ctx.genDParams(mem.fnParams) & ") {\n" &
    "    " & body & ";\n" & "}\n"

proc genDCType*(ctx: var DCodegenCtx, mem: Decl): string =
  ## A C type declared inside an `extern [c, header: ...]` block.
  ##
  ## A FIELDLESS one is an opaque handle — `typedef struct Foo Foo;` with no
  ## definition — so its size is unknown and it can only be held as a
  ## pointer. D spells that as an incomplete struct plus an alias to a
  ## pointer at it, the same shape Nim's {.incompleteStruct.} + `ptr` gives.
  ##
  ## A struct WITH fields is declared field-for-field with the C calling
  ## convention, so it passes by value with the C ABI.
  if mem.typeBody == nil: return ""
  # A C ENUM: `type Op = {OP_ADD = 10, ...}`. D's enum with explicit values
  # is the identical construct, and extern(C) fixes its underlying type to
  # the C one.
  if mem.typeBody.kind == tkSum:
    var tags: seq[string]
    for v in mem.typeBody.variants:
      tags.add(if v.value != "": v.name & " = " & v.value else: v.name)
    return "extern (C) enum " & mem.name & " { " & tags.join(", ") & " }\n"
  if mem.typeBody.kind != tkRecord: return ""
  if mem.typeBody.fields.len == 0:
    return "struct " & mem.name & "Obj;\n" &
           "alias " & mem.name & " = " & mem.name & "Obj*;\n"
  var res = "extern (C) struct " & mem.name & " {\n"
  for f in mem.typeBody.fields:
    res.add("    " & ctx.dType(f.typ) & " " & f.name & ";\n")
  res.add("}\n")
  res

proc genDPayloadSum*(ctx: var DCodegenCtx, d: Decl, body: Type): string =
  ## A PAYLOAD-carrying sum: a discriminant plus one struct per variant,
  ## overlapped in a union.
  ##
  ## This is D's parallel of NIM's case-object, not of Odin's: Odin has a
  ## native tagged union that carries its own tag and has no `.kind` field
  ## (codegen_odin.nim's `X :: union {...}`), so the three backends do NOT
  ## share a representation here and a fix for one is not a fix for another.
  var res = "enum " & d.name & "Kind { "
  var tags: seq[string]
  for v in body.variants: tags.add(v.name)
  res.add(tags.join(", ") & " }\n\n")
  for v in body.variants:
    if v.fields.len == 0: continue
    res.add("struct " & d.name & "_" & v.name & " {\n")
    for f in v.fields:
      res.add("    " & ctx.dType(f.typ) & " " & f.name & ";\n")
    res.add("}\n\n")
  res.add("struct " & d.name & " {\n")
  res.add("    " & d.name & "Kind kind;\n")
  res.add("    union {\n")
  for v in body.variants:
    if v.fields.len == 0: continue
    res.add("        " & d.name & "_" & v.name & " " &
            v.name.toLowerAscii() & ";\n")
  res.add("    }\n}\n")
  res

proc genDValidate*(ctx: var DCodegenCtx, d: Decl): string =
  ## spec 4.7: an invariant-carrying type validates at every PRODUCTION
  ## site. Emitted behind `version(tuckNoInvariants)` — opt-OUT, so the
  ## checks stay on in a release build by default.
  ##
  ## The Nim backend hardcodes `when not defined(release)`, which makes the
  ## checks impossible to keep in the build where a violated invariant means
  ## corrupt data. ROADMAP's 2026-08-25 ruling 5 reverses that; this backend
  ## is written to the ruling rather than inheriting the bug.
  var checks: seq[string]
  let savedFields = ctx.fieldVars
  let savedPrefix = ctx.fieldPrefix
  ctx.fieldVars.clear()
  for f in d.typeBody.fields: ctx.fieldVars.incl(f.name)
  ctx.fieldPrefix = "self."
  for member in d.typeMembers:
    if member != nil and member.kind == dkExpr:
      let cond = ctx.genDExpr(member.expr)
      # An explicit test + abort, NOT `assert`: dmd's -release strips
      # asserts, which would silently undo the ruling this guard exists to
      # implement (verified — an assert-based version passed in release).
      checks.add("        if (!(" & cond & "))\n" &
                 "            rt.tuckInvariantFailed(\"" &
                 cond.replace("\"", "'") & "\", \"" & d.name & "\");")
  ctx.fieldVars = savedFields
  ctx.fieldPrefix = savedPrefix
  if checks.len == 0: return ""
  "\nvoid validate_" & d.name & "(" & d.name & " self)\n{\n" &
    "    version (tuckNoInvariants) {} else\n    {\n" &
    checks.join("\n") & "\n    }\n}\n\n" &
    d.name & " __validated_" & d.name & "(" & d.name & " v)\n{\n" &
    "    validate_" & d.name & "(v);\n    return v;\n}\n"

proc genDPendingStub*(ctx: var DCodegenCtx, mem: Decl): string =
  ## A pending fn runs as a stub: log to stderr (the Nim backend's stream —
  ## the Odin one prints to stdout, a divergence recorded in the ledger),
  ## return the zero value. The payload rides a template param exactly like
  ## the Nim backend's generic stub, absorbing any record representation.
  if mem.kind != dkFn: return ""
  let retStr = ctx.dType(mem.fnReturnType)
  let params = if mem.fnParams.len > 0: "(T)(T payload)" else: "()"
  result = retStr & " " & mem.name & params & " {\n" &
           "    stderr.writeln(\"TUCK PENDING: " & mem.name &
           " invoked (not implemented)\");\n"
  if retStr != "void":
    result.add("    return typeof(return).init;\n")
  result.add("}\n")

proc genDFnSig*(ctx: var DCodegenCtx, d: Decl): string =
  ## `fnsig NAME = {params} -> ret` — a named callback shape, filled by a
  ## `:fnRef` and called through.
  ##
  ## D's `function` pointer is the identical construct, and it is the RIGHT
  ## one rather than `delegate`: Tuck has no captured environment (a "closure"
  ## is a baked record whose body reads the record's own fields), so a bare
  ## pointer loses nothing and is what a C callback needs anyway. Nim has to
  ## reach for {.cdecl.} on the C path for exactly this reason.
  var params: seq[string]
  for prm in d.sigParams:
    params.add(ctx.dType(prm.typ) & " " & prm.name)
  let retStr =
    if d.sigReturn != nil and not (d.sigReturn.kind == tkNamed and
                                   d.sigReturn.name == "void"):
      ctx.dType(d.sigReturn)
    else: "void"
  let conv = if d.sigIsCCallback: "extern (C) " else: ""
  "alias " & d.name & " = " & conv & retStr & " function(" &
    params.join(", ") & ");\n"

proc dPackedKey*(ctx: var DCodegenCtx, d: Decl, domains: seq[seq[string]],
                comboCount: int): string =
  var parts: seq[string]
  var stride = comboCount
  for c in 0 ..< domains.len:
    stride = stride div domains[c].len
    let ordExpr = ctx.dColumnOrdinal(domains[c], d.fnParams[c].name)
    parts.add(if stride == 1: ordExpr else: ordExpr & " * " & $stride)
  parts.join(" + ")

proc dCollectRows*(ctx: var DCodegenCtx, d: Decl, rowPats: var seq[seq[string]],
                  rowBodies: var seq[string]) =
  for s in d.fnBody.stmts:
    if s.kind != exkMatch or s.arms.len == 0: continue
    rowPats.add(dDecisionRowPatterns(s))
    rowBodies.add(ctx.genDExpr(s.arms[0].body))

proc genDChainedDecision*(ctx: var DCodegenCtx, d: Decl,
                         retTypeStr: string): string =
  ## An open column domain cannot be packed, so the rows become guards in
  ## order, and a table with no catch-all needs a zero value to fall out on.
  var lines: seq[string]
  var hasCatchAll = false
  for s in d.fnBody.stmts:
    if s.kind != exkMatch or s.arms.len == 0: continue
    let cond = ctx.dRowCondition(d, s.arms[0])
    let body = ctx.genDExpr(s.arms[0].body)
    if cond == "":
      hasCatchAll = true
      lines.add("    return " & body & ";")
    else:
      lines.add("    if (" & cond & ") return " & body & ";")
  if not hasCatchAll and retTypeStr != "void":
    lines.add("    return " & retTypeStr & ".init;")
  lines.join("\n")

proc genDTaskDecl*(ctx: var DCodegenCtx, d: Decl): string =
  ## `task name(...)` — an ordinary D function. What makes it a task is the
  ## CALL SITE: calling it schedules a coroutine, and binding its result
  ## awaits completion (spec §9.2). The body needs no marking of its own.
  let retStr = ctx.dType(d.taskReturnType)
  injectTailReturn(d.taskBody, retStr)
  result = retStr & " " & d.name & "(" & ctx.genDParams(d.taskParams) & ") {\n"
  ctx.indent = 1
  ctx.definedVars.clear()
  ctx.currentParams = @[]
  for p in d.taskParams:
    ctx.definedVars.incl(p.name)
    ctx.currentParams.add(FieldDef(name: p.name, typ: p.typ, span: p.span))
  result.add(ctx.genDStmtOrBlock(d.taskBody))
  result.add(dTrailingReturn(d.taskBody, retStr, 1))
  ctx.indent = 0
  ctx.currentParams = @[]
  result.add("}\n")

proc genDRegister*(ctx: var DCodegenCtx, d: Decl): string =
  ## A memory-mapped register (spec 8): named masks plus accessors reading
  ## and writing through a typed pointer at the MMIO address.
  ##
  ## Same lowering as the Odin backend, for the same reason — neither has
  ## Nim's `registerMMIO` macro to hand the layout to. The DECODING is
  ## shared (ast_query.decodeBitField); only the spelling is here.
  ##
  ## `volatile` in spirit: the pointer is shared with hardware. D has no
  ## volatile qualifier — core.volatile's volatileLoad/Store are the
  ## supported spelling — so an optimiser is free to cache a read across
  ## statements. Correct for the examples, and a real embedded target should
  ## route these through core.volatile.
  var consts: seq[string]
  var accessors: seq[string]
  for f in d.regFields:
    let bf = decodeBitField(d.name, f)
    consts.add(dBitConsts(bf))
    if bf.canRead: accessors.add(dBitGetter(bf, d.name))
    if bf.canWrite: accessors.add(dBitSetter(bf, d.name))
  "__gshared uint* " & d.name & " = cast(uint*)(" & d.regAddress & ");\n" &
    consts.join("") & accessors.join("")

proc dRegistryRaiseProc*(ctx: var DCodegenCtx, d: Decl,
                        v: VariantDef): string =
  ## `raise_<Registry>_<Event>` — record the event as latest, then run its
  ## handlers. Lowering already flattened `Registry.raise Event {...}` into
  ## a call to this, so codegen never learns registries exist at the call
  ## site.
  var params: seq[string]
  var assigns: seq[string]
  for f in v.fields:
    params.add(ctx.dType(f.typ) & " " & f.name)
    assigns.add(f.name & ": " & f.name)
  let assignStr = if assigns.len > 0: ", " & assigns.join(", ") else: ""
  "void raise_" & d.name & "_" & v.name & "(" & params.join(", ") &
    ") {\n    latest" & d.name & " = " & d.name & "(" & d.name & "Kind." &
    v.name & assignStr & ");\n" & ctx.dRegistryHandlerCalls(d, v) & "}\n\n"

proc genDHandlerCase*(ctx: var DCodegenCtx, d: Decl,
                     h: ActorMsgHandler): string =
  ## One dispatch arm: the envelope's fields are already named as the
  ## handler's params, so the body reads them directly.
  let saved = ctx.fieldVars
  let savedPrefix = ctx.fieldPrefix
  ctx.fieldVars.clear()
  for f in d.actorFields: ctx.fieldVars.incl(f.name)
  ctx.fieldPrefix = "self."
  ctx.definedVars.clear()
  for p in h.params: ctx.definedVars.incl(p.name)
  ctx.indent = 3
  var body = ctx.genDStmtOrBlock(h.body)
  ctx.indent = 0
  ctx.fieldVars = saved
  ctx.fieldPrefix = savedPrefix
  var unpack = ""
  for p in h.params:
    unpack.add("            auto " & p.name & " = msg." & p.name & ";\n")
  "        case " & d.name & "MsgKind." & msgVariantName(h.name) & ":\n" &
    unpack & body & "            break;\n"

proc genDSendHelper*(ctx: var DCodegenCtx, d: Decl,
                    h: ActorMsgHandler): string =
  ## Enqueue an envelope. A FULL ring drops (spec 9.1) — matching the other
  ## backends, and see the actor playground for what that costs today.
  var params: seq[string]
  var ctorArgs = d.name & "MsgKind." & msgVariantName(h.name)
  for p in h.params:
    params.add(ctx.dType(p.typ) & " " & p.name)
    ctorArgs.add(", " & p.name)
  let sep = if params.len > 0: ", " else: ""
  "void send" & h.name.capitalize() & "_" & d.name & "(ref " & d.name &
    " self" & sep & params.join(", ") & ") {\n" &
    "    cast(void) rt.enqueue(self.mailbox, " & d.name & "Msg(" &
    ctorArgs & "));\n    rt.tuckNotifySend();\n}\n\n"

proc genDActorState*(ctx: var DCodegenCtx, d: Decl,
                    hasShutdown: bool, hasMessages: bool): string =
  ## The actor's own fields, its mailbox, and — when it can be shut down —
  ## the flag the drain checks.
  var fields = ctx.dActorFieldLines(d)
  # No handlers means no envelope type exists, so there is nothing to hold a
  # mailbox OF. Such an actor is a specimen (`actor X: ...`) and emits only
  # its state, matching what the Nim backend emits for the same source.
  if hasMessages:
    fields.add("    rt.Mailbox!(" & d.name & "Msg, " & actorQueueSize(d) &
               ") mailbox;")
  if hasShutdown: fields.add("    bool finished;")
  if fields.len == 0: fields.add("    // no state")
  "struct " & d.name & " {\n" & fields.join("\n") & "\n}\n\n"

proc genDExternFwd*(ctx: var DCodegenCtx, mem: Decl): string =
  ## An rt-implemented extern emits a forwarder calling `rt.<name>` — D has
  ## no cross-module scope merge that would make the bare name resolve.
  if mem.kind != dkFn: return ""
  for (backend, module) in mem.externImpl:
    if backend == "d": return ctx.genDImplFwd(mem, module)
  let todo = dExternTodo(mem)
  if todo != "": return todo
  # A C-header extern binds a real symbol rather than forwarding to tuck_rt.
  if mem.externHeader != "": return ctx.genDCBinding(mem)
  let ret = mem.fnReturnType
  let retStr = ctx.dType(ret)
  let emitName = if mem.externEmit != "": mem.externEmit else: mem.name
  # A generic extern (`fn toStr[T]`) forwards as a D function template —
  # the same construct the runtime's own toStr(T)(T) already is.
  let tmplParams = if mem.fnGenerics.len > 0:
                     "(" & mem.fnGenerics.join(", ") & ")"
                   else: ""
  var args: seq[string]
  for p in mem.fnParams: args.add(p.name)
  let call = "rt." & emitName & ctx.externShapeArg(ret, retStr) &
             "(" & args.join(", ") & ")"
  let body = if retStr == "void": call else: "return " & call
  retStr & " " & mem.name & tmplParams & "(" &
    ctx.genDParams(mem.fnParams) & ") {\n" & "    " & body & ";\n" & "}\n"

proc genDPendingBlock*(ctx: var DCodegenCtx, d: Decl): string =
  for mem in d.mixinMembers:
    let code = ctx.genDPendingStub(mem)
    if code != "": result.add(code & "\n")

proc genDPackedDecision*(ctx: var DCodegenCtx, d: Decl,
                        domains: seq[seq[string]], comboCount: int): string =
  ## Every column domain is enumerable, so the whole table collapses to one
  ## switch over a packed integer key (spec 6.1). A plain `switch`, not
  ## `final switch`: the key is an int, whose domain D cannot enumerate, and
  ## the last group is the default.
  var rowPats: seq[seq[string]]
  var rowBodies: seq[string]
  ctx.dCollectRows(d, rowPats, rowBodies)
  let groups = groupByOutcome(domains, comboCount, rowPats, rowBodies)
  var lines: seq[string]
  lines.add("    switch (" & ctx.dPackedKey(d, domains, comboCount) &
            ") {   // packed decision key")
  for gi, g in groups:
    if gi == groups.len - 1:
      lines.add("    default: return " & g.outcome & ";")
    else:
      for k in g.keys:
        lines.add("    case " & $k & ":")
      lines.add("        return " & g.outcome & ";")
  lines.add("    }")
  lines.join("\n")

proc genDRegistry*(ctx: var DCodegenCtx, d: Decl): string =
  ## An event registry (spec Part 10): the event type, the latest-event
  ## global, and one raise proc per event.
  ##
  ## D resolves module-level declarations lazily like Odin, so a raise proc
  ## may call a handler declared after it — no forward declarations needed.
  result = ctx.dRegistryEventStruct(d) & "\n"
  result.add("__gshared " & d.name & " latest" & d.name & ";\n\n")
  for v in d.variants:
    result.add(ctx.dRegistryRaiseProc(d, v))

proc genDDispatch*(ctx: var DCodegenCtx, d: Decl,
                  handlers: seq[ActorMsgHandler], shutdownBody: Expr,
                  hasShutdown: bool): string =
  ## The switch routing an envelope to its handler.
  var cases: seq[string]
  for h in handlers: cases.add(ctx.genDHandlerCase(d, h))
  if hasShutdown:
    # Stops the actor rather than adding a message: run the arm's body, then
    # set the flag the drain checks.
    var sdBody = ""
    if shutdownBody != nil:
      # The shutdown arm reads and writes the actor's own fields just like
      # any other arm, so it needs the same field context — without it
      # `total = total` looked like a new local whose type nothing had
      # settled, and the no-auto rule refused it.
      let saved = ctx.fieldVars
      let savedPrefix = ctx.fieldPrefix
      ctx.fieldVars.clear()
      for f in d.actorFields: ctx.fieldVars.incl(f.name)
      ctx.fieldPrefix = "self."
      ctx.indent = 3
      sdBody = ctx.genDStmtOrBlock(shutdownBody)
      ctx.indent = 0
      ctx.fieldVars = saved
      ctx.fieldPrefix = savedPrefix
    cases.add("        case " & d.name & "MsgKind.msgShutdown:\n" & sdBody &
              "            self.finished = true;\n            break;\n")
  "void handleMsg_" & d.name & "(ref " & d.name & " self, " & d.name &
    "Msg msg) {\n    final switch (msg.kind) {\n" & cases.join("") &
    "    }\n}\n\n"

proc genDExternBlock*(ctx: var DCodegenCtx, d: Decl): string =
  for mem in d.mixinMembers:
    if mem == nil: continue
    # A C struct or callback signature declared in the block, not a fn.
    if mem.kind == dkType:
      let t = ctx.genDCType(mem)
      if t != "": result.add(t & "\n")
      continue
    if mem.kind == dkFnSig:
      result.add(ctx.genDFnSig(mem) & "\n")
      continue
    let code = ctx.genDExternFwd(mem)
    if code != "": result.add(code & "\n")

proc genDDecisionTable*(ctx: var DCodegenCtx, d: Decl): string =
  ## `decision` (spec 6.1): a table of rows, emitted either as one switch
  ## over a packed key (every column enumerable) or as guards in row order.
  ## The combinatorics come from codegen_table, shared with both other
  ## backends — only the spelling differs here.
  let retTypeStr = ctx.dType(d.fnReturnType)
  let (domains, allEnumerable, comboCount) = columnDomains(ctx.module, d)
  let body = if allEnumerable and comboCount > 0:
               ctx.genDPackedDecision(d, domains, comboCount)
             else:
               ctx.genDChainedDecision(d, retTypeStr)
  retTypeStr & " " & d.name & "(" & ctx.genDParams(d.fnParams) & ") {\n" &
    body & "\n}\n"

proc genDActor*(ctx: var DCodegenCtx, d: Decl): string =
  ## An actor is a SINGLETON SERVICE (spec 9.1): one instance per declared
  ## type, no construction, alive for the whole program. It emits its message
  ## envelope, state struct, the singleton itself, dispatch, a drain and one
  ## send helper per handler.
  let (handlers, shutdownBody, hasShutdown) = collectHandlers(d)
  var variants: seq[string]
  for h in handlers: variants.add(msgVariantName(h.name))
  if hasShutdown: variants.add("msgShutdown")
  let hasMessages = variants.len > 0
  if hasMessages:
    result = ctx.genDMsgEnvelope(d, handlers, variants)
  result.add(ctx.genDActorState(d, hasShutdown, hasMessages))
  # One instance per declared actor: sends and field reads target it, so
  # `Counter.total` means `counterSingleton.total`.
  result.add("__gshared " & d.name & " " & actorSingletonName(d.name) &
             ";\n\n")
  if not hasMessages: return
  result.add(ctx.genDDispatch(d, handlers, shutdownBody, hasShutdown))
  result.add(genDDrain(d, hasShutdown))
  for h in handlers:
    result.add(ctx.genDSendHelper(d, h))

proc genDFnDecl*(ctx: var DCodegenCtx, d: Decl, nameOverride = "",
                refSelf = false): string =
  if d.fnGenerics.len > 0: return dUnsupported("generic fn " & d.name)
  if d.isDecision: return ctx.genDDecisionTable(d)
  # A registry handler is declared as `Registry.Event`; the dot is not a D
  # identifier character, and the raise proc calls the sanitised name.
  let fnName = if nameOverride != "": nameOverride
               else: dHandlerFnName(d.name)
  let retStr = ctx.dType(d.fnReturnType)
  # A fallible fn wraps every return in the carrier; the arms below need to
  # know the payload type to name terr!(T). Restored after the body, since
  # a nested emission may set its own.
  let payload = bangInner(d.fnReturnType)
  ctx.retWrapped = payload != nil
  ctx.retInnerT = payload
  ctx.retInnerD =
    if payload == nil: ""
    else:
      let inner = ctx.dType(payload)
      if inner == "void": "rt.TuckUnit" else: inner
  # Implicit return: the value flowing at the end of a body is the result.
  # ast_query's shared version, not a private port — the Odin backend kept
  # its own copy and it has since drifted (no matchArmsReturn guard, so a
  # tail match whose arms return gets wrapped in a value-position case).
  injectTailReturn(d.fnBody, retStr)
  result = ctx.dCallConv(d) & retStr & " " & fnName & "(" &
           ctx.genDParams(d.fnParams, refSelf) & ") {\n"
  ctx.indent = 1
  ctx.definedVars.clear()
  ctx.currentParams = @[]
  for p in d.fnParams:
    ctx.definedVars.incl(p.name)
    ctx.currentParams.add(FieldDef(name: p.name, typ: p.typ, span: p.span))
  result.add(ctx.genDStmtOrBlock(d.fnBody))
  result.add(dTrailingReturn(d.fnBody, retStr, 1))
  ctx.indent = 0
  ctx.currentParams = @[]
  ctx.retWrapped = false
  ctx.retInnerD = ""
  ctx.retInnerT = nil
  result.add("}\n")

proc genDObjectDecl*(ctx: var DCodegenCtx, d: Decl): string =
  ## `object` — a plain D struct plus its member fns as qualified free
  ## procs. Composition (+Mixin) and satisfies arrive with the interface
  ## work.
  result = "struct " & d.name & " {\n"
  for f in d.objFields:
    result.add("    " & ctx.dFieldType(d.name, f) & " " & f.name & ";\n")
  result.add("}\n\n")
  for mem in d.objMembers:
    if mem == nil: continue
    if mem.kind == dkFn:
      result.add(ctx.genDFnDecl(mem, memberProcNameD(d.name, mem.name),
                                refSelf = true) & "\n")
    elif isCompositionEntry(mem):
      return dUnsupported("object composition (+Type) in " & d.name)

proc genDMixinBlock*(ctx: var DCodegenCtx, d: Decl): string =
  ## A `mixin` is a named bucket of functions (spec §5.1), not a type.
  ##
  ## A member taking `self` MATERIALISES on every object that composes it —
  ## lowering.composeObject has already spliced it in there — so emitting it
  ## again here would define the same function twice. What is left is a
  ## member that takes no self: an ordinary free function that happens to be
  ## filed under a mixin.
  for mem in d.mixinMembers:
    if mem == nil or mem.kind != dkFn: continue
    if mem.isPending or mem.fnBody == nil or takesSelf(mem): continue
    result.add(ctx.genDFnDecl(mem) & "\n")

proc genDTypeDecl*(ctx: var DCodegenCtx, d: Decl): string =
  if d.generics.len > 0: return dUnsupported("generic type " & d.name)
  let body = d.typeBody
  if body == nil: return ""
  if body.kind == tkSum and not sumHasPayload(body):
    # A payload-free sum is exactly a D enum — same construct, same checks.
    var tags: seq[string]
    for v in body.variants: tags.add(v.name)
    return "enum " & d.name & " { " & tags.join(", ") & " }\n"
  if body.kind == tkRecord:
    # A named record is a plain D struct — the value type Tuck means.
    var res = "struct " & d.name & " {\n"
    for f in body.fields:
      res.add("    " & ctx.dFieldType(d.name, f) & " " & f.name & ";\n")
    res.add("}\n")
    res.add(ctx.genDValidate(d))
    for member in d.typeMembers:
      if member != nil and member.kind == dkFn:
        res.add("\n" & ctx.genDFnDecl(member) & "\n")
    return res
  if body.kind in {tkNamed, tkApp, tkRename, tkEffect}:
    # `type Ms = int` and friends. The DISTINCTNESS was enforced by the
    # checker; the emitted carrier is the underlying type, as in the Nim
    # backend where the distinct is likewise erased for arithmetic.
    let under = ctx.dDeclType(body)
    if under != "": return "alias " & d.name & " = " & under & ";\n"
    return dUnsupported("type alias " & d.name & " to an unmapped type")
  if body.kind == tkSum: return ctx.genDPayloadSum(d, body)
  dUnsupported("type " & d.name & " (unmapped type body)")

proc genDDecl*(ctx: var DCodegenCtx, d: Decl): string =
  if d == nil: return ""
  # Imported type decls are injected for checking only; the origin module
  # emits them (mirrors codegen.nim:1756 / codegen_odin.nim:2234).
  if d.kind == dkType and d.span.file.startsWith(ImportedTypeMarker):
    return ""
  case d.kind
  of dkType: ctx.genDTypeDecl(d)
  of dkObject: ctx.genDObjectDecl(d)
  of dkRegistry: ctx.genDRegistry(d)
  of dkPool:
    # spec 7.2: one module-level instance of a fixed-count pool.
    # `Pool.acquire` reaches the runtime's generic proc — see the
    # RtByPointer list, which routes it as rt.acquire(&Pool).
    "__gshared rt.ObjectPool!(" & ctx.dType(d.poolElem) & ", " &
      $d.poolCount & ") " & d.name & ";\n"
  of dkFn:
    if d.isPending or d.isExtern: ""   # pending: M3; bare extern fn: via block
    else: ctx.genDFnDecl(d)
  of dkMixin: ctx.genDMixinBlock(d)
  of dkExtern: ctx.genDExternBlock(d)
  of dkPending: ctx.genDPendingBlock(d)
  of dkActor: ctx.genDActor(d)
  of dkTask: ctx.genDTaskDecl(d)
  of dkExpr: ""   # top-level statements are collected by emitBody
  of dkConst:
    # A literal is a true compile-time constant (`enum` is D's word for
    # one); structured data becomes an immutable module-level value.
    if d.constVal != nil and d.constVal.kind == exkLit:
      "enum " & d.name & " = " & ctx.genDExpr(d.constVal) & ";\n"
    else:
      "immutable " & d.name & " = " & ctx.genDExpr(d.constVal) & ";\n"
  of dkRegister: ctx.genDRegister(d)
  of dkStaticAssert:
    # D checks this at COMPILE time, natively — the identical construct.
    # (The Odin backend collects these into a runtime `assert` in its entry
    # point, because Odin's #assert does not reach here; Nim has
    # `static: assert`. D needs no such workaround.)
    "static assert(" & ctx.genDExpr(d.assertExpr) & ");\n"
  of dkErrors: ctx.genDErrHandler(d)
  of dkImport: ""
  of dkSelect: dUnsupported("top-level on select (arrives with the Fiber runtime)")
  of dkFnSig: ctx.genDFnSig(d)
  of dkSatisfies: dUnsupported("top-level satisfies (M4)")
  of dkInterface: ctx.genDInterface(d)
  of dkWhen: ""   # resolved away by modules.resolveWhenBlocks before codegen
