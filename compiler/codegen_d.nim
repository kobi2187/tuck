# compiler/codegen_d.nim
# D (dlang) backend — the third backend beside codegen.nim (Nim) and
# codegen_odin.nim (Odin). ROADMAP "Experimental #1".
#
# Structure mirrors codegen_odin.nim (ctx object, small gen* procs, flat
# exhaustive dispatches). The EMITTED code follows one rule: for each Tuck
# construct use the most identical native D construct, but only where the
# semantics match what codegen.nim (the authority) implements — e.g. Seq[T]
# emits as a native T[] slice, match will emit as `final switch`, but !T/?T
# stays a value-carried TuckResult (D exceptions unwind nonlocally, which is
# a different semantic, so they are out).
#
# A construct this backend cannot emit yet DIES LOUDLY at emission time
# (dUnsupported) — never silent wrong code. Exception: an extern forwarder
# whose signature needs a not-yet-ported type emits a visible TODO comment;
# the D compiler then fails only if a call site actually references it,
# naming the symbol.
import ast, strutils, sets, tables, options
import resolution
import ast_query
import codegen_common
from mangle import mangleName

type
  DCodegenCtx = object
    definedVars: HashSet[string]
    indent: int           # statement indent, in 4-space levels
    module: Module
    hoisted: seq[string]  # named decls hoisted out of field positions (records)
    recShapes: Table[string, string]  # record shape signature -> struct name
    modPrefix: string     # library modules prefix hoisted names
    realModules: Table[string, Module]
    moduleName: string
    tmpCounter: int

proc dUnsupported(construct: string): string =
  ## The D backend refuses what it cannot yet emit — loudly, at emission
  ## time, naming the construct. Silent wrong code is the one forbidden
  ## outcome (see the actor/task plan: those arrive with the Fiber runtime).
  quit("tuck: D backend does not yet support " & construct, 1)

# ---------------------------------------------------------------- types --

const dPrims = {
  # Tuck int is 64-bit (ROADMAP 2026-08-25 ruling 1); D's `int` is 32-bit,
  # so the bare word maps to `long` — the first hidden Nim-ism this backend
  # exists to flush out.
  "int": "long", "i8": "byte", "i16": "short", "i32": "int", "i64": "long",
  "u8": "ubyte", "u16": "ushort", "u32": "uint", "u64": "ulong",
  "f32": "float", "f64": "double", "float": "double",
  "bool": "bool", "str": "string", "void": "void", "unit": "void",
}.toTable

proc dType(ctx: var DCodegenCtx, t: Type): string =
  if t == nil: return "void"
  case t.kind
  of tkNamed:
    if t.name in dPrims: dPrims[t.name]
    elif t.name == UnknownName or t.name == PendingName: "void"
    else: t.name
  of tkApp:
    # Seq[T] is a native D dynamic array — same value-semantics contract as
    # the Nim backend's seq[T] (assignment copies; D slices alias, which the
    # emitter must compensate for at assignment sites — see the T17 audit).
    if t.base != nil and t.base.kind == tkNamed and t.base.name == "Seq" and
       t.args.len == 1:
      ctx.dType(t.args[0]) & "[]"
    else:
      let baseName = if t.base != nil and t.base.kind == tkNamed: t.base.name
                     else: "?"
      dUnsupported("type application " & baseName & "[...]")
  of tkTuple: dUnsupported("tuple type")
  of tkFunc: dUnsupported("fn-typed value (fnsig)")
  of tkRecord: dUnsupported("anonymous record type in this position")
  of tkSum: dUnsupported("inline sum type")
  of tkUnion: dUnsupported("union type")
  of tkEffect: ctx.dType(t.inner)   # [io] etc. — no type-level footprint yet
  of tkRename: ctx.dType(t.underlying)

# ---------------------------------------------------------- expressions --

proc genDExpr(ctx: var DCodegenCtx, e: Expr): string

proc declaresFnD(m: Module, name: string): bool =
  ## Same predicate as the Odin backend's declaresFn (private there).
  m.findFn(name) != nil

proc genDQualified(ctx: DCodegenCtx, e: Expr): string =
  ## D, like Odin, has no cross-module scope merge: an imported module's fn
  ## is always `alias.name`. Local declarations win; only a name this module
  ## does not declare is searched for among the imports.
  let modName = if e.modulePath.len > 0: e.modulePath[0] else: ""
  if modName == "":
    if not ctx.module.declaresFnD(e.qualName):
      for name, im in ctx.realModules:
        if im.declaresFnD(e.qualName):
          return name.replace("-", "_") & "." & e.qualName
    return e.qualName
  elif modName in ctx.realModules:
    return modName.replace("-", "_") & "." & e.qualName
  else:
    return modName & "_" & e.qualName

proc genDLit(e: Expr): string =
  case e.litKind
  of lkStr: "\"" & e.litValue & "\""
  of lkInt, lkFloat, lkBool: e.litValue
  of lkUnit: ""

proc expectedParamNamesD(ctx: var DCodegenCtx, e: Expr,
                         calleeStr: string): seq[string] =
  ## Param order lives with the fn, not the payload literal — mirror of the
  ## Odin backend's expectedParamNames.
  if e.callee != nil and e.callee.kind == exkQualified and
     e.callee.modulePath.len > 0 and e.callee.modulePath[0] in ctx.realModules:
    return lookupFnParams(ctx.realModules[e.callee.modulePath[0]],
                          e.callee.qualName)
  if semLayer.callParamsFor(e).len > 0: return semLayer.callParamsFor(e)
  lookupFnParams(ctx.module, calleeStr)

proc payloadFieldArgD(ctx: var DCodegenCtx, payload: Expr,
                      fieldName: string): string =
  for f in payload.fields:
    if f.name == fieldName: return ctx.genDExpr(f.value)
  # A param the payload does not carry: D default-initializes, but an absent
  # argument cannot be spelled positionally — refuse rather than guess.
  dUnsupported("call omitting parameter '" & fieldName & "'")

proc genDPayloadArgs(ctx: var DCodegenCtx, e: Expr,
                     calleeStr: string): seq[string] =
  ## A payload's fields, ordered to match the callee's params. The checker
  ## already decided which field feeds each param (semLayer.argFieldsFor);
  ## replay that decision, never re-derive it.
  let expected = ctx.expectedParamNamesD(e, calleeStr)
  if expected.len == 0:
    for f in e.args[0].fields: result.add(ctx.genDExpr(f.value))
    return
  let resolved = semLayer.argFieldsFor(e)
  for i, paramName in expected:
    let fieldName = if i < resolved.len and resolved[i].len > 0: resolved[i]
                    else: paramName
    result.add(ctx.payloadFieldArgD(e.args[0], fieldName))

proc genDCallArgs(ctx: var DCodegenCtx, e: Expr,
                  calleeStr: string): seq[string] =
  if e.args.len == 1 and e.args[0].kind == exkStruct:
    return ctx.genDPayloadArgs(e, calleeStr)
  for a in e.args: result.add(ctx.genDExpr(a))

proc resolveDCallee(ctx: var DCodegenCtx, e: Expr): string =
  ## A bare-name callee (exkVar) resolves like an unqualified exkQualified:
  ## local declarations win, then the imports — D has no scope merge to do
  ## it for us (Nim's backend leans on Nim's own resolution here).
  if e.callee != nil and e.callee.kind == exkVar and
     not ctx.module.declaresFnD(e.callee.name):
    for name, im in ctx.realModules:
      if im.declaresFnD(e.callee.name):
        return name.replace("-", "_") & "." & e.callee.name
  ctx.genDExpr(e.callee)

proc genDCall(ctx: var DCodegenCtx, e: Expr): string =
  let calleeStr = ctx.resolveDCallee(e)
  let args = ctx.genDCallArgs(e, calleeStr)
  if calleeStr == "echo":
    # `echo` is the builtin debug print; writeln is D's identical construct.
    return "writeln(" & args.join(", ") & ")"
  calleeStr & "(" & args.join(", ") & ")"

proc genDReturn(ctx: var DCodegenCtx, e: Expr): string =
  if e.returnVal == nil: "return"
  else: "return " & ctx.genDExpr(e.returnVal)

proc indD(ctx: DCodegenCtx): string = repeat(' ', ctx.indent * 4)

proc dBinOp(op: BinOp): string =
  ## D's `/` follows the operand type (integer operands truncate) — same
  ## property as Odin, so both Tuck divisions map to `/` and the Tuck source
  ## carries the distinction. `^` works on bools and ints alike.
  case op
  of boAdd: "+"
  of boSub: "-"
  of boMul: "*"
  of boDivInt, boDivFloat: "/"
  of boMod: "%"
  of boEq: "=="
  of boNeq: "!="
  of boLt: "<"
  of boGt: ">"
  of boLe: "<="
  of boGe: ">="
  of boAnd: "&&"
  of boOr: "||"
  of boXor: "^"
  of boRangeIncl, boRangeExcl: ""   # only meaningful inside foreach — genDFor

proc isStringConcatD(e: Expr): bool =
  ## `+` over strings — D's identical construct is the native `~`.
  if e.binOp != boAdd or e.left == nil: return false
  let lt = semLayer.typeFor(e.left)
  lt != nil and lt.kind == tkNamed and lt.name in ["str", "string"]

proc genDBinary(ctx: var DCodegenCtx, e: Expr): string =
  if isStringConcatD(e):
    return "(" & ctx.genDExpr(e.left) & " ~ " & ctx.genDExpr(e.right) & ")"
  if e.binOp in {boRangeIncl, boRangeExcl}:
    return dUnsupported("a range outside a for loop")
  "(" & ctx.genDExpr(e.left) & " " & dBinOp(e.binOp) & " " &
    ctx.genDExpr(e.right) & ")"

proc genDUnary(ctx: var DCodegenCtx, e: Expr): string =
  case e.unaryOp
  of uoNeg: "-" & ctx.genDExpr(e.operand)
  of uoNot: "!" & ctx.genDExpr(e.operand)
  of uoComposition: dUnsupported("composition (+Type member)")
  of uoPropagate: dUnsupported("expr? propagation (M4)")

proc isLenOnSized(ctx: var DCodegenCtx, e: Expr): bool =
  ## `.len` on a str or Seq — D spells the identical native property
  ## `.length`. (The Nim backend emits `.len` untranslated because Nim
  ## happens to share Tuck's spelling — a Nim-ism riding through.)
  if e.fieldName != "len" or e.receiver == nil: return false
  let rt = semLayer.typeFor(e.receiver)
  if rt == nil: return false
  if rt.kind == tkNamed and rt.name in ["str", "string"]: return true
  rt.kind == tkApp and rt.base != nil and rt.base.kind == tkNamed and
    rt.base.name == "Seq"

proc genDField(ctx: var DCodegenCtx, e: Expr): string =
  ## A `.name` access: a resolved call, the len property, or a plain read.
  ## (Interface dispatch, actor fields, status tests arrive with their
  ## milestones — the types involved cannot reach here yet.)
  if ctx.isLenOnSized(e):
    # cast: D's .length is size_t (unsigned); Tuck's len is a signed int.
    # Unsigned would poison later arithmetic (n - bigger wraps, comparisons
    # promote) — hidden Nim-ism #3, Nim's .len is already signed.
    return "cast(long) " & ctx.genDExpr(e.receiver) & ".length"
  if semLayer.hasCall(e):
    return ctx.genDExpr(semLayer.call(e))
  ctx.genDExpr(e.receiver) & "." & e.fieldName

proc genDVarName(ctx: var DCodegenCtx, e: Expr): string =
  ## A bare name: a checker-stamped call, a pending hole, or a variable.
  ## (input / self / enum tags arrive with their milestones.)
  if semLayer.hasCall(e): return ctx.genDExpr(semLayer.call(e))
  if e.name == "...": return ""   # pending hole: compiles, does nothing
  e.name

proc dDeclType(ctx: var DCodegenCtx, t: Type): string =
  ## The declared type for a var, or "" when it cannot be stated — the safe
  ## subset of dType that never dies (a decl can always fall back to auto,
  ## an unsupported type in any OTHER position cannot).
  if t == nil: return ""
  case t.kind
  of tkNamed:
    if t.name in dPrims: dPrims[t.name]
    elif t.name.startsWith("<"): ""   # <unknown> and the other sentinels
    else: t.name
  of tkApp:
    if t.base != nil and t.base.kind == tkNamed and t.base.name == "Seq" and
       t.args.len == 1:
      let elem = ctx.dDeclType(t.args[0])
      if elem == "": "" else: elem & "[]"
    else: ""
  of tkTuple, tkFunc, tkRecord, tkSum, tkUnion: ""
  of tkEffect: ctx.dDeclType(t.inner)
  of tkRename: ctx.dDeclType(t.underlying)

proc genDAssign(ctx: var DCodegenCtx, e: Expr): string =
  ## First assignment to a name declares it, with the CHECKER'S type stated
  ## explicitly. `auto x = 0` would make x a 32-bit D int while Tuck (and
  ## the Nim backend's inference) makes it 64-bit — a value past 2^31 then
  ## wraps in one backend and not the other. Verified with dmd; hidden
  ## Nim-ism #2. `auto` remains only for types the backend cannot state yet
  ## (sketch-mode Unknown included, where no arithmetic contract exists).
  let valStr = ctx.genDExpr(e.assignVal)
  if e.target.kind == exkVar and e.target.name notin ctx.definedVars:
    ctx.definedVars.incl(e.target.name)
    var declT = ctx.dDeclType(semLayer.typeFor(e.target))
    if declT == "": declT = ctx.dDeclType(semLayer.typeFor(e.assignVal))
    if declT == "": declT = "auto"
    return declT & " " & e.target.name & " = " & valStr
  ctx.genDExpr(e.target) & " = " & valStr

# --- statements & control flow -------------------------------------------

proc ownsLayoutD(s: Expr): bool =
  ## Constructs that emit their own indentation, braces and newlines.
  s.kind in {exkIf, exkFor, exkWhile, exkBlock, exkMatch}

proc genDStmt(ctx: var DCodegenCtx, s: Expr): string =
  ## One statement inside a block: indent + expression + `;`, except the
  ## constructs that lay themselves out.
  if s != nil and ownsLayoutD(s):
    let code = ctx.genDExpr(s)
    return if code == "": "" else: code & "\n"
  let code = ctx.genDExpr(s)
  if code == "": return ""
  ctx.indD & code & ";\n"

proc genDBlock(ctx: var DCodegenCtx, e: Expr): string =
  for s in e.stmts:
    result.add(ctx.genDStmt(s))

proc genDNested(ctx: var DCodegenCtx, body: Expr): string =
  ## A branch/loop body one level deeper, always brace-wrapped by the caller.
  ctx.indent += 1
  result = if body == nil: ""
           elif body.kind == exkBlock: ctx.genDBlock(body)
           else: ctx.genDStmt(body)
  ctx.indent -= 1

proc isValueIfD(e: Expr): bool =
  ## A value-position `if` (both branches are plain expressions and the
  ## checker stamped a type) emits as D's ternary. Mirrors ast_query's
  ## isValueIf used by the Odin backend.
  isValueIf(e)

proc genDIf(ctx: var DCodegenCtx, e: Expr): string =
  if isValueIfD(e):
    return "(" & ctx.genDExpr(e.cond) & " ? " & ctx.genDExpr(e.thenBranch) &
           " : " & ctx.genDExpr(e.elseBranch) & ")"
  let ind = ctx.indD
  result = ind & "if (" & ctx.genDExpr(e.cond) & ") {\n" &
           ctx.genDNested(e.thenBranch)
  if e.elseBranch != nil:
    if e.elseBranch.kind == exkIf:
      # `elif` chain: fold into `} else if (...)` rather than nesting.
      let elseCode = ctx.genDIf(e.elseBranch)
      result.add(ind & "} else " & elseCode.strip(chars = {' '}, trailing = false))
      return
    result.add(ind & "} else {\n" & ctx.genDNested(e.elseBranch))
  result.add(ind & "}")

proc genDWhile(ctx: var DCodegenCtx, e: Expr): string =
  let cond = if e.whileCond == nil: "true" else: ctx.genDExpr(e.whileCond)
  ctx.indD & "while (" & cond & ") {\n" & ctx.genDNested(e.whileBody) &
    ctx.indD & "}"

proc dForVars(e: Expr): string =
  ## `for idx, item in xs:` — D's foreach yields the index natively, in the
  ## same (index, value) order.
  if e.iter != nil and e.iter.kind == pkTuple and e.iter.elems.len == 2:
    genPatternStr(e.iter.elems[0]) & ", " & genPatternStr(e.iter.elems[1])
  else: genPatternStr(e.iter)

proc genDFor(ctx: var DCodegenCtx, e: Expr): string =
  ## foreach over a range or a value. D ranges are exclusive; the inclusive
  ## Tuck range adds one to the upper bound.
  var iterStr: string
  if e.iterable != nil and e.iterable.kind == exkBinary and
     e.iterable.binOp in {boRangeIncl, boRangeExcl}:
    let lo = ctx.genDExpr(e.iterable.left)
    let hi = ctx.genDExpr(e.iterable.right)
    iterStr = lo & " .. " & (if e.iterable.binOp == boRangeIncl: hi & " + 1"
                             else: hi)
  else:
    iterStr = ctx.genDExpr(e.iterable)
  ctx.indD & "foreach (" & dForVars(e) & "; " & iterStr & ") {\n" &
    ctx.genDNested(e.body) & ctx.indD & "}"

proc genDList(ctx: var DCodegenCtx, e: Expr): string =
  var parts: seq[string]
  for item in e.items: parts.add(ctx.genDExpr(item))
  "[" & parts.join(", ") & "]"

proc genDExpr(ctx: var DCodegenCtx, e: Expr): string =
  if e == nil: return ""
  case e.kind
  of exkLit: genDLit(e)
  of exkVar: ctx.genDVarName(e)
  of exkField: ctx.genDField(e)
  of exkQualified: ctx.genDQualified(e)
  of exkStruct: dUnsupported("struct literal outside a call payload")
  of exkList: ctx.genDList(e)
  of exkBracket: dUnsupported("bracket indexing")
  of exkBracketAssign: dUnsupported("bracket assignment")
  of exkCall: ctx.genDCall(e)
  of exkChain: dUnsupported("call chain")
  of exkBinary: ctx.genDBinary(e)
  of exkUnary: ctx.genDUnary(e)
  of exkBlock: ctx.genDBlock(e)
  of exkIf: ctx.genDIf(e)
  of exkMatch: dUnsupported("match")
  of exkFor: ctx.genDFor(e)
  of exkWhile: ctx.genDWhile(e)
  of exkBreak: "break"
  of exkContinue: "continue"
  of exkAssign: ctx.genDAssign(e)
  of exkReturn: ctx.genDReturn(e)
  of exkRaise: dUnsupported("raise")
  of exkImport: ""   # imports are assembled by dImports from realModules
  of exkSend: dUnsupported("actor send (arrives with the Fiber runtime)")
  of exkSelect: dUnsupported("on select (arrives with the Fiber runtime)")

# --------------------------------------------------------- declarations --

proc genDParams(ctx: var DCodegenCtx, params: seq[Param]): string =
  var parts: seq[string]
  for p in params:
    parts.add(ctx.dType(p.typ) & " " & p.name)
  parts.join(", ")

proc genDStmtOrBlock(ctx: var DCodegenCtx, body: Expr): string =
  if body == nil: return ""
  if body.kind == exkBlock: ctx.genDBlock(body)
  else: ctx.genDStmt(body)

proc genDFnDecl(ctx: var DCodegenCtx, d: Decl): string =
  if d.fnGenerics.len > 0: return dUnsupported("generic fn " & d.name)
  if d.isDecision: return dUnsupported("decision table " & d.name)
  let retStr = ctx.dType(d.fnReturnType)
  result = retStr & " " & d.name & "(" & ctx.genDParams(d.fnParams) & ") {\n"
  ctx.indent = 1
  ctx.definedVars.clear()
  for p in d.fnParams: ctx.definedVars.incl(p.name)
  result.add(ctx.genDStmtOrBlock(d.fnBody))
  ctx.indent = 0
  result.add("}\n")

proc dExternTodo(mem: Decl): string =
  ## Why this extern cannot emit a forwarder yet, or "" when it can. A TODO
  ## comment is visible in the output, and the D compiler names the missing
  ## symbol only if a call site actually references it — loud where it
  ## matters, without blocking every program that merely imports the module.
  if mem.externHeader != "" or mem.externLib != "" or mem.externImpl.len > 0:
    return "// D backend TODO: extern " & mem.name &
           " (C-header/lib/impl externs arrive in M5)\n"
  let ret = mem.fnReturnType
  # !T / ?T / !?T is tkApp(base "!"/"?"/"!?") — see codegen.nim bangInfo.
  let fallible = ret != nil and ret.kind == tkApp and ret.base != nil and
    ret.base.kind == tkNamed and ret.base.name in ["!", "?", "!?"]
  if fallible or (ret != nil and ret.kind == tkRecord):
    return "// D backend TODO: " & mem.name & " (needs TuckResult — M4)\n"
  ""

proc genDExternFwd(ctx: var DCodegenCtx, mem: Decl): string =
  ## An rt-implemented extern emits a forwarder calling `rt.<name>` — the
  ## Odin backend's shape (D likewise has no cross-module scope merge that
  ## would make the bare name resolve).
  if mem.kind != dkFn: return ""
  let todo = dExternTodo(mem)
  if todo != "": return todo
  let ret = mem.fnReturnType
  let emitName = if mem.externEmit != "": mem.externEmit else: mem.name
  result = ctx.dType(ret) & " " & mem.name & "(" &
           ctx.genDParams(mem.fnParams) & ") {\n"
  var args: seq[string]
  for p in mem.fnParams: args.add(p.name)
  let call = "rt." & emitName & "(" & args.join(", ") & ")"
  let isVoid = ret == nil or ctx.dType(ret) == "void"
  result.add("    " & (if isVoid: call else: "return " & call) & ";\n")
  result.add("}\n")

proc genDExternBlock(ctx: var DCodegenCtx, d: Decl): string =
  for mem in d.mixinMembers:
    let code = ctx.genDExternFwd(mem)
    if code != "": result.add(code & "\n")

proc genDTypeDecl(ctx: var DCodegenCtx, d: Decl): string =
  if d.generics.len > 0: return dUnsupported("generic type " & d.name)
  let body = d.typeBody
  if body == nil: return ""
  if body.kind == tkSum and not sumHasPayload(body):
    # A payload-free sum is exactly a D enum — same construct, same checks.
    var tags: seq[string]
    for v in body.variants: tags.add(v.name)
    return "enum " & d.name & " { " & tags.join(", ") & " }\n"
  dUnsupported("type " & d.name & " (only payload-free sums emit yet)")

proc genDDecl(ctx: var DCodegenCtx, d: Decl): string =
  if d == nil: return ""
  # Imported type decls are injected for checking only; the origin module
  # emits them (mirrors codegen.nim:1756 / codegen_odin.nim:2234).
  if d.kind == dkType and d.span.file.startsWith(ImportedTypeMarker):
    return ""
  case d.kind
  of dkType: ctx.genDTypeDecl(d)
  of dkObject: dUnsupported("object " & d.name)
  of dkRegistry: dUnsupported("registry " & d.name)
  of dkPool: dUnsupported("pool " & d.name)
  of dkFn:
    if d.isPending or d.isExtern: ""   # pending: M3; bare extern fn: via block
    else: ctx.genDFnDecl(d)
  of dkMixin: dUnsupported("mixin " & d.name)
  of dkExtern: ctx.genDExternBlock(d)
  of dkPending: dUnsupported("pending block (M3)")
  of dkActor: dUnsupported("actor " & d.name & " (arrives with the Fiber runtime)")
  of dkTask: dUnsupported("task " & d.name & " (arrives with the Fiber runtime)")
  of dkExpr: ""   # top-level statements are collected by emitBody
  of dkConst: dUnsupported("const " & d.name)
  of dkRegister: dUnsupported("register " & d.name)
  of dkStaticAssert: dUnsupported("static assert (M4)")
  of dkErrors: dUnsupported("errors policy (M4)")
  of dkImport: ""
  of dkSelect: dUnsupported("top-level on select (arrives with the Fiber runtime)")
  of dkFnSig: dUnsupported("fnsig " & d.name)
  of dkSatisfies: dUnsupported("top-level satisfies (M4)")
  of dkInterface: dUnsupported("interface " & d.name & " (M4)")
  of dkWhen: ""   # resolved away by modules.resolveWhenBlocks before codegen

# ------------------------------------------------------------- assembly --

proc emitDBody(ctx: var DCodegenCtx, m: Module): tuple[body, mains: string] =
  var body = ""
  var mainStmts: seq[string]
  for d in m.decls:
    if d != nil and d.kind == dkExpr:
      let oldIndent = ctx.indent
      ctx.indent = 1
      let stmtCode = ctx.genDStmt(d.expr)
      ctx.indent = oldIndent
      if stmtCode != "": mainStmts.add(stmtCode)
    else:
      let code = ctx.genDDecl(d)
      if code != "": body.add(code & "\n")
  (body, mainStmts.join(""))

proc dModuleName*(base: string): string =
  ## A D module name must be a valid identifier; example files are named
  ## like `01-data-flow`. Hyphens become underscores and a leading digit
  ## gets a prefix — the FILE keeps its own name (only imported modules
  ## need name==file, and those are mod_<name> which never start digital).
  result = base.replace("-", "_")
  if result.len > 0 and result[0] in {'0' .. '9'}: result = "_" & result

proc dImports(ctx: DCodegenCtx, body, mains: string,
              inModuleDir = false): seq[string] =
  ## Only import what the emitted code references — same policy as the Odin
  ## backend (and D warns on unused imports under -w).
  if "rt." in body or "rt." in mains:
    result.add("import rt = tuck_rt;")
  if "writeln(" in body or "writeln(" in mains:
    result.add("import std.stdio : writeln;")
  for modName in ctx.realModules.keys:
    let alias = modName.replace("-", "_")
    if (alias & ".") in body or (alias & ".") in mains:
      result.add("import " & alias & " = mod_" & alias & ";")

proc mainDeclD(m: Module): Decl =
  let tuckMain = mangleName("main")
  for d in m.decls:
    if d != nil and d.kind == dkFn and d.name == tuckMain and not d.isPending:
      return d
  nil

proc returnsValueD(d: Decl): bool =
  d.fnReturnType != nil and
    not (d.fnReturnType.kind == tkNamed and
         d.fnReturnType.name in ["void", "unit"])

proc genDEntryPoint(ctx: DCodegenCtx, m: Module, mains: string): string =
  ## Tuck's `fn main` is a plain fn; D's entry point calls it. A
  ## value-returning `fn main` IS the process exit code — D's `int main`
  ## says exactly that natively (the Nim backend needs quit(), Odin
  ## os.exit(); this is the identical-construct rule paying off).
  var hasRuntimeUsers = false
  for d in m.decls:
    if d != nil and d.kind in {dkActor, dkTask}: hasRuntimeUsers = true
  if hasRuntimeUsers:
    return dUnsupported("actor/task entry (arrives with the Fiber runtime)")
  let mainFn = mainDeclD(m)
  if mainFn == nil and mains == "": return ""
  let tuckMain = mangleName("main")
  if mainFn != nil and mainFn.returnsValueD:
    result = "int main() {\n" & mains &
             "    return cast(int) " & tuckMain & "();\n}\n"
  elif mainFn != nil:
    result = "void main() {\n" & mains & "    " & tuckMain & "();\n}\n"
  else:
    result = "void main() {\n" & mains & "}\n"

proc newDCtx(m: Module, realModules: Table[string, Module],
             moduleName: string, modPrefix = ""): DCodegenCtx =
  DCodegenCtx(definedVars: initHashSet[string](), indent: 0, module: m,
              realModules: realModules, moduleName: moduleName,
              modPrefix: modPrefix)

proc emitD*(m: Module, realModules = initTable[string, Module](),
            moduleName = "main"): string =
  ## The entry module: declarations, then D's own `main` calling tuck_main.
  var ctx = newDCtx(m, realModules, moduleName)
  let (body, mains) = ctx.emitDBody(m)
  result = "module " & dModuleName(moduleName) & ";\n\n"
  let imports = ctx.dImports(body, mains)
  if imports.len > 0:
    result.add(imports.join("\n") & "\n\n")
  for h in ctx.hoisted:
    result.add(h & "\n\n")
  result.add(body)
  result.add(ctx.genDEntryPoint(m, mains))

proc emitDModule*(name: string, m: Module,
                  realModules = initTable[string, Module]()): string =
  ## A library module (import target): file mod_<name>.d, module mod_<name>.
  ## The import alias at the use site keeps the Tuck name, so calls read
  ## `console.printLine` — and the mod_ prefix keeps a Tuck module called
  ## `std` or `core` from colliding with D's own top-level packages.
  let alias = name.replace("-", "_")
  var ctx = newDCtx(m, realModules, name, modPrefix = alias & "_")
  let (body, _) = ctx.emitDBody(m)
  result = "module mod_" & alias & ";\n\n"
  let imports = ctx.dImports(body, "", inModuleDir = true)
  if imports.len > 0:
    result.add(imports.join("\n") & "\n\n")
  for h in ctx.hoisted:
    result.add(h & "\n\n")
  result.add(body)
