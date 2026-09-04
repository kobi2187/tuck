# compiler/parser.nim
#
# STAGE 2 OF THE PIPELINE — tokens become a tree. This file handles
# DECLARATIONS: the top level of a program (fn, type, actor, task, mixin,
# pending blocks, extern blocks, decision tables).
#
# Tokens are a flat list, but programs nest: a fn holds statements, a statement
# holds expressions, expressions hold more expressions. The parser builds the
# tree that mirrors that nesting — the AST (Abstract Syntax Tree, defined in
# ast.nim).
#
# "Abstract" means it drops whatever does not change meaning: the parentheses
# you added for readability, the whitespace, the comments. `2 + 3 * 4` becomes
# a tree that already KNOWS the multiply binds tighter, without needing
# parentheses to say so. Precedence stops being a question once it is shape.
#
# WHERE THIS FILE SITS. The grammar splits into layers, each using only the
# ones below it:
#
#   parser_base      peek / advance / expect / error reporting
#      ^
#   parser_expr      expressions and patterns — the recursive core
#      ^
#   parser_type      type expressions: int, {a: int}, !str, Seq[int]
#      ^
#   parser (here)    declarations, and the module as a whole
#
# The one-way dependency is what stops mutual recursion from becoming a knot,
# and it tells you where new syntax belongs: a new type form goes in
# parser_type, a new operator in parser_expr, a new top-level keyword here.
#
# A RULE THIS CODEBASE HOLDS TO: every language construct gets its OWN node
# kind. When `on select` was added it got real exkSelect / dkSelect nodes,
# rather than being encoded as a `match` with a fake subject. Reusing an
# existing node shape is always tempting and always costs more later, because
# every downstream stage then has to know the trick and special-case it.
#
# What this stage does NOT do: it does not care whether anything is CORRECT.
# `"hello" + 5` parses fine — it is well-formed syntax. Rejecting it is the
# typechecker's job. A parser only decides whether the shape is legal.
import strutils, tables
import ast
import ../lexer
import parser_base
export parser_base
import parser_stringify
export parser_stringify
import parser_expr        # expression + pattern grammar (the recursive core)
export parser_expr
import parser_type        # type-expression grammar
import ./parser_decl_kinds
export parser_type

# Forward declaration (parseExpr/parsePattern/parseBlock from parser_expr,
# parseType from parser_type). parseTypeDecl/parseFnSigDecl (extern blocks
# take types; ...and C callback sigs) now live in parser_decl_kinds.nim,
# imported above — the per-DeclKind parsers that never recurse back into
# parseDecl itself (object/actor/arena/errors/mixin/when bodies do, and
# stay here alongside it).
proc parseDecl*(p: var Parser): Decl

# u16 [big_endian] / -> T [io] / !T [error: FsError] — attributes in TYPE-USE
# position (already inside the bracket; caller ate "[")
const MemberStarters = {tkFn, tkLet, tkVar, tkPending, tkOn, tkPlus}
  ## Tokens that begin a MEMBER of an object body rather than a field.

proc parseObjectBodyLine(p: var Parser, fields: var seq[FieldDef],
                         members: var seq[Decl]) =
  ## One line of an object or actor body: a pending hole, a member, an
  ## invariant block, a `satisfies` contract, or a field.
  if p.isPendingHole(): members.add(p.parsePendingHole())
  elif p.current().kind in MemberStarters: members.add(p.parseDecl())
  elif p.current().kind == tkAttr and p.current().value == "invariant":
    p.parseInvariantBlock(members)
  elif p.isSatisfiesLine():
    members.add(p.parseSatisfiesLine(fields.len > 0))
  else:
    fields.add(p.parseObjectField())

proc parseObjectBody(p: var Parser, fields: var seq[FieldDef],
                     members: var seq[Decl]) =
  discard p.expect(tkNewline)
  p.indentedBlock:
    p.parseObjectBodyLine(fields, members)

# arena Name [size: N]: members — bump allocator (spec 7.3)
proc parseArenaDecl(p: var Parser): Decl =
  let spArena = p.getSpan()
  discard p.advance() # eat "arena"
  let name = p.expectTypeName("arena").value
  var attrs: seq[TypeAttr]
  p.parseDeclAttrs(attrs)
  discard p.expect(tkColon)
  var members: seq[Decl]
  discard p.expect(tkNewline)
  while p.current().kind == tkNewline:
    discard p.advance()
  p.indentedBlock:
    members.add(p.parseDecl())
  let arenaType = Type(span: spArena, kind: tkRecord, fields: @[], attrs: attrs)
  return Decl(span: spArena, kind: dkType, name: name, generics: @[], typeBody: arenaType)

proc parseUnhandledHandler(p: var Parser): Decl =
  ## The block's one legal member: `on unhandled({code, site})`.
  if p.current().kind != tkColon: return nil
  discard p.advance()
  discard p.expect(tkNewline)
  while p.current().kind == tkNewline: discard p.advance()
  var handler: Decl = nil
  p.indentedBlock:
    let member = p.parseDecl()
    if member != nil and member.kind == dkFn and member.name == "unhandled":
      handler = member
    else:
      p.reportError("errors block allows only 'on unhandled({code, site})'")
  handler

proc parseErrorsDecl(p: var Parser, sp: Span): Decl =
  discard p.advance() # errors
  let policy = p.parseErrorPolicy()
  Decl(span: sp, kind: dkErrors, name: "errors", policyName: policy,
       errHandler: p.parseUnhandledHandler())

proc parseObjectDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  let name = p.expectTypeName("object").value
  discard p.expect(tkColon)
  var fields: seq[FieldDef]
  var members: seq[Decl]
  p.parseObjectBody(fields, members)
  var sats: seq[string]
  let realMembers = siftSatisfies(members, sats)
  Decl(span: sp, kind: dkObject, name: name, objFields: fields,
       satisfies: sats, objMembers: realMembers)

proc parseActorDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  let name = p.expectTypeName("actor").value
  var attrs: seq[TypeAttr]
  p.parseDeclAttrs(attrs)
  discard p.expect(tkColon)
  var fields: seq[FieldDef]
  var members: seq[Decl]
  p.parseObjectBody(fields, members)
  Decl(span: sp, kind: dkActor, name: name, attrs: attrs,
       actorFields: fields, handlers: members)

proc parseMixinDecl(p: var Parser, sp: Span): Decl =
  discard p.advance()
  let name = p.expectTypeName("mixin").value
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  var members: seq[Decl]
  p.indentedBlock:
    members.add(p.parseDecl())
  Decl(span: sp, kind: dkMixin, name: name, mixinMembers: members)

proc parseWhenDecl(p: var Parser, sp: Span): Decl =
  ## spec §8.3: `when TARGET == "value":` — compile-time platform selection.
  ## v1 supports exactly this one shape (TARGET compared against a single
  ## string literal); it is not a general compile-time boolean expression.
  ## Resolution (which block's decls actually reach the module) happens
  ## later, in modules.resolveWhenBlocks — see the dkWhen comment in ast.nim
  ## for why that has to be a separate, uncached pass.
  discard p.advance()  # eat 'when'
  let targetWord = p.expect(tkIdent, "Expected 'TARGET' after 'when' — " &
    "'when' only supports 'when TARGET == \"...\":'").value
  if targetWord != "TARGET":
    p.reportError("'when' only supports 'when TARGET == \"...\":' — got " &
                  "'when " & targetWord & "'")
  discard p.expect(tkEq, "Expected '==' after 'when TARGET'")
  let valTok = p.expect(tkStrLit,
    "Expected a string literal naming the target, e.g. " &
    "when TARGET == \"stm32f4\":")
  discard p.expect(tkColon)
  discard p.expect(tkNewline)
  var members: seq[Decl]
  p.indentedBlock:
    members.add(p.parseDecl())
  Decl(span: sp, kind: dkWhen, name: "when", whenTargetValue: valTok.value,
       whenDecls: members)

proc contextualDecl(p: var Parser, sp: Span, handled: var bool): Decl =
  ## Declarations introduced by a CONTEXTUAL keyword — a plain ident the lexer
  ## does not tokenize, so the grammar recognises it here by name. Each is
  ## gated on what follows, which is what keeps a variable named `register`
  ## or `pool` parsing as an expression.
  handled = true
  if p.current().kind != tkIdent:
    handled = false
    return nil
  case p.current().value
  # extern: / extern [c, header: "uart.h"]: — signatures implemented by the
  # runtime (tuck_rt) or imported from C. No bodies, no stubs.
  of "extern":
    if p.peek().kind in {tkColon, tkLBracket}: return p.parseExternDecl(sp)
  # Global error policy (spec 4.9): errors [policy: strict|continue|exit]:
  of "errors":
    if p.peek().kind == tkLBracket: return p.parseErrorsDecl(sp)
  of "register": return p.parseRegisterDecl(sp)
  of "pool": return p.parsePoolDecl(sp)
  of "arena": return p.parseArenaDecl()
  # `satisfies Obj: Iface` (spec 5.2) — gated on the object name following, so
  # a variable or field named `satisfies` still parses as an expression.
  of "satisfies":
    if p.peek().kind == tkIdent: return p.parseSatisfiesDecl(sp)
  else: discard
  handled = false

proc parseDecl*(p: var Parser): Decl =
  let sp = p.getSpan()
  let curr = p.current()
  var handled = false
  let contextual = p.contextualDecl(sp, handled)
  if handled: return contextual
  case curr.kind
  of tkDecision:
    return p.parseDecisionDecl(sp)

  of tkFn, tkOn:
    return p.parseFnDecl(sp)

  of tkImport: return p.parseImportDecl(sp)
  of tkPending: return p.parsePendingDecl(sp)
  of tkType: return p.parseTypeDecl(sp)
  of tkObject: return p.parseObjectDecl(sp)
  of tkActor: return p.parseActorDecl(sp)
  of tkTask: return p.parseTaskDecl(sp)
  of tkFnsig: return p.parseFnSigDecl(sp)
  of tkRegistry: return p.parseRegistryDecl(sp)
  of tkStaticAssert: return p.parseStaticAssertDecl(sp)
  of tkDistinct: return p.parseDistinctDecl(sp)
  of tkInterface: return p.parseInterfaceDecl(sp)
  of tkMixin: return p.parseMixinDecl(sp)
  of tkPlus: return p.parseCompositionDecl(sp)
  of tkConst: return p.parseConstDecl(sp)
  of tkWhen: return p.parseWhenDecl(sp)
  of tkIdent: return p.parseExprDecl(sp)
  else: return p.parseExprDecl(sp)

proc parseModule*(p: var Parser): Module =
  ## THE FIRST WORD DECIDES. A module's top level is declarations only, so an
  ## opening word that names no declaration is rejected right here — no
  ## lookahead, no shape-matching, no parsing ahead to find out what it might
  ## have been.
  ##
  ## The check belongs to parseModule rather than parseDecl because parseDecl
  ## is shared: an arena body (parseArenaDecl) calls it for ordinary statements
  ## like `ScratchSpace.reset`, which are legal THERE and only illegal here.
  let sp = p.getSpan()
  var decls: seq[Decl]
  while p.current().kind != tkEOF:
    if p.current().kind == tkNewline:
      discard p.advance()
    else:
      p.failIfNotTopLevelStart()
      decls.add(p.parseDecl())
  result = Module(path: @[], decls: decls, span: sp)
  # identity for the semantic layer, assigned once at the parse boundary
  assignIds(result)
