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

import npeg, strutils
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
  known*: int      ## declarations a stated rule matched
  unknown*: int    ## declarations that fell through to the escape hatch
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
  name      <- "tkIdent " | "tkAttr "

  # A balanced indented block, contents unexamined. This is the seam between
  # what the grammar states and what it defers: everything inside is token
  # soup, so a body is checked for STRUCTURE only.
  # A `##` doc comment is DISCARDED by the lexer but leaves its line's
  # tkNewline, so a header can be followed by several newlines before the
  # block opens — hence `+nl` at every block-taking rule rather than `nl`.
  blk       <- "tkIndent " * *(blk | (!"tkDedent " * tok)) * "tkDedent "

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
  publicDecl<- "tkPublic " * "tkColon " * +nl * blk
  fnDecl    <- "tkFn " * name * ?generics * params * sigTail * "tkColon " * +nl * ?blk
  fnSigDecl <- "tkFnsig " * name * ?generics * "tkAssign " * typeExpr *
               ?retType * nl
  groupDecl <- "tkGroup " * name * ?generics * "tkColon " * +nl * blk
  ifaceDecl <- "tkInterface " * name * "tkColon " * +nl * blk
  # spec 4.6: a type may carry attributes — `type EthernetFrame [packed,
  # align: 2]:`
  typeDecl  <- "tkType " * name * ?generics * *attrs *
               (("tkAssign " * typeExpr * nl) | ("tkColon " * +nl * blk))
  objectDecl<- ("tkObject " | "tkActor " | "tkMixin " | "tkRegistry ") *
               name * *attrs * "tkColon " * +nl * blk
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
  arenaDecl <- word * name * *attrs * "tkColon " * +nl * blk
  # spec 8.1: `register NAME at ADDR:` + block of bit fields
  regDecl   <- word * name * word * ("tkIntLit " | name) * "tkColon " * +nl * blk
  # `extern:` / `extern [c, ...]:` — a block of signatures (spec 11 / FFI)
  externDecl<- word * *attrs * "tkColon " * +nl * blk
  # spec 5.4: `pending:` — the walking skeleton block
  pendingDecl <- "tkPending " * "tkColon " * +nl * blk
  # spec 4.2: `distinct NAME = Type`
  distinctDecl<- "tkDistinct " * name * "tkAssign " * typeExpr * *attrs * nl
  # spec 8.2
  staticAssertDecl <- "tkStaticAssert " * *(!nl * tok) * nl
  # spec 6.1: `decision NAME(params) -> T:` + table
  decisionDecl <- "tkDecision " * name * ?params * sigTail * "tkColon " * +nl * blk
  # spec 9.3 / Part 10: `on select:`, and the event-registry handler form
  # `on Registry.Event({payload}):`. The payload carries its own tkColon, so
  # the head cannot be scanned as "everything up to the first colon".
  dotted    <- name * *("tkDot " * name)
  onDecl    <- "tkOn " * ("tkSelect " | dotted) * ?params * "tkColon " * +nl * blk
  # spec 8.3: `when TARGET == "x":` + block
  whenDecl  <- "tkWhen " * *(!"tkColon " * !nl * tok) * "tkColon " * +nl * blk

  known     <- importDecl | publicDecl | fnDecl | fnSigDecl | groupDecl |
               ifaceDecl | typeDecl | objectDecl | constDecl | taskDecl |
               pendingDecl | distinctDecl | staticAssertDecl | decisionDecl |
               onDecl | whenDecl |
               poolDecl | arenaDecl | regDecl | externDecl

  # A declaration the grammar does not state. Consumed so the file still
  # parses, and COUNTED by the caller so coverage is reported rather than
  # assumed — see validate().
  unknown   <- +(!nl * tok) * nl * ?blk

  decl      <- *nl * (knownCounted | unknownCounted) * *nl
  knownCounted   <- known:
    inc st.known
  unknownCounted <- >unknown:
    inc st.unknown
    let head = ($1).split(' ')[0]
    if head notin st.forms: st.forms.add(head)
  # A file ending inside an indented block closes it at EOF, so the stream can
  # end with dedents that belong to no declaration. Allowed here rather than
  # inside `blk`, which must stay balanced.
  module    <- *nl * *decl * *("tkDedent " | nl) * !1

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
