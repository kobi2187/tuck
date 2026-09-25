## Generic actors, expanded to one singleton per instantiation (issue #18).
##
## An actor is a compile-time SINGLETON, so `actor Box[T]` has to say which
## instantiation the singleton is of. The ruling (2026-09-17) is that it does
## not: `Box[int]` and `Box[str]` are TWO actors, each with its own mailbox,
## drain coroutine, singleton and registration — monomorphized the way a
## generic type is, not forwarded as a type parameter the way `type Pair[T]`
## is.
##
## Forwarding was the alternative and it is worse here. Tuck does hand `[T]`
## straight to the target language for plain types (`type Pair[T]` emits
## `tuck_Pair*[T]`), but an actor is more than a type: the singleton, the
## mailbox, the drain and the registerActor hook each need a CONCRETE element
## type, so every one of them would have to be per-instantiation anyway. Once
## that is true, cloning the declaration is the smaller change — and it has the
## property that matters: this pass runs BEFORE typechecking, so every later
## stage sees a plain, non-generic actor and **no backend needs to know generic
## actors exist at all**.
##
## What it does, in one walk:
##   * find each use — `Box[int] send put {...}`, `Box[int].last` — and record
##     the instantiation,
##   * rewrite the use to name the expanded actor (`Box_int`), so nothing
##     downstream meets a bracket where an actor name belongs,
##   * clone the declaration once per distinct instantiation with the type
##     parameter substituted, and drop the generic original.
##
## An actor with type parameters and no instantiation is left alone, and the
## checker refuses it (TK-TY28) — silence there would be the old bug back, in
## which the parameter was dropped and `last: T` emitted as an undeclared type.

import std/[tables, algorithm, strutils, sets]
import ast
import ast_ops

proc substType*(t: Type, subs: Table[string, Type]): Type

proc substAll(ts: seq[Type], subs: Table[string, Type]): seq[Type] =
  for t in ts: result.add(substType(t, subs))

proc substFields(fs: seq[FieldDef], subs: Table[string, Type]): seq[FieldDef] =
  for f in fs:
    result.add(FieldDef(name: f.name, typ: substType(f.typ, subs),
                        attrs: f.attrs, span: f.span))

proc substVariants(vs: seq[VariantDef],
                   subs: Table[string, Type]): seq[VariantDef] =
  ## A sum's payloads are FieldDefs hanging off each variant.
  for v in vs:
    var nv = v
    nv.fields = substFields(v.fields, subs)
    result.add(nv)

proc substType*(t: Type, subs: Table[string, Type]): Type =
  ## `t` with every type parameter in `subs` replaced. Returns a NEW type
  ## rather than mutating: a parameter may stand for a compound
  ## (`Box[Seq[int]]`), and a `tkNamed` node cannot become a `tkApp` in place —
  ## Nim object variants do not change kind.
  ##
  ## The three seq-mapping helpers above exist so each arm below is a single
  ## constructor call: an arm that also loops is not a lookup-table entry, and
  ## nine of them turned this into the tree's worst proc for its size.
  if t == nil: return nil
  case t.kind
  of tkNamed:
    if t.name in subs: subs[t.name] else: t
  of tkTuple:
    Type(span: t.span, kind: tkTuple, attrs: t.attrs,
         elems: substAll(t.elems, subs))
  of tkApp:
    Type(span: t.span, kind: tkApp, attrs: t.attrs,
         base: substType(t.base, subs), args: substAll(t.args, subs))
  of tkFunc:
    Type(span: t.span, kind: tkFunc, attrs: t.attrs,
         params: substAll(t.params, subs), result: substType(t.result, subs),
         paramNames: t.paramNames)
  of tkRecord:
    Type(span: t.span, kind: tkRecord, attrs: t.attrs,
         fields: substFields(t.fields, subs))
  of tkSum:
    Type(span: t.span, kind: tkSum, attrs: t.attrs,
         variants: substVariants(t.variants, subs),
         transitions: t.transitions, recursive: t.recursive)
  of tkUnion:
    Type(span: t.span, kind: tkUnion, attrs: t.attrs,
         members: substAll(t.members, subs))
  of tkEffect:
    Type(span: t.span, kind: tkEffect, attrs: t.attrs,
         inner: substType(t.inner, subs), effects: t.effects)
  of tkRename:
    Type(span: t.span, kind: tkRename, attrs: t.attrs,
         underlying: substType(t.underlying, subs), renames: t.renames)

proc substExprTypes(e: Expr, subs: Table[string, Type]) =
  ## Type annotations written INSIDE a handler body — `var acc: T = ...` and
  ## the like. Mutates the fields that hold a Type, since those are assignable
  ## even though the Type node itself is not.
  if e == nil: return
  if e.kind == exkAssign and e.declType != nil:
    e.declType = substType(e.declType, subs)
  for c in e.children: substExprTypes(c, subs)

proc substDecl(d: Decl, subs: Table[string, Type]) =
  ## Substitute through one cloned handler: its parameters, its return type and
  ## any annotation in its body.
  if d == nil: return
  if d.kind == dkFn:
    for i in 0 ..< d.fnParams.len:
      d.fnParams[i].typ = substType(d.fnParams[i].typ, subs)
    d.fnReturnType = substType(d.fnReturnType, subs)
    substExprTypes(d.fnBody, subs)
  for e in d.ownExprs(): substExprTypes(e, subs)

proc expandOne(orig: Decl, args: seq[Type]): Decl =
  ## One instantiation of a generic actor: a deep copy with the parameters
  ## replaced and a concrete name. deepCopy because every later stage mutates
  ## the tree it is handed, and two instantiations must not share a node.
  var subs = initTable[string, Type]()
  for i, p in orig.actorGenerics:
    subs[p] = if i < args.len: args[i] else: nil
  result = deepCopy(orig)
  # deepCopy copies the IDS too, and ids key the semantic layer: every
  # instantiation shared the template's, so checking `Box[str]` wrote its
  # types over `Box[int]`'s. Cleared here; parseSource's fillIds numbers the
  # copy afresh (pipeline.assertTreeIds("load") found this).
  clearIds(result)
  result.name = instName(orig.name, args)
  result.actorGenerics = @[]
  for i in 0 ..< result.actorFields.len:
    result.actorFields[i].typ = substType(result.actorFields[i].typ, subs)
  for h in result.handlers: substDecl(h, subs)

proc instantiatedActor(e: Expr, generic: Table[string, Decl]): bool =
  ## Is `e` the `Box[int]` half of a field access on a generic actor? Its own
  ## proc because the test is five conjuncts deep — exkBracket carries the
  ## instantiation, and only the RECEIVER says whether the brackets mean a type
  ## application or an index (ast.nim).
  e != nil and e.kind == exkBracket and e.brReceiver != nil and
    e.brReceiver.kind == exkVar and e.brReceiver.name in generic

proc bracketArgs(e: Expr): seq[Type] =
  ## The instantiation an `exkBracket` carries, as types.
  for a in e.brArgs: result.add(typeOfTypeExpr(a))

proc note(found: var Table[string, seq[Type]], n: string, args: seq[Type]) =
  if n notin found: found[n] = args

proc collectAndRewrite(e: Expr, generic: Table[string, Decl],
                       found: var Table[string, seq[Type]]) =
  ## One walk doing both halves: note which instantiations exist, and point
  ## each use at the expanded name. Rewriting happens through the PARENT's
  ## field (`e.receiver`), never by changing a node's kind — a `ref object`
  ## variant cannot become another kind in place.
  if e == nil: return
  if e.kind == exkSend and e.sendActorArgs.len > 0 and e.sendActor in generic:
    let n = instName(e.sendActor, e.sendActorArgs)
    found.note(n, e.sendActorArgs)
    e.sendActor = n
    e.sendActorArgs = @[]
  elif e.kind == exkField and instantiatedActor(e.receiver, generic):
    let args = bracketArgs(e.receiver)
    let n = instName(e.receiver.brReceiver.name, args)
    found.note(n, args)
    e.receiver = Expr(span: e.receiver.span, kind: exkVar, name: n)
  for c in e.children: collectAndRewrite(c, generic, found)

proc expansions(generic: Table[string, Decl],
                found: Table[string, seq[Type]]): seq[Decl] =
  ## One expanded actor per instantiation, in a DETERMINISTIC order: a table
  ## iterates arbitrarily, so the emitted file's declaration order would
  ## otherwise vary between runs of the same compiler over the same source —
  ## which the golden files would report as a spurious diff.
  var names: seq[string]
  for n in found.keys: names.add(n)
  sort(names)
  for n in names:
    for base, orig in generic:
      if n == base or n.startsWith(base & "_"):
        result.add(expandOne(orig, found[n]))
        break

proc exportedGenerics(m: Module, generic: Table[string, Decl]): HashSet[string] =
  ## The generic actors this module exports as TEMPLATES — `public: Box[T]`.
  ## An exporting module need not instantiate its own actor, and an importer
  ## instantiates at its own call site, so such a declaration has to survive
  ## this pass instead of being expanded away.
  for name in generic.keys:
    if exportedAsTemplate(m, name): result.incl(name)

proc keptDecls(m: Module, generic: Table[string, Decl],
               exported: HashSet[string]): seq[Decl] =
  ## Everything except the generic originals that this module fully consumed.
  ## A template it EXPORTS stays: an importer has to be able to instantiate it,
  ## and dropping it would leave `public: Box[T]` naming nothing.
  ##
  ## An unexported template is dropped, because it is a template and not a
  ## declaration — leaving one would reach the checker as an actor whose fields
  ## name a type parameter, which is the TK-TY28 case.
  for d in m.decls:
    if d != nil and d.kind == dkActor and d.name in generic and
       d.name notin exported: continue
    result.add(d)

proc expandGenericActors*(m: var Module) =
  ## Replace each generic actor with one expanded actor per instantiation used.
  ## Runs right after parsing, so typechecking and every backend below it see
  ## nothing but ordinary actors.
  var generic = initTable[string, Decl]()
  for d in m.decls:
    if d != nil and d.kind == dkActor and d.actorGenerics.len > 0:
      generic[d.name] = d
  if generic.len == 0: return
  let exported = exportedGenerics(m, generic)

  var found = initTable[string, seq[Type]]()
  for d in m.decls:
    for e in d.ownExprs(): collectAndRewrite(e, generic, found)
    for sub in d.childDecls():
      for e in sub.ownExprs(): collectAndRewrite(e, generic, found)
  if found.len == 0 and exported.len == 0: return
  m.decls = keptDecls(m, generic, exported) & expansions(generic, found)
