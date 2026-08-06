# compiler/typecheck_pointers.nim
#
# Pointers are legal only at the extern boundary.
#
# A pointer may be produced by an extern and consumed by another extern or a
# converter (`toStr`), but it may never be STORED — so no pointer outlives the
# expression that obtained it and a dangling reference is unreachable from safe
# code. examples/34-ffi-cstring.tuck already stated this as a comment; this is
# the rule behind it.
#
# Pointer-kind is `cstring` plus any FIELDLESS extern type — an opaque C handle
# (`typedef struct Foo Foo;`) whose size is unknown, so it can only ever be held
# as a pointer (codegen emits `ptr FooObj` / `rawptr`).
#
# Why this lifts out of typecheck.nim: every question here is about a DECLARED
# type, answered from the declaration table alone. Nothing synthesizes an
# expression type, so nothing calls back into the synth core — the same rule
# typecheck_flow.nim follows. It takes the type-declaration table rather than
# the whole TypeChecker, which is all it ever read.
import ast, tables
import typecheck_util

type
  TypeDecls* = Table[string, Decl]
    ## Every declared type by name — what decides whether a name is an opaque
    ## C handle.

const BuiltinPointerNames = ["cstring", "Buf"]
  ## The builtin FFI pointers: cstring (char*) and Buf (uint8_t*).

proc isPointerKind*(decls: TypeDecls, t: Type): bool =
  ## Is this type held as a raw pointer?
  if t == nil or t.kind != tkNamed: return false
  if t.name in BuiltinPointerNames: return true
  if not decls.hasKey(t.name): return false
  let d = decls[t.name]
  # typeExternHeader/typeBody exist only on dkType — the table also holds
  # dkObject (objects are constructible by name too), and touching a
  # dkType-only field on one is a FieldDefect, not a false.
  if d.kind != dkType: return false
  # `fields` only exists on a tkRecord body — a sum/named/alias extern type is
  # not an opaque handle, and reading .fields on those is a FieldDefect.
  d.typeExternHeader != "" and d.typeBody != nil and
    d.typeBody.kind == tkRecord and d.typeBody.fields.len == 0

proc failIfPointer*(decls: TypeDecls, t: Type, where: string, sp: Span) =
  ## Reject a pointer-kind type anywhere it would escape the extern boundary.
  ## Recurses so a pointer buried in `Seq[Buf]` or a record field is caught too.
  if t == nil: return
  if decls.isPointerKind(t):
    fail("Type Error: " & typeName(t) & " is a pointer — it may only appear " &
         "in an extern signature, not " & where & " (cross into safe Tuck " &
         "with a converter such as toStr)", sp)
  case t.kind
  of tkApp:
    failIfPointer(decls, t.base, where, sp)
    for a in t.args: failIfPointer(decls, a, where, sp)
  of tkTuple:
    for e in t.elems: failIfPointer(decls, e, where, sp)
  of tkFunc:
    for p in t.params: failIfPointer(decls, p, where, sp)
    failIfPointer(decls, t.result, where, sp)
  of tkRecord:
    for f in t.fields: failIfPointer(decls, f.typ, where, sp)
  of tkEffect: failIfPointer(decls, t.inner, where, sp)
  of tkRename: failIfPointer(decls, t.underlying, where, sp)
  else: discard

proc failIfPointerReturn*(decls: TypeDecls, t: Type, fnName: string, sp: Span) =
  ## An extern may TAKE a pointer; it may not hand one back. Recurses, so
  ## `!cstring` and `{p: Buf}` are caught as well as a bare return.
  if t == nil: return
  if decls.isPointerKind(t):
    fail("Type Error: extern '" & fnName & "' returns " & typeName(t) &
         " — a pointer may be passed INTO C but never returned out of it " &
         "(wrap it: have the binding return str or Seq[u8], and copy in the " &
         "implementation)", sp)
  case t.kind
  of tkApp:
    failIfPointerReturn(decls, t.base, fnName, sp)
    for a in t.args: failIfPointerReturn(decls, a, fnName, sp)
  of tkTuple:
    for e in t.elems: failIfPointerReturn(decls, e, fnName, sp)
  of tkRecord:
    for f in t.fields: failIfPointerReturn(decls, f.typ, fnName, sp)
  of tkEffect: failIfPointerReturn(decls, t.inner, fnName, sp)
  of tkRename: failIfPointerReturn(decls, t.underlying, fnName, sp)
  else: discard

proc checkPointerContainment(decls: TypeDecls, d: Decl, inExtern = false)

proc checkParamPointers(decls: TypeDecls, params: seq[Param], ret: Type,
                        what: string, sp: Span) =
  ## No pointer may appear in an ordinary signature, either side.
  for p in params:
    failIfPointer(decls, p.typ, "a " & what & " parameter", p.span)
  failIfPointer(decls, ret, "a " & what & " return type", sp)

proc checkFnPointers(decls: TypeDecls, d: Decl, inExtern: bool) =
  ## Pointers cross INTO C, never back out. A param is Tuck handing C something
  ## it already holds; a RETURN would put a raw pointer in a Tuck variable, and
  ## from there its lifetime is C's business and unknowable here. A C fn
  ## returning char*/uint8_t* gets a shim in the Nim layer that copies into
  ## str/Seq[u8], so the Tuck-visible signature is a safe type and forgetting
  ## the conversion is impossible rather than merely discouraged.
  if inExtern:
    failIfPointerReturn(decls, d.fnReturnType, d.name, d.span)
  else:
    checkParamPointers(decls, d.fnParams, d.fnReturnType, "fn", d.span)

proc checkTypePointers(decls: TypeDecls, d: Decl, inExtern: bool) =
  ## An extern type declaring an opaque handle is the declaration itself, not
  ## a use of one — only its MEMBERS are ordinary code.
  if not inExtern and d.typeBody != nil and d.typeBody.kind == tkRecord:
    for f in d.typeBody.fields:
      failIfPointer(decls, f.typ, "a type field", f.span)
  for m in d.typeMembers: checkPointerContainment(decls, m, inExtern)

proc checkMemberPointers(decls: TypeDecls, fields: seq[FieldDef],
                         members: seq[Decl], what: string, inExtern: bool) =
  ## A declaration that owns both fields and members: neither may hold a pointer.
  for f in fields:
    failIfPointer(decls, f.typ, what, f.span)
  for m in members: checkPointerContainment(decls, m, inExtern)

proc checkFnSigPointers(decls: TypeDecls, d: Decl, inExtern: bool) =
  ## A C callback signature is part of the boundary and may hold pointers.
  if inExtern: return
  checkParamPointers(decls, d.sigParams, d.sigReturn, "fnsig", d.span)

proc checkRegistryPointers(decls: TypeDecls, d: Decl) =
  for v in d.variants:
    for f in v.fields:
      failIfPointer(decls, f.typ, "a registry field", f.span)

proc checkPointerContainment(decls: TypeDecls, d: Decl, inExtern = false) =
  ## Mirrors resolveDeclTypeRefs' walk. `inExtern` is threaded from the PARENT
  ## decl rather than inferred here: dkMixin, dkExtern and dkPending share an
  ## arm and both recurse through mixinMembers, so keying on the arm would let a
  ## plain `mixin` hold a cstring — a real leak path, not a hypothetical one.
  if d == nil: return
  case d.kind
  of dkFn: checkFnPointers(decls, d, inExtern)
  of dkTask:
    checkParamPointers(decls, d.taskParams, d.taskReturnType, "task", d.span)
  of dkType: checkTypePointers(decls, d, inExtern)
  of dkObject: checkMemberPointers(decls, d.objFields, d.objMembers,
                                   "an object field", inExtern)
  of dkActor: checkMemberPointers(decls, d.actorFields, d.handlers,
                                  "an actor field", inExtern)
  of dkExtern:
    for m in d.mixinMembers: checkPointerContainment(decls, m, true)
  of dkMixin, dkPending:
    for m in d.mixinMembers: checkPointerContainment(decls, m, inExtern)
  of dkInterface:
    for m in d.ifaceMembers: checkPointerContainment(decls, m, inExtern)
  of dkPool: failIfPointer(decls, d.poolElem, "a pool element type", d.span)
  of dkFnSig: checkFnSigPointers(decls, d, inExtern)
  of dkRegistry: checkRegistryPointers(decls, d)
  else: discard

proc checkPointers*(decls: TypeDecls, m: Module) =
  ## Run after resolveTypeNames, when the table knows every extern type.
  for d in m.decls: checkPointerContainment(decls, d)
