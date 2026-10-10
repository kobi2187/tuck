## Backend preparation must elaborate the source's common lowered tree,
## then clone it. Test one backend per process (prepare's public contract).
import std/[os, strutils]
import ../../compiler/[ast, resolution, backend_prepare, modules]

let res = newResolution()
let ints = Type(kind: tkApp, base: Type(kind: tkNamed, name: "Seq"),
                args: @[Type(kind: tkNamed, name: "int")])
proc variable(name: string): Expr =
  res.typed(Expr(kind: exkVar, name: name), ints)
let xs = variable("xs")
let ys = variable("ys")
let source = Decl(kind: dkFn, name: "main",
  fnReturnType: Type(kind: tkNamed, name: "int"),
  fnBody: Expr(kind: exkBlock, stmts: @[
    Expr(kind: exkAssign, target: xs, isDecl: true,
         assignVal: res.typed(Expr(kind: exkList, items: @[]), ints)),
    Expr(kind: exkAssign, target: ys, isDecl: true, assignVal: variable("xs")),
    Expr(kind: exkAssign, target: variable("zs"), isDecl: true, assignVal: variable("ys")),
    Expr(kind: exkDiscard, discardVal: variable("xs")),
    Expr(kind: exkReturn, returnVal: Expr(kind: exkLit, litKind: lkInt, litValue: "0"))]))
var m = Module(decls: @[source])
fillIds(m)
let backend = case paramStr(1)
  of "nim": bkNim
  of "d": bkDlang
  else: bkOdin
let prepared = prepare(@[LoadedModule(name: "common", path: "common.tuck", m: m)],
                       backend, res, ".")
var copies, drops, moves: int
for n in source.fnBody.nodes:
  if $n.kind == "exkMove": inc moves
  if n.kind == exkCopy:
    inc copies
    doAssert n.copyKind == cpValue
  if n.kind == exkDrop:
    inc drops
    doAssert n.droppedType != nil
doAssert copies == 1 and drops == 2
doAssert moves == 1, "a sink transfer must be an explicit shared AST operation"
doAssert source.ownershipElaborated
doAssert prepared.mods[0].m.decls[0] != source, "backend receives a private clone"
doAssert prepared.mods[0].m.decls[0].fnBody != source.fnBody
echo "OK common ownership before " & paramStr(1) & " clone"
