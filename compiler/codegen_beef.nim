# compiler/codegen_beef.nim
import ast, strutils, sets

type
  BeefCodegenCtx = object
    definedVars: HashSet[string]
    fieldVars: HashSet[string]
    indent: int
    module: Module

proc repeat(s: string, n: int): string =
  var res = ""
  for i in 0..<n: res.add(s)
  res

proc capitalize(s: string): string =
  if s.len == 0: return ""
  return s[0].toUpperAscii() & s[1..^1]

proc genBeefType*(t: Type): string =
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
    of "string": "String"
    of "bool": "bool"
    of "float": "float"
    else: t.name
  of tkTuple:
    var parts: seq[string]
    for e in t.elems: parts.add(genBeefType(e))
    "(" & parts.join(", ") & ")"
  of tkRecord:
    var parts: seq[string]
    for f in t.fields: parts.add(genBeefType(f.typ) & " " & f.name)
    "struct { " & parts.join("; ") & "; }"
  of tkApp:
    if t.base.kind == tkNamed and t.base.name == "*":
      return genBeefType(t.args[0]) & "[" & genBeefType(t.args[1]) & "]"
    if t.base.kind == tkNamed and t.base.name == "Array":
      return genBeefType(t.args[1]) & "[" & genBeefType(t.args[0]) & "]"
    var parts: seq[string]
    for a in t.args: parts.add(genBeefType(a))
    return genBeefType(t.base) & "<" & parts.join(", ") & ">"
  of tkSum:
    var allNoFields = true
    for v in t.variants:
      if v.fields.len > 0: allNoFields = false
    if allNoFields:
      var tags: seq[string]
      for v in t.variants: tags.add(v.name)
      return "enum " & tags.join(", ")
    else:
      return "void"
  else:
    "void"

proc genPatternStr(p: Pattern): string =
  if p == nil: return "_"
  case p.kind
  of pkWild: "_"
  of pkVar: p.name
  of pkLit: p.litValue
  else: "_"

proc isDecisionTable(d: Decl): bool =
  if d.kind != dkFn or d.fnBody == nil or d.fnBody.kind != exkBlock: return false
  if d.fnBody.stmts.len == 0: return false
  for s in d.fnBody.stmts:
    if s.kind != exkMatch or s.subject != nil: return false
  return true

proc genBeefExpr*(ctx: var BeefCodegenCtx, e: Expr): string =
  if e == nil: return ""
  let ind = "  ".repeat(ctx.indent)
  case e.kind
  of exkLit:
    return case e.litKind
           of lkStr: "\"" & e.litValue & "\""
           else: e.litValue
  of exkVar:
    return if e.name in ctx.fieldVars: "this." & e.name
           else: e.name
  of exkField:
    return ctx.genBeefExpr(e.receiver) & "." & e.fieldName
  of exkCall:
    var args: seq[string]
    if e.args.len == 1 and e.args[0].kind == exkStruct:
      for field in e.args[0].fields:
        args.add(ctx.genBeefExpr(field[1]))
    else:
      for a in e.args: args.add(ctx.genBeefExpr(a))
    let calleeStr = ctx.genBeefExpr(e.callee)
    if calleeStr == "echo":
      return "Console.WriteLine(" & args.join(", ") & ")"
    elif calleeStr == "bake":
      return args[0] & "(" & args[1..^1].join(", ") & ")"
    return calleeStr & "(" & args.join(", ") & ")"
  of exkStruct:
    var parts: seq[string]
    for f in e.fields:
      parts.add(f[0] & " = " & ctx.genBeefExpr(f[1]))
    return ".{ " & parts.join(", ") & " }"
  of exkList:
    var parts: seq[string]
    for item in e.items:
      parts.add(ctx.genBeefExpr(item))
    return "new[] { " & parts.join(", ") & " }"
  of exkFor:
    let iterStr = ctx.genBeefExpr(e.iterable)
    let oldIndent = ctx.indent
    ctx.indent += 1
    let bodyStr = ctx.genBeefExpr(e.body)
    ctx.indent = oldIndent
    return ind & "for (let " & genPatternStr(e.iter) & " in " & iterStr & ")\n" & bodyStr
  of exkBinary:
    let opStr = case e.binOp
                of boAdd: "+"
                of boSub: "-"
                of boMul: "*"
                of boDiv: "/"
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
    return "(" & ctx.genBeefExpr(e.left) & " " & opStr & " " & ctx.genBeefExpr(e.right) & ")"
  of exkUnary:
    let opStr = case e.unaryOp
                of uoNeg: "-"
                of uoNot: "!"
                of uoComposition: ""
    return opStr & ctx.genBeefExpr(e.operand)
  of exkBlock:
    var lines: seq[string]
    let oldIndent = ctx.indent
    ctx.indent += 1
    for s in e.stmts:
      let stmtCode = ctx.genBeefExpr(s)
      if stmtCode != "":
        lines.add(ind & "  " & stmtCode & ";")
    ctx.indent = oldIndent
    if lines.len == 0:
      return ind & "{ }"
    return ind & "{\n" & lines.join("\n") & "\n" & ind & "}"
  of exkIf:
    let condStr = ctx.genBeefExpr(e.cond)
    let oldIndent = ctx.indent
    ctx.indent += 1
    let thenStr = ctx.genBeefExpr(e.thenBranch)
    let elseStr = if e.elseBranch != nil:
                    let elseBodyStr = ctx.genBeefExpr(e.elseBranch)
                    "\n" & ind & "else\n" & elseBodyStr
                  else: ""
    ctx.indent = oldIndent
    return "if (" & condStr & ")\n" & thenStr & elseStr
  of exkAssign:
    let targetStr = ctx.genBeefExpr(e.target)
    let valStr = ctx.genBeefExpr(e.assignVal)
    if e.target.kind == exkVar:
      let name = e.target.name
      if name notin ctx.definedVars and name notin ctx.fieldVars:
        ctx.definedVars.incl(name)
        return "let " & name & " = " & valStr
    return targetStr & " = " & valStr
  of exkMatch:
    if e.subject != nil:
      let subjectStr = ctx.genBeefExpr(e.subject)
      var cases: seq[string]
      for arm in e.arms:
        let patStr = genPatternStr(arm.pattern)
        let bodyStr = ctx.genBeefExpr(arm.body)
        cases.add("case ." & patStr & ": return " & bodyStr & ";")
      return "switch (" & subjectStr & ")\n{\n" & cases.join("\n") & "\n}"
    else:
      return ""
  of exkReturn:
    if e.returnVal == nil: return "return"
    else: return "return " & ctx.genBeefExpr(e.returnVal)
  of exkRaise:
    return "Runtime.FatalError(" & ctx.genBeefExpr(e.raiseVal) & ")"
  of exkChain:
    var res = ctx.genBeefExpr(e.base)
    for step in e.steps:
      let targetStr = ctx.genBeefExpr(step.target)
      let argStr = if step.arg != nil: ctx.genBeefExpr(step.arg) else: ""
      if argStr != "":
        res = res & "." & targetStr & "(" & argStr & ")"
      else:
        res = res & "." & targetStr & "()"
    return res
  else:
    ""

proc genBeefDecl*(ctx: var BeefCodegenCtx, d: Decl): string =
  if d == nil: return ""
  let ind = "  ".repeat(ctx.indent)
  case d.kind
  of dkFn:
    let fnNameSanitized = d.name.replace(".", "_")
    if d.isDecisionTable():
      var params: seq[string]
      for p in d.fnParams:
        params.add(genBeefType(p.typ) & " " & p.name)
      let retTypeStr = if d.fnReturnType != nil: genBeefType(d.fnReturnType) else: "void"
      let header = ind & "public static " & retTypeStr & " " & fnNameSanitized & "(" & params.join(", ") & ")"
      var bodyLines: seq[string]
      bodyLines.add(ind & "{")
      for idx, s in d.fnBody.stmts:
        let arm = s.arms[0]
        let pats = arm.pattern.elems
        var conds: seq[string]
        for i, pat in pats:
          let patStr = genPatternStr(pat)
          if patStr != "_":
            let paramName = d.fnParams[i].name
            conds.add(paramName & " == " & patStr)
        let condStr = if conds.len > 0: conds.join(" && ") else: "true"
        let resultExprStr = ctx.genBeefExpr(arm.body)
        if condStr == "true":
          bodyLines.add(ind & "    return " & resultExprStr & ";")
        else:
          bodyLines.add(ind & "    if (" & condStr & ") return " & resultExprStr & ";")
      bodyLines.add(ind & "}")
      return header & "\n" & bodyLines.join("\n") & "\n"

    var params: seq[string]
    for p in d.fnParams:
      params.add(genBeefType(p.typ) & " " & p.name)
    let retTypeStr = if d.fnReturnType != nil: genBeefType(d.fnReturnType) else: "void"
    let header = ind & "public static " & retTypeStr & " " & fnNameSanitized & "(" & params.join(", ") & ")"
    let oldVars = ctx.definedVars
    for p in d.fnParams:
      ctx.definedVars.incl(p.name)
    let oldIndent = ctx.indent
    ctx.indent += 1
    var bodyStr = ctx.genBeefExpr(d.fnBody)
    if d.fnBody.kind != exkBlock:
      bodyStr = "{\n" & ind & "  " & bodyStr & ";\n" & ind & "}"
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
        var res = ind & "public enum " & stateEnumName & " { " & states.join(", ") & " }\n"
        res.add(ind & "public class " & d.name & "\n" & ind & "{\n")
        res.add(ind & "    public " & stateEnumName & " state;\n")
        var casesStr: seq[string]
        casesStr.add(ind & "    public void TransitionTo(" & stateEnumName & " target)")
        casesStr.add(ind & "    {")
        casesStr.add(ind & "        switch (this.state)")
        casesStr.add(ind & "        {")
        for v in d.typeBody.variants:
          casesStr.add(ind & "        case ." & v.name & ":")
          var allowed: seq[string]
          for tr in d.typeBody.transitions:
            if tr.`from` == v.name:
              allowed.add(tr.to)
          if allowed.len > 0:
            var conds: seq[string]
            for a in allowed:
              conds.add("target != ." & a)
            casesStr.add(ind & "            if (" & conds.join(" && ") & ") Runtime.FatalError(\"Invalid transition\");")
          else:
            casesStr.add(ind & "            Runtime.FatalError(\"No outgoing transitions\");")
          casesStr.add(ind & "            break;")
        casesStr.add(ind & "        }")
        casesStr.add(ind & "        this.state = target;")
        casesStr.add(ind & "    }")
        res.add(casesStr.join("\n") & "\n" & ind & "}\n")
        return res
      elif d.typeBody.kind == tkRecord:
        var fieldsStr: seq[string]
        for f in d.typeBody.fields:
          fieldsStr.add(ind & "    public " & genBeefType(f.typ) & " " & f.name & ";")
        let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: ind & "    // empty"
        var res = ind & "public class " & d.name & "\n" & ind & "{\n" & fieldsBody & "\n"
        var invariantChecks: seq[string]
        var checkCtx = BeefCodegenCtx(definedVars: initHashSet[string](), fieldVars: initHashSet[string](), indent: ctx.indent + 1)
        for f in d.typeBody.fields:
          checkCtx.fieldVars.incl(f.name)
        for member in d.typeMembers:
          if member.kind == dkExpr:
            let condStr = checkCtx.genBeefExpr(member.expr)
            invariantChecks.add(ind & "        Runtime.Assert(" & condStr & ");")
        if invariantChecks.len > 0:
          res.add("\n" & ind & "    public void Validate()\n" & ind & "    {\n" & invariantChecks.join("\n") & "\n" & ind & "    }\n")
        res.add(ind & "}\n")
        return res
      else:
        let typeBodyStr = genBeefType(d.typeBody)
        return ind & "public typealias " & d.name & " = " & typeBodyStr & ";\n"
    return ""
  of dkObject:
    var fieldsStr: seq[string]
    for f in d.objFields:
      fieldsStr.add(ind & "    public " & genBeefType(f.typ) & " " & f.name & ";")
    let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: ind & "    // empty"
    var membersStr = ""
    let oldIndent = ctx.indent
    ctx.indent += 1
    for member in d.objMembers:
      membersStr.add(ctx.genBeefDecl(member) & "\n")
    ctx.indent = oldIndent
    return ind & "public class " & d.name & "\n" & ind & "{\n" & fieldsBody & "\n\n" & membersStr & ind & "}\n"
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
      fieldsStr.add(ind & "    [Bit(" & bitVal & ", AccessMode." & accessMode & ")] public bool " & f.name & ";")
    return ind & "[RegisterMMIO(" & d.regAddress & ")]\n" & ind & "public class " & d.name & "\n" & ind & "{\n" & fieldsStr.join("\n") & "\n" & ind & "}\n"
  of dkActor:
    var queueSize = "8"
    for attr in d.attrs:
      if attr.name == "queue":
        queueSize = attr.value
        break
    let msgEnumName = d.name & "MsgKind"
    let msgTypeName = d.name & "Msg"
    var enumVariants: seq[string]
    for h in d.handlers:
      if h.kind == dkFn:
        enumVariants.add(h.name.capitalize())
        
    var msgEnumStr = ind & "public enum " & msgEnumName & " { " & enumVariants.join(", ") & " }\n"
    var msgEnvelopeStr = ind & "public struct " & msgTypeName & "\n" & ind & "{\n" & ind & "    public " & msgEnumName & " kind;\n" & ind & "}\n"
    
    var fieldsStr: seq[string]
    var extraEnums = ""
    for f in d.actorFields:
      if f.typ != nil and f.typ.kind == tkSum:
        let inlineEnumName = d.name & "_" & f.name
        var tags: seq[string]
        for v in f.typ.variants: tags.add(v.name)
        extraEnums.add(ind & "    public enum " & inlineEnumName & " { " & tags.join(", ") & " }\n")
        fieldsStr.add(ind & "    public " & inlineEnumName & " " & f.name & ";")
      else:
        fieldsStr.add(ind & "    public " & genBeefType(f.typ) & " " & f.name & ";")
    fieldsStr.add(ind & "    public Mailbox<" & msgTypeName & ", " & queueSize & "> mailbox;")
    let fieldsBody = extraEnums & (if fieldsStr.len > 0: fieldsStr.join("\n") else: ind & "    // empty")
    
    var handlerCases: seq[string]
    var checkerCtx = BeefCodegenCtx(definedVars: initHashSet[string](), fieldVars: initHashSet[string](), indent: ctx.indent + 2)
    for f in d.actorFields:
      checkerCtx.fieldVars.incl(f.name)
    for h in d.handlers:
      if h.kind == dkFn:
        let variantName = h.name.capitalize()
        let bodyStr = checkerCtx.genBeefExpr(h.fnBody)
        handlerCases.add(ind & "            case ." & variantName & ":\n" & ind & "                " & bodyStr & ";\n" & ind & "                break;")
        
    let dispatchStr = ind & "    public void HandleMsg(" & msgTypeName & " msg)\n" & ind & "    {\n" & ind & "        switch (msg.kind)\n" & ind & "        {\n" & handlerCases.join("\n") & "\n" & ind & "        }\n" & ind & "    }\n"
    
    var helpersStr: seq[string]
    for h in d.handlers:
      if h.kind == dkFn:
        let variantName = h.name.capitalize()
        helpersStr.add(ind & "    public void Send" & variantName & "()\n" & ind & "    {\n" & ind & "        this.mailbox.Enqueue(. { kind = ." & variantName & " });\n" & ind & "    }")
        
    return msgEnumStr & msgEnvelopeStr & "\n" & ind & "public class " & d.name & "\n" & ind & "{\n" & fieldsBody & "\n\n" & dispatchStr & "\n" & helpersStr.join("\n\n") & "\n" & ind & "}\n"
  of dkTask:
    var params: seq[string]
    for p in d.taskParams:
      params.add(genBeefType(p.typ) & " " & p.name)
    let retTypeStr = if d.taskReturnType != nil: genBeefType(d.taskReturnType) else: "void"
    let header = ind & "public static " & retTypeStr & " " & d.name & "(" & params.join(", ") & ")"
    let oldVars = ctx.definedVars
    for p in d.taskParams:
      ctx.definedVars.incl(p.name)
    let oldIndent = ctx.indent
    ctx.indent += 1
    var bodyStr = ctx.genBeefExpr(d.taskBody)
    if d.taskBody.kind != exkBlock:
      bodyStr = "{\n" & ind & "  " & bodyStr & ";\n" & ind & "}"
    ctx.indent = oldIndent
    ctx.definedVars = oldVars
    return header & "\n" & bodyStr & "\n"
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
          fieldsStr.add(ind & "    public " & genBeefType(f.typ) & " " & f.name & ";")
          
    let enumStr = ind & "public enum " & msgEnumName & " { " & enumVariants.join(", ") & " }\n"
    let fieldsBody = if fieldsStr.len > 0: fieldsStr.join("\n") else: ind & "    // empty"
    let typeStr = ind & "public class " & d.name & "\n" & ind & "{\n" & ind & "    public " & msgEnumName & " kind;\n" & fieldsBody & "\n" & ind & "}\n"
    let globalVarStr = ind & "public static " & d.name & " latest" & d.name & ";\n\n"
    
    var raiseProcsStr = ""
    for v in d.variants:
      var params: seq[string]
      var assignParts: seq[string]
      for f in v.fields:
        params.add(genBeefType(f.typ) & " " & f.name)
        assignParts.add(f.name & " = " & f.name)
      let paramStr = params.join(", ")
      let assignStr = if assignParts.len > 0: assignParts.join(", ") else: ""
      
      let handlerName = d.name & "." & v.name
      let handlerNameSanitized = d.name & "_" & v.name
      var handlerCalls: seq[string]
      for decl in ctx.module.decls:
        if decl.kind == dkFn and decl.name == handlerName:
          var argNames: seq[string]
          for f in v.fields: argNames.add(f.name)
          handlerCalls.add("        " & handlerNameSanitized & "(" & argNames.join(", ") & ");")
          
      let handlerInvokes = if handlerCalls.len > 0: handlerCalls.join("\n") else: "        ;"
      let objAssign = if assignStr != "": "latest" & d.name & " = new " & d.name & "() { kind = ." & v.name & ", " & assignStr & " };"
                      else: "latest" & d.name & " = new " & d.name & "() { kind = ." & v.name & " };"
      
      raiseProcsStr.add(ind & "public static void raise_" & d.name & "_" & v.name & "(" & paramStr & ")\n" & ind & "{\n" & ind & "    " & objAssign & "\n" & handlerInvokes & "\n" & ind & "}\n\n")
      
    return enumStr & typeStr & "\n" & globalVarStr & raiseProcsStr
  of dkStaticAssert:
    return ind & "static { Runtime.Assert(" & ctx.genBeefExpr(d.assertExpr) & "); }\n"
  else:
    return ""

proc emitBeef*(m: Module): string =
  var ctx = BeefCodegenCtx(definedVars: initHashSet[string](), indent: 1, module: m)
  var methods = ""
  var mainStmts: seq[string]
  
  for d in m.decls:
    if d.kind == dkExpr:
      let stmtCode = ctx.genBeefExpr(d.expr)
      if stmtCode != "":
        mainStmts.add("        " & stmtCode & ";")
    else:
      let code = ctx.genBeefDecl(d)
      if code != "":
        methods.add(code & "\n")
        
  var res = "namespace TuckApp;\n\nusing System;\n\nclass Program\n{\n"
  res.add(methods)
  res.add("    public static void Main()\n    {\n")
  for s in mainStmts:
    res.add(s & "\n")
  res.add("    }\n}\n")
  res
