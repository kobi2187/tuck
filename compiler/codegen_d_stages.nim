# compiler/codegen_d_stages.nim
#
# Stackless transform, phase 3 (#216): print a frame fn's StagePlan
# (stages.nim) as D — the twin of codegen_stages.nim (Nim), which explains
# the shape. Each stage's statements sit inside `with (*tuckF) { ... }`, so
# the frame's fields read by their own names and the ordinary statement
# emitter prints the code between the cuts unchanged. A `return` finishes
# the frame through its `TuckRetˑf` function (genDReturn, via
# ctx.frameRet).
#
# Frames are GC-allocated: a frame's fields hold D slices the GC owns, and a
# malloc'd block is not scanned. A jump that leaves scopes is a small
# function of its own (`TuckJˑfˑN`): D has no statement-expression to run
# the scope exits and return in one place.
import std/[strutils, sets, tables]
import ast, stages
import codegen_d_ctx
import ./codegen_d

proc frameType(name: string): string = "TuckFˑ" & name
proc stageName(name: string, k: int): string = "TuckSˑ" & name & "ˑ" & $k
proc retProc(name: string): string = "TuckRetˑ" & name
proc exitProc(name: string): string = "TuckExitˑ" & name
proc scopeExit(name: string, sc: int): string = "TuckXˑ" & name & "ˑ" & $sc
proc jumpProc(name: string, n: int): string = "TuckJˑ" & name & "ˑ" & $n

proc stacklessHelperD*(calleeStr, prefix: string): string =
  ## `mod.task` -> `mod.<prefix>task`: a frame's helpers sit beside it.
  let dot = calleeStr.rfind('.')
  if dot < 0: prefix & calleeStr else: calleeStr[0 .. dot] & prefix & calleeStr[dot + 1 .. ^1]

proc isVoid(ctx: var DCodegenCtx, d: Decl): bool = ctx.dType(d.fnReturnType) == "void"

proc resultType(ctx: var DCodegenCtx, d: Decl): string =
  if ctx.isVoid(d): "bool" else: ctx.dType(d.fnReturnType)

# --- the frame type, constructor, return -----------------------------------------

proc subTypes(ctx: var DCodegenCtx, plan: StagePlan): seq[string] =
  ## The frame types this frame embeds (#219), qualified as its calls name them.
  for st in plan.stages:
    let t = st.term
    if t.kind in {tkCall, tkAwait} and t.embed:
      let q = stacklessHelperD(ctx.genDExpr(t.call.callee), "TuckFˑ")
      if q notin result: result.add q

proc genSubUnion(ctx: var DCodegenCtx, d: Decl, plan: StagePlan): string =
  ## `tuckSub`'s type: a union of every frame this one embeds.
  let subs = ctx.subTypes(plan)
  if subs.len == 0: return ""
  result = "union TuckUˑ" & d.name & "\n{\n"
  for i, q in subs: result.add "    " & q & " s" & $i & ";\n"
  result.add "}\n\n"

proc genFrameType(ctx: var DCodegenCtx, d: Decl, plan: StagePlan): string =
  let r = ctx.resultType(d)
  result = ctx.genSubUnion(d, plan) & "struct " & frameType(d.name) & "\n{\n    rt.TuckFrameHdr tuckHdr;\n" &
           "    rt.TuckSlot!(" & r & ")* tuckRes;\n    " & r & "* tuckDest;\n"
  for p in d.fnParams: result.add "    " & ctx.dType(p.typ) & " " & p.name & ";\n"
  for f in plan.fields:
    let t = if f.isSlot: "rt.TuckSlot!(" & (if f.typ == nil: "bool" else: ctx.dType(f.typ)) & ")"
            else: ctx.dType(f.typ)
    result.add "    " & t & " " & f.name & ";\n"
  for lp in plan.loops:
    if lp.kind == lkSeq: result.add "    " & ctx.dType(lp.elemType) & " " & lp.varName & ";\n"
  for k in 0 ..< plan.defers.len: result.add "    bool tuckDefer" & $k & ";\n"
  if plan.subs.len > 0: result.add "    TuckUˑ" & d.name & " tuckSub;\n"
  result.add "}\n"

proc genFrameNew(ctx: var DCodegenCtx, d: Decl): string =
  let r = ctx.resultType(d)
  var params = @[frameType(d.name) & "* tuckAt", "rt.TuckSlot!(" & r & ")* tuckRes",
                 r & "* tuckDest"]
  for p in d.fnParams: params.add ctx.dType(p.typ) & " " & p.name
  # `tuckAt`: storage the caller provides (its `tuckSub`, or main's stack),
  # or null for the (GC) heap (#219).
  result = frameType(d.name) & "* TuckNewˑ" & d.name & "(" & params.join(", ") & ")\n{\n" &
           "    auto f = tuckAt;\n" &
           "    if (f is null) f = new " & frameType(d.name) & ";\n" &
           "    else { *f = " & frameType(d.name) & ".init; f.tuckHdr.embedded = true; }\n" &
           "    f.tuckHdr.stage = &" & stageName(d.name, 0) & ";\n" &
           "    f.tuckRes = tuckRes;\n    f.tuckDest = tuckDest;\n"
  for p in d.fnParams: result.add "    f." & p.name & " = " & p.name & ";\n"
  result.add "    return f;\n}\n"

proc genRet(ctx: var DCodegenCtx, d: Decl): string =
  let f = frameType(d.name)
  let void = ctx.isVoid(d)
  result = "rt.TuckHop " & retProc(d.name) & "(" & f & "* tuckF" &
           (if void: "" else: ", " & ctx.resultType(d) & " v") & ")\n{\n"
  result.add(if void: "    if (tuckF.tuckRes !is null) rt.tuckSlComplete(tuckF.tuckRes, true);\n"
             else: "    rt.tuckSlFinish(tuckF.tuckRes, tuckF.tuckDest, v);\n")
  result.add "    " & exitProc(d.name) & "(tuckF);\n" &
             "    return rt.tuckSlReturnHop(&tuckF.tuckHdr);\n}\n"

# --- terminators -----------------------------------------------------------------

proc jump(d: Decl, k: int): string = "return " & stageName(d.name, k) & "(env);"
proc ioName(d: Decl, site: int): string = "TuckIOˑ" & d.name & "ˑ" & $site

proc leaveCalls(d: Decl, plan: StagePlan, leaves: seq[int]): seq[string] =
  for sc in leaves:
    if plan.scopeDefers[sc].len > 0: result.add scopeExit(d.name, sc) & "(tuckF);"

proc atD(calleeStr: string, t: Term): string =
  ## Where the callee's frame is built: inside this frame (#219), or null.
  if t.embed: "cast(" & stacklessHelperD(calleeStr, "TuckFˑ") & "*) &tuckF.tuckSub"
  else: "null"

proc genCall(ctx: var DCodegenCtx, d: Decl, t: Term): string =
  let calleeStr = ctx.genDExpr(t.call.callee)
  let dest = if t.target == nil: "null" else: "&" & ctx.genDExpr(t.target)
  let args = ctx.genDCallArgs(t.call)
  "        auto tuckC = " & stacklessHelperD(calleeStr, "TuckNewˑ") & "(" & atD(calleeStr, t) & ", null, " & dest &
    (if args.len > 0: ", " & args.join(", ") else: "") & ");\n" &
  "        tuckC.tuckHdr.caller = &tuckF.tuckHdr;\n" &
  "        tuckF.tuckHdr.stage = &" & stageName(d.name, t.next) & ";\n" &
  "        return " & stacklessHelperD(calleeStr, "TuckSˑ") & "ˑ0(tuckC);\n"

proc genAwait(ctx: var DCodegenCtx, d: Decl, t: Term): string =
  let calleeStr = ctx.genDExpr(t.call.callee)
  let args = ctx.genDCallArgs(t.call)
  "        tuckF." & t.slot & ".done = false;\n" &
  "        rt.tuckSlReady(&" & stacklessHelperD(calleeStr, "TuckNewˑ") & "(" & atD(calleeStr, t) & ", &tuckF." & t.slot &
    ", null" & (if args.len > 0: ", " & args.join(", ") else: "") & ").tuckHdr);\n" &
  "        return rt.tuckSlAwait(&tuckF.tuckHdr, &tuckF." & t.slot & ", &" &
    stageName(d.name, t.next) & ");\n"

proc loopTest(ctx: var DCodegenCtx, d: Decl, lp: Loop, excl: bool): string =
  let op = if excl: " >= " else: " > "
  case lp.kind
  of lkRange: "        if (" & lp.varName & op & lp.stateField & ") " & jump(d, lp.exit) & "\n"
  of lkSeq:
    "        if (" & lp.stateField & " >= " & ctx.genDExpr(lp.node.iterable) & ".length) " &
      jump(d, lp.exit) & "\n"
  of lkWhile: ""

proc seqElement(ctx: var DCodegenCtx, lp: Loop): string =
  if lp.kind != lkSeq: return ""
  "        " & lp.varName & " = " & ctx.genDExpr(lp.node.iterable) & "[" & lp.stateField & "];\n"

proc genLoopEnter(ctx: var DCodegenCtx, d: Decl, lp: Loop): string =
  case lp.kind
  of lkRange:
    let it = lp.node.iterable
    result = "        " & lp.varName & " = " & ctx.genDExpr(it.left) & ";\n" &
             "        " & lp.stateField & " = " & ctx.genDExpr(it.right) & ";\n" &
             ctx.loopTest(d, lp, it.binOp == boRangeExcl)
  of lkSeq: result = "        " & lp.stateField & " = 0;\n" & ctx.loopTest(d, lp, true)
  of lkWhile: discard
  result.add ctx.seqElement(lp) & "        " & jump(d, lp.body) & "\n"

proc genLoopNext(ctx: var DCodegenCtx, d: Decl, lp: Loop): string =
  case lp.kind
  of lkRange:
    if lp.node.iterable.binOp == boRangeIncl:
      result = "        if (" & lp.varName & " >= " & lp.stateField & ") " & jump(d, lp.exit) & "\n" &
               "        " & lp.varName & " += 1;\n"
    else:
      result = "        " & lp.varName & " += 1;\n" & ctx.loopTest(d, lp, true)
  of lkSeq: result = "        " & lp.stateField & " += 1;\n" & ctx.loopTest(d, lp, true)
  of lkWhile: discard
  result.add ctx.seqElement(lp) & "        " & jump(d, lp.body) & "\n"

proc genTerm(ctx: var DCodegenCtx, d: Decl, plan: StagePlan, t: Term): string =
  case t.kind
  of tkFall:
    result = if ctx.isVoid(d): "        return " & retProc(d.name) & "(tuckF);\n"
             else: "        assert(0, \"tuck: stackless " & d.name & " ended without a return\");\n"
  of tkGoto:
    for c in leaveCalls(d, plan, t.leaves): result.add "        " & c & "\n"
    result.add "        " & jump(d, t.next) & "\n"
  of tkYield:
    result = "        return rt.tuckSlYield(&tuckF.tuckHdr, &" & stageName(d.name, t.next) & ");\n"
  of tkBranch:
    result = "        if (" & ctx.genDExpr(t.cond) & ") " & jump(d, t.thenS) & "\n" &
             "        " & jump(d, t.elseS) & "\n"
  of tkCall: result = ctx.genCall(d, t)
  of tkAwait: result = ctx.genAwait(d, t)
  of tkOnStack:
    result = "        return rt.tuckSlOnStack(&tuckF.tuckHdr, &" & stageName(d.name, t.next) &
             ", &" & ioName(d, t.site) & ");\n"
  of tkLoopEnter: result = ctx.genLoopEnter(d, plan.loops[t.loop])
  of tkLoopNext: result = ctx.genLoopNext(d, plan.loops[t.loop])

# --- stages, jumps, exits --------------------------------------------------------

proc takes(ctx: var DCodegenCtx, plan: StagePlan, k: int): string =
  for s in plan.stages:
    if s.term.kind == tkAwait and s.term.next == k and s.term.target != nil:
      result.add "        " & ctx.genDExpr(s.term.target) & " = tuckF." & s.term.slot & ".value;\n"

proc genStageStmt(ctx: var DCodegenCtx, plan: StagePlan, s: Expr): string =
  let k = plan.defers.find(s)
  if k >= 0: return "        tuckDefer" & $k & " = true;\n"
  ctx.genDStmt(s)

proc genStage(ctx: var DCodegenCtx, d: Decl, plan: StagePlan, k: int): string =
  let st = plan.stages[k]
  result = "rt.TuckHop " & stageName(d.name, k) & "(void* env)\n{\n" &
           "    auto tuckF = cast(" & frameType(d.name) & "*) env;\n    with (*tuckF)\n    {\n" &
           ctx.takes(plan, k)
  for s in st.stmts: result.add ctx.genStageStmt(plan, s)
  let last = if st.stmts.len > 0: st.stmts[^1] else: nil
  if last == nil or not (last.kind in {exkReturn, exkRaise} or last in plan.jumps):
    result.add ctx.genTerm(d, plan, st.term)
  result.add "    }\n}\n"

proc genJumps(d: Decl, plan: StagePlan, codes: var Table[pointer, string]): string =
  ## Each jump carrier's code, and a function for each that leaves scopes.
  var n = 0
  for node, j in plan.jumps:
    let calls = leaveCalls(d, plan, j.leaves)
    if calls.len == 0:
      codes[cast[pointer](node)] = jump(d, j.target)[0 .. ^2]   # genDStmt adds the `;`
      continue
    codes[cast[pointer](node)] = "return " & jumpProc(d.name, n) & "(tuckF, env)"
    result.add "rt.TuckHop " & jumpProc(d.name, n) & "(" & frameType(d.name) &
               "* tuckF, void* env)\n{\n    " & calls.join("\n    ") & "\n    " &
               jump(d, j.target) & "\n}\n"
    inc n

proc genDeferRun(ctx: var DCodegenCtx, plan: StagePlan, k: int): string =
  let saved = ctx.indent
  ctx.indent = 3
  let body = ctx.genDBlock(plan.defers[k].deferBody)
  ctx.indent = saved
  "        if (tuckDefer" & $k & ")\n        {\n" & body &
  "            tuckDefer" & $k & " = false;\n        }\n"

proc exitHead(d: Decl, name: string): string =
  "void " & name & "(" & frameType(d.name) & "* tuckF)\n{\n    with (*tuckF)\n    {\n"

proc genExits(ctx: var DCodegenCtx, d: Decl, plan: StagePlan): string =
  result = exitHead(d, exitProc(d.name))
  for k in countdown(plan.defers.high, 0): result.add ctx.genDeferRun(plan, k)
  result.add "    }\n}\n"
  for sc in 0 ..< plan.scopeDefers.len:
    if plan.scopeDefers[sc].len == 0: continue
    result.add exitHead(d, scopeExit(d.name, sc))
    for i in countdown(plan.scopeDefers[sc].high, 0):
      result.add ctx.genDeferRun(plan, plan.scopeDefers[sc][i])
    result.add "    }\n}\n"

proc frameVars(d: Decl, plan: StagePlan): HashSet[string] =
  for p in d.fnParams: result.incl p.name
  for f in plan.fields: result.incl f.name
  for lp in plan.loops:
    if lp.kind == lkSeq: result.incl lp.varName

proc genIoHelper(ctx: var DCodegenCtx, d: Decl, plan: StagePlan, t: Term): string =
  ## A statement that may park, as a function a worker runs with the frame
  ## as its environment (tuck_coro.d's tuckSlOnStack).
  "void " & ioName(d, t.site) & "(void* env)\n{\n" &
    "    auto tuckF = cast(" & frameType(d.name) & "*) env;\n    with (*tuckF)\n    {\n" &
    ctx.genStageStmt(plan, t.stmt) & "    }\n}\n"

proc genBodies(ctx: var DCodegenCtx, d: Decl, plan: StagePlan): string =
  for k in 0 ..< plan.stages.len:
    ctx.definedVars = frameVars(d, plan)
    ctx.indent = 2
    result.add ctx.genStage(d, plan, k) & "\n"
    if plan.stages[k].term.kind == tkOnStack:
      ctx.definedVars = frameVars(d, plan)
      ctx.indent = 2
      result.add ctx.genIoHelper(d, plan, plan.stages[k].term) & "\n"
  ctx.definedVars = frameVars(d, plan)
  result.add ctx.genExits(d, plan)
  ctx.indent = 0

proc genDFrameForm*(ctx: var DCodegenCtx, d: Decl): string =
  ## The frame form of `d` in D: type, constructor, finish, stages, exits.
  let plan = planStages(ctx.res, ctx.module, d)
  if plan.error != "":
    stderr.writeLine "tuck: " & d.name & ", " & plan.error
    quit 1
  result = ctx.genFrameType(d, plan) & "\n" & ctx.genFrameNew(d) & "\n" & ctx.genRet(d) & "\n"
  let saved = (ctx.frameVar, ctx.frameRet, ctx.definedVars, ctx.indent, ctx.frameJumps)
  ctx.frameVar = "tuckF"
  ctx.frameRet = retProc(d.name)
  ctx.frameJumps.clear()
  result.add genJumps(d, plan, ctx.frameJumps)
  result.add ctx.genBodies(d, plan)
  (ctx.frameVar, ctx.frameRet, ctx.definedVars, ctx.indent, ctx.frameJumps) = saved
