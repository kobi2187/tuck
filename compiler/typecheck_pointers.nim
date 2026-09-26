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
import ast, tables, sets
import typecheck_util
import diagnostics
import resolution
import ast_ops

type
  TypeDecls* = Table[string, Decl]
    ## Every declared type by name — what decides whether a name is an opaque
    ## C handle.

const BuiltinPointerNames = ["cstring", "Buf"]
  ## The builtin FFI pointers: cstring (char*) and Buf (uint8_t*).

proc isPointerKind(decls: TypeDecls, t: Type): bool =
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

proc failIfPointer(decls: TypeDecls, t: Type, where: string, sp: Span) =
  ## Reject a pointer-kind type anywhere it would escape the extern boundary.
  ## Recurses so a pointer buried in `Seq[Buf]` or a record field is caught too.
  if t == nil: return
  if decls.isPointerKind(t):
    fail(dcTyPointerStored, "Type Error: " & typeName(t) & " is a pointer — it may only appear " &
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
  # Listed rather than left to `else`, because this is a SAFETY check and a
  # kind it forgets to descend into is a pointer it lets through. tkNamed is
  # the base case (isPointerKind above already answered for it); tkSum's
  # variant payloads are field lists checked where the variant is declared;
  # tkUnion is flattened to a record before any backend sees it.
  of tkNamed, tkSum, tkUnion: discard

proc isMemoryPointer(t: Type): bool =
  ## A pointer INTO MEMORY — `cstring` or `Buf`. Distinct from an opaque
  ## handle, which is also held as a pointer but addresses nothing readable.
  t.kind == tkNamed and t.name in BuiltinPointerNames

proc memoryPointerReturnMsg(fnName, tName: string): string =
  "Type Error: extern '" & fnName & "' returns " & tName &
  " — a pointer INTO MEMORY may be passed into C but never returned out of " &
  "it, because its lifetime is C's and unknowable here (wrap it: have the " &
  "binding return str or Seq[u8], and copy in the implementation). An opaque " &
  "handle — a fieldless extern type — is exempt: there is nothing to " &
  "dereference."

proc failIfPointerReturn(decls: TypeDecls, t: Type, fnName: string, sp: Span) =
  ## An extern may TAKE a pointer into memory; it may not hand one back.
  ## Recurses, so `!cstring` and `{p: Buf}` are caught as well as a bare return.
  ##
  ## THE RULE IS ABOUT MEMORY, NOT ABOUT POINTERS. A returned `cstring`/`Buf`
  ## lands in a Tuck variable pointing at bytes whose lifetime is C's business
  ## and unknowable to the checker — that is the hazard.
  ##
  ## An OPAQUE HANDLE is not that. `typedef struct Counter Counter;` declares a
  ## type with no definition, so there is nothing to dereference and no memory
  ## Tuck can read: it is a token the library hands out and takes back, and
  ## every real C API works this way (FILE*, sqlite3*, ImGuiContext*). Barring
  ## it left `counterNew` unwritable in any form, since a handle has no
  ## by-value equivalent to copy out — the wrap this message suggests does not
  ## exist for one. See examples/37-ffi-handle.
  if t == nil: return
  if isMemoryPointer(t):
    fail(dcTyPointerReturn, memoryPointerReturnMsg(fnName, typeName(t)), sp)
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
  of tkFunc:
    # Was missing while failIfPointer above descended into it — a returned
    # callback whose own signature passes memory would have gone unchecked.
    for p in t.params: failIfPointerReturn(decls, p, fnName, sp)
    failIfPointerReturn(decls, t.result, fnName, sp)
  # Listed, not `else`: a kind this forgets is a pointer it returns. See the
  # note on failIfPointer for why each of these has nothing to descend into.
  of tkNamed, tkSum, tkUnion: discard

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
  of dkGroup:
    for m in d.groupMembers: checkPointerContainment(decls, m, inExtern)
  of dkPool: failIfPointer(decls, d.poolElem, "a pool element type", d.span)
  of dkFnSig: checkFnSigPointers(decls, d, inExtern)
  of dkRegistry: checkRegistryPointers(decls, d)
  else: discard

proc checkPointers*(decls: TypeDecls, m: Module) =
  ## Run after resolveTypeNames, when the table knows every extern type.
  for d in m.decls: checkPointerContainment(decls, d)


# --- a pool cell's address: straight to an extern (#45) ----------------------
#
# `Pool.addr {h}` is the one place Tuck code itself PRODUCES a pointer: a
# cell's bytes, for a DMA controller or an ISR to fill. The declaration rule
# above keeps `Buf` out of every signature but an extern's; this is the other
# half, about VALUES. The address is bound by `let` — TK-PA13 forbids nesting
# the op inside a payload — and every use of that local must be an argument
# of an extern call. Returned, stored in a record, sent, reassigned or handed
# to any other fn, it would outlive the boundary it exists to cross
# (TK-TY08). It reads the checker's stamps, so it runs after checkDecl.

type AddrScan = object
  res: Resolution
  externs: HashSet[string]  ## every extern fn by the name the source uses
  bound: HashSet[string]    ## locals holding a cell's address

proc isCellAddr(res: Resolution, n: Expr): bool =
  n != nil and n.kind == exkField and res.hasCall(n) and
    res.call(n).kind == exkPoolOp and res.call(n).poolOp == poAddr

proc isExternCall(s: AddrScan, c: Expr): bool =
  c != nil and c.kind == exkCall and c.callee != nil and
    c.callee.kind == exkVar and c.callee.name in s.externs

proc isExternArg(s: AddrScan, parent, grand: Expr): bool =
  ## Is a node directly under `parent` an argument of an extern call — a
  ## positional one, or a field of the one payload?
  if parent == nil: return false
  if s.isExternCall(parent): return true
  parent.kind == exkStruct and s.isExternCall(grand) and
    grand.args.len == 1 and grand.args[0] == parent

proc failIfLooseAddr(s: AddrScan, n, parent: Expr) =
  ## A `Pool.addr` anywhere but the value of a `let`.
  if not isCellAddr(s.res, n): return
  if parent != nil and parent.kind == exkAssign and parent.assignVal == n and
     parent.isDecl and parent.target != nil and parent.target.kind == exkVar:
    return
  fail(dcTyPointerStored, "Type Error: a cell's address (`Pool.addr`) is " &
       "bound by `let` and handed to an extern; it cannot be used here", n.span)

proc scanAssign(s: var AddrScan, n: Expr) =
  ## A `let` of an address binds a local; any other assignment to one is
  ## refused.
  if n.target == nil or n.target.kind != exkVar: return
  if n.isDecl and isCellAddr(s.res, n.assignVal):
    s.bound.incl n.target.name
  elif n.target.name in s.bound:
    fail(dcTyPointerStored, "Type Error: `" & n.target.name & "` holds a " &
         "cell's address and cannot be reassigned", n.span)

proc scanUse(s: AddrScan, n, parent, grand: Expr) =
  ## A read of a local holding an address: an extern call's argument, or
  ## refused.
  if n.name notin s.bound: return
  if parent != nil and parent.kind == exkAssign and parent.target == n: return
  if s.isExternArg(parent, grand): return
  fail(dcTyPointerStored, "Type Error: `" & n.name & "` holds a cell's " &
       "address, which only an extern may take — this use is not an " &
       "argument of an extern call", n.span)

proc scan(s: var AddrScan, n, parent, grand: Expr) =
  if n == nil: return
  s.failIfLooseAddr(n, parent)
  if n.kind == exkAssign: s.scanAssign(n)
  elif n.kind == exkVar: s.scanUse(n, parent, grand)
  for c in n.children: s.scan(c, n, parent)

proc checkCellAddresses*(res: Resolution, m: Module, externs: HashSet[string]) =
  ## Every `Pool.addr` in the module goes only where an extern takes it.
  for body in m.bodies:
    var s = AddrScan(res: res, externs: externs)
    s.scan(body, nil, nil)
