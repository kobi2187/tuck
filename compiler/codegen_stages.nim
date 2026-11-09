# compiler/codegen_stages.nim
#
# Stackless transform, phase 2 (#216): print a frame fn's StagePlan
# (stages.nim) as Nim. The code between the cuts goes through the ordinary
# statement emitter unchanged: each stage opens with a template per frame
# field (`template x: untyped = tuckF.x`), so the statements read the frame
# by their own names and nothing in them is rewritten. A `return` inside a
# stage is the one statement that changes, and genReturn does that when
# `ctx.frameVar` is set.
#
# Emitted, for a frame fn or task `f` with result type R (bool when void):
#   TuckFˑf          the frame: header, slot/dest for the result, params,
#                    the locals that live in the frame
#   TuckNewˑf(...)   allocate and fill one, entry stage set
#   TuckSˑfˑK        stage K: `proc (env: pointer): TuckHop`
import std/[strutils, sets, tables]
import ast, ast_query, resolution, stages
import codegen_ctx, codegen_type
import ./codegen

proc frameType*(name: string): string = "TuckFˑ" & name
proc frameNew*(name: string): string = "TuckNewˑ" & name
proc stageName(name: string, k: int): string = "TuckSˑ" & name & "ˑ" & $k

proc resultType(d: Decl): string =
  if d.fnReturnType == nil or genType(d.fnReturnType) == "void": "bool"
  else: genType(d.fnReturnType)

# --- the frame type and its constructor ------------------------------------------

proc fieldLine(f: FrameField): string =
  let t = if f.isSlot: "TuckSlot[" & (if f.typ == nil: "bool" else: genType(f.typ)) & "]"
          else: genType(f.typ)
  "    " & f.name & ": " & t & "\n"

proc genFrameType(d: Decl, plan: StagePlan): string =
  let r = resultType(d)
  result = "type " & frameType(d.name) & "* = object\n" &
           "    hdr: TuckFrameHdr\n    slot: ptr TuckSlot[" & r & "]\n" &
           "    dest: ptr " & r & "\n"
  for p in d.fnParams: result.add "    " & p.name & ": " & genType(p.typ) & "\n"
  for f in plan.fields: result.add fieldLine(f)
  for k in 0 ..< plan.defers.len: result.add "    tuckDefer" & $k & ": bool\n"

proc genFrameNew(d: Decl): string =
  ## The constructor: arguments are stored by their bits — the caller's
  ## rules moved or copied each one for this frame, as for a spawned job.
  let r = resultType(d)
  var params = @["slot: ptr TuckSlot[" & r & "]", "dest: ptr " & r]
  for p in d.fnParams: params.add p.name & ": " & genType(p.typ)
  result = "proc " & frameNew(d.name) & "*(" & params.join(", ") & "): ptr " &
           frameType(d.name) & " =\n" &
           "  result = tuckSlAlloc(" & frameType(d.name) & ")\n" &
           "  result.hdr.stage = " & stageName(d.name, 0) & "\n" &
           "  result.slot = slot\n  result.dest = dest\n"
  for p in d.fnParams: result.add "  tuckStore(result." & p.name & ", " & p.name & ")\n"

# --- terminators -----------------------------------------------------------------

proc jump(d: Decl, k: int): string = "return " & stageName(d.name, k) & "(env)"

proc genFall(d: Decl): string =
  if resultType(d) == "bool" and (d.fnReturnType == nil or genType(d.fnReturnType) == "void"):
    "  return tuckSlRetVoid(tuckF)\n"
  else:
    "  quit \"tuck: stackless " & d.name & " ended without a return\"\n"

proc genCall(ctx: var CodegenCtx, d: Decl, t: Term): string =
  ## A frame call: build the callee's frame pointing back at this one, and
  ## enter its first stage directly.
  let calleeStr = ctx.genExpr(t.call.callee)
  let dest = if t.target == nil: "nil" else: "addr " & ctx.genExpr(t.target)
  let args = ctx.genCallArgs(t.call)
  let ctor = stacklessHelper(calleeStr, "TuckNewˑ")
  let entry = stacklessHelper(calleeStr, "TuckSˑ") & "ˑ0"
  "  let tuckC = " & ctor & "(nil, " & dest & (if args.len > 0: ", " & args.join(", ") else: "") & ")\n" &
  "  tuckC.hdr.caller = addr tuckF.hdr\n" &
  "  tuckF.hdr.stage = " & stageName(d.name, t.next) & "\n" &
  "  return " & entry & "(tuckC)\n"

proc genAwait(ctx: var CodegenCtx, d: Decl, t: Term): string =
  ## Spawn the task into this frame's slot and park until it is done.
  let calleeStr = ctx.genExpr(t.call.callee)
  let args = ctx.genCallArgs(t.call)
  let ctor = stacklessHelper(calleeStr, "TuckNewˑ")
  "  tuckF." & t.slot & ".done = false\n" &
  "  tuckSlReady(addr " & ctor & "(addr tuckF." & t.slot & ", nil" &
    (if args.len > 0: ", " & args.join(", ") else: "") & ").hdr)\n" &
  "  return tuckSlAwait(addr tuckF.hdr, addr tuckF." & t.slot & ", " &
    stageName(d.name, t.next) & ")\n"

proc genDeferRun(ctx: var CodegenCtx, plan: StagePlan, k: int): string

proc genGoto(ctx: var CodegenCtx, d: Decl, plan: StagePlan, t: Term): string =
  ## A jump; out of a branch, the branch's armed `defer`s run first.
  for i in countdown(t.runDefers.high, 0): result.add ctx.genDeferRun(plan, t.runDefers[i])
  result.add "  " & jump(d, t.next) & "\n"

proc genTerm(ctx: var CodegenCtx, d: Decl, plan: StagePlan, t: Term): string =
  case t.kind
  of tkFall: genFall(d)
  of tkGoto: ctx.genGoto(d, plan, t)
  of tkYield: "  return tuckSlYield(addr tuckF.hdr, " & stageName(d.name, t.next) & ")\n"
  of tkBranch:
    "  if " & ctx.genExpr(t.cond) & ": " & jump(d, t.thenS) & "\n" &
    "  else: " & jump(d, t.elseS) & "\n"
  of tkCall: ctx.genCall(d, t)
  of tkAwait: ctx.genAwait(d, t)

# --- stages ----------------------------------------------------------------------

proc aliases(d: Decl, plan: StagePlan): string =
  ## Every param and frame field, readable by its own name in the stage.
  for p in d.fnParams: result.add "  template " & p.name & ": untyped = tuckF." & p.name & "\n"
  for f in plan.fields:
    if not f.isSlot: result.add "  template " & f.name & ": untyped = tuckF." & f.name & "\n"

proc takes(ctx: var CodegenCtx, plan: StagePlan, k: int): string =
  ## A stage entered after an await starts by taking the task's value.
  for s in plan.stages:
    if s.term.kind == tkAwait and s.term.next == k and s.term.target != nil:
      result.add "  " & ctx.genExpr(s.term.target) & " = tuckMove(tuckF." & s.term.slot & ".value)\n"

proc genStageStmt(ctx: var CodegenCtx, plan: StagePlan, s: Expr): string =
  ## One statement of a stage; a frame-level `defer` only arms its flag.
  let k = plan.defers.find(s)
  if k >= 0: return "  tuckF.tuckDefer" & $k & " = true\n"
  let code = ctx.genStmts(Expr(kind: exkBlock, stmts: @[s]), "")
  if code.len > 0: code & "\n" else: ""

proc genDeferRun(ctx: var CodegenCtx, plan: StagePlan, k: int): string =
  ## Run defer `k` if it was armed, and disarm it.
  let body = ctx.genStmts(plan.defers[k].deferBody, "  ")   # inside the `if`
  "  if tuckF.tuckDefer" & $k & ":\n" & body & "\n    tuckF.tuckDefer" & $k & " = false\n"

proc genExit(ctx: var CodegenCtx, d: Decl, plan: StagePlan): string =
  ## `tuckSlExit`: every still-armed `defer`, last armed first. The runtime
  ## calls it when the frame finishes, after its value is stored.
  result = "proc tuckSlExit(tuckF: ptr " & frameType(d.name) & ") =\n" & aliases(d, plan)
  for k in countdown(plan.defers.high, 0): result.add ctx.genDeferRun(plan, k)
  result.add "  discard\n"

proc genStage(ctx: var CodegenCtx, d: Decl, plan: StagePlan, k: int): string =
  let st = plan.stages[k]
  result = "proc " & stageName(d.name, k) & "(env: pointer): TuckHop {.nimcall.} =\n" &
           "  let tuckF = cast[ptr " & frameType(d.name) & "](env)\n" & aliases(d, plan) &
           ctx.takes(plan, k)
  for s in st.stmts: result.add ctx.genStageStmt(plan, s)
  let returned = st.stmts.len > 0 and st.stmts[^1].kind == exkReturn
  if not returned:                                 # nothing runs after a return
    result.add ctx.genTerm(d, plan, st.term)

proc frameVars(d: Decl, plan: StagePlan): HashSet[string] =
  for p in d.fnParams: result.incl p.name
  for f in plan.fields: result.incl f.name

proc genFrameForm*(ctx: var CodegenCtx, d: Decl): string =
  ## The frame form of `d`: its type, constructor and stages. The caller set
  ## up the return shape (retWrapped, ...) as for the fn's ordinary body.
  let plan = planStages(ctx.res, ctx.module, d)
  if plan.error != "":
    # A shape the splitter does not cut yet: refused by name, never run wrong.
    stderr.writeLine "tuck: " & d.name & ", " & plan.error
    quit 1
  result = genFrameType(d, plan) & "\n"
  for k in 0 ..< plan.stages.len:
    result.add "proc " & stageName(d.name, k) & "(env: pointer): TuckHop {.nimcall.}\n"
  result.add "proc tuckSlExit(tuckF: ptr " & frameType(d.name) & ")\n"
  result.add genFrameNew(d) & "\n"
  let saved = (ctx.inTask, ctx.frameVar, ctx.definedVars, ctx.indent)
  ctx.inTask = false        # the yields are cuts now, not tuckYield calls
  ctx.frameVar = "tuckF"
  for k in 0 ..< plan.stages.len:
    ctx.definedVars = frameVars(d, plan)
    ctx.indent = 0
    result.add ctx.genStage(d, plan, k) & "\n"
  ctx.definedVars = frameVars(d, plan)
  ctx.indent = 0
  result.add ctx.genExit(d, plan) & "\n"
  (ctx.inTask, ctx.frameVar, ctx.definedVars, ctx.indent) = saved
