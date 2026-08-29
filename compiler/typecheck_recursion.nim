# compiler/typecheck_recursion.nim
#
# A type may not contain itself by value.
#
# `type Expr: | Add({lhs: Expr, rhs: Expr})` has no finite size: every Expr
# holds two more. Tuck has no references, so a field IS its value and the
# cycle is real rather than a matter of representation.
#
# The compiler already refused this — but in the BACKEND, and in the backend's
# words: `tuck ch` passed, then Nim reported `illegal recursion in type
# 'tuck_Expr'`, naming a mangled type in a generated file the author does not
# have open. This detects it at check time and says it in Tuck's terms, naming
# the field that closes the cycle and the way out.
#
# THE WAY OUT IS `Seq`. A Seq is a growable handle, so a variant holding
# `Seq[Expr]` is finite and builds today — that is how the corpus writes trees
# (JSON, ASTs). `Array[N, T]` is INLINE storage and does NOT break the cycle:
# it is N values, not a handle. Both were verified by building.
#
# NOT COVERED: mutual recursion (`type A` holding a `B` that holds an `A`).
# It fails differently — the emitter writes the two declarations in source
# order and Nim reports `undeclared identifier: 'tuck_B'`, with or without a
# Seq in the cycle. That is a declaration-ORDERING bug in codegen, not a
# sizing one, and wants its own fix.
#
# Why this lifts out of typecheck.nim, like its siblings: every question is
# about a DECLARED type and is answered from the declaration table alone.
# Nothing synthesizes an expression type.
import ast, tables, sets, strutils
import typecheck_util

const HandleContainers = ["Seq"]
  ## Containers that hold their elements BEHIND a handle, so a type reaching
  ## itself through one is still finite.
  ##
  ## `Array` is deliberately absent: `Array[N, T]` stores N elements inline,
  ## so it propagates containment exactly as a plain field does. `Buf` holds
  ## bytes and can never name a user type.

proc fieldsOf(d: Decl): seq[FieldDef] =
  ## Every field a declaration stores, records and sum variants alike — the
  ## two shapes that can close a cycle. `declaredFields` in ast_query returns
  ## nothing for a sum body, which is the case this check exists for.
  if d == nil: return @[]
  case d.kind
  of dkType:
    if d.typeBody == nil: return @[]
    case d.typeBody.kind
    of tkRecord: d.typeBody.fields
    of tkSum:
      for v in d.typeBody.variants:
        for f in v.fields: result.add(f)
      result
    else: @[]
  of dkObject: d.objFields
  else: @[]

iterator inlineTypeNames(t: Type): string =
  ## The type names this field stores INLINE — the ones whose size counts
  ## toward its own. Descends through the shapes that store their argument by
  ## value and stops at a handle container, which is what makes `Seq[Expr]`
  ## finite while `Array[4, Expr]` is not.
  var stack = @[t]
  while stack.len > 0:
    let cur = stack.pop()
    if cur == nil: continue
    case cur.kind
    of tkNamed: yield cur.name
    of tkApp:
      if cur.base != nil and cur.base.kind == tkNamed and
         cur.base.name in HandleContainers:
        discard              # behind a handle: contributes no inline size
      else:
        for a in cur.args: stack.add(a)
    of tkTuple:
      for e in cur.elems: stack.add(e)
    else: discard
      # tkFunc is a code pointer, tkUnion/tkEffect/tkRename/tkRecord/tkSum
      # cannot name a declared type inline from a field position here.

proc findCycle(decls: Table[string, Decl], start: string):
    tuple[found: bool, field: string, path: seq[string]] =
  ## Walk the inline-containment graph from `start`, looking for the way back
  ## to it. Reports the FIELD that closes the cycle, which is the one line the
  ## author has to change.
  var seen = initHashSet[string]()
  var stack: seq[(string, string, seq[string])] = @[(start, "", @[start])]
  while stack.len > 0:
    let (name, viaField, path) = stack.pop()
    if not decls.hasKey(name): continue
    for f in fieldsOf(decls[name]):
      for inner in inlineTypeNames(f.typ):
        let closing = if path.len == 1: f.name else: viaField
        if inner == start:
          return (true, closing, path & inner)
        if inner in seen: continue
        seen.incl(inner)
        stack.add((inner, closing, path & inner))
  (false, "", @[])

proc checkRecursiveTypes*(decls: Table[string, Decl], m: Module) =
  ## Reject a type that contains itself by value, before any backend sees it.
  for d in m.decls:
    if d == nil or d.kind notin {dkType, dkObject}: continue
    if d.name.len == 0: continue
    let (found, field, path) = findCycle(decls, d.name)
    if not found: continue
    # A one-hop cycle and a multi-hop one need different sentences. Saying
    # "field 'back' stores a value of 'Inner'" when it actually stores an
    # 'Outer' sends the author to the wrong line, so the indirect case shows
    # the route instead.
    let how =
      if path.len <= 2:
        "field '" & field & "' stores a value of '" & d.name & "'"
      else:
        "it is reached again through " & path.join(" -> ") &
        ", starting at field '" & field & "'"
    fail(dcTyInfiniteType,
         "'" & d.name & "' contains itself: " & how & ", so its size would " &
         "be infinite. Tuck has no references, so a field IS its value. " &
         "Fix: hold the recursive part as `Seq[" & d.name & "]`, a growable " &
         "handle that stays finite because an empty Seq ends the chain. " &
         "(`Array[N, " & d.name & "]` does NOT work: it stores N inline.)",
         d.span)
