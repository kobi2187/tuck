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
# The Nim backend already had this as six private `*Fast` procs over an index
# in its own ctx. That is the right shape and the wrong home: the other two
# backends ask the same questions and paid the scan. Keyed by module here, so
# a backend gets the index without restructuring its context object.
import tables, sets
import ast, ast_query

type DeclIndex* = object
  recordNames: HashSet[string]   ## records AND objects — both construct with
                                 ## named fields, so both answer isRecordType
  actorNames: HashSet[string]
  taskNames: HashSet[string]
  invariantTypes: HashSet[string]
  saturating: Table[string, Type]

# A Module is a plain value object with no identity — no name, no id — so a
# global cache keyed by module cannot be written safely. The index is built
# once by the backend that wants it and passed explicitly, which is also
# clearer: the lifetime is visible instead of hidden in a table.

proc buildDeclIndex*(m: Module): DeclIndex =
  for d in m.decls:
    if d == nil: continue
    case d.kind
    of dkObject:
      # An object constructs exactly like a record — `{name: "rex"} Dog` is
      # named fields, not positional — so it belongs in the same set.
      result.recordNames.incl(d.name)
      if hasInvariants(m, d.name): result.invariantTypes.incl(d.name)
    of dkType:
      if d.typeBody != nil and d.typeBody.kind == tkRecord:
        result.recordNames.incl(d.name)
      if hasInvariants(m, d.name): result.invariantTypes.incl(d.name)
      let sat = saturatingType(m, d.name)
      if sat != nil: result.saturating[d.name] = sat
    of dkActor: result.actorNames.incl(d.name)
    of dkTask: result.taskNames.incl(d.name)
    # Everything else contributes no NAME to this index. Listed rather than
    # left to `else`, so a new DeclKind that should be indexed is a compile
    # error here instead of a lookup that quietly returns false.
    of dkFn, dkMixin, dkExtern, dkPending, dkPool, dkFnSig, dkRegistry,
       dkRegister, dkExpr, dkConst, dkStaticAssert, dkErrors, dkImport,
       dkSelect, dkSatisfies, dkInterface, dkWhen: discard

proc isRecordTypeIdx*(idx: DeclIndex, name: string): bool =
  name in idx.recordNames

proc isActorTypeIdx*(idx: DeclIndex, name: string): bool =
  name in idx.actorNames

proc isTaskNameIdx*(idx: DeclIndex, name: string): bool =
  name in idx.taskNames

proc hasInvariantsIdx*(idx: DeclIndex, name: string): bool =
  name in idx.invariantTypes

proc saturatingTypeIdx*(idx: DeclIndex, name: string): Type =
  if name in idx.saturating: idx.saturating[name] else: nil
