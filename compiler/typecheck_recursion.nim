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
# MUTUAL RECURSION WORKS. `type A` holding a `Seq[B]` that holds a `Seq[A]`
# builds and runs on all three backends, in both the record and the sum shape,
# whichever order the two are declared in — verified 2026-09-08 by building and
# running one of each. This comment used to say the opposite (an `undeclared
# identifier: 'tuck_B'` decl-ordering bug); whatever fixed it, the claim
# outlived it. `tests/suites/recursive_types.nim` pins both shapes now.
#
# Still rejected, correctly: a cycle with NO handle container in it. That is
# what this check is for, and it is a sizing question, not an ordering one.
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

iterator reachedTypeNames(t: Type, throughHandles: bool): string =
  ## The type names this field reaches.
  ##
  ## `throughHandles = false` — the names stored INLINE, whose size counts
  ## toward its own. Stops at a handle container, which is what makes
  ## `Seq[Expr]` finite while `Array[4, Expr]` is not. That is the SIZE
  ## question, and TK-TY17's.
  ##
  ## `throughHandles = true` — every name reached at all. That is the SHAPE
  ## question: `Seq[Expr]` inside `Expr` still makes a tree, and a pass that
  ## has to REPRESENT one needs to know. See markRecursiveSums.
  var stack = @[t]
  while stack.len > 0:
    let cur = stack.pop()
    if cur == nil: continue
    case cur.kind
    of tkNamed: yield cur.name
    of tkApp:
      if not throughHandles and cur.base != nil and cur.base.kind == tkNamed and
         cur.base.name in HandleContainers:
        discard              # behind a handle: contributes no inline size
      else:
        for a in cur.args: stack.add(a)
    of tkTuple:
      for e in cur.elems: stack.add(e)
    else: discard
      # tkFunc is a code pointer, tkUnion/tkEffect/tkRename/tkRecord/tkSum
      # cannot name a declared type inline from a field position here.

proc findCycle(decls: Table[string, Decl], start: string,
               throughHandles = false,
               boxed = initHashSet[string]()):
    tuple[found: bool, field: string, path: seq[string]] =
  ## Walk the inline-containment graph from `start`, looking for the way back
  ## to it. Reports the FIELD that closes the cycle, which is the one line the
  ## author has to change.
  var seen = initHashSet[string]()
  var stack: seq[(string, string, seq[string])] = @[(start, "", @[start])]
  while stack.len > 0:
    let (name, viaField, path) = stack.pop()
    if not decls.hasKey(name): continue
    # A field of a recursive sum whose type IS one of those sums becomes a
    # handle in lowering_recursive, so it breaks the cycle just as a hand-
    # written `Seq[T]` does. `Array[N, T]` does NOT: the walk reaches T
    # through the application's argument rather than as the field's own type,
    # so it is not boxable and stays a sizing error.
    let ownerBoxes = name in boxed
    for f in fieldsOf(decls[name]):
      if ownerBoxes and f.typ != nil and f.typ.kind == tkNamed and
         f.typ.name in boxed: continue
      for inner in reachedTypeNames(f.typ, throughHandles):
        let closing = if path.len == 1: f.name else: viaField
        if inner == start:
          return (true, closing, path & inner)
        if inner in seen: continue
        seen.incl(inner)
        stack.add((inner, closing, path & inner))
  (false, "", @[])

proc markRecursiveSums*(decls: Table[string, Decl], m: Module) =
  ## Set `recursive` on every sum type that reaches itself, by any route.
  ##
  ## Runs BEFORE checkRecursiveTypes and answers a different question: not
  ## "does this have a finite size?" but "is this a tree?". A sum holding
  ## `Seq[Self]` is legal today and still recursive; one holding a bare `Self`
  ## is recursive AND currently rejected by the check below.
  ##
  ## Sums only. A record reaching itself is a sizing error with no shape to
  ## represent — there is no variant to end the chain, so every value would be
  ## infinite. That stays TK-TY17.
  for d in m.decls:
    if d == nil or d.kind != dkType or d.name.len == 0: continue
    if d.typeBody == nil or d.typeBody.kind != tkSum: continue
    d.typeBody.recursive = findCycle(decls, d.name, throughHandles = true).found

proc infiniteTypeMessage(d: Decl, field: string, path: seq[string]): string =
  ## The two ways to arrive at TK-TY17 want opposite advice, and giving a sum
  ## the record's advice would be actively wrong: a recursive sum's edges are
  ## given handles automatically, so `kids: Tree` already works and only the
  ## wrapping is the problem.
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
  let fix =
    if d.kind == dkType and d.typeBody != nil and d.typeBody.kind == tkSum:
      "A recursive sum's edges are given handles for you, so `" & field &
      ": " & d.name & "` on its own is fine — it is the wrapping that is " &
      "not. `Array[N, " & d.name & "]` stores N values INLINE, so it " &
      "propagates the size exactly as a plain field does. Fix: drop the " &
      "Array (`" & field & ": " & d.name & "`) for one child, or use " &
      "`Seq[" & d.name & "]` for many."
    else:
      "A record has no variant to end the chain, so every value really " &
      "would be infinite. Fix: make it a SUM type — a variant that does " &
      "not recur is the base case, and a recursive sum's edges are given " &
      "handles for you — or hold the recursive part as `Seq[" & d.name &
      "]` by hand. (`Array[N, " & d.name & "]` does NOT work either: it " &
      "stores N inline.)"
  "'" & d.name & "' contains itself: " & how & ", so its size would be " &
    "infinite. Tuck has no references, so a field IS its value. " & fix

proc checkRecursiveTypes*(decls: Table[string, Decl], m: Module) =
  ## Reject a type that contains itself by value, before any backend sees it.
  ##
  ## A recursive SUM is no longer one of them. Its variants end the chain — a
  ## value is one variant, and the ones that do not recur are the base cases —
  ## so it is finite the moment its edges are handles, and lowering_recursive
  ## makes them handles. That is the `Seq[Expr]` this check used to demand the
  ## author write by hand.
  ##
  ## A RECORD still fails: no variants, so nothing ends the chain and every
  ## value really would be infinite. So does an edge this pass cannot box,
  ## `Array[N, Self]` above all — N inline copies is not a handle.
  var boxable = initHashSet[string]()
  for d in m.decls:
    if d != nil and d.kind == dkType and d.typeBody != nil and
       d.typeBody.kind == tkSum and d.typeBody.recursive:
      boxable.incl(d.name)
  for d in m.decls:
    if d == nil or d.kind notin {dkType, dkObject}: continue
    if d.name.len == 0: continue
    let (found, field, path) = findCycle(decls, d.name, boxed = boxable)
    if not found: continue
    # A one-hop cycle and a multi-hop one need different sentences. Saying
    # "field 'back' stores a value of 'Inner'" when it actually stores an
    # 'Outer' sends the author to the wrong line, so the indirect case shows
    # the route instead.
    fail(dcTyInfiniteType, infiniteTypeMessage(d, field, path), d.span)
