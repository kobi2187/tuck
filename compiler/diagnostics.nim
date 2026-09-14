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
#   AC  actor        an actor declaration the runtime could not honour (9.1)
#   ME  memory       a pool or arena whose size/count is not a real footprint
#   IV  invariant    an `invariant:` predicate that cannot mean anything (4.7)
#   RG  registry     the event registry's rules (Part 10)
#   RE  register     a memory-mapped register's layout or access mode (8.1)
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
    dcLxBadEscape = "TK-LX07"           ## an escape sequence Tuck does not define

    # --- PA: parse --------------------------------------------------------
    dcPaExpectedExpr = "TK-PA01"        ## an expression was required here
    dcPaExpectedToken = "TK-PA02"       ## a specific token was required here
    dcPaNotADeclaration = "TK-PA03"     ## top-level word opens no declaration
    dcPaCallSyntax = "TK-PA04"          ## `f(args)` — calls are postfix
    dcPaDivision = "TK-PA05"            ## bare `/` — write `/i` or `/f`
    dcPaSatisfiesOrder = "TK-PA06"      ## `satisfies` after the object's fields
    dcPaStrayIndent = "TK-PA07"         ## indented line with nothing open above
    dcPaReservedWord = "TK-PA08"        ## a reserved word used as a plain name
    dcPaEmptyBlock = "TK-PA09"          ## a `:` opens nothing — no `discard`, no statement
    dcPaNoWhile = "TK-PA10"             ## `while` — Tuck spells it `for <cond>:`
    dcPaWordOperator = "TK-PA11"        ## `mod`/`div` — Tuck spells them `%`/`/i`
    dcPaHostKeyword = "TK-PA12"         ## a param or field named after a backend's keyword
    dcPaCallInPayload = "TK-PA13"       ## a payload call nested inside a payload
    dcPaChainAfterPayloadCall = "TK-PA14" ## `..` chained straight onto a bare
                                          ## `{payload} fn` call (parse-time;
                                          ## the `.field` sibling case needs
                                          ## name resolution — see TK-TY23)

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
    dcTyUninitRead = "TK-TY16"          ## reading a field the construction skipped
    dcTyInfiniteType = "TK-TY17"        ## a type contains itself by value
    dcTyDroppedValue = "TK-TY18"        ## a call's value is dropped in statement position
    dcTyMissingReturnValue = "TK-TY19"  ## bare `return` where a value is required
    dcTyUntypedEmptyList = "TK-TY20"    ## `[]` with nothing to say what it holds
    dcTyNoSuchField = "TK-TY21"         ## `with` naming a field the record has not got
    dcTyVariantPayload = "TK-TY22"      ## a sum variant's payload does not match its declaration
    dcTyChainAfterPayloadCall = "TK-TY23" ## `.field` chained straight onto a
                                          ## bare `{payload} fn` call's result —
                                          ## the fn's own name resolves to a
                                          ## plain top-level fn, not a value
                                          ## with fields, so this can only be a
                                          ## chain onto the call, not a slot call
    dcTyErrNeedsList = "TK-TY24"        ## a fn raises but declares no
                                        ## `[error: ...]` list
    dcTyUninspectedWrapper = "TK-TY25"  ## a `?T`/`!T` bound and never read
    dcTyCtorFieldType = "TK-TY26"       ## a construction field does not fit its
                                        ## declared type
    dcTyMemberShadowsFn = "TK-TY27"     ## one name is both an object's member
                                        ## and a top-level fn

    # --- CO / DE / ST / TR / CN / EF / PE / PO / SE / SM -------------------
    dcCoNotImplemented = "TK-CO01"      ## a `satisfies` member is missing
    dcCoUnknownIface = "TK-CO02"        ## `satisfies` names no interface
    dcCoNotAnObject = "TK-CO03"         ## `satisfies` subject is not an object
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
    dcCxComplexity = "TK-CX01"          ## a fn has too many independent paths
    dcCxLines = "TK-CX02"               ## a fn spans too many source lines
    dcSmOther = "TK-SM01"               ## a semantic rule with no code of its own

    # --- AC / IV / RG / RE: the DECLARATION side ---------------------------
    # Call sites were well checked long before declarations were: `send`,
    # task results, decision rows and transitions all validate, while the
    # things they refer TO — an actor's queue, an invariant's predicate, the
    # registry, a register's bit layout — were walked by nobody. Everything
    # here is a rule the spec already states; the codes are what makes the
    # rejection Tuck's rather than the backend's.
    dcAcQueueSize = "TK-AC01"           ## an actor's [queue: N] is not a positive count
    dcAcHandlerReturn = "TK-AC02"       ## a handler declares a return type; actors cannot reply yet
    dcMeSizeCount = "TK-ME01"           ## a pool/arena size or count is not positive
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
    dcRsUnknownKind = "TK-RS01"         ## [resource: k] names no declared kind
    dcRsDuplicateKind = "TK-RS02"       ## two `resources:` blocks declare one kind
    dcRsUndeclared = "TK-RS03"          ## a caller does not declare a kind it acquires

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
  of "CX": "Complexity"
  of "RS": "Resource"
  else: "Semantic"

const WarningCodes* = {dcTyMemberShadowsFn}
  ## Codes that REPORT without stopping the build. Kept beside the registry
  ## rather than inferred from the category letters, because severity is a
  ## property of the individual diagnostic and not of its category — TY holds
  ## both. `tuck explain` reads this so it cannot label a warning "Error".

proc severityOf*(d: DiagCode): string =
  if d in WarningCodes: "Warning" else: "Error"

proc withSeverity*(d: DiagCode, severity, msg: string): string =
  ## `Type Error [TK-TY05]: ...` / `Type Warning [TK-TY27]: ...`
  ##
  ## The category word stays: it is what a reader understands without a lookup,
  ## and the code is what they search for. An uncoded diagnostic passes through
  ## untouched, so a message keeps whatever prefix it already wrote itself.
  if d == dcNone: msg
  else: categoryName(d) & " " & severity & " [" & $d & "]: " & msg

proc withCode*(d: DiagCode, msg: string): string =
  withSeverity(d, "Error", msg)

type PendingWarning* = tuple[msg: string, line, col: int]

var warnings*: seq[PendingWarning]
  ## Diagnostics that do NOT stop the build.
  ##
  ## Module-level for the same reason `fail` raises: a warning is reported
  ## from deep inside the checker, where threading a collector through every
  ## proc would touch far more than the warning is worth. Drained once by the
  ## driver, which is the only thing that knows the FILE the line belongs to.

proc warn*(d: DiagCode, msg: string, line, col: int) =
  ## Report without stopping. Deduplicated on the exact text and position, so
  ## a checker path reached twice does not say the same thing twice.
  let w: PendingWarning = (withSeverity(d, "Warning", msg), line, col)
  if w notin warnings: warnings.add(w)

proc takeWarnings*(): seq[PendingWarning] =
  ## Hand over what has accumulated and reset, so a second check in the same
  ## process does not re-report the first one's findings.
  result = warnings
  warnings = @[]

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
  of dcLxBadEscape:
    "A backslash in a string literal begins an escape, and this is not one " &
    "Tuck defines. The whole set is \\\\, \\\", \\n, \\t, \\r and \\0. " &
    "An unknown escape is rejected rather than passed through, because " &
    "passing it through would hand the backslash to whichever backend built " &
    "the program and let the same source mean different things on each."
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
  of dcPaReservedWord:
    "This word belongs to the language, so it cannot also be a name. " &
    "Reservation is total — a keyword is reserved everywhere, which is what " &
    "keeps `pending:` and `when TARGET == \"...\"` decidable no matter what " &
    "the surrounding code declares. Fix: choose another name. (Attribute " &
    "names like `error` and `priority` are NOT restricted here: they are " &
    "reserved only inside brackets, so they stay usable as fields, " &
    "parameters and function names.)"
  of dcPaEmptyBlock:
    "A `:` opened a block with nothing inside it — no statement, and no " &
    "`discard`. An empty body reads as an accident (a stray blank line, a " &
    "forgotten implementation) rather than a deliberate no-op, so it is " &
    "never inferred either way. Fix: write `discard` if doing nothing here " &
    "is intentional, or add the statement that was meant to go here."
  of dcPaCallInPayload:
    "A payload field holds a VALUE — a literal, a name, a field read, an " &
    "expression over those. A call nested inside one goes to a `let` first, " &
    "so it has a name and a place: `let b = {value: v} u8` and then " &
    "`{items: xs, value: b} push`. A nested record LITERAL is still fine " &
    "(`{point: {x: 1, y: 2}} Thing`) — what is refused is a `{...}` applied " &
    "to a callee. Besides reading better, this makes a whole class of " &
    "performance bug unwriteable: `xs = {items: xs, ...} push` appends IN " &
    "PLACE, but the same call nested inside a construction does not, and " &
    "alloc.string shipped quadratic for exactly that reason."
  of dcPaChainAfterPayloadCall:
    "`{payload} fnName` is a complete statement's worth of value on its " &
    "own — a call or a construction, nothing more may follow the same " &
    "closing brace. Bind it to a `let` first, then chain from the name: " &
    "`let r = {x: v} f` and then `r..step {..}`, not `{x: v} f..step {..}`."
  of dcTyChainAfterPayloadCall:
    "`{payload} fnName.field` reads as `{payload} c.op` (a call THROUGH a " &
    "fnsig-typed slot) unless `fnName` cannot possibly hold one — a plain " &
    "top-level `fn` has no fields at all, so the only other reading left " &
    "is a call chained onto ITS result: `{payload} fnName` first, `.field` " &
    "second. Bind it to a `let` first, then chain from the name: " &
    "`let r = {x: v} f` and then `r.field`, not `{x: v} f.field`. Not only " &
    "style: this shape used to reach codegen as one expression and skip " &
    "verifying the call's OWN arguments against its declared params entirely."
  of dcPaHostKeyword:
    "A PARAMETER or a FIELD may not be named after a keyword of any backend " &
    "Tuck emits to. Every other user name gets a `tuck_` prefix that cannot " &
    "clash, but these two keep the name you wrote — so `fn replace({t: str, " &
    "what: str, with: str})` emitted `string tuck_replace(string t, string " &
    "what, string with)` and dmd answered \"found `with` when expecting " &
    "`)`\", and `type T:` with a field `out` emitted `out*: string`, which " &
    "nim refuses the same way. Both halves matter together: a payload field " &
    "binds to a parameter BY NAME, so a field you could declare but never " &
    "pass would be a worse hole than either one alone. " &
    "The word is refused here rather than renamed for you, so the emitted " &
    "code keeps saying what the source says. The list is MEASURED against " &
    "dmd, nim and odin rather than copied from their manuals: `body` and " &
    "`string` are not on it, because those hosts accept them. Fix: choose " &
    "another name."
  of dcTyErrNeedsList:
    "A fn whose body contains `err` must name the enums it can raise, in its " &
    "effect bracket: `[io, error: FsError | NetError]`. The list is not " &
    "decoration — it is what the compiler validates BOTH sides against. A " &
    "raise site is checked against it (`err AccesDenied` is caught as a typo " &
    "only because the list says which enum to look in), and so is the " &
    "CONSUMER's `match r.err`: an arm naming a variant that exists nowhere " &
    "used to be accepted when the producer declared no list, and emitted " &
    "`of Wibble:` straight into the host compiler. Re-raising (`err r.err`) " &
    "counts as raising — the caller still needs to know what can come out. " &
    "Fix: add `[error: <Enum>]`, listing every enum this fn can return."
  of dcTyUninspectedWrapper:
    "A `?T` or `!T` was bound to a name and then never read. Dropping one in " &
    "statement position was already an error (TK-TY04); KEEPING it and " &
    "ignoring it was not, which is the same mistake with a name attached — " &
    "and it is exactly the shape that forgets to check whether a pool handed " &
    "out a slot, on the exhaustion path nobody tests. " &
    "Reading it in ANY way discharges this: guard it (`if r.ok:`), pass it " &
    "on, return it, store it. Only ignoring it entirely is left. A `?T` " &
    "PARAMETER is exempt — that value is the caller's choice to pass, and a " &
    "callee that hands it straight through never reads it either."
  of dcTyMemberShadowsFn:
    "One name is declared both as an object's own member and as a top-level " &
    "fn. Both are reachable and they are different functions: a call through " &
    "a RECEIVER (`b.noise`) reaches the member, and a call that NAMES the fn " &
    "(`{n: 41} noise`) reaches the top-level one. That is not an error — it " &
    "is worth saying out loud, because the two read alike and picking the " &
    "wrong one compiles."
  of dcTyCtorFieldType:
    "A field given in a construction does not fit the type the declaration " &
    "gives it. This was unchecked: the value rode to codegen and only the " &
    "BACKEND's compiler objected, in generated code the author never wrote."
  of dcPaWordOperator:
    "`mod` and `div` are word-operators in Nim, Pascal and Python; in Tuck " &
    "they are `%` and `/i`. Left alone, a bare word between two operands " &
    "parses as a POSTFIX CALL on the left one (`a mod b` becomes `mod(a)`) " &
    "and the right operand is silently dropped — the expression typechecks " &
    "and emits wrong code, which is why this is rejected outright. Fix: " &
    "`a % b` for modulo, `a /i b` for truncating integer division, `a /f b` " &
    "for float division."
  of dcPaNoWhile:
    "Tuck has no `while` keyword — `while` is an ordinary, unreserved " &
    "identifier, so `while cond:` parses `while` as a bare name and then " &
    "fails on what follows. `for` covers both counted and conditional " &
    "loops: `for x in 1 .. 10:` counts, and `for <condition>:` (no `in`) " &
    "is the while-equivalent — it lowers straight to a native while loop. " &
    "Fix: `for i < 10:` instead of `while i < 10:`."
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
  of dcTyInfiniteType:
    "A type that contains itself by value has no finite size — every value " &
    "would hold another one. Tuck has no references, so a field IS its " &
    "value and the cycle is real rather than a matter of representation.\n\n" &
    "A recursive SUM does not land here. Its variants end the chain — the " &
    "ones that do not recur are the base cases — so the compiler gives each " &
    "recursive edge a handle and `| Add({left: Expr, right: Expr})` simply " &
    "works. A handle rather than a pointer, so a subtree stays a VALUE: two " &
    "parents holding the same child hold two children, and editing one " &
    "cannot reach the other.\n\n" &
    "What still lands here: a RECORD containing itself, which has no variant " &
    "to end the chain — make it a sum, or hold the recursive part as " &
    "`Seq[T]` by hand. And `Array[N, T]` anywhere in the cycle, which stores " &
    "N values INLINE and so is not a handle at all."
  of dcTyUntypedEmptyList:
    "An empty list literal carries no element type, and nothing around it " &
    "supplies one. A list takes its type from its first item, or from the " &
    "place it is going (a parameter or field declared `Seq[T]`), and `var " &
    "xs = []` has neither — the emitted code would be an untyped empty " &
    "sequence the backend cannot name. Fix: seed it with the first element " &
    "(`var xs = [firstItem]`), or pass it straight into the `Seq[T]` " &
    "position that gives it a type. There is no local type annotation to " &
    "write instead."
  of dcTyVariantPayload:
    "A `Type.Variant {payload}` construction supplies the fields that variant " &
    "DECLARES, and only those, each at its declared type. This went " &
    "unchecked for a long time — the payload of a variant construction was " &
    "never synthesized at all, so a wrong type and a misspelled name both " &
    "passed, and the emitted code then read the payload through whichever " &
    "variant happened to declare that field first. Fix: check the name and " &
    "the type against the variant's declaration."
  of dcTyNoSuchField:
    "`with` is the copy-modify-return shortcut: it copies the receiver, " &
    "replaces the fields you name, and hands back the SAME type — which is " &
    "what lets `return self with {done: true}` satisfy `-> Task`. So every " &
    "name must already be a field of that record and keep its declared " &
    "type; a grown shape would no longer be the type the receiver was. Fix: " &
    "check the spelling against the type's declaration, or use `merge`, " &
    "which is the combinator that widens a record on purpose."
  of dcTyMissingReturnValue:
    "A bare `return` in a fn that declares a value type would hand back " &
    "whatever the backend zero-inits, which is the same thing TK-TY16 " &
    "refuses for a field nobody set: a zero is not a value. It stays legal " &
    "where the type SAYS so — `void` and `!void` carry nothing, and `?T`/" &
    "`!?T` lower a bare return to `tnone`, because absence is a declared " &
    "state there. Fix: return a value, or declare the return type `?T` if " &
    "\"nothing to return\" is a real outcome for this fn."
  of dcTyDroppedValue:
    "A call in statement position produced a value nothing receives. The " &
    "result is computed and thrown away, which is almost always a mistake — " &
    "and where it is not, saying so keeps the reader from having to guess. " &
    "Fix: bind it (`let x = ...`), return it, or write `discard` after it to " &
    "say the drop is deliberate. A fn returning `void` is unaffected, and a " &
    "fallible `!T` has its own rule (TK-TY04), which is stricter."
  of dcTyUninitRead:
    "The construction did not supply this field and nothing has assigned it " &
    "since, so there is no value to read — only whatever the backend would " &
    "zero-init. Partial construction is deliberately legal (it is how the " &
    "builder pattern works: construct, fill by chain, then read), so the " &
    "error is the READ, not the omission — a field you never read is fine. " &
    "Fix: set it first (`c.field = ...` or `c ..field {...}`), or declare it " &
    "`T?` if absence is a real state the type should carry. The marker is " &
    "compile-time only; nothing about it reaches the emitted code."
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
  of dcCoNotAnObject:
    "`X satisfies I` attaches a contract to an OBJECT — the promise is " &
    "recorded on that object's declaration, and dispatch reads it from " &
    "there. A primitive has no declaration to record it on, and neither " &
    "does a plain `type` record: only `object` declares members, and a " &
    "contract with no members to check is not a contract. To give a " &
    "primitive interface-like behaviour, wrap it in an object with the " &
    "primitive as a field, or pass a `fnsig` slot instead of a contract."
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
  of dcCxComplexity:
    "A fn has more independent paths through it than the size budget allows " &
    "(one per if, loop, `and`/`or`, match guard and `?`, plus one). Reported " &
    "worst-first on a normal build; fails a `--release` build. Split it, or " &
    "raise the limit with `--max-complexity:N` (`:0` disables). A `match` or " &
    "`on select` costs nothing for the construct itself — dispatching over " &
    "many variants is free; only what the arms DO is counted."
  of dcCxLines:
    "A fn spans more source lines than the size budget allows, counted from " &
    "its first line to its last. Reported worst-first on a normal build; " &
    "fails a `--release` build. Split it, or raise the limit with " &
    "`--max-fn-lines:N` (`:0` disables). Match and select arm bodies, and " &
    "`decision` tables, do not count toward the total."
  of dcSmOther: "A semantic rule with no code of its own yet."
  of dcMeSizeCount:
    "A `pool`'s `count` and an `arena`'s `size` ARE the allocation — the " &
    "footprint is fixed at compile time, which is the entire point of both " &
    "(spec 7.2, 7.3). So the number must be positive: zero or negative is " &
    "not a smaller reservation, it is one that cannot hold anything. Fix: " &
    "give a real count or size."
  of dcAcHandlerReturn:
    "A handler declared a return type, but an actor message is " &
    "fire-and-forget (spec 9.1) and there is no reply channel: correlation " &
    "tokens are designed and not implemented. The declared type therefore " &
    "promises something nothing can deliver — before this was rejected, the " &
    "value was assigned to a local the emitter then discarded. Fix: drop the " &
    "return type and expose the value as a public field the caller reads " &
    "(`Counter.total`), or have the caller pass its own address and send a " &
    "message back."
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
  of dcRsUnknownKind:
    "`[resource: k]` must name a kind some `resources:` block declares " &
    "(spec §7.4) — the same rule an `[error: E]` follows for an error enum. " &
    "Kinds are an open set: any module may declare its own, so the fix is " &
    "either a typo in the marker or a missing `resources:` line."
  of dcRsDuplicateKind:
    "Two `resources:` blocks declare the same kind. Kinds accumulate across " &
    "the program, so the second block's knobs would silently lose to the " &
    "first's — cap, policy and sweep batch all belong to ONE table. Fix: " &
    "pick one owner for the kind, or give them distinct names."
  of dcRsUndeclared:
    "A fn calling an acquire site must declare the kind itself, exactly as " &
    "it must declare an effect it reaches (spec §3.7 — explicit, not " &
    "inferred). Fix: add `[resource: k]` to this fn's own bracket, or " &
    "finish the handle here so it does not escape."
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

const ForeignSpellings*: seq[tuple[foreign, tuck, note: string]] = @[
  # Word operators and keywords other languages have and Tuck spells
  # differently. The parser rejects these by shape before they can silently
  # mis-parse; the entries here are what makes the message say the RIGHT
  # spelling rather than just "unexpected".
  ("mod", "%", "modulo is an operator, not a word"),
  ("div", "/i", "integer division truncates; `/f` divides as float"),
  ("while", "for <condition>:", "`for` covers counted AND conditional loops"),
  ("elseif", "elif", ""),
  # Function names someone reaches for from another stdlib. These reach the
  # user through the CHECKER's undeclared-name path, which is where a wrong
  # guess actually lands.
  ("print", "printLine", "std/console; `print` exists too, without the newline"),
  ("println", "printLine", "std/console"),
  ("puts", "printLine", "std/console"),
  ("toString", "toStr", "std/str"),
  ("str", "toStr", "std/str"),
  ("format", "toStr", "std/str, plus `+` to concatenate"),
  ("length", "len", "on a Seq"),
  ("size", "len", "on a Seq"),
  ("count", "len", "on a Seq"),
  ("append", "push", "std/seq — value semantics, it RETURNS the grown seq"),
  ("add", "push", "std/seq — value semantics, it RETURNS the grown seq"),
  ("split", "splitLines", "std/str splits on newlines only, for now"),
  ("contains", "containsChar", "std/str, for a length-1 str"),
  ("indexOf", "containsChar", "std/str only answers yes/no, for now"),
  ("charCodeAt", "ord", "std/str"),
  ("chr", "charAt", "std/str — a length-1 str, there is no char type"),
  ("readFileSync", "readFile", "std/fs"),
  ("writeFileSync", "writeFile", "std/fs"),
  ("mkdir", "makeDir", "std/fs — creates parents, idempotent"),
  ("exists", "fileExists", "std/fs"),
  ("random", "rollRange", "std/random, over a Dice you thread yourself"),
  ("rand", "rollRange", "std/random"),
  ("now", "nowMs", "std/time"),
  ("sleep", "sleepMs", "std/time"),
  ("abs", "", "not in std yet — std/math has sqrt and pow only"),
  ("floor", "", "not in std yet — std/math has sqrt and pow only"),
  ("min", "", "not in std yet"),
  ("max", "", "not in std yet"),
  ("sort", "", "not in std yet — std/seq has at/setAt/push"),
  ("result", "", "no implicit result — return a value, or bind a local"),
  # Names that exist in most stdlibs and not (yet) in this one. Saying so
  # outright beats "not declared", which reads as a typo the user has to go
  # hunting for.
  ("map", "", "no iterator combinators in std yet — write a `for` loop"),
  ("filter", "", "no iterator combinators in std yet — write a `for` loop"),
  ("reduce", "", "no iterator combinators in std yet — write a `for` loop"),
  ("each", "", "iteration is `for x in xs:`"),
  ("foreach", "", "iteration is `for x in xs:`"),
  ("join", "", "not in std yet — `+` concatenates two strs"),
  ("concat", "+", "`+` concatenates two strs"),
  ("trim", "", "not in std yet — std/str has toStr/charAt/containsChar/splitLines/ord"),
  ("upper", "", "no case conversion in std yet"),
  ("lower", "", "no case conversion in std yet"),
  ("substring", "", "not in std yet — charAt reads one character"),
  ("slice", "", "not in std yet — charAt reads one character"),
  ("parseInt", "", "no string-to-number parsing in std yet"),
  ("toInt", "", "no string-to-number parsing in std yet"),
  ("printf", "", "build the str with `+` and toStr, then printLine"),
  ("sprintf", "toStr", "std/str, plus `+` to concatenate"),
  ("assert", "static_assert", "compile-time only; `invariant:` states a runtime one"),
  ("panic", "", "no runtime abort in std — an unhandled `!T` reports itself"),
  # A builtin that is real but POSTFIX, so the prefix spelling reads as an
  # undeclared name.
  ("echo", "", "`echo` is postfix: write `x echo`, not `echo x`"),
]
  ## What someone reasonably typed -> what Tuck calls it. One table, so a
  ## wrong guess gets the same answer wherever it surfaces (the parser for
  ## keywords and operators, the checker for fn names) instead of each site
  ## inventing its own hint or, worse, saying nothing.

proc spellingHint*(name: string): string =
  ## "Did you mean" text for a name Tuck doesn't have, or "" when the name
  ## isn't one anybody has been observed to reach for. Kept as a suffix the
  ## caller appends, so each diagnostic keeps its own phrasing.
  for (foreign, tuck, note) in ForeignSpellings:
    if foreign != name: continue
    if tuck.len == 0:
      return " — Tuck has no `" & name & "`" &
             (if note.len > 0: " (" & note & ")" else: "")
    return " — did you mean `" & tuck & "`?" &
           (if note.len > 0: " (" & note & ")" else: "")
  ""
