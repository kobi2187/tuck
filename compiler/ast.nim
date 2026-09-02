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

func effectName*(e: EffectMarker): string =
  ## How a marker is SPELLED IN SOURCE — what the author writes in the
  ## bracket, and therefore the only spelling a diagnostic may print.
  ##
  ## Two call sites used to derive this mechanically from the enum name
  ## (`($e)[2..^1].toLowerAscii`, `($e).replace("em","").toLowerAscii`), which
  ## silently drops the underscore: `[may_block]` was reported as
  ## `[mayblock]`, a word that appears nowhere in the language, so a reader
  ## could not search for it. `no_alloc` and `irq_safe` had it too.
  ##
  ## Spelled out rather than derived: the case is exhaustive, so a new marker
  ## fails to compile here until someone states its source spelling — which is
  ## the whole reason a mechanical derivation was the wrong tool.
  case e
  of emIo: "io"
  of emNoAlloc: "no_alloc"
  of emIrqSafe: "irq_safe"
  of emUnsafe: "unsafe"
  of emMayBlock: "may_block"
  of emStack: "stack"
  of emPriority: "priority"

proc enumDomain*(m: Module, t: Type): seq[string] =
  ## Values of an enumerable decision-table column: bool, or a fieldless sum
  ## type declared in the module. Empty result = not enumerable (open domain).
  if t == nil: return @[]
  if t.kind == tkNamed:
    if t.name == "bool": return @["false", "true"]
    for d in m.decls:
      if d.kind == dkType and d.name == t.name and d.typeBody != nil and
         d.typeBody.kind == tkSum:
        var vals: seq[string]
        for v in d.typeBody.variants:
          if v.fields.len > 0: return @[]  # payload variants: not a flat enum
          vals.add(v.name)
        return vals
  return @[]

# --- SourceName: the name the user wrote -----------------------------------

proc writtenName*(e: Expr): string =
  ## What the user wrote for this expression's name. Use it for anything the
  ## user sees or that must be stable across backends — never for an emitted
  ## identifier, which has to stay mangled. Only exkVar carries a name.
  if e == nil or e.kind != exkVar: return ""
  if e.sourceName.isSome: e.sourceName.get else: e.name

proc writtenName*(d: Decl): string =
  ## What the user wrote for this declaration's name. See the Expr overload.
  if d == nil: return ""
  if d.sourceName.isSome: d.sourceName.get else: d.name

# --- NodeId: identity for the semantic layer -------------------------------

proc `==`*(a, b: NodeId): bool {.borrow.}
proc hash*(a: NodeId): Hash {.borrow.}
proc `$`*(a: NodeId): string = "n" & $uint32(a)

proc isSet*(a: NodeId): bool = uint32(a) != 0'u32

iterator children*(t: Type): Type =
  ## Every type one level down. The Type half of `children(Expr)`, and it
  ## exists for the same reason: this walk was hand-rolled in eight files, and
  ## the copies had already diverged — mangleType ended in `else: discard`
  ## while resolveTypeRefs listed tkEffect explicitly. Latent rather than live,
  ## since nothing constructs a tkEffect today, but that is exactly the kind of
  ## drift a shared iterator makes impossible.
  ##
  ## Exhaustive on purpose: a new TypeKind must be listed here or this stops
  ## compiling.
  ##
  ## Field and variant NAMES are not yielded — they are not types. A caller
  ## that needs them (codegen emitting a record) walks `fields` itself; this
  ## iterator answers "what types does this type refer to".
  if t != nil:
    case t.kind
    of tkNamed: discard
    of tkApp:
      yield t.base
      for a in t.args: yield a
    of tkTuple:
      for e in t.elems: yield e
    of tkFunc:
      for p in t.params: yield p
      yield t.result
    of tkRecord:
      for f in t.fields: yield f.typ
    of tkSum:
      for v in t.variants:
        for f in v.fields: yield f.typ
    of tkUnion:
      for mem in t.members: yield mem
    of tkEffect: yield t.inner
    of tkRename: yield t.underlying

iterator children*(e: Expr): Expr =
  ## Every sub-expression, one level down. For the walks that only need to
  ## VISIT nodes rather than rewrite them — the traversal is the boilerplate,
  ## and assignIds/clearIds already hand-roll it twice because they mutate.
  ##
  ## The case is exhaustive on purpose: a new ExprKind must be listed here or
  ## the compiler refuses, which is what stops a walk from silently missing a
  ## node and reporting a clean result over a subtree it never looked at.
  ##
  ## No `skip: set[ExprKind]` parameter, deliberately. It would be two lines,
  ## but every caller today wants the whole tree, and every bug this iterator
  ## replaced came from a walk that CHOSE which kinds to visit
  ## (raisedEventsIn, scanReturns, mentionsName, synthesizeExpr — four silent
  ## gaps, all the same shape). A skip set hands that choice back.
  ##
  ## The two callers that really do treat a kind differently — mangleExpr's
  ## scoping arms, lowerExpr's bracket nodes — do not merely skip it, they do
  ## something ELSE with it, which is an explicit `case` arm before the walk
  ## and not something a skip set could express. Add the parameter when a
  ## caller wants plain omission and can be named in this comment.
  if e != nil:
    case e.kind
    of exkLit, exkVar, exkQualified, exkImport, exkBreak, exkContinue: discard
    of exkField:
      yield e.receiver
      yield e.dotArg
    of exkStruct:
      for f in e.fields: yield f.value
    of exkList:
      for it in e.items: yield it
    of exkBracket:
      yield e.brReceiver
      for a in e.brArgs: yield a
    of exkBracketAssign:
      yield e.brTarget
      yield e.brValue
    of exkCall:
      yield e.callee
      for a in e.args: yield a
    of exkChain:
      yield e.base
      for s in e.steps:
        yield s.target
        yield s.arg
    of exkBinary:
      yield e.left
      yield e.right
    of exkUnary: yield e.operand
    of exkBlock:
      for s in e.stmts: yield s
    of exkIf:
      yield e.cond
      yield e.thenBranch
      yield e.elseBranch
    of exkMatch:
      yield e.subject
      for arm in e.arms:
        yield arm.guard
        yield arm.body
    of exkFor:
      yield e.iterable
      yield e.body
    of exkWhile:
      yield e.whileCond
      yield e.whileBody
    of exkAssign:
      yield e.target
      yield e.assignVal
    of exkReturn: yield e.returnVal
    of exkRaise: yield e.raiseVal
    of exkDiscard: yield e.discardVal
    of exkSend: yield e.sendPayload
    of exkSelect:
      for arm in e.selArms:
        yield arm.arg
        yield arm.body

iterator childDecls*(d: Decl): Decl =
  ## Every declaration nested one level inside `d`, whichever field holds it.
  ##
  ## The Decl half of `children(Expr)`, and it exists for the same reason: the
  ## traversal is boilerplate, and assignIds/clearIds hand-rolled it twice —
  ## identical arms differing only in the action. A walk that lists kinds by
  ## hand is a walk that can silently miss one.
  ##
  ## Exhaustive on purpose. A new DeclKind must be listed here or this stops
  ## compiling, which is the whole guarantee.
  ##
  ## NOT the same as ast_query.members: that one is the API for "what is
  ## declared inside this thing" and deliberately excludes a `when` block's
  ## body (resolved away before checking) and a select arm's. This one is the
  ## TRAVERSAL — everything an id-assigning or id-clearing walk must reach.
  if d != nil:
    case d.kind
    of dkType:
      for m in d.typeMembers: yield m
    of dkObject:
      for m in d.objMembers: yield m
    of dkMixin, dkExtern, dkPending:
      for m in d.mixinMembers: yield m
    of dkWhen:
      for m in d.whenDecls: yield m
    of dkInterface:
      for m in d.ifaceMembers: yield m
    of dkActor:
      for h in d.handlers: yield h
    of dkFn, dkTask, dkConst, dkExpr, dkStaticAssert, dkSelect, dkRegistry,
       dkPool, dkRegister, dkErrors, dkImport, dkFnSig, dkSatisfies:
      discard

iterator ownTypes*(d: Decl): Type =
  ## Every type this declaration mentions DIRECTLY — its fields' types, its
  ## params and return, a pool's element type. Not its members' (walk
  ## childDecls for those) and not the types nested inside these (walk
  ## children(Type)).
  ##
  ## The third of the four iterators that together cover a Decl:
  ## childDecls / ownExprs / ownTypes, plus children(Type) beneath. Written
  ## once because resolveDeclTypeRefs and mangleDeclTypes were the same list
  ## of field accesses with a different action.
  if d != nil:
    case d.kind
    of dkFn:
      for p in d.fnParams: yield p.typ
      yield d.fnReturnType
    of dkTask:
      for p in d.taskParams: yield p.typ
      yield d.taskReturnType
    of dkFnSig:
      for p in d.sigParams: yield p.typ
      yield d.sigReturn
    of dkType: yield d.typeBody
    of dkObject:
      for f in d.objFields: yield f.typ
    of dkActor:
      for f in d.actorFields: yield f.typ
    of dkPool: yield d.poolElem
    of dkRegistry:
      for v in d.variants:
        for f in v.fields: yield f.typ
    # Nothing to yield. dkRegister's fields are `bit N` ranges, never a
    # user-named type; dkExpr/dkConst/dkStaticAssert carry expressions whose
    # types the expression walk reaches; dkErrors a policy name; dkImport a
    # module path; dkSelect arm bodies; dkSatisfies interface NAMES, resolved
    # by conformance. dkMixin/dkExtern/dkPending/dkInterface/dkWhen hold only
    # members — childDecls reaches those.
    of dkRegister, dkExpr, dkConst, dkStaticAssert, dkErrors, dkImport,
       dkSelect, dkSatisfies, dkMixin, dkExtern, dkPending, dkInterface,
       dkWhen:
      discard

iterator ownExprs*(d: Decl): Expr =
  ## Every expression this declaration owns directly — its body, initializer or
  ## arm bodies. Paired with `childDecls`, these two reach everything under a
  ## Decl, which is what an id walk needs.
  ##
  ## dkSelect is here rather than in childDecls because a select arm holds an
  ## Expr body, not a nested declaration.
  if d != nil:
    case d.kind
    of dkFn: yield d.fnBody
    of dkTask: yield d.taskBody
    of dkConst: yield d.constVal
    of dkExpr: yield d.expr
    of dkStaticAssert: yield d.assertExpr
    of dkSelect:
      for arm in d.selectArms: yield arm.body
    of dkType, dkObject, dkMixin, dkExtern, dkPending, dkWhen, dkInterface,
       dkActor, dkRegistry, dkPool, dkRegister, dkErrors, dkImport, dkFnSig,
       dkSatisfies:
      discard

proc assignIds*(e: Expr, next: var uint32) =
  ## Give every node in this tree an id. Idempotent: a node that already has
  ## one keeps it, so re-running over a partly-built tree is safe.
  ##
  ## The traversal is `children`; only exkChain needs an arm of its own,
  ## because a ChainStep carries its OWN id and is not an Expr, so the
  ## iterator cannot yield it. This used to list all 21 kinds, which is the
  ## same walk `children` exists to stop people writing.
  if e == nil: return
  if not e.id.isSet:
    next.inc
    e.id = NodeId(next)
  if e.kind == exkChain:
    for s in e.steps.mitems:
      if not s.id.isSet:
        next.inc
        s.id = NodeId(next)
  for c in e.children: assignIds(c, next)

proc assignIds*(d: Decl, next: var uint32) =
  ## The declaration itself, then every Expr reachable from it.
  ##
  ## The declaration needs its own id so a reference can point AT it: that is
  ## what turns "which decl is named X" from a scan of the decl list into a
  ## table read.
  if d == nil: return
  inc next
  d.id = NodeId(next)
  # The traversal is childDecls + ownExprs. Kinds with neither — dkSatisfies
  # carries only names, dkRegistry only event shapes — fall out of both
  # iterators and need no arm here.
  for e in d.ownExprs: assignIds(e, next)
  for m in d.childDecls: assignIds(m, next)

# The id supply. SINGLE-WRITER: one thread mints ids, which holds today because
# tuck is built --threads:off (tuck.nim pickFastCC — that flag is also what lets
# tcc, the fastest C backend here, build the runtime at all).
#
# If modules are ever parsed/checked in PARALLEL, this is the first thing that
# breaks, and it breaks SILENTLY: two threads racing `inc` hand out the same
# NodeId, and a duplicate id does not crash — it cross-wires the semantic layer,
# so one node reads another's type or resolved call. Two ways out, both cheap:
#
#   - RANGE-PARTITION: give thread N the id space N shl 24. Collision becomes
#     impossible by construction, NodeId stays 4 bytes.
#   - ATOMIC: fetchAdd on the counter. Simplest, but needs --threads:on.
#
# NOT a UUID. NodeId is a Table key on the compiler's hottest path (codegen
# alone does ~68 semLayer lookups), so 16-byte keys would cost 4x the key width
# and slower hashing to solve a problem partitioning solves for free.
var globalNodeCounter: uint32 = 0

proc assignIds*(m: var Module) =
  ## Give the whole module's expressions their ids. Runs once, right after
  ## parsing, so the semantic layer has a stable key for every source node.
  ##
  ## The counter is PROGRAM-wide, not per-module: a build checks and emits
  ## several modules, and the Resolution table spans all of them, so ids
  ## must not collide across modules.
  for d in m.decls: assignIds(d, globalNodeCounter)

proc clearIds*(e: Expr) =
  ## Drop ids so assignIds hands out fresh ones. Needed when a module comes
  ## back from the AST cache carrying ids from the run that wrote it.
  ## The traversal is `children` — this used to repeat all 21 arms of it.
  if e == nil: return
  e.id = NodeId(0)
  # A chain STEP carries its own id, which is not an Expr and so is not a
  # child. Everything else is reached by the iterator.
  if e.kind == exkChain:
    for s in e.steps.mitems: s.id = NodeId(0)
  for c in e.children: clearIds(c)

proc clearIds*(d: Decl) =
  if d == nil: return
  for e in d.ownExprs: clearIds(e)
  for m in d.childDecls: clearIds(m)

proc clearIds*(m: var Module) =
  for d in m.decls: clearIds(d)

proc newNodeId*(): NodeId =
  ## For nodes minted AFTER parsing (the checker synthesizes calls). Keeps
  ## the invariant that every node can key into the semantic layer.
  globalNodeCounter.inc
  NodeId(globalNodeCounter)
