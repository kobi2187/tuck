# compiler/ast.nim
# Tuck AST node definitions.
# This file contains the core syntax tree shape for the lexer/parser/compiler.
#
# SourceName
# ----------
# Three node types (Type, Expr, Decl) carry `sourceName: Option[string]`.
# The mangle pass renames top-level declarations and the references to them
# (`Feed` -> `tuck_Feed`) so no emitted name can clash in any backend. It used
# to do that destructively: the name the user wrote was gone, and anything
# needing it back guessed by stripping the prefix off the mangled one.
#
# Guessing was wrong twice. Error ids hash over the name, and so does the
# report that prints it to the user, so a mangled id both broke `match r.err`
# and leaked `tuck_` into output. `sourceName` records the original AT the
# rename, so the user-facing name is stored data rather than a convention:
#
#   none    -> never renamed; `name` IS the source name (the common case —
#              locals, params and externs are never mangled)
#   some(s) -> renamed; `s` is what the user wrote, `name` is what we emit
#
# It is common to all nodes but only meaningful on named ones, which is why
# it sits beside `id`/`span` rather than inside a `case` branch.

import hashes, std/options

type
  Span* = object
    line*: int
    col*: int
    file*: string

  # What every AST node has: where it came from, and who it is.
  #
  # `id` is the handle the semantic layer uses. Before this existed only Expr
  # carried one, so a Decl or a Type could be a lookup KEY but never a lookup
  # TARGET — which is why passes ask "which declaration is named X" and scan
  # the decl list to answer. Giving Decl and Type identity is what lets those
  # scans become table reads, and what lets a reference point AT a declaration
  # instead of describing it by name.
  Node* = ref object of RootObj
    id*: NodeId
    span*: Span

  EffectMarker* = enum
    emIo
    emNoAlloc
    emIrqSafe
    emUnsafe
    emMayBlock
    emStack
    emPriority


  TypeAttr* = object
    name*: string
    value*: string
    span*: Span

  FieldDef* = object
    name*: string
    typ*: Type
    attrs*: seq[TypeAttr]
    span*: Span

  FieldInit* = tuple[name: string, value: Expr]
    ## One `name: value` pair of a record literal `{a: 1, b: 2}`.
    ## A NAMED tuple, so a reader sees `f.name` / `f.value` instead of
    ## having to know that index 0 is the name and index 1 the value.
    ## Structurally identical to the anonymous pair it replaced, so
    ## positional construction `(name, expr)` still compiles.

  VariantDef* = object
    name*: string
    fields*: seq[FieldDef]
    value*: string  # `A = 10` — explicit ordinal, needed to match a C enum;
                    # empty = sequential from 0, Tuck's and C's default
    span*: Span

  Transition* = object
    `from`*: string
    to*: string
    span*: Span

  TypeKind* = enum
    tkNamed
    tkTuple
    tkApp
    tkFunc
    tkRecord
    tkSum
    tkUnion
    tkEffect
    tkRename

  Type* = ref object of Node
    attrs*: seq[TypeAttr]
    sourceName*: Option[string]  ## see SourceName note below
    case kind*: TypeKind
    of tkNamed:
      name*: string
    of tkTuple:
      elems*: seq[Type]
    of tkApp:
      base*: Type
      args*: seq[Type]
    of tkFunc:
      params*: seq[Type]
      result*: Type
    of tkRecord:
      fields*: seq[FieldDef]
    of tkSum:
      variants*: seq[VariantDef]
      transitions*: seq[Transition]
    of tkUnion:
      members*: seq[Type]
    of tkEffect:
      inner*: Type
      effects*: seq[EffectMarker]
    of tkRename:
      underlying*: Type
      renames*: seq[(string, string)]

  Param* = object
    name*: string
    typ*: Type
    span*: Span

  PatternKind* = enum
    pkWild
    pkVar
    pkLit
    pkRecord
    pkTuple
    pkOr

  Pattern* = ref object
    span*: Span
    case kind*: PatternKind
    of pkWild:
      discard
    of pkVar:
      name*: string
    of pkLit:
      litKind*: LitKind
      litValue*: string
    of pkRecord:
      fields*: seq[(string, Pattern)]
    of pkTuple:
      elems*: seq[Pattern]
    of pkOr:
      left*, right*: Pattern

  MatchArm* = object
    pattern*: Pattern
    guard*: Expr
    body*: Expr
    span*: Span

  # `on select` arm (spec §9.3). Phase B: message sources only — `source` is a
  # message handler name; timer/timeout/shutdown sources come later.
  SelectArm* = object
    source*: string      # actor: message handler name. task: "read"/"timeout".
    arg*: Expr           # task select: the fd (read) or ms (timeout); else nil
    binding*: seq[Param] # `-> {x, y}` payload binding (may be empty)
    body*: Expr
    span*: Span

  # What a task select arm's `source` string MEANS. The parser stores the
  # source verbatim — including dotted forms like `timeout.5s`, which it
  # concatenates into one opaque string — so the raw field cannot be compared
  # against "read"/"timeout" safely: `timeout.5s` is not `timeout`.
  #
  # An enum rather than those bare string compares, because the compare is
  # what made a whole handler body vanish: an arm the emitter did not
  # recognise fell through to `discard` and dropped its body with no
  # diagnostic. Classifying once and matching exhaustively means a shape the
  # backend cannot lower is a branch someone must WRITE, not a string that
  # quietly matches nothing.
  SelectSourceKind* = enum
    sskRead              ## `read <fd>` — wait for the fd to become readable
    sskTimeout           ## `timeout <ms>` — plain deadline, arg carries the ms
    sskTimeoutTyped      ## `timeout.5s` — dotted duration; parsed, NOT lowered
    sskOther             ## anything else: an actor handler name, or unbuilt

  BinOp* = enum
    boAdd, boSub, boMul, boMod
    # Division names its arithmetic (R1): `/i` truncating integer divide,
    # `/f` float divide. There is no operand-inferred `/` — the two lower to
    # different instructions, so the source says which one runs.
    boDivInt, boDivFloat
    boEq, boNeq, boLt, boGt, boLe, boGe
    boAnd, boOr, boXor
    boRangeIncl, boRangeExcl

  UnaryOp* = enum
    uoNeg
    uoNot
    uoComposition
    uoPropagate  # expr? — pass the error upward; enclosing fn must return !T

  ChainOp* = enum
    coDot
    coDotDot

  # Identity for the semantic layer. Assigned once, right after parsing, and
  # carried through every later pass — including a per-target clone — so the
  # Resolution built during checking stays reachable from a rewritten tree.
  # 0 means "not yet assigned" (a node built by a later pass).
  NodeId* = distinct uint32

  ChainStep* = object
    op*: ChainOp
    target*: Expr
    arg*: Expr
    span*: Span
    id*: NodeId      # identity for the Resolution (a step can resolve to a call)

  ExprKind* = enum
    exkLit
    exkVar
    exkField
    exkQualified
    exkStruct
    exkList
    exkBracket
    exkBracketAssign
    exkCall
    exkChain
    exkBinary
    exkUnary
    exkBlock
    exkIf
    exkMatch
    exkFor
    exkWhile
    exkBreak
    exkContinue
    exkAssign
    exkReturn
    exkRaise
    exkDiscard   # `discard` / `discard <expr>` — an explicit, silent value drop
    exkImport
    exkSend      # `ActorType send handler {payload}` — enqueue to an actor
    exkSelect    # task-body `on select:` — wait on read/timeout branches
    # The five below replace a bare exkVar that names a non-value
    # declaration outright — resolveDeclRefs (compiler/resolve_refs.nim)
    # rewrites the matching exkVar into one of these, between load and
    # typecheck, once, against the real declaration list. synthVar's
    # local/nullary-call/sum-variant chain never sees these names at all
    # afterward, so it never has to guess at them by string comparison.
    exkActorRef     # a bare actor singleton name (`Sink` in `Sink.seen`)
    exkRegisterRef  # a bare memory-mapped register name (`CTRL` in `CTRL.EN`)
    exkRegistryRef  # a bare registry name (`AppEvents` in `AppEvents.raise X`)
    exkPoolRef      # a bare pool name (`Bufs` in `Bufs.acquire`)
    exkMixinRef     # a bare mixin name (`Helpers` in `+ Helpers`)

  Expr* = ref object of Node
    sourceName*: Option[string]  ## see SourceName note below
    case kind*: ExprKind
    of exkLit:
      litKind*: LitKind
      litValue*: string
    of exkVar:
      name*: string
    of exkField:
      receiver*: Expr
      fieldName*: string
      ctorUnsafe*: bool  # Type.Variant [unsafe] — sealed-construction escape hatch
      dotArg*: Expr      # `.fn {args}` — extra args for the method form
                         # (receiver rides as the fn's first parameter)
    of exkQualified:
      modulePath*: seq[string]
      qualName*: string
    of exkStruct:
      fields*: seq[FieldInit]
    of exkList:
      items*: seq[Expr]
    of exkBracket:
      # `recv[a, b, ...]`. The receiver decides the meaning, not the argument
      # count: a declared type is a type application, a value is an index.
      # The checker resolves it; the call lands in the Resolution.
      brReceiver*: Expr
      brArgs*: seq[Expr]
    of exkBracketAssign:
      # `recv[i] = v` — the checker resolves this to a setAt call
      brTarget*: Expr    # the exkBracket being assigned into
      brValue*: Expr
    of exkCall:
      callee*: Expr
      args*: seq[Expr]
      # The payload-to-param mapping the checker decides for this call lives
      # in the semantic layer (resolution.argFieldsFor / callParamsFor), not
      # here — it is derived, not syntax.
    of exkChain:
      base*: Expr
      steps*: seq[ChainStep]
    of exkBinary:
      binOp*: BinOp
      left*, right*: Expr
    of exkUnary:
      unaryOp*: UnaryOp
      operand*: Expr
    of exkBlock:
      stmts*: seq[Expr]
    of exkIf:
      cond*, thenBranch*, elseBranch*: Expr
    of exkMatch:
      subject*: Expr
      arms*: seq[MatchArm]
    of exkFor:
      iter*: Pattern
      iterable*, body*: Expr
    of exkWhile:
      whileCond*: Expr        # nil = infinite loop (`loop:`)
      whileBody*: Expr
    of exkBreak, exkContinue:
      discard
    of exkAssign:
      target*, assignVal*: Expr
      isDecl*: bool     # true for `let x = ...` / `var x = ...`
      isMutable*: bool  # true only for `var`
    of exkReturn:
      returnVal*: Expr
    of exkRaise:
      raiseVal*: Expr
    of exkDiscard:
      discardVal*: Expr   # nil = bare `discard`, a pure no-op statement
    of exkImport:
      path*: seq[string]
    of exkSend:
      sendActor*: string   # the actor TYPE name (singleton target)
      sendHandler*: string # the `on <handler>` name
      sendPayload*: Expr    # the `{...}` struct literal, or nil
    of exkSelect:
      selArms*: seq[SelectArm]  # read/timeout branches (spec §9.3)
    of exkActorRef, exkRegisterRef, exkRegistryRef, exkPoolRef, exkMixinRef:
      refName*: string  # the resolved name; the Decl itself is one
                        # declFor(semLayer, e) away (resolution.nim) once
                        # resolveDeclRefs links it — not stored here, so
                        # this node stays small and deepCopy/JSON-safe

  LitKind* = enum
    lkInt, lkFloat, lkStr, lkBool, lkUnit

  # Imported type decls are injected into the importer for checking and
  # lowering, marked with this span.file so codegen skips re-emitting them.
const ImportedTypeMarker* = "<imported>"

# The checker's gradual-typing sentinel: undeclared symbols synthesize this
# named type; codegen treats it as "no type information".
#
# BEING SPLIT UP. One sentinel was doing several unrelated jobs, and because
# `compatible` treats it as matching everything, every one of those jobs
# silently disabled type checking wherever its value flowed. Measured: making
# it incompatible breaks 15 checks, of which only the generic ones are a real
# need — the rest were bugs it was hiding (a loop variable's element type, an
# object's fields, an interface argument, actor `result`, `Error.X`).
#
# Each distinct meaning gets its own name so the checker can be strict about
# the one that means "I could not work it out":
const
  UnknownName* = "<unknown>"      # the checker could not tell — a GAP, and the
                                  # long-term goal is for this to be an error
  TypeParamName* = "<typeparam>"  # a generic's T inside its own body: not
                                  # unknown, but ANY type, fixed per call site
  PendingName* = "<pending>"      # declared, not implemented (spec §5.4). The
                                  # walking skeleton must still run, so this
                                  # one is deliberately permissive
  EmptyRecName* = "<emptyrec>"    # `{}` — a real type (the empty record), not
                                  # an absence of one
  AfterErrorName* = "<afterror>"  # a dummy returned after fail() has already
                                  # reported; nothing should ever check it
  BranchOutcomeName* = "<branchoutcome>"  # `on select:` as a task's own
                                  # tail: each arm returns explicitly, so
                                  # the construct's OWN synthesized value
                                  # is never consumed — not a gap, just
                                  # nothing to report a type for
  UninitName* = "<uninit>"        # a declared field the construction did not
                                  # supply. Wraps the field's own type
                                  # (`<uninit>[int]`), rides with the value so
                                  # nesting cannot launder it, and is erased
                                  # before codegen — the emitted record keeps
                                  # its declared field types exactly.

# A `satisfies I` line inside an object body (spec §5.2). parseObjectBody is
# shared with dkActor and has no out-param, so the line is collected as a dkExpr
# member carrying this sentinel, with the interface name in `Decl.name`; the
# dkObject arm sifts those into the object's `satisfies` field. Same shape as
# the `+ X` composition members, which are sifted by isCompositionEntry.
const satisfiesMark* = "<satisfies>"

type
  # A function signature as stored in the .tuck-cache signature index:
  # enough to typecheck an importer without deserializing the module's AST.
  # What a module EXPORTS, in the form that survives to disk. This is the
  # cross-module contract: msgpack'd into .tuck-cache so a later run can check
  # against an import without re-reading its source, which is what keeps the
  # stdlib out of every compile.
  #
  # Anything a caller must know to check a call correctly belongs here. If a
  # field is missing, the check silently weakens the moment the callee comes
  # from cache instead of source — effects were exactly that: without them an
  # imported [io] fn looked pure to its callers.
  SigInfo* = object
    name*: string
    params*: seq[Param]
    ret*: Type
    generics*: seq[string]
    effects*: seq[EffectMarker]  # [io], [may_block], ... — propagates to callers
    isPending*: bool
    line*: int

  DeclKind* = enum
    dkType
    dkObject
    dkRegistry
    dkPool
    dkFn
    dkMixin   # `mixin Name:` — fns materialised onto a composing object
    # `extern:` and `pending:` blocks parse into their own kinds rather than
    # a dkMixin distinguished by `name == "extern"` / `== "pending"`. They are
    # not mixins: nothing composes them, and consumers ask entirely different
    # questions of them (what C symbol does this bind, is this fn still
    # unimplemented). They keep `mixinMembers` because the payload — a list of
    # member decls — is genuinely the same shape.
    dkExtern  # `extern:` / `extern [c, header: "x.h"]:` — externally provided
    dkPending # `pending:` — declared, not yet implemented; stubs are emitted
    dkActor
    dkTask
    dkExpr
    dkConst   # compile-time data declaration: const name = <literal data>
    dkRegister
    dkStaticAssert
    dkErrors  # global error policy declaration (spec 4.9)
    dkImport  # import <module> — loads <module>.tuck next to the importer
    dkSelect  # `on select:` — wait on multiple event sources (spec §9.3)
    dkFnSig   # `fnsig NAME = {params} -> ret` — named function-signature type
    dkSatisfies # `Obj satisfies Iface` at TOP LEVEL — a calling module attaching
                # an object it did not declare to a contract it did not declare
                # (spec §5.2). Its own kind rather than a dkExpr carrying a
                # marker: the object-body form is sifted into dkObject.satisfies
                # at parse time and disappears, whereas this one has to SURVIVE
                # as a declaration so a later module in the closure can see it.
                # Conformance is checked identically either way — attaching does
                # not weaken the contract, it only widens where it may be stated.
    dkInterface # `interface NAME:` — a contract (spec §5.2). Its own kind, NOT
                # a share of dkMixin's arm: a mixin's members are CODE that gets
                # composed into an object, an interface's are REQUIREMENTS that
                # get checked against one. Sharing an arm is what let a plain
                # mixin hold a cstring past the pointer rule (see
                # checkPointerContainment) — the same mistake twice would be
                # careless.
    dkWhen      # `when TARGET == "value":` — compile-time platform selection
                # (spec §8.3). Resolved by modules.resolveWhenBlocks right after
                # load, BEFORE typecheck ever runs: a non-matching block's decls
                # are dropped from the module entirely (never checked, never
                # emitted), a matching block's decls splice in as if declared
                # directly. Never resolved inside parseSource/rewriteModule,
                # because those results are what the AST cache stores — caching
                # a resolved tree would key it to whichever --target happened to
                # be active on the run that wrote the cache.

  Decl* = ref object of Node
    name*: string
    sourceName*: Option[string]  ## see SourceName note below
    case kind*: DeclKind
    of dkType:
      generics*: seq[string]
      typeBody*: Type
      typeMembers*: seq[Decl]
      # declared INSIDE an `extern [c, header: ...]` block: the struct belongs
      # to the C library, so the backends must DECLARE it (Nim's
      # {.importc, header.}, Odin's #packed-free plain struct) rather than
      # define a layout-compatible duplicate the C compiler will reject.
      typeExternHeader*: string
    of dkObject:
      objFields*: seq[FieldDef]
      satisfies*: seq[string]  # `satisfies I` lines — the interfaces this object
                               # promises to implement (spec §5.2). Checked by
                               # checkConformance; a seq because an object may
                               # satisfy several. (Was `mixins`, which was
                               # written once as @[] and never read —
                               # composition arrives as uoComposition members.)
      objMembers*: seq[Decl]
    of dkRegistry:
      variants*: seq[VariantDef]
    of dkPool:
      # spec 7.2: N slots of an arbitrary element type. `count` is required —
      # a pool without one has no static footprint, which is the whole point.
      poolElem*: Type
      poolCount*: int
    of dkFn:
      fnGenerics*: seq[string]
      fnParams*: seq[Param]
      fnReturnType*: Type
      fnEffects*: seq[EffectMarker]
      fnBody*: Expr
      isPending*: bool  # declared in a `pending:` block; body is nil
      isDecision*: bool # parsed from a `decision` table; body is match rows
      isExtern*: bool   # declared in an `extern:` block; implemented by the
                        # runtime (tuck_rt) or, with a header, imported from C
      externHeader*: string # extern [c, header: "uart.h"] — empty = rt-implemented
      externEmit*: string   # [emit: "nimProc"] — the exact runtime/C proc name
                            # to emit; empty = use the Tuck name
      externLib*: string    # extern [c, header: "zlib.h", lib: "z"] — the C
                            # library to link. Nim emits {.passL: "-lz".};
                            # Odin emits `foreign import z "system:z"`.
                            # Empty = header-only (or rt-implemented).
      externImpl*: seq[tuple[backend, module: string]]
                            # extern [impl: nim "std/strutils", odin "core:strings"]
                            # — the BACKEND-LANGUAGE module implementing these
                            # sigs, so a header-less extern can name a body
                            # module other than tuck_rt. The path is foreign
                            # (Nim's or Odin's own spelling), which is why it
                            # stays a string. A seq, not a Table: it holds one
                            # or two entries and rides the msgpack AST cache.
      isInline*: bool   # `fn inline name(...)` — codegen hint ({.inline.} / [Inline])
      fnErrorTypes*: seq[string]  # [error: FsError | NetError] — declared error enums
    of dkMixin, dkExtern, dkPending:
      mixinMembers*: seq[Decl]
    of dkWhen:
      whenTargetValue*: string  # the string literal on the RHS of `TARGET ==`
      whenDecls*: seq[Decl]     # top-level declarations gated by this block
    of dkInterface:
      ifaceMembers*: seq[Decl]  # body-less dkFn sigs — the requirements
    of dkActor:
      attrs*: seq[TypeAttr]
      actorFields*: seq[FieldDef]
      handlers*: seq[Decl]
    of dkTask:
      taskParams*: seq[Param]
      taskReturnType*: Type
      taskEffects*: seq[EffectMarker]
      taskBody*: Expr
    of dkSatisfies:
      # `Obj satisfies Iface` / `Obj satisfies [A, B, C]` at TOP LEVEL.
      # `name` is the OBJECT; these are the interfaces being attached to it.
      # A seq because the list form attaches several at once, and because a
      # module may state several separate lines for the same object.
      satisfyTargets*: seq[string]
    of dkFnSig:
      # `fnsig NAME[T, ...] = {params} -> ret` — a named function-signature
      # type (a named delegate). NAME becomes usable as a type for
      # slots/callbacks; the checker validates calls through it
      # (arity/param-types/ret), substituting `generics` from a slot's own
      # type args (`Mapper[int, str]`) when non-empty.
      sigGenerics*: seq[string]
      sigParams*: seq[Param]
      sigReturn*: Type
      # declared INSIDE an `extern [c, ...]` block: a C function pointer, so it
      # must use the C calling convention. Nim's default {.closure.} is a
      # two-word (proc, env) pair that no C function pointer can receive.
      sigIsCCallback*: bool
    of dkExpr:
      expr*: Expr
    of dkConst:
      constVal*: Expr
    of dkRegister:
      regAddress*: string
      regFields*: seq[FieldDef]
    of dkStaticAssert:
      assertExpr*: Expr
    of dkErrors:
      policyName*: string  # strict | continue | exit
      errHandler*: Decl    # the `on unhandled({code, site})` fn, nil if strict
    of dkImport:
      discard  # module name lives in Decl.name
    of dkSelect:
      selectArms*: seq[SelectArm]

  Module* = object
    path*: seq[string]
    decls*: seq[Decl]
    span*: Span



# --- SourceName: the name the user wrote -----------------------------------



# --- NodeId: identity for the semantic layer -------------------------------

proc `==`*(a, b: NodeId): bool {.borrow.}
proc hash*(a: NodeId): Hash {.borrow.}
proc `$`*(a: NodeId): string = "n" & $uint32(a)

# Operations over these types (children/assignIds/clearIds/newNodeId/
# effectName/enumDomain/writtenName) now live in ast_ops.nim, imported and
# re-exported below so existing `import ast` call sites see no difference.
import ast_ops
export ast_ops
