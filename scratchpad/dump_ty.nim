import os, tables, strutils
import ../lexer
import ../compiler/ast
import ../compiler/parser
import ../compiler/typecheck
import ../compiler/modules
import ../compiler/lowering

proc dumpExpr(e: Expr, indent = 0) =
  if e == nil: return
  let pad = "  ".repeat(indent)
  let tyStr = if e.ty == nil: "<nil>"
              elif e.ty.kind == tkNamed: "tkNamed(" & e.ty.name & ")"
              else: $e.ty.kind
  case e.kind
  of exkBinary:
    echo pad, "Binary ", e.binOp, " ty=", tyStr
    dumpExpr(e.left, indent+1)
    dumpExpr(e.right, indent+1)
  of exkField:
    echo pad, "Field .", e.fieldName, " ty=", tyStr,
         " callNode=", (e.callNode != nil)
    if e.callNode != nil:
      let ct = if e.callNode.ty == nil: "<nil>"
               elif e.callNode.ty.kind == tkNamed: e.callNode.ty.name
               else: $e.callNode.ty.kind
      echo pad, "  callNode.ty=", ct
    dumpExpr(e.receiver, indent+1)
  of exkVar:
    echo pad, "Var ", e.name, " ty=", tyStr
  of exkLit:
    echo pad, "Lit ", e.litKind, " ", e.litValue, " ty=", tyStr
  of exkCall:
    let cn = if e.callee != nil and e.callee.kind == exkVar: e.callee.name else: "?"
    echo pad, "Call ", cn, " ty=", tyStr
    for a in e.args: dumpExpr(a, indent+1)
  of exkAssign:
    echo pad, "Assign ty=", tyStr
    dumpExpr(e.target, indent+1)
    dumpExpr(e.assignVal, indent+1)
  of exkBlock:
    echo pad, "Block"
    for s in e.stmts: dumpExpr(s, indent+1)
  of exkStruct:
    echo pad, "Struct ty=", tyStr
    for f in e.fields:
      echo pad, "  .", f[0]
      dumpExpr(f[1], indent+2)
  else:
    echo pad, $e.kind, " ty=", tyStr

let path = paramStr(1)
var prog = loadProgram(path)
injectImportedTypes(prog)
var mods: seq[tuple[name, path: string, m: Module]]
for lm in prog: mods.add((lm.name, lm.path, lm.m))
discard typecheckProgram(mods)
echo "=== AFTER TYPECHECK ==="
for d in prog[^1].m.decls:
  if d.kind == dkFn and d.name == "main":
    dumpExpr(d.fnBody)
echo "=== AFTER LOWER ==="
lowerModule(prog[^1].m)
for d in prog[^1].m.decls:
  if d.kind == dkFn and d.name == "main":
    dumpExpr(d.fnBody)
