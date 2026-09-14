# compiler/resolution.nim
# The semantic layer: what the checker concluded, keyed by node identity.
#
# The AST stays a faithful record of syntax. Everything the checker DERIVES
# lives here instead of in the tree, so a later pass may rewrite or clone the
# tree for its target without carrying (or losing) semantic residue: ids
# survive the copy, so these lookups still resolve.

import tables, sets, strutils
import ast

type
  Resolution* = ref object
    ## A REF, so it can be handed from stage to stage rather than reached for.
    ## As a plain object every `proc(res: Resolution)` would have copied a
    ## dozen tables; as a ref the pipeline can pass the one layer along and
    ## the pass-ordering constraint stops being a comment.
    ##
    ## Sugar that turned out to be a call. One table, because callNode,
    ## varCallNode, brCallNode and brAssignNode were always the same idea:
    ## `x.f`, a bare nullary `f`, `xs[i]` and `xs[i] = v` all resolve to an
    ## ordinary call once the checker knows the types.
    calls*: Table[NodeId, Expr]
    types*: Table[NodeId, Type]        # what the checker inferred
    shortcuts*: Table[NodeId, string]  # errors-policy drop sites
    asyncCalls*: HashSet[NodeId]       # call sites whose callee is [io] —
                                       # codegen awaits/yields them (async)
    # Name resolution, recorded once by the checker and read by every later
    # pass. `decls` is the index — "give me that declaration" — and `declOf`
    # is the edge a reference has to its target: "what does this name mean".
    # Together they replace asking the module "which decl is named X", which
    # is a scan of the declaration list per question.
    decls*: Table[NodeId, Decl]        # id -> the declaration itself
    declOf*: Table[NodeId, NodeId]     # referring node -> declaration id
    # Whole-program name -> Decl, for the five kinds a bare Capitalized name
    # can reference OUTRIGHT (not through `decls`/`declOf`, which are
    # per-NODE edges recorded once a reference is already known — these are
    # the NAME->Decl step that answers "is this string a declared actor/
    # register/registry/pool/mixin" at all). Built once, whole-program, by
    # resolveDeclRefs (compiler/resolve_refs.nim) between load and
    # typecheck; consulted only there, to rewrite a matching exkVar into
    # the matching exkActorRef/exkRegisterRef/exkRegistryRef/exkPoolRef/
    # exkMixinRef. Not a general-purpose lookup for other passes to grow
    # dependent on — those should use declFor on the rewritten reference.
    actorNames*: Table[string, Decl]
    registerNames*: Table[string, Decl]
    registryNames*: Table[string, Decl]
    poolNames*: Table[string, Decl]
    mixinNames*: Table[string, Decl]
    # How a call's payload maps onto its callee's parameters, decided once by
    # checkCallArgs. `argFields[i]` names the payload FIELD that satisfies
    # param i — matched by name, or by type when the names differ — and
    # `callParams[i]` is that param's own name. Codegen and lowering read
    # these instead of re-deriving the mapping, which misses by-type matches.
    argFields*: Table[NodeId, seq[string]]
    callParams*: Table[NodeId, seq[string]]
    callTypeArgs*: Table[NodeId, seq[Type]]
                    ## The concrete types a generic call resolved its callee's
                    ## type params to, in the callee's declaration order. Only
                    ## recorded where a backend cannot recover them: a type
                    ## param that appears in no parameter (`[C: Indexable[E], E]`
                    ## returning E) is solved from the group conformance, and
                    ## no host language can infer it from the arguments.
    # Interface wraps (spec §5.3). `wraps` marks the expression where a concrete
    # object enters an interface slot, so codegen emits the tagged variant there
    # instead of the bare value. `ifacePairs` is the DEMAND SET: exactly the
    # (object, interface) combinations some wrap actually asked for.
    #
    # Demand-driven on purpose. Emitting a variant branch for every declared
    # `satisfies` would generate code for pairs no program uses — an object may
    # satisfy an interface it is never passed as. Collecting from call sites
    # instead means an unused `satisfies` costs the conformance check and
    # nothing else. Safe because the checker completes before codegen begins
    # (tuck.nim: checkOrDie, then mangleProgram, then emitNim), so the set is
    # closed by the time anything reads it.
    wraps*: Table[NodeId, tuple[objName, iface: string]]
    ifacePairs*: HashSet[tuple[objName, iface: string]]
    ifaceCalls*: Table[NodeId, tuple[iface, member: string]]
    lastUses*: HashSet[NodeId]
      ## Nodes analysis_lastuse proved are a local's FINAL read, so the copy
      ## made for them is unobservable and may be a move. A set rather than a
      ## table: the only question asked is yes/no.

proc poolHandleName*(pool: string): string = pool & "Handle"

proc isPoolHandleType*(m: Module, name: string): bool =
  ## Is this the handle type of some pool declared in this module?
  ##
  ## The checker gives every pool its OWN handle type so releasing into the
  ## wrong pool is a type error; the backends need only the runtime's single
  ## `PoolHandle`, so each type mapper answers every one of these with that.
  ## The separation is resolved and discarded before codegen, exactly as a
  ## group bound is.
  if not name.endsWith("Handle"): return false
  let pool = name[0 ..< name.len - "Handle".len]
  for d in m.decls:
    if d == nil or d.kind != dkPool: continue
    # The pool's name is MANGLED by the time codegen asks (`tuck_Cells`); the
    # handle type is not, because the checker synthesised it and mangling
    # walks the AST, which never held it. Compare both spellings rather than
    # teaching mangle about a type that does not exist in the tree. (The
    # literal prefix rather than mangle.TuckNamePrefix: resolution sits below
    # mangle in the import graph.)
    if d.name == pool or d.name == "tuck_" & pool: return true
  return false

proc resourceHandleName*(kind: string): string =
  ## The per-kind handle type's name (spec §7.4). Capitalized, because it IS a
  ## type and Tuck's type names are: a kind spelled `udp` hands out a
  ## `UdpHandle`. One place, for the reason poolHandleName is one place — the
  ## checker names it, every backend maps it, and the two have to agree.
  if kind.len == 0: "Handle"
  else: kind[0].toUpperAscii & kind[1 .. ^1] & "Handle"

proc resourceTableName*(kind: string): string =
  ## The emitted name of a kind's registry table. Prefixed rather than bare:
  ## kind names are lowercase and user-chosen (`file`, `net`), so an unadorned
  ## `file` would collide with an ordinary fn of that name in every backend.
  ## The prefix is not a mangling — the table is a symbol the checker
  ## synthesised, and mangling walks the AST, which never held it.
  "tuckRes_" & kind

const ResourceShutdownProc* = "tuckResourcesShutdown"
  ## The per-program registry shutdown the entry point calls: report what
  ## leaked, then close every table. One name across the three backends, in
  ## one place, because three entry-point emitters have to agree on it.

proc declaresResources*(m: Module): bool =
  ## Does this module declare any resource kind? The entry points ask, to
  ## decide whether there is a shutdown to call at all — a program with no
  ## `resources:` block emits no table, no shutdown, and no call to one.
  for d in m.decls:
    if d != nil and d.kind == dkResources and d.resKinds.len > 0: return true
  false

proc rtOnFinishProc*(f: ResourceOnFinish): string =
  ## The runtime proc a declared `on_finish` binds to, or "" for none.
  ##
  ## ONE mechanism: the declaration PICKS a callback rather than setting a flag
  ## the runtime then switches on, so `setResourceHooks` overriding it writes
  ## the same field and the two cannot disagree. Here rather than in a backend
  ## because the answer is backend-neutral — all three runtimes name these
  ## procs identically, which is what keeps them one vocabulary.
  case f
  of rfNone: ""
  of rfFlush: "tuckResFlush"
  of rfShutdown: "tuckResShutdown"

proc isResourceHandleType*(m: Module, name: string): bool =
  ## Is this the handle type of some resource kind declared in this module?
  ##
  ## The §7.4 twin of isPoolHandleType, and true for the same reason: the
  ## checker gives every KIND its own handle type so finishing into the wrong
  ## registry is a type error, while the backends need only the runtime's
  ## single `ResourceHandle`. Not mangled — the checker synthesised it, and
  ## mangling walks the AST, which never held it.
  if not name.endsWith("Handle"): return false
  for d in m.decls:
    if d == nil or d.kind != dkResources: continue
    for k in d.resKinds:
      if resourceHandleName(k.name) == name: return true
  return false
  ## The per-pool handle type's name. One place, because the checker names it,
  ## every backend emits an alias for it, and mangling has to agree with both.

proc ensureId*(e: Expr) =
  ## Nodes minted after the parse boundary (checker-synthesized calls) have
  ## no id yet. Give them one on first use so nothing silently drops out of
  ## the semantic layer.
  if e != nil and not e.id.isSet: e.id = newNodeId()

proc setCall*(r: Resolution, e: Expr, call: Expr) =
  if e == nil: return
  ensureId(e)
  r.calls[e.id] = call

proc call*(r: Resolution, e: Expr): Expr =
  ## The resolved call for this node, or nil if it did not resolve to one.
  if e == nil or not e.id.isSet: return nil
  if r.calls.hasKey(e.id): r.calls[e.id] else: nil

proc hasCall*(r: Resolution, e: Expr): bool =
  e != nil and e.id.isSet and r.calls.hasKey(e.id)

proc markAsync*(r: Resolution, e: Expr) =
  ## Flag a call site as async — its callee carries [io], so codegen emits the
  ## suspend/await transform (the effect marker IS the async annotation).
  if e == nil: return
  ensureId(e)
  r.asyncCalls.incl(e.id)

proc isAsync*(r: Resolution, e: Expr): bool =
  e != nil and e.id.isSet and e.id in r.asyncCalls

proc markWrap*(r: Resolution, e: Expr, objName, iface: string) =
  ## Flag an expression as an interface wrap: a concrete object entering an
  ## interface slot. Codegen emits the tagged variant here rather than the bare
  ## value, copying the object in, and records the pair as demanded so the
  ## variant gets a branch for it.
  if e == nil: return
  ensureId(e)
  r.wraps[e.id] = (objName: objName, iface: iface)
  r.ifacePairs.incl((objName: objName, iface: iface))

proc wrapOf*(r: Resolution, e: Expr): tuple[objName, iface: string] =
  if e == nil or not e.id.isSet: return (objName: "", iface: "")
  r.wraps.getOrDefault(e.id, (objName: "", iface: ""))

proc markIfaceCall*(r: Resolution, e: Expr, iface, member: string) =
  ## Flag `a.noise` as a call THROUGH an interface value: codegen switches on
  ## the value's tag rather than emitting a direct call, because which
  ## implementation runs is carried by the value, not known here.
  if e == nil: return
  ensureId(e)
  r.ifaceCalls[e.id] = (iface: iface, member: member)

proc ifaceCallOf*(r: Resolution, e: Expr): tuple[iface, member: string] =
  if e == nil or not e.id.isSet: return (iface: "", member: "")
  r.ifaceCalls.getOrDefault(e.id, (iface: "", member: ""))

# The program-wide semantic layer. The compiler processes one program per
# run, so a single instance is the honest model; passing it through every
# signature in checker, lowering and both backends would be pure ceremony
# (~105 call sites across 6 files).
#
# OWNERSHIP. typecheckProgram owns the lifecycle: it calls resetResolution()
# first thing, so every entry here belongs to the program currently being
# checked. Nothing else may reset it — tuck.nim's checkOrDie carries a comment
# about this because the effect pass must run AFTER typecheckProgram or its
# async call-site marks are wiped before codegen reads them.
#
# SINGLE-WRITER, in two senses:
#
#   1. In PHASE. The checker writes; lowering and both backends only read.
#      mangleProgram is the one exception, and it runs whole-program BEFORE the
#      per-backend deepCopies precisely because this is shared — renaming per
#      copy would leave the other backend looking up names that no longer
#      exist (tuck.nim).
#   2. In THREAD. One thread, which holds because tuck is built --threads:off
#      (tuck.nim pickFastCC). Parallel module checking would need this sharded
#      per module and merged at the join, or guarded. The tables are keyed by
#      NodeId, which is minted from another single-writer global — see
#      ast.globalNodeCounter, which breaks first and breaks silently.
#
# Cleared at the start of each check so repeated in-process runs (the test
# suites) never see a previous program's entries.
proc newResolution*(): Resolution =
  Resolution(calls: initTable[NodeId, Expr](),
             types: initTable[NodeId, Type](),
             shortcuts: initTable[NodeId, string](),
             asyncCalls: initHashSet[NodeId](),
             decls: initTable[NodeId, Decl](),
             declOf: initTable[NodeId, NodeId](),
             argFields: initTable[NodeId, seq[string]](),
             callParams: initTable[NodeId, seq[string]](),
             callTypeArgs: initTable[NodeId, seq[Type]](),
             wraps: initTable[NodeId, tuple[objName, iface: string]](),
             ifacePairs: initHashSet[tuple[objName, iface: string]](),
             ifaceCalls: initTable[NodeId, tuple[iface, member: string]](),
             lastUses: initHashSet[NodeId]())

var semLayer* = newResolution()

proc resetResolution*() =
  ## Called by typecheckProgram, which owns this layer's lifecycle. A field
  ## added to Resolution is initialised in ONE place now — the two copies of
  ## this literal had to be kept in step by hand.
  ##
  ## The five whole-program name tables are the one exception: resolve_refs.
  ## resolveDeclRefs populates them ONCE, before typecheckProgram runs (so
  ## the exkVar-rewriting pass it does has something to rewrite AGAINST),
  ## and typecheck-time consumers (registryEventOwner) need them to survive
  ## THIS reset to still be there. Carried across rather than rebuilt here,
  ## because rebuilding would need the whole loaded program again, which
  ## this proc does not have — resolveDeclRefs already did that scan once.
  let actorNames = semLayer.actorNames
  let registerNames = semLayer.registerNames
  let registryNames = semLayer.registryNames
  let poolNames = semLayer.poolNames
  let mixinNames = semLayer.mixinNames
  semLayer = newResolution()
  semLayer.actorNames = actorNames
  semLayer.registerNames = registerNames
  semLayer.registryNames = registryNames
  semLayer.poolNames = poolNames
  semLayer.mixinNames = mixinNames

proc setStepCall*(r: Resolution, s: ChainStep, call: Expr) =
  if s.id.isSet: r.calls[s.id] = call

proc stepCall*(r: Resolution, s: ChainStep): Expr =
  if not s.id.isSet: return nil
  if r.calls.hasKey(s.id): r.calls[s.id] else: nil

# --- types and shortcut sites ----------------------------------------------

proc setType*(r: Resolution, e: Expr, t: Type) =
  if e == nil: return
  ensureId(e)
  r.types[e.id] = t

iterator allTypes*(r: Resolution): Type =
  ## Every type the checker recorded for an expression. For passes that need
  ## to finish a job over inferred types — resolving their declaration edge,
  ## say — rather than over the types the user wrote.
  for t in r.types.values:
    if t != nil: yield t

proc typeFor*(r: Resolution, e: Expr): Type =
  ## The checker's type for this node, or nil if it was never typed.
  if e == nil or not e.id.isSet: return nil
  if r.types.hasKey(e.id): r.types[e.id] else: nil

# --- name resolution ---------------------------------------------------------

proc indexDecl*(r: Resolution, d: Decl) =
  ## Register a declaration so references can point at it.
  if d != nil and d.id.isSet: r.decls[d.id] = d

proc resolveTo*(r: Resolution, e: Expr, d: Decl) =
  ## Record that this expression refers to that declaration. Called where the
  ## checker already resolved the name, so the answer costs nothing to keep.
  if e == nil or d == nil or not d.id.isSet: return
  ensureId(e)
  r.decls[d.id] = d
  r.declOf[e.id] = d.id

proc declFor*(r: Resolution, e: Expr): Decl =
  ## The declaration this expression refers to, or nil if the checker never
  ## resolved it (sketch code, a local, a builtin).
  if e == nil or not e.id.isSet: return nil
  if not r.declOf.hasKey(e.id): return nil
  r.decls.getOrDefault(r.declOf[e.id], nil)

proc resolveTypeTo*(r: Resolution, t: Type, d: Decl) =
  ## Record that this type reference names that declaration. A tkNamed carries
  ## a name because that is what the user wrote; this is what it MEANS.
  if t == nil or d == nil or not d.id.isSet: return
  if not t.id.isSet: t.id = newNodeId()
  r.decls[d.id] = d
  r.declOf[t.id] = d.id

proc declForType*(r: Resolution, t: Type): Decl =
  ## The declaration a named type refers to, or nil if never resolved.
  if t == nil or not t.id.isSet: return nil
  if not r.declOf.hasKey(t.id): return nil
  r.decls.getOrDefault(r.declOf[t.id], nil)

proc setArgFields*(r: Resolution, e: Expr, fields: seq[string]) =
  ## Which payload field feeds each param, in param order.
  if e == nil: return
  ensureId(e)
  r.argFields[e.id] = fields

proc argFieldsFor*(r: Resolution, e: Expr): seq[string] =
  ## Empty when the checker recorded no mapping — callers fall back to
  ## matching by param name.
  if e == nil or not e.id.isSet: return @[]
  r.argFields.getOrDefault(e.id, @[])

proc setCallParams*(r: Resolution, e: Expr, params: seq[string]) =
  ## The callee's parameter names, in declaration order.
  if e == nil: return
  ensureId(e)
  r.callParams[e.id] = params

proc callParamsFor*(r: Resolution, e: Expr): seq[string] =
  ## Empty when the callee was never resolved, or is not one whose payload
  ## may be exploded (a member fn, a task) — callers leave the call alone.
  if e == nil or not e.id.isSet: return @[]
  r.callParams.getOrDefault(e.id, @[])

proc setCallTypeArgs*(r: Resolution, e: Expr, args: seq[Type]) =
  ## The callee's type arguments, in its own generic-parameter order.
  if e == nil or args.len == 0: return
  ensureId(e)
  r.callTypeArgs[e.id] = args

proc callTypeArgsFor*(r: Resolution, e: Expr): seq[Type] =
  ## Empty when the call needs no explicit type arguments — which is the
  ## common case, since a type param mentioned by a parameter is inferred by
  ## every backend's own host language.
  if e == nil or not e.id.isSet: return @[]
  r.callTypeArgs.getOrDefault(e.id, @[])

proc setShortcut*(r: Resolution, e: Expr, site: string) =
  if e == nil: return
  ensureId(e)
  r.shortcuts[e.id] = site

proc shortcut*(r: Resolution, e: Expr): string =
  ## Non-empty when the errors policy routes this statement's dropped !T
  ## to the global handler.
  if e == nil or not e.id.isSet: return ""
  r.shortcuts.getOrDefault(e.id, "")

proc markLastUse*(r: Resolution, e: Expr) =
  ## Record that `e` is the final read of its binding.
  if e == nil: return
  ensureId(e)
  r.lastUses.incl(e.id)

proc isLastUse*(r: Resolution, e: Expr): bool =
  ## Was `e` proved to be a binding's final read? False for anything the
  ## analysis did not reach, which is the safe answer: an unproved use is
  ## copied exactly as it always was.
  e != nil and e.id in r.lastUses

proc memberProcName*(objName, memberName: string): string =
  ## An object member emits QUALIFIED: `B.noise` -> `tuck_B_noise`, where
  ## objName is already mangled.
  ##
  ## One rule for all three backends, which is what keeps the member and the
  ## free fn of the same name from ever competing. Odin and D needed it
  ## because neither overloads — two `noise :: proc` at package level is a
  ## redeclaration. Nim did NOT need it, and so emitted a bare `noise`; that
  ## bare name then collided with a top-level `noise` at MANGLING time and
  ## silently called the wrong one (issue #50). Nim now qualifies too: the
  ## collision cannot arise rather than being resolved by a precedence rule.
  objName & "_" & memberName

proc escapeStringLit*(v: string): string =
  ## A Tuck string literal, spelled for a target language.
  ##
  ## The lexer DECODES escapes, so `v` holds real characters — a literal
  ## newline, a literal quote. Emitting it raw produced source the host could
  ## not parse (an embedded `"` closed the literal early) or silently
  ## reinterpreted. Escaping here is what makes the three backends agree.
  ##
  ## Lives in resolution.nim because it is the one module the checker and all
  ## three backends already import; Nim, Odin and D accept this same spelling,
  ## so there is nothing per-backend to say.
  ##
  ## `\x00` rather than `\0` for NUL: Nim reads `\0` in a string as an octal
  ## escape it does not define, and the explicit hex form is accepted by all
  ## three.
  result = newStringOfCap(v.len)
  for c in v:
    case c
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\t': result.add("\\t")
    of '\r': result.add("\\r")
    of '\0': result.add("\\x00")
    else: result.add(c)

