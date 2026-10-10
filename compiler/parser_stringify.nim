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
  ## The prefix spelling of each unary operator.
  case op
  of uoNeg: "-"
  of uoNot: "not "
  of uoComposition: "+ "

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
  ## A payload literal as `{name: value, ...}`.
  var parts: seq[string]
  for f in e.fields: parts.add(f.name & ": " & f.value.toString())
  "{" & parts.join(", ") & "}"

proc qualifiedToString(e: Expr): string =
  ## A qualified name as written: `mod::sub::name`.
  for p in e.modulePath: result.add(p & "::")
  result.add(e.qualName)

proc chainToString(e: Expr): string =
  ## `base ..step arg ..step arg`. The arg is optional per step, which is the
  ## one real branch here.
  result = e.base.toString()
  for step in e.steps:
    result.add(" .." & step.target.toString())
    result.add(optToString(step.arg, " "))

proc poolOpToString(e: Expr): string =
  ## Checker-stamped: `Pool.op {operands}`, as it was written.
  var args: seq[string]
  for a in e.poolOperands: args.add a.toString()
  result = e.poolRef.toString() & "." & ($e.poolOp)[2 .. ^1].toLowerAscii()
  if args.len > 0: result.add " {" & args.join(", ") & "}"

proc slabOpToString(e: Expr): string =
  ## Checker-stamped: `Slab.op {operands}`, as it was written.
  var args: seq[string]
  if e.slabArg != nil: args.add e.slabArg.toString()
  if e.slabValue != nil: args.add e.slabValue.toString()
  result = e.slabRef.toString() & "." & ($e.slabOp)[2 .. ^1].toLowerAscii()
  if args.len > 0: result.add " {" & args.join(", ") & "}"

proc toString*(e: Expr): string =
  ## A one-line, source-like rendering of `e` for messages and dumps. Lossy on
  ## purpose: control flow prints only its keyword (`if`, `match`, `block`), so
  ## two different bodies can render the same — never compare code by it.
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
  of exkFill: return "[" & e.fillValue.toString() & "; " & e.fillCount.toString() & "]"
  of exkCall:
    if e.args.len == 0: return e.callee.toString()
    return e.callee.toString() & listToString(e.args, "(", ")")
  of exkCombinator:
    # Round-trips to the surface spelling: postfix, receiver first.
    let nm = (case e.comb
              of ckBake: "bake"
              of ckWith: "with"
              of ckAlias: "alias"
              of ckMerge: "merge")
    if e.combArg == nil: return e.combRecv.toString() & " " & nm
    return e.combRecv.toString() & " " & nm & " " & e.combArg.toString()
  of exkChain: return chainToString(e)
  of exkBinary:
    return e.left.toString() & " " & opStr(e.binOp) & " " & e.right.toString()
  of exkUnary:
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
  of exkTripleDot: return "..."
  of exkImport:
    return "import"
  of exkSend:
    return e.sendActor & " send " & e.sendHandler &
           optToString(e.sendPayload, " ")
  of exkSelect:
    return "on select (" & $e.selArms.len & " arms)"
  of exkDefer:
    return "defer: " & optToString(e.deferBody)
  of exkOrdinal:
    # Not surface syntax — lowering builds it — so this is only ever read in
    # a dump, where `ord(x)` says what it is.
    return "ord(" & e.ordinalOf.toString() & ")"
  of exkValidate:
    return "validate(" & e.validated.toString() & ")"   # lowering-built too
  of exkPoolOp:
    return poolOpToString(e)
  of exkSlabOp:
    return slabOpToString(e)
  of exkSlabCell:
    # Lowering-built: the cell a reference names.
    return "cell(" & e.cellRef.toString() & ")"
  of exkArenaReset:
    return e.arenaRef.toString() & ".reset"
  of exkAppend:
    # Prepare-built: an append in place.
    return e.appendTarget.toString() & " += " & e.appendValue.toString()
  of exkCopy:
    # Prepare-built: a copy where the backend's assignment would alias.
    let what = if e.copyKind == cpFields: "copy[" & e.copyFields.join(", ") & "]"
               else: "copy"
    return what & "(" & e.copied.toString() & ")"
  of exkDrop:
    # Prepare-built: a release of the storage a place owns.
    return "drop(" & e.dropped.toString() & ")"
  of exkReset: return "reset(" & e.resetPlace.toString() & ")"
  of exkMove: return "move(" & e.movedValue.toString() & ")"
  of exkIfaceCall:
    # Lowering-built: one arm per satisfying object, shown by name.
    var sats: seq[string]
    for arm in e.dispatchArms: sats.add arm.satisfier
    return e.dispatchRecv.toString() & " dispatch<" & e.dispatchIface & ": " &
           sats.join(" | ") & ">"
  of exkIfaceIs:
    # Lowering-built, from a `| Flac f ->` arm.
    return e.tagSubject.toString() & " is " & e.tagObject
  of exkIfacePayload:
    return e.tagSubject.toString() & " as " & e.tagObject
  of exkWrapOk:
    # Lowering-built: a plain value stored into a `?T` place.
    return "some(" & e.optValue.toString() & ")"
  of exkAbsent:
    return "none"
  of exkAcquire:
    return "acquire " & optToString(e.acquireRef) & ", " & e.acquireKind
  of exkFinish:
    return "finish " & optToString(e.finishHandle) & ", " & e.finishKind
  of exkActorRef, exkRegisterRef, exkRegistryRef, exkPoolRef, exkMixinRef,
     exkSlabRef, exkArenaRef:
    return e.refName
