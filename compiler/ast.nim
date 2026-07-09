# compiler/ast.nim
# Tuck AST node definitions.
# This file contains the core syntax tree shape for the lexer/parser/compiler.

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

  UnaryOp* = enum
    uoNeg
    uoNot
    uoComposition
    uoPropagate  # expr? — pass the error upward; enclosing fn must return !T

  ChainOp* = enum
    coDot
    coDotDot

  ChainStep* = object
    op*: ChainOp
    target*: Expr
    arg*: Expr
    span*: Span

  ExprKind* = enum
    exkLit
    exkVar
    exkField
    exkQualified
    exkStruct
    exkList
    exkCall
    exkChain
    exkBinary
    exkUnary
    exkBlock
    exkIf
    exkMatch
    exkFor
    exkAssign
    exkReturn
    exkRaise
    exkImport

  Expr* = ref object
    span*: Span
    shortcutSite*: string  # set by checker under continue/exit policy: this
                           # statement drops a !T and routes to the handler
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
    of exkQualified:
      modulePath*: seq[string]
      qualName*: string
    of exkStruct:
      fields*: seq[(string, Expr)]
    of exkList:
      items*: seq[Expr]
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

  # A function signature as stored in the .tuck-cache signature index:
  # enough to typecheck an importer without deserializing the module's AST.
  SigInfo* = object
    name*: string
    params*: seq[Param]
    ret*: Type
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
      fnParams*: seq[Param]
      fnReturnType*: Type
      fnEffects*: seq[EffectMarker]
      fnBody*: Expr
      isPending*: bool  # declared in a `pending:` block; body is nil
      isDecision*: bool # parsed from a `decision` table; body is match rows
      isExtern*: bool   # declared in an `extern:` block; implemented by the
                        # runtime (tuck_rt) or, with a header, imported from C
      externHeader*: string # extern [c, header: "uart.h"] — empty = rt-implemented
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
