# compiler/codegen.nim
import ast, strutils, sets

type
  CodegenCtx = object
    definedVars: HashSet[string]
    fieldVars: HashSet[string]
    indent: int
    module: Module
    hoisted: seq[string]  # named decls hoisted out of field positions (inline enums)

proc repeat(s: string, n: int): string =
  var res = ""
  for i in 0..<n: res.add(s)
  res

proc capitalize(s: string): string =
  if s.len == 0: return ""
  return s[0].toUpperAscii() & s[1..^1]

proc genType*(t: Type): string =
  if t == nil: return "void"
  case t.kind
  of tkNamed:
    case t.name
    of "void": "void"
    of "u8": "uint8"
    of "u16": "uint16"
    of "u32": "uint32"
    of "u64": "uint64"
    of "i8": "int8"
    of "i16": "int16"
    of "i32": "int32"
    of "i64": "int64"
    of "int": "int"
    of "string", "str": "string"
    of "bool": "bool"
    of "float": "float"
    of "f32": "float32"
    of "f64": "float64"
    of "usize": "uint"
    of "Seq": "seq"
    of "Array": "array"
    of "fn": "pointer"  # ponytail: fn-ref fields become proc types once bake lands
    else:
      # Odd bit widths from decision tables (u2, u12, ...) round up to a real int
      if t.name.len >= 2 and t.name[0] in {'u', 'i'} and t.name[1..^1].allCharsInSet({'0'..'9'}):
        let bits = parseInt(t.name[1..^1])
        let base = if t.name[0] == 'u': "uint" else: "int"
        if bits <= 8: base & "8"
        elif bits <= 16: base & "16"
        elif bits <= 32: base & "32"
        else: base & "64"
      else: t.name
  of tkTuple:
    var parts: seq[string]
    for e in t.elems: parts.add(genType(e))
    "(" & parts.join(", ") & ")"
  of tkApp:
    if t.base.kind == tkNamed and t.base.name == "*":
      return "array[" & genType(t.args[1]) & ", " & genType(t.args[0]) & "]"
    # !T / ?T / !?T: v1 erases the wrapper and emits the payload type
    if t.base.kind == tkNamed and t.base.name in ["!", "?", "!?"] and t.args.len == 1:
      return genType(t.args[0])
    var parts: seq[string]
    for a in t.args: parts.add(genType(a))
    genType(t.base) & "[" & parts.join(", ") & "]"
  of tkRecord:
    var parts: seq[string]
    for f in t.fields: parts.add(f.name & ": " & genType(f.typ))
    "tuple[" & parts.join(", ") & "]"
  of tkSum:
    var allNoFields = true
    for v in t.variants:
      if v.fields.len > 0: allNoFields = false
    if allNoFields:
      var tags: seq[string]
      for v in t.variants: tags.add(v.name)
      "enum " & tags.join(", ")
    else:
      "ref object"
  else:
    "pointer"

# Field type emission. Nim forbids anonymous enums in field positions, so an
# inline sum type is hoisted to a named enum `<Parent><Field>Kind`.
proc fieldType(ctx: var CodegenCtx, parent: string, f: FieldDef): string =
  if f.typ != nil and f.typ.kind == tkSum:
    var allNoFields = true
    for v in f.typ.variants:
      if v.fields.len > 0: allNoFields = false
    if allNoFields and f.typ.variants.len > 0:
      let enumName = parent & f.name.capitalize() & "Kind"
      var tags: seq[string]
      for v in f.typ.variants: tags.add(v.name)
      ctx.hoisted.add("type " & enumName & "* = enum " & tags.join(", "))
      return enumName
  return genType(f.typ)

proc lookupFnParams(m: Module, name: string): seq[string] =
  for d in m.decls:
    if d.kind == dkFn and d.name == name:
      var res: seq[string]
      for p in d.fnParams:
        res.add(p.name)
      return res
  return @[]

proc genExpr*(ctx: var CodegenCtx, e: Expr, m: Module): string =
  if e == nil: return ""
  let ind = "  ".repeat(ctx.indent)
  case e.kind
  of exkLit:
    case e.litKind
    of lkStr: "\"" & e.litValue & "\""
    else: e.litValue
  of exkVar:
    if e.name == "...": "discard"  # pending hole: compiles, does nothing
    elif e.name in ctx.fieldVars: "self." & e.name
    else: e.name
  of exkField:
    # Unit sugar (5.ms) — emit the bare number; distinct unit types come later
    if e.receiver != nil and e.receiver.kind == exkLit and e.receiver.litKind in {lkInt, lkFloat}:
      ctx.genExpr(e.receiver, m)
    else:
      ctx.genExpr(e.receiver, m) & "." & e.fieldName
  of exkCall:
    var args: seq[string]
    let calleeStr = ctx.genExpr(e.callee, m)
    if e.args.len == 1 and e.args[0].kind == exkStruct:
      let expectedParams = lookupFnParams(m, calleeStr)
      if expectedParams.len > 0:
        for paramName in expectedParams:
          var found = false
          for field in e.args[0].fields:
            if field[0] == paramName:
              args.add(ctx.genExpr(field[1], m))
              found = true
              break
          if not found:
            args.add("nil")
      else:
        for field in e.args[0].fields:
          args.add(ctx.genExpr(field[1], m))
    else:
      for a in e.args: args.add(ctx.genExpr(a, m))
    if calleeStr == "bake":
      return args[0] & "(" & args[1..^1].join(", ") & ")"
    elif calleeStr == "alias":
      return args[0]
    return calleeStr & "(" & args.join(", ") & ")"
  of exkStruct:
    var parts: seq[string]
    for f in e.fields:
      parts.add(f[0] & ": " & ctx.genExpr(f[1], m))
    "(" & parts.join(", ") & ")"
  of exkBinary:
    let opStr = case e.binOp
                of boAdd: "+"
                of boSub: "-"
                of boMul: "*"
                of boDiv: "/"
                of boMod: "mod"
                of boEq: "=="
                of boNeq: "!="
                of boLt: "<"
                of boGt: ">"
                of boLe: "<="
                of boGe: ">="
                of boAnd: "and"
                of boOr: "or"
                of boXor: "xor"
    if e.binOp == boOr and e.right.kind == exkReturn:
      let tmpName = "or_tmp_" & $ctx.definedVars.len
      return "(block: let " & tmpName & " = " & ctx.genExpr(e.left, m) & "; if not " & tmpName & ": " & ctx.genExpr(e.right, m) & "; " & tmpName & ")"
    return "(" & ctx.genExpr(e.left, m) & " " & opStr & " " & ctx.genExpr(e.right, m) & ")"
  of exkUnary:
    let opStr = case e.unaryOp
                of uoNeg: "-"
                of uoNot: "not "
                of uoComposition: ""
    opStr & ctx.genExpr(e.operand, m)
  of exkBlock:
    var lines: seq[string]
    let oldIndent = ctx.indent
    ctx.indent += 1
    for s in e.stmts:
      let stmtCode = ctx.genExpr(s, m)
      if stmtCode != "":
        lines.add(ind & "  " & stmtCode)
    ctx.indent = oldIndent
    if lines.len == 0:
      return ind & "discard"
    ind & "block:\n" & lines.join("\n")
  of exkIf:
    let condStr = ctx.genExpr(e.cond, m)
    let oldIndent = ctx.indent
    ctx.indent += 1
    let thenStr = ctx.genExpr(e.thenBranch, m)
    let elseStr = if e.elseBranch != nil:
                    let elseBodyStr = ctx.genExpr(e.elseBranch, m)
                    "\n" & ind & "else:\n" & elseBodyStr
                  else: ""
    ctx.indent = oldIndent
    ind & "if " & condStr & ":\n" & thenStr & elseStr
  of exkAssign:
    let targetStr = ctx.genExpr(e.target, m)
    let valStr = ctx.genExpr(e.assignVal, m)
    if e.target.kind == exkVar:
      let name = e.target.name
      if name notin ctx.definedVars:
        ctx.definedVars.incl(name)
        return "var " & name & " = " & valStr
    return targetStr & " = " & valStr
  of exkReturn:
    if e.returnVal == nil: "return"
    else: "return " & ctx.genExpr(e.returnVal, m)
  of exkRaise:
    "raise " & ctx.genExpr(e.raiseVal, m)
  of exkChain:
    var res = ctx.genExpr(e.base, m)
    for step in e.steps:
      let targetStr = ctx.genExpr(step.target, m)
      let argStr = if step.arg != nil: ctx.genExpr(step.arg, m) else: ""
      if argStr != "":
        res = res & "." & targetStr & "(" & argStr & ")"
      else:
        res = res & "." & targetStr & "()"
    return res
  else:
    "discard"

proc isDecisionTable(d: Decl): bool =
  if d.kind != dkFn or d.fnBody == nil or d.fnBody.kind != exkBlock: return false
  if d.fnBody.stmts.len == 0: return false
  for s in d.fnBody.stmts:
    if s.kind != exkMatch or s.subject != nil: return false
  return true

proc genPatternStr(p: Pattern): string =
  if p == nil: return "_"
  case p.kind
  of pkWild: "_"
  of pkVar: p.name
  of pkLit: p.litValue
  else: "_"

proc genExpr*(ctx: var CodegenCtx, e: Expr): string =
  if e == nil: return ""
  let ind = "  ".repeat(ctx.indent)
  case e.kind
  of exkLit:
    case e.litKind
    of lkStr: "\"" & e.litValue & "\""
    else: e.litValue
  of exkVar:
    if e.name == "...": "discard"
    elif e.name in ctx.fieldVars: "self." & e.name
    else: e.name
  of exkField:
    if e.receiver != nil and e.receiver.kind == exkLit and e.receiver.litKind in {lkInt, lkFloat}:
      ctx.genExpr(e.receiver)
    else:
      ctx.genExpr(e.receiver) & "." & e.fieldName
  of exkCall:
    var args: seq[string]
    if e.args.len == 1 and e.args[0].kind == exkStruct:
      for field in e.args[0].fields:
        args.add(ctx.genExpr(field[1]))
    else:
      for a in e.args: args.add(ctx.genExpr(a))
    let calleeStr = ctx.genExpr(e.callee)
    if calleeStr == "bake":
      return args[0] & "(" & args[1..^1].join(", ") & ")"
    elif calleeStr == "alias":
      return args[0]
    return calleeStr & "(" & args.join(", ") & ")"
  of exkStruct:
    var parts: seq[string]
    for f in e.fields:
      parts.add(f[0] & ": " & ctx.genExpr(f[1]))
    "(" & parts.join(", ") & ")"
  of exkBinary:
    let opStr = case e.binOp
                of boAdd: "+"
                of boSub: "-"
                of boMul: "*"
                of boDiv: "/"
                of boMod: "mod"
                of boEq: "=="
                of boNeq: "!="
                of boLt: "<"
                of boGt: ">"
                of boLe: "<="
                of boGe: ">="
                of boAnd: "and"
                of boOr: "or"
                of boXor: "xor"
    if e.binOp == boOr and e.right.kind == exkReturn:
      let tmpName = "or_tmp_" & $ctx.definedVars.len
      return "(block: let " & tmpName & " = " & ctx.genExpr(e.left) & "; if not " & tmpName & ": " & ctx.genExpr(e.right) & "; " & tmpName & ")"
    return "(" & ctx.genExpr(e.left) & " " & opStr & " " & ctx.genExpr(e.right) & ")"
  of exkUnary:
    let opStr = case e.unaryOp
                of uoNeg: "-"
                of uoNot: "not "
                of uoComposition: ""
    opStr & ctx.genExpr(e.operand)
  of exkBlock:
    var lines: seq[string]
    let oldIndent = ctx.indent
    ctx.indent += 1
    for s in e.stmts:
      let stmtCode = ctx.genExpr(s)
      if stmtCode != "":
        lines.add(ind & "  " & stmtCode)
    ctx.indent = oldIndent
    if lines.len == 0:
      return ind & "discard"
    ind & "block:\n" & lines.join("\n")
  of exkIf:
    let condStr = ctx.genExpr(e.cond)
    let oldIndent = ctx.indent
    ctx.indent += 1
    let thenStr = ctx.genExpr(e.thenBranch)
    let elseStr = if e.elseBranch != nil:
                    let elseBodyStr = ctx.genExpr(e.elseBranch)
                    "\n" & ind & "else:\n" & elseBodyStr
                  else: ""
    ctx.indent = oldIndent
    ind & "if " & condStr & ":\n" & thenStr & elseStr
  of exkAssign:
    let targetStr = ctx.genExpr(e.target)
    let valStr = ctx.genExpr(e.assignVal)
    if e.target.kind == exkVar:
      let name = e.target.name
      if name notin ctx.definedVars and name notin ctx.fieldVars:
        ctx.definedVars.incl(name)
        return "var " & name & " = " & valStr
    return targetStr & " = " & valStr
  of exkMatch:
    if e.subject != nil:
      let subjectStr = ctx.genExpr(e.subject)
      var cases: seq[string]
      for arm in e.arms:
        let patStr = genPatternStr(arm.pattern)
        let bodyStr = ctx.genExpr(arm.body)
        cases.add("  of " & patStr & ":\n    " & bodyStr)
      return "(case " & subjectStr & "\n" & cases.join("\n") & ")"
    else:
      return "discard"
  of exkReturn:
    if e.returnVal == nil: "return"
    else: "return " & ctx.genExpr(e.returnVal)
  of exkRaise:
    "raise " & ctx.genExpr(e.raiseVal)
  of exkChain:
    var res = ctx.genExpr(e.base)
    for step in e.steps:
      let targetStr = ctx.genExpr(step.target)
      let argStr = if step.arg != nil: ctx.genExpr(step.arg) else: ""
      if argStr != "":
        res = res & "." & targetStr & "(" & argStr & ")"
      else:
        res = res & "." & targetStr & "()"
    return res
  else:
    "discard"

# Pending stub: logs on invocation, returns the zero value (Nim zero-inits result).
# The walking skeleton runs; the compile-time PENDING report nags until implemented.
proc genPendingStub(d: Decl): string =
  # Tuck call sites pass one whole payload struct; the Tuck checker already
  # verified its shape against the pending signature. The Nim stub is generic
  # so any payload representation is absorbed.
  let fnNameSanitized = d.name.replace(".", "_")
  let retTypeStr = if d.fnReturnType != nil: genType(d.fnReturnType) else: "void"
  let paramStr = if d.fnParams.len > 0: "[T](payload: T)" else: "()"
  return "proc " & fnNameSanitized & "*" & paramStr & ": " & retTypeStr &
         " =\n  stderr.writeLine(\"TUCK PENDING: " & d.name & " invoked (not implemented)\")\n"

proc genDecl*(ctx: var CodegenCtx, d: Decl): string =
  if d == nil: return ""
  case d.kind
  of dkFn:
    if d.isPending:
      return genPendingStub(d)
    let fnNameSanitized = d.name.replace(".", "_")
    if d.isDecisionTable():
      var params: seq[string]
      for p in d.fnParams:
        params.add(p.name & ": " & genType(p.typ))
      let retTypeStr = if d.fnReturnType != nil: genType(d.fnReturnType) else: "void"
      let header = "proc " & fnNameSanitized & "*(" & params.join(", ") & "): " & retTypeStr & " ="
      var bodyLines: seq[string]
      for idx, s in d.fnBody.stmts:
        let arm = s.arms[0]
        let pats = arm.pattern.elems
        var conds: seq[string]
        for i, pat in pats:
          let patStr = genPatternStr(pat)
          if patStr != "_":
            let paramName = d.fnParams[i].name
            conds.add(paramName & " == " & patStr)
        let condStr = if conds.len > 0: conds.join(" and ") else: "true"
        let resultExprStr = ctx.genExpr(arm.body)
        let prefix = if idx == 0: "if " else: "elif "
        if condStr == "true":
          bodyLines.add("  else:\n    return " & resultExprStr)
        else:
          bodyLines.add("  " & prefix & condStr & ":\n    return " & resultExprStr)
      return header & "\n" & bodyLines.join("\n") & "\n"

    var params: seq[string]
    for p in d.fnParams:
      params.add(p.name & ": " & genType(p.typ))
    let retTypeStr = if d.fnReturnType != nil: genType(d.fnReturnType) else: "void"
    let header = "proc " & fnNameSanitized & "*(" & params.join(", ") & "): " & retTypeStr & " ="
    let oldVars = ctx.definedVars
    for p in d.fnParams:
      ctx.definedVars.incl(p.name)
    let oldIndent = ctx.indent
    ctx.indent += 1
    let bodyStr = ctx.genExpr(d.fnBody)
    ctx.indent = oldIndent
    ctx.definedVars = oldVars
    return header & "\n" & bodyStr & "\n"
  of dkType:
    if d.typeBody != nil:
      if d.typeBody.kind == tkSum and d.typeBody.transitions.len > 0:
        let stateEnumName = d.name & "State"
        var states: seq[string]
        for v in d.typeBody.variants:
          states.add(v.name)
        var res = "type " & stateEnumName & "* = enum " & states.join(", ") & "\n"
        res.add("type " & d.name & "* = ref object\n  state*: " & stateEnumName & "\n")
        var casesStr: seq[string]
        casesStr.add("proc transitionTo*(self: " & d.name & ", target: " & stateEnumName & ") =")
        casesStr.add("  case self.state")
        for v in d.typeBody.variants:
          casesStr.add("  of " & v.name & ":")
          var allowed: seq[string]
          for tr in d.typeBody.transitions:
            if tr.`from` == v.name:
              allowed.add(tr.to)
          if allowed.len > 0:
            var conds: seq[string]
            for a in allowed:
              conds.add("target != " & a)
            casesStr.add("    if " & conds.join(" and ") & ": raise newException(ValueError, \"Invalid transition\")")
          else:
            casesStr.add("    raise newException(ValueError, \"No outgoing transitions\")")
        casesStr.add("  self.state = target")
        res.add(casesStr.join("\n") & "\n")
        return res
      elif d.typeBody.kind == tkRecord:
        var fieldsStr: seq[string]
        for f in d.typeBody.fields:
          fieldsStr.add("    " & f.name & "*: " & ctx.fieldType(d.name, f))
        let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: "    discard"
        var res = "type " & d.name & "* = ref object\n" & fieldsBody & "\n"
        var invariantChecks: seq[string]
        var checkCtx = CodegenCtx(definedVars: initHashSet[string](), fieldVars: initHashSet[string](), indent: 0)
        for f in d.typeBody.fields:
          checkCtx.fieldVars.incl(f.name)
        for member in d.typeMembers:
          if member.kind == dkExpr:
            let condStr = checkCtx.genExpr(member.expr)
            invariantChecks.add("  assert(" & condStr & ", \"Invariant violated: " & condStr & "\")")
        if invariantChecks.len > 0:
          res.add("\nproc validate*(self: " & d.name & ") =\n" & invariantChecks.join("\n") & "\n")
        return res
      else:
        let typeBodyStr = genType(d.typeBody)
        return "type " & d.name & "* = " & typeBodyStr & "\n"
    return ""
  of dkObject:
    var fieldsStr: seq[string]
    for f in d.objFields:
      fieldsStr.add("    " & f.name & "*: " & ctx.fieldType(d.name, f))
    let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: "    discard"
    var membersStr = ""
    for member in d.objMembers:
      membersStr.add(ctx.genDecl(member) & "\n")
    return "type " & d.name & "* = ref object\n" & fieldsBody & "\n\n" & membersStr
  of dkActor:
    var queueSize = "8"
    for attr in d.attrs:
      if attr.name == "queue":
        queueSize = attr.value
        break
    
    # 1. Generate Msg Kind enum and Msg envelope
    let msgEnumName = d.name & "MsgKind"
    let msgTypeName = d.name & "Msg"
    var enumVariants: seq[string]
    var msgFields: seq[string]
    
    for h in d.handlers:
      if h.kind == dkFn:
        let variantName = "msg" & h.name.capitalize()
        enumVariants.add(variantName)

    if enumVariants.len == 0:
      # No message handlers: an empty enum is invalid Nim. Emit just the state object.
      var bareFields: seq[string]
      for f in d.actorFields:
        bareFields.add("    " & f.name & "*: " & ctx.fieldType(d.name, f))
      let bareBody = if bareFields.len > 0: bareFields.join("\n") else: "    discard"
      return "type " & d.name & "* = ref object\n" & bareBody & "\n"

    # Handler params ride in the message envelope (deduped by name across handlers)
    var seenMsgFields = initHashSet[string]()
    for h in d.handlers:
      if h.kind == dkFn:
        for p in h.fnParams:
          if p.name notin seenMsgFields:
            seenMsgFields.incl(p.name)
            msgFields.add("  " & p.name & "*: " & genType(p.typ))

    var msgEnumStr = "type " & msgEnumName & "* = enum " & enumVariants.join(", ") & "\n"
    var msgEnvelopeStr = "type " & msgTypeName & "* = object\n  kind*: " & msgEnumName & "\n" &
                         (if msgFields.len > 0: msgFields.join("\n") & "\n" else: "")
    
    # 2. Generate Actor state object
    var fieldsStr: seq[string]
    for f in d.actorFields:
      fieldsStr.add("    " & f.name & "*: " & ctx.fieldType(d.name, f))
    fieldsStr.add("    mailbox*: Mailbox[" & msgTypeName & ", " & queueSize & "]")
    let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: "    discard"
    var actorTypeStr = "type " & d.name & "* = ref object\n" & fieldsBody & "\n"
    
    # 3. Generate dispatch handler
    var handlerCases: seq[string]
    var ctx = CodegenCtx(definedVars: initHashSet[string](), fieldVars: initHashSet[string](), indent: 2)
    for f in d.actorFields:
      ctx.fieldVars.incl(f.name)
    for h in d.handlers:
      if h.kind == dkFn:
        let variantName = "msg" & h.name.capitalize()
        var caseBody = ""
        for p in h.fnParams:
          caseBody.add("    let " & p.name & " = msg." & p.name & "\n")
        let bodyStr = ctx.genExpr(h.fnBody)
        handlerCases.add("  of " & variantName & ":\n" & caseBody & bodyStr)
      
    let dispatchStr = "proc handleMsg*(self: " & d.name & ", msg: " & msgTypeName & ") =\n  case msg.kind\n" & handlerCases.join("\n") & "\n"
    
    # 4. Generate send helpers
    var helpersStr = ""
    for h in d.handlers:
      if h.kind == dkFn:
        let helperName = "send" & h.name.capitalize()
        let variantName = "msg" & h.name.capitalize()
        var helperParams = "self: " & d.name
        var ctorArgs = "kind: " & variantName
        for p in h.fnParams:
          helperParams.add(", " & p.name & ": " & genType(p.typ))
          ctorArgs.add(", " & p.name & ": " & p.name)
        helpersStr.add("proc " & helperName & "*(" & helperParams & ") =\n  discard self.mailbox.enqueue(" & msgTypeName & "(" & ctorArgs & "))\n\n")
      
    return msgEnumStr & msgEnvelopeStr & "\n" & actorTypeStr & "\n" & dispatchStr & "\n" & helpersStr

  of dkTask:
    var params: seq[string]
    for p in d.taskParams:
      params.add(p.name & ": " & genType(p.typ))
    let retTypeStr = if d.taskReturnType != nil: genType(d.taskReturnType) else: "void"
    let header = "proc " & d.name & "*(" & params.join(", ") & "): " & retTypeStr & " ="
    let oldVars = ctx.definedVars
    for p in d.taskParams:
      ctx.definedVars.incl(p.name)
    let oldIndent = ctx.indent
    ctx.indent += 1
    let bodyStr = ctx.genExpr(d.taskBody)
    ctx.indent = oldIndent
    ctx.definedVars = oldVars
    return header & "\n" & bodyStr & "\n"

  of dkExpr:
    return ctx.genExpr(d.expr)
  of dkRegister:
    var fieldsStr: seq[string]
    for f in d.regFields:
      let bitVal = f.typ.name.replace("bit ", "").replace("bits ", "")
      var accessMode = "ReadWrite"
      var hasRead = false
      var hasWrite = false
      for a in f.attrs:
        if a.name == "read": hasRead = true
        elif a.name == "write": hasWrite = true
      if hasRead and not hasWrite: accessMode = "ReadOnly"
      elif hasWrite and not hasRead: accessMode = "WriteOnly"
      fieldsStr.add("  " & f.name & ": bit(" & bitVal & ", " & accessMode & ")")
    return "registerMMIO(" & d.name & ", " & d.regAddress & "):\n" & fieldsStr.join("\n") & "\n"
  of dkRegistry:
    let msgEnumName = d.name & "Kind"
    var enumVariants: seq[string]
    var fieldsStr: seq[string]
    var seenFields = initHashSet[string]()
    for v in d.variants:
      enumVariants.add(v.name)
      for f in v.fields:
        if f.name notin seenFields:
          seenFields.incl(f.name)
          fieldsStr.add("    " & f.name & "*: " & genType(f.typ))
          
    let enumStr = "type " & msgEnumName & "* = enum " & enumVariants.join(", ") & "\n"
    let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: ""
    let typeStr = "type " & d.name & "* = ref object\n    kind*: " & msgEnumName & "\n" & fieldsBody & "\n"
    let globalVarStr = "var latest" & d.name & "*: " & d.name & "\n\n"

    # Forward-declare handler procs: raise procs call them before their definition
    var fwdDeclsStr = ""
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
          let retStr = if decl.fnReturnType != nil: genType(decl.fnReturnType) else: "void"
          fwdDeclsStr.add("proc " & handlerNameSanitized & "*(" & paramStr & "): " & retStr & "\n")

      let handlerInvokes = if handlerCalls.len > 0: handlerCalls.join("\n") else: "  discard"
      raiseProcsStr.add("proc raise_" & d.name & "_" & v.name & "*(" & paramStr & ") =\n  latest" & d.name & " = " & d.name & "(kind: " & v.name & assignStr & ")\n" & handlerInvokes & "\n\n")
      
    return enumStr & typeStr & "\n" & globalVarStr & fwdDeclsStr & raiseProcsStr
  of dkStaticAssert:
    return "static: assert(" & ctx.genExpr(d.assertExpr) & ")"
  of dkMixin:
    # Pending blocks parse as a mixin named "pending"; emit stubs for its members.
    var res = ""
    for m in d.mixinMembers:
      if m.kind == dkFn and m.isPending:
        res.add(genPendingStub(m) & "\n")
    if res == "":
      return "# [codegen] ignored decl kind " & $d.kind & "\n"
    return res
  else:
    return "# [codegen] ignored decl kind " & $d.kind & "\n"

proc emitNim*(m: Module, rtImport = "../compiler/tuck_rt"): string =
  var ctx = CodegenCtx(definedVars: initHashSet[string](), indent: 0, module: m)
  var body = ""
  for d in m.decls:
    let code = ctx.genDecl(d)
    if code != "":
      body.add(code & "\n")
  var res = "import " & rtImport & "\n\n"
  for h in ctx.hoisted:
    res.add(h & "\n")
  if ctx.hoisted.len > 0:
    res.add("\n")
  res.add(body)
  res
