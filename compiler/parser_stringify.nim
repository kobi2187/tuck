# compiler/parser_stringify.nim
#
# Expr → source-ish string. A standalone printer used for debug output and
# error messages; it walks an Expr and calls only itself, so it has no
# dependency on the parser state or grammar.
import ast, strutils

proc toString*(e: Expr): string =
  if e == nil: return ""
  case e.kind
  of exkLit: return e.litValue
  of exkVar: return e.name
  of exkField: return e.receiver.toString() & "." & e.fieldName
  of exkQualified:
    var res = ""
    for p in e.modulePath:
      res.add(p & "::")
    res.add(e.qualName)
    return res
  of exkStruct:
    var res = "{"
    for i, f in e.fields:
      if i > 0: res.add(", ")
      res.add(f[0] & ": " & f[1].toString())
    res.add("}")
    return res
  of exkBracket:
    var parts: seq[string]
    for a in e.brArgs: parts.add(a.toString())
    return e.brReceiver.toString() & "[" & parts.join(", ") & "]"
  of exkBracketAssign:
    return e.brTarget.toString() & " = " & e.brValue.toString()
  of exkList:
    var res = "["
    for i, item in e.items:
      if i > 0: res.add(", ")
      res.add(item.toString())
    res.add("]")
    return res
  of exkCall:
    var res = e.callee.toString()
    if e.args.len > 0:
      res.add("(")
      for i, arg in e.args:
        if i > 0: res.add(", ")
        res.add(arg.toString())
      res.add(")")
    return res
  of exkChain:
    var res = e.base.toString()
    for step in e.steps:
      res.add(" .." & step.target.toString())
      if step.arg != nil:
        res.add(" " & step.arg.toString())
    return res
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
                of boAnd: "and"
                of boOr: "or"
                of boXor: "xor"
                of boRangeIncl: ".."
                of boRangeExcl: "..<"
    return e.left.toString() & " " & opStr & " " & e.right.toString()
  of exkUnary:
    let opStr = case e.unaryOp
                of uoNeg: "-"
                of uoNot: "not "
                of uoComposition: "+ "
                of uoPropagate: ""
    if e.unaryOp == uoPropagate:
      return e.operand.toString() & "?"
    return opStr & e.operand.toString()
  of exkBlock:
    return "block"
  of exkIf:
    return "if"
  of exkMatch:
    return "match"
  of exkFor:
    return "for"
  of exkWhile:
    return if e.whileCond == nil: "loop" else: "for " & e.whileCond.toString()
  of exkBreak:
    return "break"
  of exkContinue:
    return "continue"
  of exkAssign:
    return e.target.toString() & " = " & e.assignVal.toString()
  of exkReturn:
    let rVal = if e.returnVal != nil: e.returnVal.toString() else: ""
    return "return " & rVal
  of exkRaise:
    let rVal = if e.raiseVal != nil: e.raiseVal.toString() else: ""
    return "raise " & rVal
  of exkImport:
    return "import"
  of exkSend:
    let p = if e.sendPayload != nil: " " & e.sendPayload.toString() else: ""
    return e.sendActor & " send " & e.sendHandler & p
  of exkSelect:
    return "on select (" & $e.selArms.len & " arms)"
