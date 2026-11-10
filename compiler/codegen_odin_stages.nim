# compiler/codegen_odin_stages.nim
#
# Stackless transform, phase 3 (#216): print a frame fn's StagePlan
# (stages.nim) as Odin — the twin of codegen_stages.nim (Nim), which
# explains the shape. Odin has no templates, so each stage opens with
# `using tuckF` (the file declares `#+feature using-stmt`): the frame's
# fields read by their own names, and the ordinary statement emitter prints
# the code between the cuts unchanged. A `return` finishes the frame through
# its `TuckRetˑf` proc (genReturnStmt, via ctx.frameRet).
#
# A split loop over a Seq copies the element into a frame field at each
# iteration. An Odin copy is by bits, so it is a view as far as ownership
# goes: the rules never drop a loop element.
import std/[strutils, sets, tables]
import ast, stages
import codegen_odin_ctx
import ./codegen_odin

proc frameType(name: string): string = "TuckFˑ" & name
proc stageName(name: string, k: int): string = "TuckSˑ" & name & "ˑ" & $k
proc retProc(name: string): string = "TuckRetˑ" & name
proc exitProc(name: string): string = "TuckExitˑ" & name
proc scopeExit(name: string, sc: int): string = "TuckXˑ" & name & "ˑ" & $sc

proc stacklessHelperOdin*(calleeStr, prefix: string): string =
  ## `pkg.task` -> `pkg.<prefix>task`: a frame's helpers sit beside it.
  let dot = calleeStr.rfind('.')
  if dot < 0: prefix & calleeStr else: calleeStr[0 .. dot] & prefix & calleeStr[dot + 1 .. ^1]

proc isVoid(d: Decl): bool =
  d.fnReturnType == nil or (d.fnReturnType.kind == tkNamed and d.fnReturnType.name == "void")

proc resultType(ctx: var OdinCodegenCtx, d: Decl): string =
  if d.isVoid: "bool" else: ctx.odinType(d.fnReturnType)

# --- the frame type, constructor, return -----------------------------------------

proc subTypes(ctx: var OdinCodegenCtx, plan: StagePlan): seq[string] =
  ## The frame types this frame embeds (#219), qualified as its calls name them.
  for st in plan.stages:
    let t = st.term
    if t.kind in {tkCall, tkAwait} and t.embed:
      let q = stacklessHelperOdin(ctx.genOdinExpr(t.call.callee), "TuckFˑ")
      if q notin result: result.add q

proc genSubUnion(ctx: var OdinCodegenCtx, d: Decl, plan: StagePlan): string =
  ## `tuckSub`'s type: a raw union of every frame this one embeds.
  let subs = ctx.subTypes(plan)
  if subs.len == 0: return ""
  result = "TuckUˑ" & d.name & " :: struct #raw_union {\n"
  for i, q in subs: result.add "\ts" & $i & ": " & q & ",\n"
  result.add "}\n\n"

proc genFrameType(ctx: var OdinCodegenCtx, d: Decl, plan: StagePlan): string =
  let r = ctx.resultType(d)
  result = ctx.genSubUnion(d, plan) & frameType(d.name) & " :: struct {\n\ttuckHdr: rt.TuckFrameHdr,\n" &
           "\ttuckRes: ^rt.TuckSlot(" & r & "),\n\ttuckDest: ^" & r & ",\n"
  for p in d.fnParams: result.add "\t" & p.name & ": " & ctx.odinType(p.typ) & ",\n"
  for f in plan.fields:
    let t = if f.isSlot: "rt.TuckSlot(" & (if f.typ == nil: "bool" else: ctx.odinType(f.typ)) & ")"
            else: ctx.odinType(f.typ)
    result.add "\t" & f.name & ": " & t & ",\n"
  for lp in plan.loops:
    if lp.kind == lkSeq: result.add "\t" & lp.varName & ": " & ctx.odinType(lp.elemType) & ",\n"
  for k in 0 ..< plan.defers.len: result.add "\ttuckDefer" & $k & ": bool,\n"
  if plan.subs.len > 0: result.add "\ttuckSub: TuckUˑ" & d.name & ",\n"
  result.add "}\n"

proc genFrameNew(ctx: var OdinCodegenCtx, d: Decl): string =
  let r = ctx.resultType(d)
  var params = @["tuckAt: ^" & frameType(d.name), "tuckRes: ^rt.TuckSlot(" & r & ")",
                 "tuckDest: ^" & r]
  for p in d.fnParams: params.add p.name & ": " & ctx.odinType(p.typ)
  # `tuckAt`: storage the caller provides (its `tuckSub`, or main's stack),
  # or nil for the heap (#219).
  result = "TuckNewˑ" & d.name & " :: proc(" & params.join(", ") & ") -> ^" &
           frameType(d.name) & " {\n\tf := tuckAt\n" &
           "\tif f == nil { f = new(" & frameType(d.name) & ") } else { f^ = {}; f.tuckHdr.embedded = true }\n" &
           "\tf.tuckHdr.stage = " & stageName(d.name, 0) & "\n" &
           "\tf.tuckRes = tuckRes\n\tf.tuckDest = tuckDest\n"
  for p in d.fnParams: result.add "\tf." & p.name & " = " & p.name & "\n"
  result.add "\treturn f\n}\n"

proc genRet(ctx: var OdinCodegenCtx, d: Decl): string =
  ## The frame's finish: value to its slot or destination, armed `defer`s,
  ## free, and the hop to whoever resumes next.
  let f = frameType(d.name)
  result = retProc(d.name) & " :: proc(tuckF: ^" & f &
           (if d.isVoid: "" else: ", v: " & ctx.resultType(d)) & ") -> rt.TuckHop {\n"
  result.add(if d.isVoid: "\tif tuckF.tuckRes != nil do rt.tuckSlComplete(tuckF.tuckRes, true)\n"
             else: "\trt.tuckSlFinish(tuckF.tuckRes, tuckF.tuckDest, v)\n")
  result.add "\t" & exitProc(d.name) & "(tuckF)\n\th := rt.tuckSlReturnHop(&tuckF.tuckHdr)\n" &
             "\tif !tuckF.tuckHdr.embedded do free(tuckF)\n\treturn h\n}\n"

# --- terminators -----------------------------------------------------------------

proc jump(d: Decl, k: int): string = "return " & stageName(d.name, k) & "(env)"
proc ioName(d: Decl, site: int): string = "TuckIOˑ" & d.name & "ˑ" & $site

proc leaveCalls(d: Decl, plan: StagePlan, leaves: seq[int]): seq[string] =
  for sc in leaves:
    if plan.scopeDefers[sc].len > 0: result.add scopeExit(d.name, sc) & "(tuckF)"

proc jumpCode(d: Decl, plan: StagePlan, j: Jump): string =
  ## A jump carrier, printed as one statement (it may sit in an inline `if`).
  let calls = leaveCalls(d, plan, j.leaves)
  if calls.len == 0: return jump(d, j.target)
  "{ " & calls.join("; ") & "; " & jump(d, j.target) & " }"

proc atOdin(calleeStr: string, t: Term): string =
  ## Where the callee's frame is built: inside this frame (#219), or nil.
  if t.embed: "(^" & stacklessHelperOdin(calleeStr, "TuckFˑ") & ")(&tuckF.tuckSub)"
  else: "nil"

proc genCall(ctx: var OdinCodegenCtx, d: Decl, t: Term): string =
  let calleeStr = ctx.genOdinExpr(t.call.callee)
  let dest = if t.target == nil: "nil" else: "&" & ctx.genOdinExpr(t.target)
  let args = ctx.genCallArgs(t.call)
  "  tuckC := " & stacklessHelperOdin(calleeStr, "TuckNewˑ") & "(" & atOdin(calleeStr, t) & ", nil, " & dest &
    (if args.len > 0: ", " & args.join(", ") else: "") & ")\n" &
  "  tuckC.tuckHdr.caller = &tuckF.tuckHdr\n" &
  "  tuckF.tuckHdr.stage = " & stageName(d.name, t.next) & "\n" &
  "  return " & stacklessHelperOdin(calleeStr, "TuckSˑ") & "ˑ0(tuckC)\n"

proc genAwait(ctx: var OdinCodegenCtx, d: Decl, t: Term): string =
  let calleeStr = ctx.genOdinExpr(t.call.callee)
  let args = ctx.genCallArgs(t.call)
  "  tuckF." & t.slot & ".done = false\n" &
  "  rt.tuckSlReady(&" & stacklessHelperOdin(calleeStr, "TuckNewˑ") & "(" & atOdin(calleeStr, t) & ", &tuckF." & t.slot &
    ", nil" & (if args.len > 0: ", " & args.join(", ") else: "") & ").tuckHdr)\n" &
  "  return rt.tuckSlAwait(&tuckF.tuckHdr, &tuckF." & t.slot & ", " &
    stageName(d.name, t.next) & ")\n"

proc loopTest(ctx: var OdinCodegenCtx, d: Decl, lp: Loop, excl: bool): string =
  let op = if excl: " >= " else: " > "
  case lp.kind
  of lkRange: "  if " & lp.varName & op & lp.stateField & " do " & jump(d, lp.exit) & "\n"
  of lkSeq:
    "  if " & lp.stateField & " >= len(" & ctx.genOdinExpr(lp.node.iterable) & ") do " &
      jump(d, lp.exit) & "\n"
  of lkWhile: ""

proc seqElement(ctx: var OdinCodegenCtx, lp: Loop): string =
  if lp.kind != lkSeq: return ""
  "  " & lp.varName & " = " & ctx.genOdinExpr(lp.node.iterable) & "[" & lp.stateField & "]\n"

proc genLoopEnter(ctx: var OdinCodegenCtx, d: Decl, lp: Loop): string =
  case lp.kind
  of lkRange:
    let it = lp.node.iterable
    result = "  " & lp.varName & " = " & ctx.genOdinExpr(it.left) & "\n" &
             "  " & lp.stateField & " = " & ctx.genOdinExpr(it.right) & "\n" &
             ctx.loopTest(d, lp, it.binOp == boRangeExcl)
  of lkSeq: result = "  " & lp.stateField & " = 0\n" & ctx.loopTest(d, lp, true)
  of lkWhile: discard
  result.add ctx.seqElement(lp) & "  " & jump(d, lp.body) & "\n"

proc genLoopNext(ctx: var OdinCodegenCtx, d: Decl, lp: Loop): string =
  case lp.kind
  of lkRange:
    if lp.node.iterable.binOp == boRangeIncl:
      result = "  if " & lp.varName & " >= " & lp.stateField & " do " & jump(d, lp.exit) & "\n" &
               "  " & lp.varName & " += 1\n"
    else:
      result = "  " & lp.varName & " += 1\n" & ctx.loopTest(d, lp, true)
  of lkSeq: result = "  " & lp.stateField & " += 1\n" & ctx.loopTest(d, lp, true)
  of lkWhile: discard
  result.add ctx.seqElement(lp) & "  " & jump(d, lp.body) & "\n"

proc genTerm(ctx: var OdinCodegenCtx, d: Decl, plan: StagePlan, t: Term): string =
  case t.kind
  of tkFall:
    result = if d.isVoid: "  return " & retProc(d.name) & "(tuckF)\n"
             else: "  panic(\"tuck: stackless " & d.name & " ended without a return\")\n"
  of tkGoto:
    for c in leaveCalls(d, plan, t.leaves): result.add "  " & c & "\n"
    result.add "  " & jump(d, t.next) & "\n"
  of tkYield: result = "  return rt.tuckSlYield(&tuckF.tuckHdr, " & stageName(d.name, t.next) & ")\n"
  of tkBranch:
    result = "  if " & ctx.genOdinExpr(t.cond) & " do " & jump(d, t.thenS) & "\n" &
             "  " & jump(d, t.elseS) & "\n"
  of tkCall: result = ctx.genCall(d, t)
  of tkAwait: result = ctx.genAwait(d, t)
  of tkOnStack:
    result = "  return rt.tuckSlOnStack(&tuckF.tuckHdr, " & stageName(d.name, t.next) & ", " &
             ioName(d, t.site) & ")\n"
  of tkLoopEnter: result = ctx.genLoopEnter(d, plan.loops[t.loop])
  of tkLoopNext: result = ctx.genLoopNext(d, plan.loops[t.loop])

# --- stages, exits ---------------------------------------------------------------

proc opening(d: Decl): string =
  "  tuckF := (^" & frameType(d.name) & ")(env)\n  using tuckF\n"

proc takes(ctx: var OdinCodegenCtx, plan: StagePlan, k: int): string =
  for s in plan.stages:
    if s.term.kind == tkAwait and s.term.next == k and s.term.target != nil:
      result.add "  " & ctx.genOdinExpr(s.term.target) & " = tuckF." & s.term.slot & ".value\n"

proc genStageStmt(ctx: var OdinCodegenCtx, plan: StagePlan, s: Expr): string =
  let k = plan.defers.find(s)
  if k >= 0: return "  tuckDefer" & $k & " = true\n"
  let code = ctx.genBlock(Expr(kind: exkBlock, stmts: @[s]), "")
  if code.strip.len > 0: code & "\n" else: ""

proc genStage(ctx: var OdinCodegenCtx, d: Decl, plan: StagePlan, k: int): string =
  let st = plan.stages[k]
  result = stageName(d.name, k) & " :: proc(env: rawptr) -> rt.TuckHop {\n" & opening(d) &
           ctx.takes(plan, k)
  for s in st.stmts: result.add ctx.genStageStmt(plan, s)
  let last = if st.stmts.len > 0: st.stmts[^1] else: nil
  if last == nil or not (last.kind in {exkReturn, exkRaise} or last in plan.jumps):
    result.add ctx.genTerm(d, plan, st.term)
  result.add "}\n"

proc genDeferRun(ctx: var OdinCodegenCtx, plan: StagePlan, k: int): string =
  let body = ctx.genBlock(plan.defers[k].deferBody, "  ")
  "  if tuckDefer" & $k & " {\n" & body & "\n    tuckDefer" & $k & " = false\n  }\n"

proc genExits(ctx: var OdinCodegenCtx, d: Decl, plan: StagePlan): string =
  ## The frame's exit (every armed `defer`) and each scope's exit.
  let head = proc (name: string): string =
    name & " :: proc(tuckF: ^" & frameType(d.name) & ") {\n  using tuckF\n"
  result = head(exitProc(d.name))
  for k in countdown(plan.defers.high, 0): result.add ctx.genDeferRun(plan, k)
  result.add "}\n"
  for sc in 0 ..< plan.scopeDefers.len:
    if plan.scopeDefers[sc].len == 0: continue
    result.add head(scopeExit(d.name, sc))
    for i in countdown(plan.scopeDefers[sc].high, 0):
      result.add ctx.genDeferRun(plan, plan.scopeDefers[sc][i])
    result.add "}\n"

proc frameVars(d: Decl, plan: StagePlan): HashSet[string] =
  for p in d.fnParams: result.incl p.name
  for f in plan.fields: result.incl f.name
  for lp in plan.loops:
    if lp.kind == lkSeq: result.incl lp.varName

proc genIoHelper(ctx: var OdinCodegenCtx, d: Decl, plan: StagePlan, t: Term): string =
  ## A statement that may park, as a proc a worker runs with the frame as
  ## its environment (tuckrt's tuckSlOnStack).
  ioName(d, t.site) & " :: proc(env: rawptr) {\n" & opening(d) &
    ctx.genStageStmt(plan, t.stmt) & "}\n"

proc genBodies(ctx: var OdinCodegenCtx, d: Decl, plan: StagePlan): string =
  for k in 0 ..< plan.stages.len:
    ctx.definedVars = frameVars(d, plan)
    ctx.indent = 0
    result.add ctx.genStage(d, plan, k) & "\n"
    if plan.stages[k].term.kind == tkOnStack:
      ctx.definedVars = frameVars(d, plan)
      ctx.indent = 0
      result.add ctx.genIoHelper(d, plan, plan.stages[k].term) & "\n"
  ctx.definedVars = frameVars(d, plan)
  ctx.indent = 0
  result.add ctx.genExits(d, plan)

proc genOdinFrameForm*(ctx: var OdinCodegenCtx, d: Decl): string =
  ## The frame form of `d` in Odin: type, constructor, finish, stages, exits.
  let plan = planStages(ctx.res, ctx.module, d)
  if plan.error != "":
    stderr.writeLine "tuck: " & d.name & ", " & plan.error
    quit 1
  result = ctx.genFrameType(d, plan) & "\n" & ctx.genFrameNew(d) & "\n" & ctx.genRet(d) & "\n"
  let saved = (ctx.frameVar, ctx.frameRet, ctx.definedVars, ctx.indent, ctx.frameJumps)
  ctx.frameVar = "tuckF"
  ctx.frameRet = retProc(d.name)
  ctx.frameJumps.clear()
  for node, j in plan.jumps: ctx.frameJumps[cast[pointer](node)] = jumpCode(d, plan, j)
  result.add ctx.genBodies(d, plan)
  (ctx.frameVar, ctx.frameRet, ctx.definedVars, ctx.indent, ctx.frameJumps) = saved
