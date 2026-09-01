# compiler/parser_stringify.nim
#
# Expr → source-ish string. A standalone printer used for debug output and
# error messages; it walks an Expr and calls only itself, so it has no
# dependency on the parser state or grammar.
import ast, strutils

proc opStr*(op: BinOp): string =
  ## How a binary operator is SPELLED in source. A lookup table, so it lives
  ## on its own rather than nested inside the printer's exkBinary arm — the
  ## spelling of `/i` is a fact about the language, not about printing.
  case op
  of boAdd: "+"
  of boSub: "-"
  of boMul: "*"
  of boDivInt: "/i"
  of boDivFloat: "/f"
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

proc opStr*(op: UnaryOp): string =
  ## The prefix spelling. uoPropagate is postfix (`x?`) and has no prefix, so
  ## it maps to the empty string and the printer special-cases it.
  case op
  of uoNeg: "-"
  of uoNot: "not "
  of uoComposition: "+ "
  of uoPropagate: ""

proc toString*(e: Expr): string

proc optToString(e: Expr, prefix = ""): string =
  ## An optional sub-expression: its text behind `prefix`, or nothing at all.
  ## `return`, `raise` and `send` all carry a payload that may be absent, and
  ## each was spelling this out as its own `if`.
  if e == nil: "" else: prefix & e.toString()

proc listToString(items: seq[Expr], open, close: string): string =
  ## A delimited, comma-joined list — `[a, b]`, `(a, b)`. Three arms built this
  ## by hand with an index test for the separator, which `join` already does.
  var parts: seq[string]
  for it in items: parts.add(it.toString())
  open & parts.join(", ") & close

proc structToString(e: Expr): string =
  var parts: seq[string]
  for f in e.fields: parts.add(f.name & ": " & f.value.toString())
  "{" & parts.join(", ") & "}"

proc qualifiedToString(e: Expr): string =
  for p in e.modulePath: result.add(p & "::")
  result.add(e.qualName)

proc chainToString(e: Expr): string =
  ## `base ..step arg ..step arg`. The arg is optional per step, which is the
  ## one real branch here.
  result = e.base.toString()
  for step in e.steps:
    result.add(" .." & step.target.toString())
    result.add(optToString(step.arg, " "))

proc toString*(e: Expr): string =
  if e == nil: return ""
  case e.kind
  of exkLit: return e.litValue
  of exkVar: return e.name
  of exkField: return e.receiver.toString() & "." & e.fieldName
  of exkQualified: return qualifiedToString(e)
  of exkStruct: return structToString(e)
  of exkBracket:
    return e.brReceiver.toString() & listToString(e.brArgs, "[", "]")
  of exkBracketAssign:
    return e.brTarget.toString() & " = " & e.brValue.toString()
  of exkList: return listToString(e.items, "[", "]")
  of exkCall:
    if e.args.len == 0: return e.callee.toString()
    return e.callee.toString() & listToString(e.args, "(", ")")
  of exkChain: return chainToString(e)
  of exkBinary:
    return e.left.toString() & " " & opStr(e.binOp) & " " & e.right.toString()
  of exkUnary:
    if e.unaryOp == uoPropagate:
      return e.operand.toString() & "?"   # postfix, unlike the other three
    return opStr(e.unaryOp) & e.operand.toString()
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
  of exkReturn: return "return " & optToString(e.returnVal)
  of exkRaise: return "raise " & optToString(e.raiseVal)
  of exkDiscard: return "discard " & optToString(e.discardVal)
  of exkImport:
    return "import"
  of exkSend:
    return e.sendActor & " send " & e.sendHandler &
           optToString(e.sendPayload, " ")
  of exkSelect:
    return "on select (" & $e.selArms.len & " arms)"
