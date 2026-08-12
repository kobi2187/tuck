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
    dcLxIndentWidth = "TK-LX06"         ## a step in that is not exactly 2 spaces
    dcLxNumber = "TK-LX05"              ## malformed numeric literal

    # --- PA: parse --------------------------------------------------------
    dcPaExpectedExpr = "TK-PA01"        ## an expression was required here
    dcPaExpectedToken = "TK-PA02"       ## a specific token was required here
    dcPaNotADeclaration = "TK-PA03"     ## top-level word opens no declaration
    dcPaCallSyntax = "TK-PA04"          ## `f(args)` — calls are postfix
    dcPaDivision = "TK-PA05"            ## bare `/` — write `/i` or `/f`
    dcPaSatisfiesOrder = "TK-PA06"      ## `satisfies` after the object's fields
    dcPaStrayIndent = "TK-PA07"         ## indented line with nothing open above

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
    dcTyCondNotBool = "TK-TY10"         ## an if/loop condition is not bool
    dcTyBranchDisagree = "TK-TY11"      ## if/match branches yield different types
    dcTyNotExhaustive = "TK-TY12"       ## a match leaves a variant unhandled
    dcTyImmutable = "TK-TY13"           ## assigning to something declared `let`
    dcTyBadIndex = "TK-TY14"            ## an index is not an int, or not one index
    dcTyParamMutation = "TK-TY15"       ## `..` on a parameter (a value, not a var)

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

    # --- AC / IV / RG / RE: the DECLARATION side ---------------------------
    # Call sites were well checked long before declarations were: `send`,
    # task results, decision rows and transitions all validate, while the
    # things they refer TO — an actor's queue, an invariant's predicate, the
    # registry, a register's bit layout — were walked by nobody. Everything
    # here is a rule the spec already states; the codes are what makes the
    # rejection Tuck's rather than the backend's.
    dcAcQueueSize = "TK-AC01"           ## an actor's [queue: N] is not a positive count
    dcIvUnknownField = "TK-IV01"        ## an invariant names a field the type lacks
    dcIvNotBool = "TK-IV02"             ## an invariant predicate is not a bool
    dcRgUnknownEvent = "TK-RG01"        ## raise/handle names no declared event
    dcRgPayload = "TK-RG02"             ## an event payload does not match its variant
    dcRgNoHandler = "TK-RG03"           ## a declared event nothing handles
    dcRgSelfRaise = "TK-RG04"           ## a handler raises the event it handles
    dcRgDuplicate = "TK-RG05"           ## more than one registry in a program
    dcReReadOnly = "TK-RE01"            ## writing a field declared [read]
    dcReWriteOnly = "TK-RE02"           ## reading a field declared [write]
    dcReBitRange = "TK-RE03"            ## a bit index outside the register's width
    dcReOverlap = "TK-RE04"             ## two fields claim the same bit

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

proc lexExplanation(d: DiagCode): string =
  ## LX — the bytes do not form tokens.
  case d
  of dcLxTab:
    "Indentation is spaces only. A tab is rejected rather than assigned a " &
    "width, because any width would be a guess that differs between editors."
  of dcLxUnterminatedStr:
    "A string literal reached the end of the line with no closing quote."
  of dcLxBadChar: "A byte that begins no token in Tuck."
  of dcLxIndent:
    "This line's indentation does not line up with any block it could be in. " &
    "Fix: match it to the block you meant — either the one above, or a level " &
    "you have already closed."
  of dcLxIndentWidth:
    "Going one level in is exactly two spaces. This line went in by a " &
    "different amount. Fix: use two spaces per level. Tuck fixes the width " &
    "because indentation is structure here — if any amount nested, two files " &
    "that look different could be the same program."
  of dcLxNumber: "A numeric literal the lexer cannot read."
  else: ""

proc parseExplanation(d: DiagCode): string =
  ## PA — the tokens do not form the grammar.
  case d
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
    "PROMISES is visible before its data. Fix: move the `satisfies` line above " &
    "the first field."
  of dcPaStrayIndent:
    "This line is indented, but there is nothing above it to be inside of. " &
    "Usually the declaration it belongs to is missing, or its name is " &
    "misspelled so the compiler never opened a block. Fix: check the line " &
    "above — it should be a declaration ending in `:`."
  else: ""

proc nameExplanation(d: DiagCode): string =
  ## TY — the name does not resolve, or the shape does not carry it.
  case d
  of dcTyNoField:
    "That type has no field by this name. Fix: check the spelling, and check " &
    "you are reading the value you think you are — the type is named in the " &
    "message."
  of dcTyUndeclared:
    "The name is neither a field of the value on the left nor a function in " &
    "scope. Fix: check the spelling first, then whether the module declaring " &
    "it is imported — a helper like `ms` lives in std/time and needs " &
    "`import time`."
  of dcTyComposedCollision:
    "Composition is set union (spec 4.5), so a field name contributed by two " &
    "members is a conflict. The compiler does not pick a winner: rename one " &
    "at the composition site, `type C = A + B {oldName -> newName}` (2.5)."
  of dcTyDuplicateMember:
    "A field, parameter or variant name appears twice in one declaration. " &
    "Fix: rename one of them."
  else: ""

proc pointerExplanation(d: DiagCode): string =
  ## TY — the extern boundary, where unsafe types are allowed and nowhere else.
  case d
  of dcTyPointerReturn:
    "An extern may take a pointer INTO memory but never return one, because " &
    "the lifetime of what it addresses is C's and unknowable here. Fix: have " &
    "the binding return `str` or `Seq[u8]` and copy in the implementation. An " &
    "opaque handle — a fieldless extern type — is exempt: nothing to " &
    "dereference, so nothing to outlive."
  of dcTyPointerStored:
    "A pointer is legal only at the extern boundary, never stored, so none " &
    "outlives the expression that obtained it. Fix: copy what you need out of " &
    "it — into a `str` or a `Seq[u8]` — and keep that instead."
  else: ""

proc controlFlowExplanation(d: DiagCode): string =
  ## TY — the types a control-flow construct requires of its parts.
  case d
  of dcTyCondNotBool:
    "A condition must be a `bool`. Fix: compare something — `if n > 0:` " &
    "rather than `if n:`. Tuck has no truthiness, so a number or a string is " &
    "never a yes/no on its own."
  of dcTyBranchDisagree:
    "Every branch of an `if` or `match` used as a VALUE has to produce the " &
    "same type, because the whole expression has one type. Fix: make the " &
    "branches agree, or use it as a statement and return from each branch."
  of dcTyNotExhaustive:
    "A `match` has to cover every variant. Fix: add the missing arms — they " &
    "are named in the message. Tuck has no catch-all `else` here on purpose: " &
    "when a new variant is added later, this error is what finds every place " &
    "that has to handle it."
  else: ""

proc valueFitExplanation(d: DiagCode): string =
  ## TY — a value does not fit the position it reached.
  case d
  of dcTyMismatch:
    "A value's type is not the one this position needs. Fix: convert it, or " &
    "change the declaration to the type you actually meant. Tuck does not " &
    "convert silently — a widening you did not ask for is a bug you cannot see."
  of dcTyImmutable:
    "This name was declared with `let`, so it cannot be reassigned. Fix: use " &
    "`var` if it really does change, or bind a new name for the new value."
  of dcTyParamMutation:
    "A parameter is a VALUE the caller handed you, not a variable you own, " &
    "so `..` cannot mutate it — otherwise a function that looks like it only " &
    "reads (`{acct, fee} afterFee`) could quietly change the caller's record. " &
    "Fix: copy it first and return the copy — `var s = <param>`, chain on " &
    "`s`, `return s` — which is what every mutator in the corpus already " &
    "does. An object member mutating its own `self`, or an actor mutating " &
    "its own fields, is a different thing and stays legal: that is state the " &
    "callee owns."
  of dcTyBadIndex:
    "An index must be a single `int`. Fix: check the value's type, and pass " &
    "exactly one index — `xs[i]`, not `xs[i, j]`."
  of dcTyUnhandledResult:
    "A function that can fail returned `!T`, and the result was thrown away " &
    "— so a failure would pass unnoticed. Fix: bind it with `let` and check " &
    "`.ok`, hand it to something that handles it, or add `?` to pass the " &
    "failure up to your own caller."
  of dcTyArgMismatch:
    "An argument does not fit the parameter it fills. Fix: the message names " &
    "both types — convert the value, or change the parameter."
  else: ""

proc typeExplanation(d: DiagCode): string =
  ## TY — grouped by what the reader was doing when it fired.
  result = nameExplanation(d)
  if result.len == 0: result = pointerExplanation(d)
  if result.len == 0: result = controlFlowExplanation(d)
  if result.len == 0: result = valueFitExplanation(d)

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
  of dcAcQueueSize:
    "An actor's `[queue: N]` is the exact capacity of its mailbox ring, so N " &
    "must be a positive whole number. Zero or negative is not a smaller " &
    "mailbox, it is a broken one — the emitted ring divides by its capacity, " &
    "so the program builds and then dies on the first send. Fix: give a real " &
    "count, or drop the attribute to take the default."
  of dcIvUnknownField:
    "An `invariant:` predicate may only name fields of the type it is " &
    "declared in — it runs wherever a value of that type is produced, where " &
    "nothing else is in scope. Fix: check the spelling, or add the field."
  of dcIvNotBool:
    "An `invariant:` predicate has to be a yes/no about the value, so it " &
    "must be a `bool`. Fix: compare something — `value <= 100` rather than " &
    "`value + 1`. Tuck has no truthiness, so a number is never a condition."
  of dcRgUnknownEvent:
    "`raise` and `on` may only name variants the `registry` declares, so the " &
    "whole event surface stays readable from the declaration plus its " &
    "handlers. Fix: check the spelling, or add the variant to the registry."
  of dcRgPayload:
    "An event's payload has to match the fields its registry variant " &
    "declares. Fix: pass exactly those fields — the variant's declaration is " &
    "the contract every raise site is checked against."
  of dcRgNoHandler:
    "Every declared event needs at least one handler: an event nothing " &
    "listens to is a signal that silently goes nowhere, which is the failure " &
    "the one-registry design exists to prevent. Fix: add an `on " &
    "<Registry>.<Event>` handler, or remove the variant."
  of dcRgSelfRaise:
    "A handler may not raise the event it handles — that is an infinite " &
    "loop, and raising is synchronous, so it is an immediate one. Fix: raise " &
    "a different event, or do the work directly."
  of dcRgDuplicate:
    "One `registry` per program (spec Part 10). The point is that the entire " &
    "event surface is readable in one place; two registries means two places " &
    "and no guarantee they agree. Fix: merge them into one."
  of dcReReadOnly:
    "This register field is declared `[read]`, so writing it is a compile " &
    "error — on real hardware the write is either ignored or has a side " &
    "effect nobody wrote down. Fix: check the datasheet; if it really is " &
    "writable, declare it `[read, write]`."
  of dcReWriteOnly:
    "This register field is declared `[write]`, so reading it is a compile " &
    "error — a write-only field reads back as something undefined. Fix: keep " &
    "the value you wrote in a variable, or declare the field `[read, write]` " &
    "if the hardware supports it."
  of dcReBitRange:
    "A register field's bits must fit inside the register's width. Fix: " &
    "check the bit numbers against the datasheet — an index past the end " &
    "silently reads or writes nothing on hardware."
  of dcReOverlap:
    "Two fields of one register claim the same bit, so writing one would " &
    "corrupt the other. Fix: check the bit ranges — this is almost always a " &
    "transcription slip from the datasheet."
  else: ""

proc explanationOf*(d: DiagCode): string =
  ## What the code MEANS, beyond what one message said. `tuck explain TK-TY05`
  ## reads this. A message is written for the site that raised it; this is
  ## written for the reader looking the rule up afterwards.
  if d == dcNone: return "No code assigned to this diagnostic yet."
  result = lexExplanation(d)
  if result.len == 0: result = parseExplanation(d)
  if result.len == 0: result = typeExplanation(d)
  if result.len == 0: result = ruleExplanation(d)


proc parseCode*(s: string): DiagCode =
  ## Look up a code the user typed — `tuck explain TK-TY01`. Case-insensitive,
  ## and tolerant of a missing `TK-` prefix.
  let want = (if s.toUpperAscii.startsWith("TK-"): s else: "TK-" & s).toUpperAscii
  for d in DiagCode:
    if $d == want: return d
  dcNone

proc explainCode*(code: string): string =
  ## Explain a code given as a STRING — what an error carries, and what a user
  ## pastes back. The lexer reports codes as strings (it sits below this module
  ## and cannot import the enum), so this is the lookup both sides share.
  explanationOf(parseCode(code))
