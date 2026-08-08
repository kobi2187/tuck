# compiler/diagnostics.nim
#
# EVERY DIAGNOSTIC HAS A CODE. `TK-TY41`, `TK-PA07` — a stable identifier a
# user can look up, quote in a bug report, or search for, independent of how
# the message text is worded today.
#
# The code is `TK-` plus a two-letter CATEGORY plus a number within that
# category. The category says which rule was broken, not merely which stage
# noticed:
#
#   LX  lexical      the bytes do not form tokens
#   PA  parse        the tokens do not form the grammar
#   TY  type         a value does not fit where it flows
#   CO  conformance  an object does not keep a `satisfies` promise (spec 5.2)
#   DE  decision     a decision table is incomplete or contradictory (6.1)
#   ST  structure    a declaration is in a place the language does not allow
#   TR  transition   an illegal state transition, or a sealed type constructed
#   CN  const        a `const` is not compile-time data
#   EF  effect       a callee's effects exceed its caller's budget
#   PE  pending      a `pending:` declaration clashes with a real one
#   PO  policy       the `errors [policy: ...]` block is malformed
#   SE  sealed       a sealed type constructed outside its transitions
#   SM  semantic     everything else the checker rejects
#
# NUMBERS ARE PERMANENT. Once a code appears in a release it names that
# diagnostic forever. A diagnostic that is deleted RETIRES its number — the
# number is never reused for something else, because a user who searched for
# TK-TY41 last year must not land on an unrelated rule today. Add new
# diagnostics at the END of their category's block.
#
# The enum is the registry: `tuck explain TK-TY41` reads it, and a code with no
# call site is dead weight the compiler can be asked about.
import std/strutils

type
  DiagCode* = enum
    ## Every diagnostic the compiler can emit, by code. The enum's ORDER is not
    ## meaningful; the number in each name is what a user sees.
    dcNone = "TK-0000"          ## no code assigned yet — see UNCODED below

    # --- LX: lexical ------------------------------------------------------
    dcLxTab = "TK-LX01"                 ## a tab where indentation is expected
    dcLxUnterminatedStr = "TK-LX02"     ## string literal with no closing quote
    dcLxBadChar = "TK-LX03"             ## a byte that begins no token
    dcLxIndent = "TK-LX04"              ## indentation does not match any level
    dcLxNumber = "TK-LX05"              ## malformed numeric literal

    # --- PA: parse --------------------------------------------------------
    dcPaExpectedExpr = "TK-PA01"        ## an expression was required here
    dcPaExpectedToken = "TK-PA02"       ## a specific token was required here
    dcPaNotADeclaration = "TK-PA03"     ## top-level word opens no declaration
    dcPaCallSyntax = "TK-PA04"          ## `f(args)` — calls are postfix
    dcPaDivision = "TK-PA05"            ## bare `/` — write `/i` or `/f`
    dcPaSatisfiesOrder = "TK-PA06"      ## `satisfies` after the object's fields

    # --- TY: type ---------------------------------------------------------
    dcTyMismatch = "TK-TY01"            ## a value does not fit where it flows
    dcTyNoField = "TK-TY02"             ## no such field on that type
    dcTyUndeclared = "TK-TY03"          ## name is neither field nor fn
    dcTyUnhandledResult = "TK-TY04"     ## a !T dropped without handling
    dcTyComposedCollision = "TK-TY05"   ## composition contributes a name twice
    dcTyDuplicateMember = "TK-TY06"     ## field/param/variant declared twice
    dcTyPointerReturn = "TK-TY07"       ## extern returns a memory pointer
    dcTyPointerStored = "TK-TY08"       ## a pointer stored outside the boundary
    dcTyArgMismatch = "TK-TY09"         ## an argument does not fit its param

    # --- CO / DE / ST / TR / CN / EF / PE / PO / SE / SM -------------------
    dcCoNotImplemented = "TK-CO01"      ## a `satisfies` member is missing
    dcCoUnknownIface = "TK-CO02"        ## `satisfies` names no interface
    dcDeGap = "TK-DE01"                 ## a decision table has an uncovered case
    dcDeOverlap = "TK-DE02"             ## two rows match the same input
    dcDeBadValue = "TK-DE03"            ## a cell is not a value of its column
    dcStTopLevel = "TK-ST01"            ## a statement at module top level
    dcStDuplicateDecl = "TK-ST02"       ## two declarations share a name
    dcTrIllegal = "TK-TR01"             ## a transition the type does not allow
    dcCnNotConst = "TK-CN01"            ## `const` initialised at runtime
    dcEfBudget = "TK-EF01"              ## callee's effects exceed the caller's
    dcPeClash = "TK-PE01"               ## `pending:` clashes with a real decl
    dcPoMalformed = "TK-PO01"           ## the errors policy block is malformed
    dcSeConstruction = "TK-SE01"        ## a sealed type built outside a transition
    dcSmOther = "TK-SM01"               ## a semantic rule with no code of its own

const UncodedNote* = """
UNCODED DIAGNOSTICS. `dcNone` exists because codes are being adopted site by
site rather than in one sweep — a diagnostic that has not been assigned one
still reports, just without a code to look up. It is not an error state, and it
is not permanent: the count only goes down.
"""

proc code*(d: DiagCode): string =
  ## The user-facing code, `TK-TY41`. Empty for dcNone, so a message with no
  ## code assigned yet reads exactly as it did before.
  if d == dcNone: "" else: $d

proc categoryName*(d: DiagCode): string =
  ## The human word for a code's category — the same word the messages have
  ## always led with, so a coded diagnostic reads as before plus its code.
  if d == dcNone: return ""
  case ($d)[3 .. 4]
  of "LX": "Lexical"
  of "PA": "Parse"
  of "TY": "Type"
  of "CO": "Conformance"
  of "DE": "Decision"
  of "ST": "Structure"
  of "TR": "Transition"
  of "CN": "Const"
  of "EF": "Effect"
  of "PE": "Pending"
  of "PO": "Policy"
  of "SE": "Sealed"
  else: "Semantic"

proc withCode*(d: DiagCode, msg: string): string =
  ## `Type Error [TK-TY05]: composed field 'x' ...`
  ##
  ## The category word stays: it is what a reader understands without a lookup,
  ## and the code is what they search for. An uncoded diagnostic passes through
  ## untouched, so a message keeps whatever prefix it already wrote itself.
  if d == dcNone: msg
  else: categoryName(d) & " Error [" & $d & "]: " & msg

proc frontEndExplanation(d: DiagCode): string =
  ## LX and PA — the bytes, and the grammar.
  case d
  of dcLxTab:
    "Indentation is spaces only. A tab is rejected rather than assigned a " &
    "width, because any width would be a guess that differs between editors."
  of dcLxUnterminatedStr:
    "A string literal reached the end of the line with no closing quote."
  of dcLxBadChar: "A byte that begins no token in Tuck."
  of dcLxIndent: "The indentation matches no enclosing level."
  of dcLxNumber: "A numeric literal the lexer cannot read."
  of dcPaExpectedExpr:
    "An expression was required at this position and something else was found."
  of dcPaExpectedToken: "A specific token was required at this position."
  of dcPaNotADeclaration:
    "A module's top level holds declarations only. The FIRST word decides " &
    "which declaration follows, so a word that opens none is rejected on the " &
    "spot rather than parsed as a statement — usually a misspelled keyword."
  of dcPaCallSyntax:
    "Calls are postfix in Tuck: `{payload} fnName`, not `fnName(args)`."
  of dcPaDivision:
    "`/` is not an operator. Write `/i` for integer division (truncating) or " &
    "`/f` for float division — the operator names the arithmetic, so the " &
    "result cannot depend on how the operands were inferred."
  of dcPaSatisfiesOrder:
    "A `satisfies` line comes before the object's fields, so what the object " &
    "PROMISES is visible before its data."
  else: ""

proc typeExplanation(d: DiagCode): string =
  ## TY — a value does not fit where it flows.
  case d
  of dcTyMismatch: "A value does not fit where it flows."
  of dcTyNoField: "The receiver's type has no field by that name."
  of dcTyUndeclared:
    "The name resolved to neither a field of the receiver nor a fn in scope. " &
    "A missing `import` is the usual cause."
  of dcTyUnhandledResult:
    "A fallible result (`!T`) was dropped. Bind it, pass it on, or propagate " &
    "it with `?`."
  of dcTyComposedCollision:
    "Composition is set union (spec 4.5), so a field name contributed by two " &
    "members is a conflict. The compiler does not pick a winner: rename one " &
    "at the composition site, `type C = A + B {oldName -> newName}` (2.5)."
  of dcTyDuplicateMember:
    "A field, parameter or variant name appears twice in one declaration."
  of dcTyPointerReturn:
    "An extern may take a pointer INTO memory but never return one, because " &
    "the lifetime of what it addresses is C's and unknowable here. An opaque " &
    "handle — a fieldless extern type — is exempt: nothing to dereference."
  of dcTyPointerStored:
    "A pointer is legal only at the extern boundary, never stored, so none " &
    "outlives the expression that obtained it."
  of dcTyArgMismatch: "An argument does not fit the parameter it fills."
  else: ""

proc ruleExplanation(d: DiagCode): string =
  ## The remaining categories — one declared rule each.
  case d
  of dcCoNotImplemented:
    "An object declaring `satisfies I` must implement every member of I, " &
    "with matching parameter names, types and order (spec 5.2)."
  of dcCoUnknownIface: "`satisfies` names something that is not an interface."
  of dcDeGap: "A decision table leaves a combination of inputs unmatched."
  of dcDeOverlap: "Two rows of a decision table match the same input."
  of dcDeBadValue: "A cell holds something that is not a value of its column."
  of dcStTopLevel:
    "A module's top level is declarations; the runnable program is `fn main`."
  of dcStDuplicateDecl: "Two declarations share one name."
  of dcTrIllegal: "The type does not allow this state transition."
  of dcCnNotConst: "A `const` must be compile-time data."
  of dcEfBudget:
    "A callee's effects must fit inside its caller's declared budget: a pure " &
    "fn cannot call an `[io]` one."
  of dcPeClash: "A `pending:` declaration clashes with a real one."
  of dcPoMalformed: "The `errors [policy: ...]` block is malformed."
  of dcSeConstruction:
    "A sealed type is constructed only through its declared transitions."
  of dcSmOther: "A semantic rule with no code of its own yet."
  else: ""

proc explanationOf*(d: DiagCode): string =
  ## What the code MEANS, beyond what one message said. `tuck explain TK-TY05`
  ## reads this. A message is written for the site that raised it; this is
  ## written for the reader looking the rule up afterwards.
  if d == dcNone: return "No code assigned to this diagnostic yet."
  result = frontEndExplanation(d)
  if result.len == 0: result = typeExplanation(d)
  if result.len == 0: result = ruleExplanation(d)

proc parseCode*(s: string): DiagCode =
  ## Look up a code the user typed — `tuck explain TK-TY01`. Case-insensitive,
  ## and tolerant of a missing `TK-` prefix.
  let want = (if s.toUpperAscii.startsWith("TK-"): s else: "TK-" & s).toUpperAscii
  for d in DiagCode:
    if $d == want: return d
  dcNone
