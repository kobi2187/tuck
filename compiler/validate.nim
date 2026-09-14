# compiler/validate.nim
#
# A SECOND grammar for Tuck, written from the spec rather than from the
# parser, used to cross-check the parser. `tuck validate` runs both over the
# same file and reports where they disagree.
#
# WHY A SECOND GRAMMAR. The hand-written parser is a recursive-descent
# program: its grammar is implied by control flow and is therefore impossible
# to read as a whole, which is how edge cases get patched one at a time
# without anyone noticing the rule they broke. A PEG states the grammar as
# data. Where the two disagree, exactly one of three things is true:
#
#   1. the parser accepts something the spec does not describe  (parser bug,
#      or an undocumented extension — the silent kind)
#   2. the parser rejects something the spec describes          (spec drift,
#      or a missing feature)
#   3. the PEG is wrong                                         (fix the PEG)
#
# All three are worth knowing, and none of them are visible from either side
# alone.
#
# ERROR MESSAGES ARE NOT A GOAL. A PEG says yes or no and points at an offset;
# that is all a cross-check needs. The real parser keeps its diagnostics, and
# nothing here is on the path of a normal build.
#
# THE SUBJECT IS THE TOKEN STREAM, NOT THE TEXT. Tuck is indentation
# sensitive, and the lexer already resolves that into tkIndent/tkDedent. Each
# token becomes one symbol word, so the grammar below reads at the same level
# as a spec's EBNF — `fn NAME ( params ) -> type` rather than a soup of
# whitespace rules.
#
# The cost of that choice, stated plainly: the lexer is SHARED, so this
# validates the grammar and not the lexing. A lexer bug is invisible to it.
#
# COVERAGE IS PARTIAL AND SAYS SO. Declarations, signatures and types are
# written out; bodies are accepted as balanced indent blocks. A declaration
# form the grammar does not know is counted and reported rather than passed,
# so the coverage number is honest — an unhelpful validator is one that
# quietly accepts everything.

import npeg, strutils, tables
import ../lexer

proc tokensOf*(source: string): seq[Token] =
  ## The whole token stream, EOF included. Same lexer the parser uses — which
  ## is the deliberate limit of this cross-check: it validates the grammar,
  ## not the lexing.
  var lx = Lexer(source: source, position: 0, line: 1, column: 1,
                 indentStack: @[0])
  while true:
    let t = lx.nextToken()
    result.add(t)
    if t.kind == tkEOF: break

proc symbolize*(toks: seq[Token]): string =
  ## One symbol word per token, space-terminated. `$kind` verbatim rather than
  ## a hand-written table: a mapping would be a second copy of the token enum
  ## and would drift the first time a token is added.
  for t in toks:
    if t.kind == tkEOF: continue
    result.add($t.kind & " ")

type Stats* = object
  ## What the grammar actually covered. Without this the validator is
  ## vacuous: `unknown` accepts any declaration it does not state, so a file
  ## can "agree" while the grammar described none of it.
  ##
  ## COUNTING IS POSITION-KEYED, and that is not a detail. npeg runs a rule's
  ## code block the moment the rule matches, and a PEG backtracks: a plain
  ## `inc` counts every attempt, including the ones an ordered choice threw
  ## away. Measured that way this corpus reported 1519 declarations where it
  ## has 313. So each site records itself under its subject offset and the
  ## last writer at an offset wins — alternatives are tried in order, so the
  ## surviving one is the last to have run there.
  sites*: Table[int, string]
    ## subject offset -> tag: "d:" a declaration, "s:" a statement, then
    ## either "known" or the first token of what escaped
  known*: int      ## declarations a stated rule matched
  unknown*: int    ## declarations that fell through to the escape hatch
  stmts*: int      ## statements a stated rule matched
  stmtEscapes*: int ## statements that fell through
  stmtForms*: seq[string]
    ## the FIRST token of each escaped statement, same purpose one level down
  forms*: seq[string]
    ## the FIRST token of each escaped declaration — the whole point of the
    ## report, since it names which spec constructs are still unwritten here

let tuckGrammar = peg("module", st: Stats):
  # --- lexical shims ------------------------------------------------------
  # A token is a run of non-space characters plus its trailing space. Needed
  # because the subject is a STRING of symbols: npeg's `1` is one character,
  # and a rule wanting "any one token" has to say so.
  tok       <- +(1 - ' ') * ' '
  nl        <- "tkNewline "
  # The lexer emits no tkNewline for a file's LAST line: it goes straight to
  # tkDedent/EOF. A statement rule that demands `nl` therefore fails on the
  # last line of every block that ends the file — which is why every
  # statement ends on `eol`, not on `nl`.
  eol       <- nl | &"tkDedent " | !1
  name      <- "tkIdent " | "tkAttr "

  # A balanced indented block, contents unexamined. This is the seam between
  # what the grammar states and what it defers: everything inside is token
  # soup, so a body is checked for STRUCTURE only.
  # A `##` doc comment is DISCARDED by the lexer but leaves its line's
  # tkNewline, so a header can be followed by several newlines before the
  # block opens — hence `+nl` at every block-taking rule rather than `nl`.
  # `blk` states its STATEMENTS where it can and counts what it cannot — the
  # same honesty the declaration level uses, one layer down. `rawBlk` is the
  # old soup, kept for blocks that are not statement lists at all: a decision
  # table's rows, a register's bit layout, an interface's requirement list.
  rawBlk    <- "tkIndent " * *(rawBlk | (!"tkDedent " * tok)) * "tkDedent "
  blk       <- "tkIndent " * +stmtLine * "tkDedent "
  # A body that holds DECLARATIONS rather than statements — an actor's
  # handlers, a group's requirements, a conditional compilation block. It
  # reuses `decl`, so nested declarations are counted like top-level ones.
  declBlk   <- "tkIndent " * +decl * "tkDedent "
  # A body of MEMBERS: a type's fields, an actor's state, a registry's or sum
  # type's variants. Neither statements nor declarations — its own shape.
  memberBlk <- "tkIndent " * +member * "tkDedent "
  member    <- *nl * (memberCounted | knownCounted | unknownCounted) * *nl
  memberCounted <- >(fieldDecl | variantDecl | composeMember | satisfiesMember |
                     blockMember | ellipsisStmt):
    st.sites[capture[0].si] = "d:known"
  fieldDecl <- name * "tkColon " * typeExpr * *attrs * ?("tkAssign " * expr) * eol
  variantDecl <- "tkPipe " * name * ?params * eol
  # `+ AudioPlayer` — mixin composition, one line per mixin.
  composeMember <- "tkPlus " * typeExpr * eol
  # `satisfies Storable` — conformance. `satisfies` is NOT a keyword to the
  # lexer; it arrives as tkIdent, so this is two identifiers on a line and
  # can only be stated positionally, inside a member block. `fieldDecl` is
  # tried first, so `lane: int` is never mistaken for it.
  satisfiesMember <- word * name * eol
  # `invariant:` and friends: a named block inside a type or actor body.
  # `invariant` lexes as tkAttr, which `name` already covers.
  blockMember <- name * "tkColon " * +nl * blk

  # --- statements ---------------------------------------------------------
  stmtLine  <- *nl * (stmtCounted | unknownStmt) * *nl
  stmtCounted <- >stmt:
    st.sites[capture[0].si] = "s:known"
  unknownStmt <- >(!"tkDedent " * tok * *(!nl * !"tkDedent " * tok) * eol *
                   ?rawBlk):
    st.sites[capture[0].si] = "s:" & ($1).split(' ')[0]

  stmt      <- letStmt | varStmt | returnStmt | ifStmt | forStmt | loopStmt |
               matchStmt | onStmt | deferStmt | finishStmt | ellipsisStmt |
               simpleStmt | transRow | assignStmt | exprStmt
  # spec 7.4: `defer:` + block — statements held back until scope exit.
  # Positional, like `satisfiesMember` and the identifier-headed declarations
  # above: `defer` is not a keyword to the lexer, so it arrives as tkIdent and
  # this grammar can only say WHERE it sits, not what it is called. The shape
  # is unambiguous today because Tuck has no labels (a user ruling), so
  # `<ident>:` opening a block in STATEMENT position is a defer and nothing
  # else.
  deferStmt <- word * "tkColon " * +nl * blk
  # spec 7.4: `finish <handle>, <kind>`. Positional for the same reason —
  # `finish` is not a keyword to the lexer — and stated BEFORE the general
  # expression statements so the comma is read as this form's rather than as
  # whatever an expression might do with one.
  finishStmt<- word * expr * "tkComma " * name * eol
  letStmt   <- ("tkLet " | "tkConst ") * name * ?("tkColon " * typeExpr) *
               "tkAssign " * (matchTail | ifTail | (expr * eol))
  varStmt   <- "tkVar " * name * ?("tkColon " * typeExpr) *
               (("tkAssign " * (matchTail | ifTail | (expr * eol))) | eol)
  returnStmt<- "tkReturn " * ?expr * eol
  # Two shapes share one keyword: a block `if` whose `else` opens a new line,
  # and an inline `if c: a else: b` where the whole thing is one expression.
  ifTail    <- ("tkIf " | "tkElif ") * expr * "tkColon " *
               ((+nl * blk * *elsePart) | (expr * (inlineElse | eol)))
  inlineElse<- ("tkElse " * "tkColon " * expr * eol) |
               ("tkElif " * expr * "tkColon " * expr * (inlineElse | eol))
  ifStmt    <- ifTail
  elsePart  <- *nl * (("tkElif " * expr * "tkColon " * ((+nl * blk) | (expr * eol))) |
                      ("tkElse " * "tkColon " * ((+nl * blk) | (expr * eol))))
  forStmt   <- "tkFor " * ((name * "tkIn " * expr) | expr) * "tkColon " * +nl * blk
  loopStmt  <- "tkLoop " * "tkColon " * +nl * blk
  # Arms are a table, not a statement list — `rawBlk` on purpose, the same
  # deferral the decision-table and register-layout blocks get.
  matchTail <- "tkMatch " * expr * "tkColon " * +nl * rawBlk
  matchStmt <- matchTail
  # An assignment's right side may itself be a block-valued `match`.
  assignStmt<- expr * assignOp * (matchTail | ifTail | (expr * eol))
  assignOp  <- "tkAssign " | "tkPlusAssign " | "tkMinusAssign " |
               "tkStarAssign " | "tkSlashAssign " | "tkSlashIntAssign " |
               "tkSlashFloatAssign "
  # `on select:` is a declaration at file level and a statement inside a body;
  # same form either way. Arms are a table, so `rawBlk`.
  onStmt    <- onForm
  # `...` is the spec's "unwritten body" placeholder. The lexer has no
  # ellipsis token, so it arrives as `..` followed by `.`.
  ellipsisStmt <- "tkDotDot " * "tkDot " * eol
  # `{payload} fn discard` — the trailing `discard` is POSTFIX, like every
  # other call in the language, and it is what says "this result is dropped
  # on purpose" (TK-TY25). Bare `discard` on its own line is `simpleStmt`.
  exprStmt  <- expr * ?"tkDiscard " * eol
  # A row of a `transitions:` table. It can only be stated here, not given
  # its own block rule: the subject is token KINDS, so `transitions` is
  # indistinguishable from any other identifier followed by a colon.
  transRow  <- name * "tkArrow " * name * eol
  simpleStmt<- ("tkBreak " | "tkContinue " | "tkDiscard ") * eol

  # --- expressions --------------------------------------------------------
  # Postfix by construction: a payload precedes the name it applies to
  # (`{a: 1} f`), and every continuation — field, chain-mutate, module
  # qualification, bake — attaches to what is already there.
  expr      <- unary * *(binOp * unary)
  unary     <- *("tkMinus " | "tkNot ") * postfix
  postfix   <- primary * *contin
  contin    <- ("tkDot " * name) |
               ("tkDotDot " * name * ?structLit) |
               ("tkColonColon " * name) |
               ("tkBake " * structLit) |
               # `alias(old: new, ...)` — the one parenthesised argument list
               # in a language with no paren calls. `alias` itself lexes as a
               # plain identifier, so this is a continuation, not a keyword.
               ("tkLParen " * fieldInit * *("tkComma " * fieldInit) *
                "tkRParen ") |
               ("tkLBracket " * expr * *("tkComma " * expr) * "tkRBracket ") |
               structLit |
               name
  primary   <- fnRef | structLit | listLit | parenExpr | literal | name
  fnRef     <- "tkColon " * name * ?("tkColonColon " * name)
  structLit <- "tkLBrace " * ?(fieldInit * *("tkComma " * fieldInit)) * "tkRBrace "
  # A payload field is `name: expr`, or a BARE expression — `{8080}` is the
  # shorthand for `{value: 8080}`, so the field name is optional in a way a
  # `name`-first rule cannot express.
  fieldInit <- (name * "tkColon " * expr) | expr
  listLit   <- "tkLBracket " * ?(expr * *("tkComma " * expr)) * "tkRBracket "
  parenExpr <- "tkLParen " * expr * "tkRParen "
  literal   <- "tkIntLit " | "tkFloatLit " | "tkStrLit " | "tkTrue " |
               "tkFalse " | "tkNone "
  binOp     <- "tkPlus " | "tkMinus " | "tkStar " | "tkPercent " |
               "tkSlashInt " | "tkSlashFloat " | "tkEq " | "tkNeq " |
               "tkLt " | "tkGt " | "tkLte " | "tkGte " | "tkAnd " | "tkOr " |
               "tkRange " | "tkRangeLt "

  # --- types --------------------------------------------------------------
  # `?T` / `!T` / `!?T` prefixes, `T?` / `T!` suffixes, `A[B, C]`
  # application, `A + B` composition, and the record form.
  typeExpr  <- typePrefix * typeAtom * *typeSuffix * *typeCompose
  typePrefix<- *("tkQuestion " | "tkBang " | "tkBangQuestion ")
  typeAtom  <- typeRecord | typeInlineSum | (name * ?typeArgs)
  typeArgs  <- "tkLBracket " * typeExpr * *("tkComma " * typeExpr) * "tkRBracket "
  typeSuffix<- "tkQuestion " | "tkBang " | "tkBangQuestion " |
               ("tkStar " * "tkIntLit ")
  typeCompose <- "tkPlus " * typeAtom
  typeRecord<- "tkLBrace " * ?(fieldDef * *("tkComma " * fieldDef)) * "tkRBrace "
  # An INLINE SUM — `type Color = {Red, Green, Blue}`. Bare variant names, no
  # field types, which is what tells it from a record: ordered after
  # typeRecord so a record's `name:` still wins.
  typeInlineSum <- "tkLBrace " * name * *("tkComma " * name) * "tkRBrace "
  fieldDef  <- name * "tkColon " * typeExpr

  # --- signatures ---------------------------------------------------------
  # A payload group `{a: T, b: U}` or a bare `name: T`; `self` may stand alone.
  params    <- "tkLParen " * ?(paramGroup * *("tkComma " * paramGroup)) * "tkRParen "
  paramGroup<- typeRecord | (name * ?("tkColon " * typeExpr))
  generics  <- "tkLBracket " * genericOne * *("tkComma " * genericOne) * "tkRBracket "
  genericOne<- name * ?("tkColon " * typeExpr)
  retType   <- "tkArrow " * typeExpr
  attrs     <- "tkLBracket " * *(!"tkRBracket " * tok) * "tkRBracket "
  sigTail   <- ?retType * *attrs

  # --- declarations -------------------------------------------------------
  importDecl<- "tkImport " * name * nl
  publicDecl<- "tkPublic " * "tkColon " * +nl * rawBlk
  fnDecl    <- "tkFn " * name * ?generics * params * sigTail * "tkColon " * +nl * ?blk
  # An interface requirement is a signature with no colon and no body.
  fnReqDecl <- "tkFn " * name * ?generics * params * sigTail * eol
  fnSigDecl <- "tkFnsig " * name * ?generics * "tkAssign " * typeExpr *
               ?retType * nl
  groupDecl <- "tkGroup " * name * ?generics * "tkColon " * +nl * declBlk
  ifaceDecl <- "tkInterface " * name * "tkColon " * +nl * declBlk
  # spec 4.6: a type may carry attributes — `type EthernetFrame [packed,
  # align: 2]:`
  typeDecl  <- "tkType " * name * ?generics * *attrs *
               (("tkAssign " * typeExpr * nl) | ("tkColon " * +nl * memberBlk))
  objectDecl<- ("tkObject " | "tkActor " | "tkMixin " | "tkRegistry ") *
               name * *attrs * "tkColon " * +nl * memberBlk
  constDecl <- "tkConst " * name * "tkAssign " * *(!nl * tok) * nl
  taskDecl  <- "tkTask " * name * ?params * sigTail * "tkColon " * +nl * ?blk

  # --- forms whose head word is a plain identifier ------------------------
  # `pool`, `arena`, `register`, `extern`, `errors` and `resource` read as
  # declaration keywords in the spec, and the TokenKind enum even declares
  # tkPool/tkArena/tkRegister — but the lexer emits none of them, so each
  # arrives as tkIdent and is recognised by spelling. Written the same way
  # here, deliberately, so this grammar describes the language as it is
  # LEXED; whether they should be real keywords is a ruling, not a fact.
  word      <- "tkIdent "

  # spec 7.2: `pool NAME = Type [count: N]`
  poolDecl  <- word * name * "tkAssign " * typeExpr * *attrs * nl
  # spec 7.3: `arena NAME [size: N]:` + block
  arenaDecl <- word * name * *attrs * "tkColon " * +nl * rawBlk
  # spec 8.1: `register NAME at ADDR:` + block of bit fields
  regDecl   <- word * name * word * ("tkIntLit " | name) * "tkColon " * +nl * rawBlk
  # THREE forms share one shape: `<word> [attrs]:` opening an opaque block.
  #   `extern:` / `extern [c, header: "x.h"]:`  — signatures (spec 11 / FFI)
  #   `errors [policy: strict]:`                — the global policy (spec 4.9)
  #   `resources [policy: lazy]:`               — the registry kinds (spec 7.4)
  # One rule rather than three identical ones: npeg would never reach the
  # second, and a rule the grammar cannot reach states nothing. Which of the
  # three a given block IS comes from the head word, which this grammar
  # deliberately does not read — it describes the language as it is LEXED, and
  # all three arrive as tkIdent.
  externDecl<- word * *attrs * "tkColon " * +nl * rawBlk
  # spec 5.4: `pending:` — the walking skeleton block
  pendingDecl <- "tkPending " * "tkColon " * +nl * rawBlk
  # spec 4.2: `distinct NAME = Type`
  distinctDecl<- "tkDistinct " * name * "tkAssign " * typeExpr * *attrs * nl
  # spec 8.2
  staticAssertDecl <- "tkStaticAssert " * *(!nl * tok) * nl
  # spec 6.1: `decision NAME(params) -> T:` + table
  decisionDecl <- "tkDecision " * name * ?params * sigTail * "tkColon " * +nl * rawBlk
  # spec 9.3 / Part 10: `on select:`, and the event-registry handler form
  # `on Registry.Event({payload}):`. The payload carries its own tkColon, so
  # the head cannot be scanned as "everything up to the first colon".
  dotted    <- name * *("tkDot " * name)
  # `on select:` arms are a table (`| chan -> {payload}: body`); an event
  # handler's body is an ordinary statement list. One keyword, two bodies.
  onForm    <- "tkOn " * (("tkSelect " * "tkColon " * +nl * rawBlk) |
                          (dotted * ?params * sigTail * "tkColon " * +nl * blk))
  onDecl    <- onForm
  # spec 8.3: `when TARGET == "x":` + block
  whenDecl  <- "tkWhen " * *(!"tkColon " * !nl * tok) * "tkColon " * +nl * declBlk

  known     <- importDecl | publicDecl | fnDecl | fnReqDecl | fnSigDecl | groupDecl |
               ifaceDecl | typeDecl | objectDecl | constDecl | taskDecl |
               pendingDecl | distinctDecl | staticAssertDecl | decisionDecl |
               onDecl | whenDecl |
               poolDecl | arenaDecl | regDecl | externDecl

  # A declaration the grammar does not state. Consumed so the file still
  # parses, and COUNTED by the caller so coverage is reported rather than
  # assumed — see validate().
  # `tok` would happily eat a tkDedent, and an escape hatch that swallows a
  # block terminator unbalances every enclosing block — which showed up as
  # phantom "tkDedent" declarations and forced retries that corrupted the
  # coverage count. An unstated declaration is a LINE plus an opaque block.
  unknown   <- +(!nl * !"tkDedent " * tok) * nl * ?rawBlk

  decl      <- *nl * (knownCounted | unknownCounted) * *nl
  knownCounted   <- >known:
    st.sites[capture[0].si] = "d:known"
  unknownCounted <- >unknown:
    st.sites[capture[0].si] = "d:" & ($1).split(' ')[0]
  # A file ending inside an indented block closes it at EOF, so the stream can
  # end with dedents that belong to no declaration. Allowed here rather than
  # inside `blk`, which must stay balanced.
  # Stray dedents are skipped between TOP-LEVEL declarations only: a block
  # this grammar defers on leaves its terminators behind. `decl` itself must
  # not skip them, or a nested one eats the dedent that closes its own block.
  module    <- *nl * *(decl * *("tkDedent " | nl)) * !1

type Verdict* = enum
  vOk          ## the grammar accepts this file
  vRejected    ## the grammar rejects it — parser and spec disagree

proc validateTokens*(toks: seq[Token]): (Verdict, int, Stats) =
  ## Run the spec grammar over a token stream. Returns the verdict and how
  ## many symbols were consumed, which locates a rejection well enough to
  ## find the construct by hand.
  let subject = symbolize(toks)
  var st = Stats()
  let m = tuckGrammar.match(subject, st)
  for _, tag in st.sites:
    let form = tag[2 .. ^1]
    if tag[0] == 'd':
      if form == "known": inc st.known
      else:
        inc st.unknown
        if form notin st.forms: st.forms.add(form)
    else:
      if form == "known": inc st.stmts
      else:
        inc st.stmtEscapes
        if form notin st.stmtForms: st.stmtForms.add(form)
  if m.ok and m.matchLen >= subject.len: (vOk, m.matchLen, st)
  else: (vRejected, m.matchLen, st)

proc tokenAt*(toks: seq[Token], symbolOffset: int): Token =
  ## The token a symbol offset lands on, for reporting. Walks the same
  ## encoding symbolize produces rather than guessing from the offset.
  var at = 0
  for t in toks:
    if t.kind == tkEOF: continue
    at += ($t.kind).len + 1
    if at > symbolOffset: return t
  if toks.len > 0: toks[^1] else: Token()
