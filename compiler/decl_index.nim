# compiler/decl_index.nim
#
# O(1) answers to "what kind of thing is this name", for the emit hot path.
#
# WHY THIS EXISTS. The natural spelling of these questions is a scan of the
# module's declaration list — `for d in m.decls: if d.name == name`. That is
# fine once, and quadratic when every expression asks it: emitting N call
# sites over a module of D declarations costs N*D.
#
# MEASURED, not assumed. 1000 types x 1000 call sites: the D backend's share
# of the compile was 0.36s against the whole Nim pipeline's 0.45s. Holding
# the call sites at 1000 and dropping to 5 types took the same work to
# 0.01s — so the cost scaled with decls x call sites, which is the scan.
#
# ONE INDEX FOR ALL THREE BACKENDS. Nim had it as six private `*Fast` procs
# over an index in its own ctx, D had this one, and Odin scanned — three
# answers to the same questions. Each backend now reaches this index through
# its ctx's `index` accessor, and asks it by the same names `ast_query`
# answers by scanning (`hasInvariants`, `isTaskName`, ...): the index is a
# cache of those answers, not a second definition of them.
import tables, sets
import ast, ast_query

type DeclIndex* = object
  ## Hash-set answers to the per-name questions every backend asks on its hot
  ## path (is this a record, a task, invariant-carrying?), built once per module
  ## instead of scanning the decl list each time.
  recordNames: HashSet[string]   ## records AND objects — both construct with
                                 ## named fields, so both answer isRecordType
  taskNames: HashSet[string]
  invariantTypes: HashSet[string]
  saturating: Table[string, Type]
  externInvRets: Table[string, string]  ## extern fn -> invariant return type
  externEmits: Table[string, string]    ## extern fn -> its `[emit: "..."]`

# A Module is a plain value object with no identity — no name, no id — so a
# global cache keyed by module cannot be written safely. The index is built
# once by the backend that wants it and passed explicitly, which is also
# clearer: the lifetime is visible instead of hidden in a table.

proc indexExterns(idx: var DeclIndex, m: Module) =
  ## A SECOND pass: an extern's invariant-carrying return type is looked up
  ## in `invariantTypes`, which the first pass has to finish filling (a type
  ## may be declared after the extern that returns it).
  for mem in m.externFns():
    if mem.externEmit != "": idx.externEmits[mem.name] = mem.externEmit
    if mem.fnReturnType != nil and mem.fnReturnType.kind == tkNamed and
       mem.fnReturnType.name in idx.invariantTypes:
      idx.externInvRets[mem.name] = mem.fnReturnType.name

proc buildDeclIndex*(m: Module): DeclIndex =
  ## Builds the index in one pass over `m`'s decls, then a second over its
  ## externs (`indexExterns`), which needs the invariant set finished first.
  for d in m.decls:
    if d == nil: continue
    case d.kind
    of dkObject:
      result.recordNames.incl(d.name)
      if hasInvariants(m, d.name): result.invariantTypes.incl(d.name)
    of dkType:
      if d.typeBody != nil and d.typeBody.kind == tkRecord:
        result.recordNames.incl(d.name)
      if hasInvariants(m, d.name): result.invariantTypes.incl(d.name)
      let sat = saturatingType(m, d.name)
      if sat != nil: result.saturating[d.name] = sat
    of dkTask: result.taskNames.incl(d.name)
    of dkFn, dkActor, dkMixin, dkExtern, dkPending, dkPool, dkSlab, dkArena, dkFnSig, dkRegistry,
       dkRegister, dkExpr, dkConst, dkStaticAssert, dkErrors, dkImport,
       dkSelect, dkSatisfies, dkInterface, dkGroup, dkWhen,
       dkPublic, dkResources: discard
  result.indexExterns(m)

# Named as `ast_query` names the scanning answers, so a call reads the same
# whichever it asks: `m.hasInvariants(n)` scans, `ctx.index.hasInvariants(n)`
# looks up.

proc isRecordType*(idx: DeclIndex, name: string): bool =
  ## Does `name` construct with named fields — a record type or an object?
  ## The O(1) twin of `ast_query.isRecordType`.
  name in idx.recordNames

proc isTaskName*(idx: DeclIndex, name: string): bool =
  ## Is `name` a declared task? Calls to a task emit as spawns, not calls.
  name in idx.taskNames

proc hasInvariants*(idx: DeclIndex, name: string): bool =
  ## Does the type `name` declare invariants, so a value of it must be
  ## validated where it is built or returned?
  name in idx.invariantTypes

proc saturatingType*(idx: DeclIndex, name: string): Type =
  ## The saturating integer type a named type wraps, or nil when it is not
  ## declared saturating.
  idx.saturating.getOrDefault(name, nil)

proc externInvRet*(idx: DeclIndex, fnName: string): string =
  ## The invariant-carrying type an extern fn returns, or "" — its result must
  ## be validated at the call, since no Tuck body produced it.
  idx.externInvRets.getOrDefault(fnName, "")

proc externEmitName*(idx: DeclIndex, fnName: string): string =
  ## This MODULE's extern's `[emit:]` name, or "".
  idx.externEmits.getOrDefault(fnName, "")
