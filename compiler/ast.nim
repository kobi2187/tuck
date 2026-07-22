# compiler/ast.nim
# Tuck AST node definitions.
# This file contains the core syntax tree shape for the lexer/parser/compiler.

import hashes

type
  Span* = object
    line*: int
    col*: int
    file*: string

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

  VariantDef* = object
    name*: string
    fields*: seq[FieldDef]
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

  Type* = ref object
    span*: Span
    attrs*: seq[TypeAttr]
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

  BinOp* = enum
    boAdd, boSub, boMul, boDiv, boMod
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
    exkImport

  Expr* = ref object
    id*: NodeId
    span*: Span
    shortcutSite*: string  # set by checker under continue/exit policy: this
                           # statement drops a !T and routes to the handler
    ty*: Type              # stamped by the checker (typed AST): codegen reads
                           # it for type-directed lowering; nil = not checked
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
      fields*: seq[(string, Expr)]
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
    of exkImport:
      path*: seq[string]

  LitKind* = enum
    lkInt, lkFloat, lkStr, lkBool, lkUnit

  # Imported type decls are injected into the importer for checking and
  # lowering, marked with this span.file so codegen skips re-emitting them.
const ImportedTypeMarker* = "<imported>"

# The checker's gradual-typing sentinel: undeclared symbols synthesize this
# named type; codegen treats it as "no type information".
const UnknownName* = "<unknown>"

type
  # A function signature as stored in the .tuck-cache signature index:
  # enough to typecheck an importer without deserializing the module's AST.
  SigInfo* = object
    name*: string
    params*: seq[Param]
    ret*: Type
    generics*: seq[string]
    isPending*: bool
    line*: int

  DeclKind* = enum
    dkType
    dkObject
    dkRegistry
    dkFn
    dkMixin
    dkActor
    dkTask
    dkExpr
    dkConst   # compile-time data declaration: const name = <literal data>
    dkRegister
    dkStaticAssert
    dkErrors  # global error policy declaration (spec 4.9)
    dkImport  # import <module> — loads <module>.tuck next to the importer

  Decl* = ref object
    span*: Span
    name*: string
    case kind*: DeclKind
    of dkType:
      generics*: seq[string]
      typeBody*: Type
      typeMembers*: seq[Decl]
    of dkObject:
      objFields*: seq[FieldDef]
      mixins*: seq[string]
      objMembers*: seq[Decl]
    of dkRegistry:
      variants*: seq[VariantDef]
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
      isInline*: bool   # `fn inline name(...)` — codegen hint ({.inline.} / [Inline])
      fnErrorTypes*: seq[string]  # [error: FsError | NetError] — declared error enums
    of dkMixin:
      mixinMembers*: seq[Decl]
    of dkActor:
      attrs*: seq[TypeAttr]
      actorFields*: seq[FieldDef]
      handlers*: seq[Decl]
    of dkTask:
      taskParams*: seq[Param]
      taskReturnType*: Type
      taskEffects*: seq[EffectMarker]
      taskBody*: Expr
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

  Module* = object
    path*: seq[string]
    decls*: seq[Decl]
    span*: Span

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

# --- NodeId: identity for the semantic layer -------------------------------

proc `==`*(a, b: NodeId): bool {.borrow.}
proc hash*(a: NodeId): Hash {.borrow.}
proc `$`*(a: NodeId): string = "n" & $uint32(a)

proc isSet*(a: NodeId): bool = uint32(a) != 0'u32

proc assignIds*(e: Expr, next: var uint32) =
  ## Give every node in this tree an id. Idempotent: a node that already has
  ## one keeps it, so re-running over a partly-built tree is safe.
  if e == nil: return
  if not e.id.isSet:
    next.inc
    e.id = NodeId(next)
  case e.kind
  of exkLit, exkVar, exkQualified, exkImport: discard
  of exkField:
    assignIds(e.receiver, next); assignIds(e.dotArg, next)
  of exkStruct:
    for f in e.fields: assignIds(f[1], next)
  of exkList:
    for it in e.items: assignIds(it, next)
  of exkBracket:
    assignIds(e.brReceiver, next)
    for a in e.brArgs: assignIds(a, next)
  of exkBracketAssign:
    assignIds(e.brTarget, next); assignIds(e.brValue, next)
  of exkCall:
    assignIds(e.callee, next)
    for a in e.args: assignIds(a, next)
  of exkChain:
    assignIds(e.base, next)
    for s in e.steps.mitems:
      if not s.id.isSet:
        next.inc
        s.id = NodeId(next)
      assignIds(s.target, next); assignIds(s.arg, next)
  of exkBinary:
    assignIds(e.left, next); assignIds(e.right, next)
  of exkUnary:
    assignIds(e.operand, next)
  of exkBlock:
    for s in e.stmts: assignIds(s, next)
  of exkIf:
    assignIds(e.cond, next); assignIds(e.thenBranch, next)
    assignIds(e.elseBranch, next)
  of exkMatch:
    assignIds(e.subject, next)
    for arm in e.arms:
      assignIds(arm.guard, next); assignIds(arm.body, next)
  of exkFor:
    assignIds(e.iterable, next); assignIds(e.body, next)
  of exkWhile:
    assignIds(e.whileCond, next); assignIds(e.whileBody, next)
  of exkBreak, exkContinue: discard
  of exkAssign:
    assignIds(e.target, next); assignIds(e.assignVal, next)
  of exkReturn:
    assignIds(e.returnVal, next)
  of exkRaise:
    assignIds(e.raiseVal, next)

proc assignIds*(d: Decl, next: var uint32) =
  ## Every Expr reachable from a declaration.
  if d == nil: return
  case d.kind
  of dkFn: assignIds(d.fnBody, next)
  of dkTask: assignIds(d.taskBody, next)
  of dkConst: assignIds(d.constVal, next)
  of dkExpr: assignIds(d.expr, next)
  of dkStaticAssert: assignIds(d.assertExpr, next)
  of dkType:
    for m in d.typeMembers: assignIds(m, next)
  of dkObject:
    for m in d.objMembers: assignIds(m, next)
  of dkMixin:
    for m in d.mixinMembers: assignIds(m, next)
  of dkActor:
    for h in d.handlers: assignIds(h, next)
  of dkRegistry, dkRegister, dkErrors, dkImport: discard

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
  if e == nil: return
  e.id = NodeId(0)
  case e.kind
  of exkLit, exkVar, exkQualified, exkImport: discard
  of exkField: (clearIds(e.receiver); clearIds(e.dotArg))
  of exkStruct: (for f in e.fields: clearIds(f[1]))
  of exkList: (for it in e.items: clearIds(it))
  of exkBracket:
    clearIds(e.brReceiver)
    for a in e.brArgs: clearIds(a)
  of exkBracketAssign: (clearIds(e.brTarget); clearIds(e.brValue))
  of exkCall:
    clearIds(e.callee)
    for a in e.args: clearIds(a)
  of exkChain:
    clearIds(e.base)
    for s in e.steps.mitems:
      s.id = NodeId(0)
      clearIds(s.target); clearIds(s.arg)
  of exkBinary: (clearIds(e.left); clearIds(e.right))
  of exkUnary: clearIds(e.operand)
  of exkBlock: (for s in e.stmts: clearIds(s))
  of exkIf: (clearIds(e.cond); clearIds(e.thenBranch); clearIds(e.elseBranch))
  of exkMatch:
    clearIds(e.subject)
    for arm in e.arms: (clearIds(arm.guard); clearIds(arm.body))
  of exkFor: (clearIds(e.iterable); clearIds(e.body))
  of exkWhile: (clearIds(e.whileCond); clearIds(e.whileBody))
  of exkBreak, exkContinue: discard
  of exkAssign: (clearIds(e.target); clearIds(e.assignVal))
  of exkReturn: clearIds(e.returnVal)
  of exkRaise: clearIds(e.raiseVal)

proc clearIds*(d: Decl) =
  if d == nil: return
  case d.kind
  of dkFn: clearIds(d.fnBody)
  of dkTask: clearIds(d.taskBody)
  of dkConst: clearIds(d.constVal)
  of dkExpr: clearIds(d.expr)
  of dkStaticAssert: clearIds(d.assertExpr)
  of dkType: (for m in d.typeMembers: clearIds(m))
  of dkObject: (for m in d.objMembers: clearIds(m))
  of dkMixin: (for m in d.mixinMembers: clearIds(m))
  of dkActor: (for h in d.handlers: clearIds(h))
  of dkRegistry, dkRegister, dkErrors, dkImport: discard

proc clearIds*(m: var Module) =
  for d in m.decls: clearIds(d)
