# compiler/lowering_recursive.nim
#
# GIVE EVERY RECURSIVE EDGE A HANDLE, so an author can write the obvious thing.
#
#     type Expr:
#       | Num({value: int})
#       | Add({left: Expr, right: Expr})
#
# has no finite size — a field IS its value, so every Expr holds two more. That
# is what TK-TY17 rejects, and its advice is to write `Seq[Expr]` by hand. This
# pass writes it for you: a field whose type is the sum being declared becomes
# `Seq[T]`, a construction wraps its value, and a read unwraps it.
#
# WHY A HANDLE AND NOT A POINTER. Tuck is value-semantic; a pointer would make
# two names view one node and reintroduce exactly the aliasing this language
# exists to prevent. A Seq is a handle whose ASSIGNMENT COPIES — verified on
# all three backends, and repaired on two of them (see lowering_seqcopy) — so
# the tree stays a value all the way down.
#
# WHY HERE AND NOT BEFORE THE CHECKER. The checker should see what the AUTHOR
# wrote: `e.left` is an `Expr`, and typing it that way is what makes the arm
# bodies check. Boxing before the checker would type it `Seq[Expr]` and put
# the `[0]` in the author's hands, which is the thing being removed. So the
# checker keeps the author's view (markRecursiveSums tells checkRecursiveTypes
# to permit it) and the representation changes here, with full type
# information, exactly as `..` and `xs[i]` are resolved elsewhere.
#
# WHAT THIS IS NOT: an arena. Each edge is its own one-element handle, so a
# tree is a tree and a subtree cannot be SHARED between two parents — copying
# is copying. An arena-and-index representation would allow sharing and make a
# subtree swap O(1); it is a strictly bigger change (a synthesized storage
# wrapper, generated merge/shift helpers, and a rewritten `match`), and it can
# replace this one behind the same author-facing surface, which is the reason
# the boxing lives in a pass rather than in the emitters.
import ast, tables, sets
import resolution
import ast_query

proc seqOf(t: Type): Type =
  Type(span: t.span, kind: tkApp, args: @[t],
       base: Type(span: t.span, kind: tkNamed, name: "Seq"))

proc recursiveSumNames(m: Module): HashSet[string] =
  ## The sums markRecursiveSums flagged. Keyed by NAME because a field's type
  ## names its target rather than pointing at the declaration.
  for d in m.decls:
    if d != nil and d.kind == dkType and d.name.len > 0 and
       d.typeBody != nil and d.typeBody.kind == tkSum and d.typeBody.recursive:
      result.incl(d.name)

proc boxEdgeDecls(m: Module, names: HashSet[string]):
    Table[string, HashSet[string]] =
  ## Rewrite each recursive edge's DECLARATION to `Seq[T]`, and report which
  ## field names were rewritten, per owning type — the expression rewrites
  ## below need to recognise exactly those.
  ##
  ## A direct `tkNamed` only. A field already written `Seq[T]` needs nothing,
  ## and one holding `Array[N, T]` is a genuine sizing error TK-TY17 still
  ## reports: N inline copies is not a handle.
  for d in m.decls:
    if d == nil or d.kind != dkType or d.name notin names: continue
    if d.typeBody == nil or d.typeBody.kind != tkSum: continue
    var boxed = initHashSet[string]()
    for v in d.typeBody.variants.mitems:
      for f in v.fields.mitems:
        if f.typ != nil and f.typ.kind == tkNamed and f.typ.name in names:
          boxed.incl(f.name)
          f.typ = seqOf(f.typ)
    if boxed.len > 0: result[d.name] = boxed

proc edgeOwner(res: Resolution, e: Expr,
               edges: Table[string, HashSet[string]]): string =
  ## The recursive sum this field access reads an EDGE of, or "".
  if e == nil or e.kind != exkField or e.receiver == nil: return ""
  let t = res.typeFor(e.receiver)
  if t == nil or t.kind != tkNamed or not edges.hasKey(t.name): return ""
  if e.fieldName in edges[t.name]: t.name else: ""

proc wrapValue(res: Resolution, value: Expr, elemT: Type): Expr =
  ## `x` -> `[x]`. The list node is STAMPED: the Odin backend spells a list
  ## literal with its element type (`[dynamic]T{...}`) and reports "Missing
  ## type in compound literal" without one, and a node this pass invents has
  ## no type unless it is given one.
  result = Expr(span: value.span, kind: exkList, items: @[value])
  res.setType(result, seqOf(elemT))

proc unwrapRead(res: Resolution, e: Expr, elemT: Type) =
  ## `e.edge` -> `tuckAt(e.edge, 0)`, recorded as a RESOLVED CALL on the node
  ## rather than by rewriting the parent's slot. Every backend's field-access
  ## emitter already asks `hasCall` first — that is how `xs[i]` reaches
  ## tuckAt — so this needs no new emitter arm anywhere.
  ##
  ## The call's first argument is a FRESH copy of the access. Passing `e`
  ## itself would make the emitter find this same resolved call while emitting
  ## its own argument, and recur forever.
  let inner = Expr(span: e.span, kind: exkField,
                   receiver: e.receiver, fieldName: e.fieldName)
  res.setType(inner, seqOf(elemT))
  let zero = Expr(span: e.span, kind: exkLit, litKind: lkInt, litValue: "0")
  res.setType(zero, Type(span: e.span, kind: tkNamed, name: "int"))
  let call = Expr(span: e.span, kind: exkCall, args: @[inner, zero],
                  callee: Expr(span: e.span, kind: exkVar, name: "tuckAt"))
  res.setType(call, elemT)
  res.setCall(e, call)

proc payloadOf(e: Expr): Expr =
  ## The `{...}` of a `Type.Variant {payload}` construction, whichever way it
  ## was written: postfix on the variant (an exkField carrying dotArg), or
  ## payload-first (an exkCall whose callee is that field access).
  if e == nil: return nil
  if e.kind == exkField and e.dotArg != nil and e.dotArg.kind == exkStruct:
    return e.dotArg
  if e.kind == exkCall and e.callee != nil and e.callee.kind == exkField and
     e.args.len == 1 and e.args[0].kind == exkStruct:
    return e.args[0]
  nil

proc variantOf(e: Expr): tuple[owner, variant: string] =
  let f = if e.kind == exkCall: e.callee else: e
  if f == nil or f.kind != exkField or f.receiver == nil or
     f.receiver.kind != exkVar: return ("", "")
  (f.receiver.name, f.fieldName)

proc rewriteExpr(res: Resolution, e: Expr,
                 edges: Table[string, HashSet[string]]) =
  if e == nil: return
  for c in e.children: rewriteExpr(res, c, edges)

  # A construction's edge values are wrapped AFTER the walk above, so a read
  # sitting inside one has already been unwrapped and is wrapped as it stands.
  let payload = payloadOf(e)
  if payload != nil:
    let (owner, _) = variantOf(e)
    if edges.hasKey(owner):
      for i in 0 ..< payload.fields.len:
        if payload.fields[i].name notin edges[owner]: continue
        let elemT = Type(span: e.span, kind: tkNamed, name: owner)
        payload.fields[i].value = wrapValue(res, payload.fields[i].value, elemT)

  let owner = edgeOwner(res, e, edges)
  if owner != "" and not res.hasCall(e):
    unwrapRead(res, e, Type(span: e.span, kind: tkNamed, name: owner))

proc boxRecursiveEdges*(res: Resolution, m: Module) =
  ## Runs inside lowerModule, on the backend's own copy of the tree.
  let names = recursiveSumNames(m)
  if names.len == 0: return
  let edges = boxEdgeDecls(m, names)
  if edges.len == 0: return
  for fn in m.allFns(): rewriteExpr(res, fn.fnBody, edges)
  for d in m.decls(dkTask): rewriteExpr(res, d.taskBody, edges)
  for d in m.decls(dkExpr): rewriteExpr(res, d.expr, edges)
