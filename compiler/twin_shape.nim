# compiler/twin_shape.nim
#
# WHAT SHAPE OF FN GETS A MOVED TWIN, in ONE place.
#
# This is item 5 of thoughts/ssa-mirror-design.md, and it is the only one of
# the six that is not about the value mirror at all — it is about layering.
#
# `movedFnParam` decides which fns codegen emits a destructive twin for. The
# ANALYSES need the same answer: provenance had to know that a value read
# through a twin's parameter is the caller's buffer (then `rootedAtMoved`),
# and which calls can consume their argument (`threadsFirstArg`). They could
# not call the codegen predicate, because codegen sits downstream of every
# analysis — so `analysis_provenance` grew `maybeMovedParam`, a second
# predicate kept in step by hand. Both are gone; it calls this one.
#
# It was not kept in step. Codegen learned a second twin shape
# (`returnWrapsParam`: `Seq[int]` in, a record with a `Seq[int]` field out);
# the analysis did not; and for every fn of that shape `rootedAtMoved` could
# not fire, `afterBinding` claimed the binding had copied, and the returned
# fields read as freshly allocated. The twin then emitted `defer delete(xs)`
# over the buffer it was handing back — a use-after-free that came back 14 on
# one run and 48 on the next (PR #75).
#
# The duplication was structural rather than lazy, so the fix is structural:
# the predicate moves BELOW both. Nothing here reaches for codegen or for an
# analysis; it needs the AST, the resolution layer, and the field lookup.
import ast, resolution
import ast_query
from lowering import getFieldsForType

proc seqFieldNames*(res: Resolution, m: Module, t: Type): seq[string] =
  ## Names of `t`'s fields whose own type is `Seq[T]` — a D struct copies by
  ## value field-for-field, but a `T[]` field's copy is only the slice
  ## HEADER, so any Seq field aliases across the copy exactly the way a bare
  ## Seq assignment does. "" (never nil) when `t` is not a record at all.
  for f in getFieldsForType(res, m, t):
    if seqElem(f.typ) != nil: result.add(f.name)

proc genericBaseBody*(m: Module, t: Type): Type =
  ## A GENERIC application's declared body — `Set[T]` -> `Set`'s record.
  ## getFieldsForType answers @[] for every tkApp on purpose (most are `Seq`
  ## or a `!T` carrier, which have no declaration), so the lookup is done
  ## here rather than by widening a function the whole compiler shares.
  if t == nil or t.kind != tkApp or t.base == nil or t.base.kind != tkNamed:
    return nil
  for d in m.decls:
    if d != nil and d.kind == dkType and d.name == t.base.name:
      return d.typeBody
  nil


proc twinnableFn*(d: Decl): bool =
  ## A plain fn with a body and at least one parameter — and not `self`,
  ## which an object member already takes by pointer.
  d != nil and d.kind == dkFn and d.fnBody != nil and
    not d.isExtern and not d.isPending and not d.isDecision and
    d.fnParams.len > 0 and d.fnReturnType != nil and
    d.fnParams[0].name != "self"

proc sameTypeName*(a, b: Type): bool =
  ## Do two types name the same thing? `Bag` and `Bag`, or `Set[T]` and
  ## `Set[T]` — a GENERIC container is a tkApp, and the whole alloc tier is
  ## generic, so restricting this to tkNamed meant not one stdlib module
  ## qualified.
  if a == nil or b == nil or a.kind != b.kind: return false
  case a.kind
  of tkNamed: a.name == b.name
  of tkApp:
    a.base != nil and b.base != nil and a.base.kind == tkNamed and
      b.base.kind == tkNamed and a.base.name == b.base.name and
      a.args.len == b.args.len
  else: false

proc returnWrapsParam*(res: Resolution, m: Module, d: Decl, p: Param): bool =
  ## Does the fn hand the parameter back WRAPPED — `Seq[int]` in, a record
  ## with a `Seq[int]` field out?
  ##
  ## `sweep({ladder: Seq[int], ...}) -> Filled` is the shape, and it is the
  ## one the matching engine's remaining copies live in: the container really
  ## is threaded through, just parcelled into a result record on the way out.
  ## Requiring the return type to be the param type OUTRIGHT missed every
  ## such fn, so each copied its container defensively on every call.
  if seqElem(p.typ) == nil: return false
  for f in getFieldsForType(res, m, d.fnReturnType):
    if sameTypeName(f.typ, p.typ): return true
  false

proc threadsBackSameType*(res: Resolution, m: Module, d: Decl, p: Param): bool =
  ## Does the fn hand back the very type its first parameter came in as —
  ## either directly, or as a field of what it returns?
  sameTypeName(p.typ, d.fnReturnType) or returnWrapsParam(res, m, d, p)

proc movedCopyFields*(res: Resolution, m: Module, t: Type): seq[string] =
  ## The Seq-typed FIELDS a MOVED wrapper must copy, resolving a generic
  ## application to its declared body. ONE definition, used by the predicate
  ## and by both backends' wrappers — they disagreed once, and the wrapper
  ## then emitted `s = s.dup` for a `Set[T]`, which dmd answers with "none of
  ## the overloads of template `object.dup` are callable".
  result = seqFieldNames(res, m, t)
  if result.len == 0:
    result = seqFieldNames(res, m, genericBaseBody(m, t))

proc copyableContainer*(res: Resolution, m: Module, t: Type): bool =
  ## Can the wrapper actually spell the copy it owes — a Seq, or a record
  ## with Seq fields? `str` owns heap and is NOT this: the copy helper is
  ## Seq-shaped, and emitting it for a string param gave "Cannot assign
  ## 'rt.tuckSeqCopy(title)' of type '[dynamic]T' to 'string'".
  ##
  ## Exported because the SEND helpers ask the same question — does this
  ## payload alias the sender's storage on a backend whose container is a
  ## header? One definition, because this is exactly the decision three
  ## backends grew three copies of before. Excluding `str` is right for the
  ## send too: it is immutable in both D and Odin, so sharing its buffer is
  ## safe.
  seqElem(t) != nil or movedCopyFields(res, m, t).len > 0

proc movedFnParam*(res: Resolution, m: Module, d: Decl): string =
  ## The parameter a MOVED twin would take destructively, or "".
  ##
  ## Narrow on purpose, and narrower than "owns heap": the FIRST parameter,
  ## when the fn hands back that same type AND the wrapper can actually spell
  ## the copy it owes — a Seq, or a record with Seq fields.
  ##
  ## `str` owns heap and is NOT eligible: the wrapper's copy helper is
  ## Seq-shaped, and emitting it for a string param gave "Cannot assign
  ## 'rt.tuckSeqCopy(title)' of type '[dynamic]T' to 'string'". `self` is not
  ## eligible either — an object member already takes it by pointer, which is
  ## the opposite convention.
  ##
  ## The corpus found both. The twin is emitted for every fn that qualifies,
  ## so unlike the CALL-SITE rewrite (where an unrecognised shape merely
  ## misses the speedup) getting this predicate wrong breaks compilation.
  if not twinnableFn(d): return ""
  let p = d.fnParams[0]
  if not threadsBackSameType(res, m, d, p): return ""
  if not copyableContainer(res, m, p.typ): return ""
  p.name

proc movedName*(fnName: string): string = fnName & "_moved"

# --- does a value own storage? ------------------------------------------
# Moved here from codegen_common so a PASS can ask it (twin_calls, M3.5)
# without importing an emitter's helpers.

proc ownsHeap*(m: Module, t: Type, depth = 0): bool

proc anyOwnsHeap(m: Module, ts: seq[Type], depth: int): bool =
  for t in ts:
    if ownsHeap(m, t, depth): return true
  false

proc fieldsOwnHeap(m: Module, fields: seq[FieldDef], depth: int): bool =
  var ts: seq[Type]
  for f in fields: ts.add(f.typ)
  anyOwnsHeap(m, ts, depth)

proc namedOwnsHeap(m: Module, name: string, depth: int): bool =
  if name == "str": return true
  for d in m.decls:
    if d != nil and d.kind == dkType and d.name == name:
      return ownsHeap(m, d.typeBody, depth)
  false

proc sumOwnsHeap(m: Module, t: Type, depth: int): bool =
  for v in t.variants:
    if fieldsOwnHeap(m, v.fields, depth): return true
  false

proc ownsHeap*(m: Module, t: Type, depth = 0): bool =
  ## Does a value of this type own storage that copying would duplicate?
  ##
  ## Only these are worth moving. A record of two ints copies in a register
  ## pair, so marking it movable buys nothing and only adds noise to the
  ## emitted output — every golden in the corpus moved for it before this
  ## guard went in.
  if t == nil or depth > 4: return false
  case t.kind
  of tkNamed: namedOwnsHeap(m, t.name, depth + 1)
  of tkApp:
    # Seq[T] owns a buffer outright; a `!T`/`?T` carrier, or an Array, owns
    # whatever its arguments do. A GENERIC USER TYPE — `Box[T]`, `Set[T]`,
    # `Table[K, V]` — owns whatever its DECLARED BODY does: without this the
    # whole alloc tier read as owning nothing, and the container-threading
    # benchmark was linear on Odin and D (which look through the twin's own
    # predicate) and quadratic on Nim, which consults this one.
    if t.base != nil and t.base.kind == tkNamed and t.base.name == "Seq": true
    elif ownsHeap(m, genericBaseBody(m, t), depth + 1): true
    else: anyOwnsHeap(m, t.args, depth + 1)
  of tkRecord: fieldsOwnHeap(m, t.fields, depth + 1)
  of tkSum: sumOwnsHeap(m, t, depth + 1)
  else: false

