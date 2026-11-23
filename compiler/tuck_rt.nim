# compiler/tuck_rt.nim
## Shared Tuck compiler runtime implementation for static environments.
import std/bitops
import std/macros
import std/typetraits
import ./tuck_mem
export tuck_mem   # tuckDrop, tuckMove, tuckCopy, …: what emitted code calls
import ./tuck_sl
export tuck_sl    # frames and stages: `--concurrency:stackless` (#216)
when defined(freestanding):
  proc tuckRegisterFlush*(a, b: pointer, c: pointer) = discard
  proc tuckFlushStaged*() = discard
  proc tuckFlushDueStaged*() = discard
  proc tuckAwaitRoom*(handle: pointer, actor: string) = discard
import std/strutils
import std/tables as stdtables
import std/math as stdmath

type
  TuckStatus* = enum
    ## How a fallible or optional result came out: a value, an error code, or
    ## absence.
    tsOk, tsErr, tsAbsent
  TuckResult*[T] = object
    ## The runtime shape of `!T`, `?T` and `!?T`: a status, the 16-bit error code
    ## when it failed, and the value when it succeeded.
    status*: TuckStatus
    err*: uint16   # app-wide error code; meaningful only when status == tsErr
    value*: T

# --- the text of a float --------------------------------------------------
# ONE rule on every backend (A67, ruled 2026-10-22), so the runtime writes the
# text itself rather than taking the host's: Python's `repr`. The shortest
# digits that read back as the same value; fixed notation for a decimal
# exponent from -4 to 15, keeping `.0` on a whole number (`1.0`, `100.0`);
# otherwise `1e+22`, `1.2e-05`; `nan`, `inf`, `-inf`, `-0.0`. The digits come
# from C's snprintf("%.*e") and strtod, which all three runtimes call, so
# they cannot differ; the layout below is written out identically in
# tuckrt/tuck_rt.odin and tuckrt_d/tuck_rt.d.
proc cSnprintf(buf: cstring, n: csize_t, frmt: cstring): cint
  {.importc: "snprintf", header: "<stdio.h>", varargs.}
proc cStrtod(s: cstring, rest: ptr cstring): cdouble
  {.importc: "strtod", header: "<stdlib.h>".}

proc tuckFloatLayout(neg: bool, digitsIn: string, exp: int): string =
  ## Shortest digits `d1d2...` meaning d1.d2... x 10^exp, laid out.
  var digits = digitsIn
  while digits.len > 1 and digits[^1] == '0': digits.setLen(digits.len - 1)
  let n = digits.len
  var body = ""
  if exp >= -4 and exp < 16:
    if exp >= 0:
      if n <= exp + 1:
        body = digits & repeat('0', exp + 1 - n) & ".0"
      else:
        body = digits[0 .. exp] & "." & digits[exp + 1 .. ^1]
    else:
      body = "0." & repeat('0', -exp - 1) & digits
  else:
    body = digits[0 .. 0]
    if n > 1: body.add("." & digits[1 .. ^1])
    let e = abs(exp)
    body.add(if exp < 0: "e-" else: "e+")
    if e < 10: body.add('0')
    body.add($e)
  if neg: "-" & body else: body

proc tuckShortestE(x: float64, single: bool): string =
  ## `x` as C's "%.*e" at the fewest digits that read back as `x` (as an f32,
  ## when `single`): `1.2e-05`, `1e+00`.
  var buf: array[64, char]
  for p in 0 .. 17:
    discard cSnprintf(cast[cstring](addr buf[0]), 64, "%.*e", cint(p), x)
    let back = float64(cStrtod(cast[cstring](addr buf[0]), nil))
    if (single and float32(back) == float32(x)) or (not single and back == x):
      break
  $cast[cstring](addr buf[0])

proc tuckSplitE(text: string): tuple[digits: string, exp: int] =
  ## `-1.25e+03` -> ("125", 3): the mantissa's digits and the exponent.
  var i = 0
  if text[i] == '-': inc i
  while i < text.len and text[i] != 'e':
    if text[i] != '.': result.digits.add(text[i])
    inc i
  result.exp = parseInt(text[i + 1 .. ^1])

proc tuckFloatText*(x: float64, single: bool): string =
  ## The text of a float (see above). `single`: the value is an f32, whose
  ## shortest digits are the ones that read back as the same f32.
  if x != x: return "nan"
  if x == Inf: return "inf"
  if x == NegInf: return "-inf"
  let neg = x < 0.0 or (x == 0.0 and 1.0 / x < 0.0)
  if x == 0.0: return (if neg: "-0.0" else: "0.0")
  let (digits, exp) = tuckSplitE(tuckShortestE(x, single))
  tuckFloatLayout(neg, digits, exp)

proc toStr*[T](value: T): string =
  ## Any value as its string form: a float by the one rule above, anything
  ## else through Nim's `$`.
  when T is float32: tuckFloatText(float64(value), true)
  elif T is float64: tuckFloatText(value, false)
  else: $value

# `{.inline.}` is a hint, and the C compiler declined it: `tuckAt` stayed a call
# at hundreds of thousands of sites in fannkuch, a third of its instructions.
# These are a compare, a branch and a load; every call to one is meant to be
# the access itself. (24.0M instructions against 42.3M for fannkuch 8.)
{.pragma: hot, codegenDecl: "static inline __attribute__((always_inline)) $# $#$#".}

proc tuckOutOfBounds(index, length: int, op: string) {.noinline, noreturn.} =
  ## The cold half of tuckSeqBounds: the message is built only on failure,
  ## out of line, so the check itself is small enough to inline.
  when defined(freestanding):
    discard index
    discard length
    discard op
    tuckFatal("index out of bounds")
  else:
    raise newException(IndexDefect,
      op & ": index " & $index & " out of bounds for seq of length " & $length)

proc tuckSeqBounds(index, length: int, op: string) {.inline, hot.} =
  ## Raises IndexDefect unless `0 <= index < length`; `op` names the access.
  ##
  ## Bounds are a PRECONDITION: violating one is a program error,
  ## reported with the caller's file/line, not an error value the caller matches.
  ##
  ## INLINE, with the failure out of line: every `xs[i]` in a loop is a call
  ## to tuckAt/tuckSetAt, and with the message built here they were too big
  ## to inline even under LTO — 40% of fannkuch's time was the calls
  ## themselves (benches/game).
  when defined(freestanding):
    # Straight to the board from the inlined check, so the trap's LR is the
    # access site in the Tuck fn rather than a runtime helper.
    if index < 0 or index >= length: tuckFatal("index out of bounds")
  else:
    if index < 0 or index >= length: tuckOutOfBounds(index, length, op)

{.push boundChecks: off.}
# The bounds are checked once, by tuckSeqBounds; Nim's own check on the index
# below would be a second, identical one.
proc tuckAt*[T](items: seq[T], index: int): lent T {.inline, hot.} =
  ## What `xs[i]` lowers to: a bounds-checked read.
  ##
  ## A BORROW (`lent`), not a copy. By value, reading an element that owns
  ## storage copied all of it — and a recursive edge (lowering_recursive reads
  ## `e.left` as `tuckAt(e.left, 0)`) owns the whole subtree, so a tree walk
  ## copied every subtree it passed through: 0.25 s against 0.011 s on a
  ## 2^15-leaf tree (benches/SCORES.md, "Trees"). A caller that keeps the
  ## element (`var x = xs[i]`) still gets its own copy.
  ##
  ## `xs[i]` bracket sugar lowers to tuckAt/tuckSetAt, NOT to std/seq's `at` —
  ## brackets are grammar, so they must work without `import seq`, and the
  ## reserved `tuck` prefix (same convention as tuckConcat/tuckSat above) is
  ## what keeps them from colliding with a user's own `fn at`. std/seq.tuck's
  ## `at`/`setAt` stay as the explicit spelling and delegate here.
  tuckSeqBounds(index, items.len, "at")
  items[index]
{.pop.}

proc at*[T](items: seq[T], index: int): T =
  ## std/seq's explicit `at`: the same bounds-checked read as `xs[i]`.
  tuckAt(items, index)

proc charAt*(s: string, index: int): string =
  ## The character at `index` as a one-character string. Out of range is a
  ## program error, like any index.
  tuckSeqBounds(index, s.len, "charAt")
  $s[index]

proc containsChar*(s: string, ch: string): bool =
  ## Does `s` contain the substring `ch`?
  strutils.contains(s, ch)

proc splitLines*(s: string): seq[string] =
  ## `s` split at line breaks (`\n`, `\r\n`), without the breaks.
  strutils.splitLines(s)

proc ord*(ch: string): int =
  ## The byte value of a string's first character. An empty string is an
  ## out-of-bounds read.
  tuckSeqBounds(0, ch.len, "ord")
  system.ord(ch[0])

{.push boundChecks: off.}
proc tuckSetAt*[T](items: var seq[T], index: int, value: T) {.inline.} =
  ## What `xs[i] = v` lowers to: a bounds-checked write, in place.
  tuckSeqBounds(index, items.len, "setAt")
  tuckReplace(items[index], value)   # the old element is dropped, `value` kept
{.pop.}

proc setAt*[T](items: var seq[T], index: int, value: T) =
  ## std/seq's explicit `setAt`: the same bounds-checked write as
  ## `xs[i] = v`.
  tuckSetAt(items, index, value)

{.push boundChecks: off.}
proc tuckAtU*[T](items: seq[T], index: int): lent T {.inline, hot.} =
  ## `xs[i]` with its loop's guard already holding (bounds_guard): no check.
  items[index]

proc tuckSetAtU*[T](items: var seq[T], index: int, value: T) {.inline.} =
  ## `xs[i] = v` under a guard; the elements own nothing, so a plain store.
  items[index] = value
{.pop.}

proc tuckArrayAt*[N: static int, T](items: array[N, T], index: int): lent T {.inline, hot.} =
  ## A bounds-checked read of a fixed `Array[N, T]`.
  ##
  ## `Array[N, T]` needs its OWN pair, separate from tuckAt/tuckSetAt above.
  ## core.array's `at`/`setAt` cannot be plain Tuck functions using `items[i]`:
  ## the bracket-index dispatch (typecheck.nim's indexCallee) routes to whatever
  ## `fn at` is in scope, which — inside `at`'s OWN body — is `at` itself. A
  ## Tuck-body `at` for Array[N, T] self-recurses infinitely rather than
  ## indexing. std/seq.tuck's `at`/`setAt` dodge this because THIS proc, not a
  ## Tuck fn, is what the bracket actually lowers to; core.array's `at`/`setAt`
  ## must be `extern` declarations bound to these, with no Tuck body to recurse
  ## in — same shape, one container over.
  tuckSeqBounds(index, N, "at")
  items[index]

proc tuckArraySetAt*[N: static int, T](items: var array[N, T], index: int,
                                       value: T) {.inline, hot.} =
  ## A bounds-checked write into a fixed `Array[N, T]`, in place; the length
  ## is the type's `N`.
  tuckSeqBounds(index, N, "setAt")
  tuckReplace(items[index], value)

# Value semantics: `items` is copied on return, same as any other Tuck
# record/seq — growing the result never mutates the caller's seq, unlike
# setAt's in-place write through a `var` receiver.
#
# No sibling `len` extern: a top-level `proc len*[T](items: seq[T]): int`
# in THIS module makes every seq operation inside tuck_rt.nim itself —
# `add`, `newSeq`, `setLen`, all of which expand unqualified `len(x)` deep
# in Nim's own seqs_v2.nim templates — an ambiguous call between
# `system.len` and this module's own `len`. Not the readFile-style
# caller-side collision (that one is dodgeable by qualifying the call
# site); this one fires from inside tuck_rt.nim's own module scope no
# matter how a caller spells it, so there is no workaround short of not
# declaring it. `Seq.len`'s existing accidental-UFCS behavior (TODO.md §3)
# is the only way to get a count today.
proc getLength*[T](x: T): int =
  ## Behind `len`. Named so nothing can be ambiguous with it: a runtime proc
  ## actually called `len` collides with `system.len` at every unqualified
  ## `.len` in this module. FULLY GENERIC on purpose — `len` has to answer for
  ## a Seq AND a str, which a `seq[T]`-only signature cannot.
  system.len(x)

proc count*[T](items: seq[T]): int =
  ## PROTOCOLS.md's verb for "how many". Named `count` rather than `len`
  ## precisely so it does not make every unqualified `len` in this module
  ## ambiguous — see std/seq.tuck.
  system.len(items)

proc byteCount*(s: string): int =
  ## A string's length in BYTES (UTF-8 code units), not characters.
  s.len

proc fromBytes*(bytes: seq[uint8]): string =
  ## A string whose bytes are exactly `bytes`, uninterpreted.
  result = newString(bytes.len)
  for i, b in bytes: result[i] = char(b)

proc byteAt*(s: string, index: int): uint8 =
  ## The byte at `index`; out of range is a program error.
  tuckSeqBounds(index, s.len, "byteAt")
  uint8(s[index])

proc joinStr*(parts: seq[string], sep: string): string =
  ## One pass, one allocation path — `acc = acc & part` in a loop is O(n^2).
  parts.join(sep)

proc push*[T](items: seq[T], value: T): seq[T] =
  ## `items` with `value` appended, as a NEW seq: the caller's seq is
  ## unchanged (value semantics).
  result = items
  tuckPush(result, value)

# --- bit operations -------------------------------------------------------
#
# Tuck has no bitwise OPERATORS. `|` is already sum-variant syntax, and a
# word operator is refused outright (TK-PA11: `mod`/`div` "parses as a postfix
# call and silently drops the right operand"), so the spelling of `&`/`^`/`<<`
# is a language-surface question with no answer yet.
#
# These are the answer that needs no syntax: ordinary postfix calls, declared
# in std/bits.tuck exactly the way std/seq.tuck declares at/setAt. Everything
# that wants bits — core.num's whole bitset half, core.hash's FNV-1a fold —
# is written against these, and swapping in real operators later changes no
# caller that used them.
#
# u64 throughout: bit work is on the widest unsigned type, and Tuck's own
# `int` is signed, where a shift would be arithmetic rather than logical.
proc bitAnd*(a, b: uint64): uint64 {.inline.} =
  ## Bitwise AND.
  a and b
proc bitOr*(a, b: uint64): uint64 {.inline.} =
  ## Bitwise OR.
  a or b
proc bitXor*(a, b: uint64): uint64 {.inline.} =
  ## Bitwise exclusive OR.
  a xor b
proc bitNot*(a: uint64): uint64 {.inline.} =
  ## Bitwise complement of all 64 bits.
  not a

proc shiftLeft*(a: uint64, by: int): uint64 {.inline.} =
  ## A shift at or past the width is 0, not undefined. C leaves `x << 64`
  ## undefined and the three backends inherit that from their own codegen, so
  ## the guard is here rather than in each of them.
  if by >= 64 or by < 0: 0'u64 else: a shl by

proc shiftRight*(a: uint64, by: int): uint64 {.inline.} =
  ## Logical right shift; a shift at or past the width is 0, as for
  ## `shiftLeft`.
  if by >= 64 or by < 0: 0'u64 else: a shr by

proc popCount*(a: uint64): int {.inline.} =
  ## The number of set bits.
  countSetBits(a)

proc leadingZeros*(a: uint64): int {.inline.} =
  if a == 0: 64 else: countLeadingZeroBits(a)

proc trailingZeros*(a: uint64): int {.inline.} =
  if a == 0: 64 else: countTrailingZeroBits(a)

proc rotateLeft*(a: uint64, by: int): uint64 {.inline.} =
  ## Rotation by `by` modulo 64.
  let n = by and 63
  if n == 0: a else: (a shl n) or (a shr (64 - n))

proc rotateRight*(a: uint64, by: int): uint64 {.inline.} =
  let n = by and 63
  if n == 0: a else: (a shr n) or (a shl (64 - n))

proc byteSwap*(a: uint64): uint64 {.inline.} =
  var r = 0'u64
  for i in 0 ..< 8:
    r = (r shl 8) or ((a shr (i * 8)) and 0xFF'u64)
  r

proc tuckConcat*(a, b: string): string {.inline.} =
  ## What `str + str` lowers to: a new string, both inputs untouched.
  a & b

proc tuckSat*[T: SomeUnsignedInt](v: uint64): T {.inline.} =
  ## Clamps a wide unsigned intermediate to `T`'s maximum.
  ##
  ## `[saturating]` (spec 4.1): clamp at the type's bounds instead of wrapping.
  ## This is VALUE SEMANTICS, not an assertion — unlike validate() it is never
  ## stripped in release, because removing it would change results.
  ##
  ## The guard runs where a value is STORED, on a wider intermediate, so a
  ## chain like `a + b - c` clamps once against the final value rather than at
  ## every operator (an intermediate that overshoots and comes back is not an
  ## overflow). Compiles to a branchless cmov: ~3 instructions.
  ##
  ## ponytail: u64 has no wider intermediate, so a chain that overflows u64
  ## itself wraps before this sees it. Exact for u8/u16/u32. See known_bugs.
  if v > uint64(T.high): T.high else: T(v)

proc tuckSatI*[T: SomeInteger](v: int64): T {.inline.} =
  ## The signed twin of `tuckSat`: clamps a wide intermediate to `T`'s range
  ## at both ends. Any `T` narrower than 64 bits, unsigned too: a stored
  ## `[saturating]` chain (lowering_saturating) is computed signed, so that
  ## `0 - 5` on a u16 clamps to 0 rather than wrapping to a huge value.
  when T is SomeUnsignedInt:
    static: doAssert sizeof(T) < 8, "u64 has no wider intermediate"
  if v > int64(T.high): T.high
  elif v < int64(T.low): T.low
  else: T(v)

type
  OvOp* = enum ovAdd, ovSub, ovMul
  OvPolicy* = enum ovTrap, ovWrap, ovSat

proc tuckOverflowTrap*(ty, op: string) {.noreturn.} =
  ## Integer overflow under `[trapping]` — the default for a narrow integer.
  ## Stops AT the site, naming the type and the operator, in every build:
  ## a wrong number that keeps travelling is worse than a stopped program
  ## (ROADMAP ruling 2026-08-25 §4), so this is real code, not an assert.
  ## A standalone/freestanding image has no `appendString` compiler magic, so
  ## the descriptive message is host-only; the trap itself still stops here.
  when not defined(freestanding):
    stderr.writeLine("Arithmetic overflow on " & ty & ": " & op)
    quit(1)
  else:
    # No string building on metal (no appendString magic), so a fixed text;
    # the fault record's LR names the trapping site.
    discard ty
    discard op
    tuckFatal("arithmetic overflow on a [trapping] integer")

proc tuckBufferAddress*[T](b: var T): uint32 =
  ## `NAME.address` (owner ruling 2026-11-23): the buffer's address as a
  ## NUMBER for a peripheral register, never a pointer Tuck code can follow.
  ## It is also a barrier: every write to the buffer before it has reached
  ## memory, so a DMA stream started with this address reads what was
  ## written. On a hosted build the address is only for show (64-bit hosts
  ## truncate it).
  when defined(freestanding):
    {.emit: "__asm volatile(\"dmb\" ::: \"memory\");".}
  cast[uint32](cast[uint](addr b))

proc tuckDivTrap*(ty, op: string) {.noreturn.} =
  ## Integer `/i` or `%` by zero: stops at the site with exit 1, as an
  ## overflow trap does, on every backend (audit Y2 — Nim raised a defect
  ## (1), Odin died on SIGILL (132), D on SIGFPE (136)).
  when not defined(freestanding):
    stderr.writeLine("Division by zero on " & ty & ": " & op)
    quit(1)
  else:
    # As tuckOverflowTrap: a fixed text on metal, where the fault record's
    # LR names the dividing site.
    discard ty
    discard op
    tuckFatal("division by zero")

proc tuckDivI*[T: SomeInteger](a, b: T, tn: string): T {.inline.} =
  ## `a /i b`, truncating, with the one case each host faults on instead of
  ## answering — the minimum divided by -1 — stopped as an overflow. `tn` is
  ## the Tuck type's name, which a trap reports (the host's differs per backend).
  if b == 0: tuckDivTrap(tn, "/i")
  when T is SomeSignedInt:
    if b == -1 and a == low(T): tuckOverflowTrap(tn, "/i")
  a div b

proc tuckModI*[T: SomeInteger](a, b: T, tn: string): T {.inline.} =
  ## `a % b`. The minimum mod -1 is 0, which the host's divide faults on.
  if b == 0: tuckDivTrap(tn, "%")
  when T is SomeSignedInt:
    if b == -1: return 0
  a mod b

type ArithRes[T] = tuple[r: T, over, high: bool]
  ## A wrapped result, whether the exact one did not fit, and which end of the
  ## range the exact result lies past.

proc arithNarrow[T: SomeInteger](a, b: T, op: static OvOp): ArithRes[T] {.inline.} =
  ## Under 64 bits: widen to int64, which is exact for + - * of two such values.
  let w = when op == ovAdd: int64(a) + int64(b)
          elif op == ovSub: int64(a) - int64(b)
          else: int64(a) * int64(b)
  (cast[T](w), w < int64(low(T)) or w > int64(high(T)), w > 0)

proc arithWideUnsigned[T: SomeUnsignedInt](a, b: T,
                                           op: static OvOp): ArithRes[T] {.inline.} =
  ## 64-bit unsigned: unsigned arithmetic wraps in Nim, so test the result.
  when op == ovAdd:
    let r = a + b
    (r, r < a, true)
  elif op == ovSub:
    (a - b, a < b, false)
  else:
    let r = a * b
    (r, a != 0 and r div a != b, true)

proc arithWideSigned[T: SomeSignedInt](a, b: T, op: static OvOp): ArithRes[T] {.inline.} =
  ## 64-bit signed: wrap through the unsigned type, then test the sign bits.
  let ua = cast[uint64](a)
  let ub = cast[uint64](b)
  when op == ovAdd:
    let r = cast[T](ua + ub)
    (r, ((a xor r) and (b xor r)) < 0, b > 0)
  elif op == ovSub:
    let r = cast[T](ua - ub)
    (r, ((a xor b) and (a xor r)) < 0, b < 0)
  else:
    let r = cast[T](ua * ub)
    (r, a != 0 and ((a == T(-1) and b == low(T)) or
                    (a != T(-1) and r div a != b)), (a < 0) == (b < 0))

proc tuckArith*[T: SomeInteger](a, b: T, op: static OvOp,
                                pol: static OvPolicy, tn: string): T {.inline.} =
  ## `a + b`, `a - b`, `a * b` on a narrow integer, with the overflow policy
  ## the author's type chose: trap (the default), wrap, or saturate. `tn` is
  ## the Tuck type's name, which a trap reports.
  ## Value semantics, never stripped in release.
  let res =
    when sizeof(T) < 8: arithNarrow(a, b, op)
    elif T is SomeUnsignedInt: arithWideUnsigned(a, b, op)
    else: arithWideSigned(a, b, op)
  if res.over:
    when pol == ovTrap:
      tuckOverflowTrap(tn, when op == ovAdd: "+" elif op == ovSub: "-" else: "*")
    elif pol == ovSat:
      return if res.high: high(T) else: low(T)
  res.r

proc errCode*(name: static string): uint16 =
  ## An error variant's stable 16-bit code, computed at compile time from its
  ## qualified name — the same hash every backend uses, so codes agree.
  # compile-time FNV-1a, folded to 16 bits; stable across builds, no tables
  var h = 2166136261'u32
  for c in name:
    h = (h xor uint32(c)) * 16777619'u32
  uint16((h xor (h shr 16)) and 0xFFFF'u32)

proc ok*[T](r: TuckResult[T]): bool {.inline.} =
  ## Did the result succeed (not failed, not absent)?
  r.status == tsOk

proc tok*[T](v: T): TuckResult[T] {.inline.} =
  ## A successful result carrying `v`. The result takes `v` by its bits: it
  ## was built (or moved) for this, and an assignment would copy it and leak
  ## the original.
  result.status = tsOk
  copyMem(addr result.value, unsafeAddr v, sizeof(T))

proc tokVoid*(): TuckResult[tuple[]] {.inline.} =
  ## A successful `!void` result, which carries nothing.
  TuckResult[tuple[]](status: tsOk)

proc terr*[T](code: uint16): TuckResult[T] {.inline.} =
  ## A failed result carrying the error `code`.
  TuckResult[T](status: tsErr, err: code)

proc tuckFill*[N: static int, T](v: T): array[N, T] =
  ## `[v; N]` (R8): N copies of a scalar. A zero fill never reaches here — it
  ## is `default(array[N, T])`, the zeroed storage.
  for i in 0 ..< N: result[i] = v

proc tnone*[T](): TuckResult[T] {.inline.} =
  ## An absent result (`?T` with no value).
  TuckResult[T](status: tsAbsent)

proc parseFloat*(s: string): TuckResult[float] =
  ## Absent, not an error: "that text is not a number" is a question with a
  ## legitimate no, which is what `?T` is for.
  try: tok(strutils.parseFloat(s))
  except ValueError: tnone[float]()

proc tfwd*[T](status: TuckStatus, err: uint16): TuckResult[T] {.inline.} =
  ## `?` propagation: forward failure OR absence unchanged (status-preserving)
  TuckResult[T](status: status, err: err)

proc tuckReportUnhandled*(code: uint16, site: string) =
  ## The default `errors` handler: reports a dropped error's code and call
  ## site on stderr and lets the program continue.
  stderr.writeLine("TUCK UNHANDLED: error " & $code & " at " & site)

type TuckUnhandledProc* = proc (code: uint16, site: string) {.nimcall, gcsafe.}
var tuckUnhandledHook*: TuckUnhandledProc
  ## The application's `on unhandled`, registered at its module init. A
  ## partial library's shortcut sites reach it through `tuckRouteUnhandled`:
  ## the library cannot import the application (ruling 2026-11-22).

proc tuckRouteUnhandled*(code: uint16, site: string) {.gcsafe.} =
  ## A partial library's shortcut site: the application's handler, or the
  ## default report when none is registered.
  {.cast(gcsafe).}:
    if tuckUnhandledHook != nil: tuckUnhandledHook(code, site)
    else: tuckReportUnhandled(code, site)

type TuckMemoTable*[K, V] = object
  ## The unbounded `fn memo` cache: every distinct argument list ever seen.
  t: stdtables.Table[K, V]

proc tuckMemoGet*[K, V](m: var TuckMemoTable[K, V], k: K, v: var V): bool =
  if m.t.hasKey(k):
    v = m.t[k]
    return true
  false

proc tuckMemoPut*[K, V](m: var TuckMemoTable[K, V], k: K, v: V) =
  m.t[k] = v

proc tuckMemoMix*[T](h: uint64, v: T): uint64 {.inline.} =
  ## One argument folded into a `fn memo` slot hash (FNV-1a style). Integers
  ## and bools only, which is all `fn memo` accepts.
  when T is bool: (h xor uint64(ord(v))) * 1099511628211'u64
  elif T is SomeUnsignedInt: (h xor uint64(v)) * 1099511628211'u64
  else: (h xor cast[uint64](int64(v))) * 1099511628211'u64

proc tuckDepthExceeded*(name: string, limit: int) {.noreturn.} =
  ## A `[depth: N]` fn was entered more than N levels deep. Same exit status
  ## as an invariant violation, and for the same reason it is real code, not
  ## an `assert`: it must survive a release build.
  stderr.writeLine("Recursion depth exceeded in " & name & ": limit " & $limit)
  quit(1)

proc tuckInvariantFailed*(cond, typeName: string) =
  ## An invariant violation (spec 4.7) — abort naming the condition.
  ##
  ## NOT Nim's `assert`: `-d:release` strips asserts outright by default, so
  ## a guard built on one silently evaporates in exactly the build where a
  ## violated invariant means corrupt data. ROADMAP's 2026-08-25 ruling 5
  ## says invariants stay on in release by default, opt-out only, so the
  ## check has to be real code the optimizer keeps — same fix as the D
  ## backend's `tuckInvariantFailed`, from the direction Nim needed it.
  stderr.writeLine("Invariant violated on " & typeName & ": " & cond)
  quit(1)

type
  BumpArena*[Size: static int] = object
    ## A fixed-size bump allocator (spec 7.3): allocation advances a cursor,
    ## and only `reset` frees. No backend emits a use of it yet.
    buffer*: array[Size, byte]
    cursor*: int

proc alloc*[Size: static int](arena: var BumpArena[Size], bytes: int): pointer =
  ## `bytes` from the arena, or an `OutOfMemoryDefect` when it is exhausted.
  if arena.cursor + bytes > Size:
    when defined(freestanding):
      tuckFatal("arena buffer exhausted")
    else:
      raise newException(OutOfMemoryDefect, "Arena buffer exhausted")
  result = addr arena.buffer[arena.cursor]
  arena.cursor += bytes

proc reset*[Size: static int](arena: var BumpArena[Size]) =
  ## Frees everything the arena handed out, at once.
  arena.cursor = 0

# spec 7.2: N slots of an arbitrary T plus an occupancy bitmask. Fixed size,
# no fragmentation, O(1) release. Exhaustion is ABSENCE (?T), not nil and not
# an error — the caller decides what running out means for its situation.
proc tuckPoolMisuse*(what: string) =
  ## A pool operation that cannot be honoured: a handle for a slot nobody
  ## holds, or one whose tenancy has ended. Aborts rather than returning,
  ## because the alternative is the silent corruption this replaced — a
  ## release that matched the wrong cell freed a slot still in use and leaked
  ## the one being returned, and said nothing.
  stderr.writeLine("TUCK POOL: " & what)
  quit(1)

type
  PoolHandle* = object
    ## What `acquire` hands back: WHICH cell, and WHICH TENANCY of it.
    ##
    ## The value used to be the cell's contents, which meant the cell's
    ## identity was gone by the time `release` needed it — it searched by
    ## equality, every slot held the same zero value, and so every release
    ## matched slot 0. Carrying the index is what makes release O(1) and
    ## correct; carrying the generation is what makes a stale handle a caught
    ## error instead of a write into someone else's slot.
    ##
    ## Opaque on the Tuck side: `<Pool>Handle` is emitted per pool as an alias
    ## of this, so the CHECKER separates two pools' handles even though the
    ## target type is shared (spec 7.4's "handles, not refs", reached through
    ## 7.2's machinery, which 7.4 says is the same machinery).
    slot*: int32
    gen*: uint32

  CellState* = enum
    ## Where one cell of a pool stands. A cell STARTS ABSENT (#42): acquiring
    ## it hands out a handle, not a value, and it reads absent until something
    ## writes it — so zeroed storage is never read as a value of the element
    ## type, which may break its invariant.
    csFree      ## nobody holds it
    csAbsent    ## held, and nothing written since it was acquired
    csPresent   ## held, and written — by `write`, or handed out by `addr`

  ObjectPool*[T; Count: static int] = object
    ## A fixed pool of `Count` cells of `T` (spec 7.2): storage, a tenancy
    ## counter per cell, and each cell's state. Exhaustion is absence, never nil.
    storage*: array[Count, T]
    gen*: array[Count, uint32]  ## tenancy counter per cell; 0 = never handed out
    state*: array[Count, CellState]
      ## one per cell; it was a single `u64` of held bits, which capped a pool
      ## at 64 cells the checker never enforced

proc tuckPoolAcquire*[T; Count: static int](pool: var ObjectPool[T, Count]): TuckResult[PoolHandle] =
  ## The first free cell, now held and absent, as a handle carrying its new
  ## tenancy; none when every cell is held.
  for i in 0 ..< Count:
    if pool.state[i] == csFree:
      pool.state[i] = csAbsent
      pool.gen[i] = pool.gen[i] + 1'u32
      return tok(PoolHandle(slot: int32(i), gen: pool.gen[i]))
  tnone[PoolHandle]()

proc heldCell[T; Count: static int](pool: ObjectPool[T, Count], h: PoolHandle,
                                   what: string): int =
  ## The cell a handle names, if its holder still holds it. The handle names
  ## the cell, so there is nothing to search for and nothing to guess; every
  ## way of being wrong is caught rather than absorbed.
  let i = int(h.slot)
  if i < 0 or i >= Count:
    tuckPoolMisuse(what & " of a handle that names no slot (" & $i & ")")
  elif pool.state[i] == csFree:
    tuckPoolMisuse(what & " of slot " & $i & ", which nobody holds")
  elif pool.gen[i] != h.gen:
    tuckPoolMisuse(what & " of a stale handle for slot " & $i & ": tenancy " &
                   $h.gen & ", slot is on " & $pool.gen[i])
  i

proc tuckPoolRelease*[T; Count: static int](pool: var ObjectPool[T, Count], h: PoolHandle) =
  ## Frees the cell `h` holds. A stale or foreign handle aborts the program.
  pool.state[pool.heldCell(h, "release")] = csFree

proc tuckPoolRead*[T; Count: static int](pool: var ObjectPool[T, Count], h: PoolHandle): TuckResult[T] =
  ## The value in `h`'s cell, or none if nothing has been written since it was
  ## acquired.
  let i = pool.heldCell(h, "read")
  if pool.state[i] == csPresent: tok(pool.storage[i]) else: tnone[T]()

proc tuckPoolWrite*[T; Count: static int](pool: var ObjectPool[T, Count], h: PoolHandle, v: T) =
  ## Stores `v` in `h`'s cell, which then reads as present.
  let i = pool.heldCell(h, "write")
  pool.storage[i] = v
  pool.state[i] = csPresent

proc tuckPoolAddr*[T; Count: static int](pool: var ObjectPool[T, Count], h: PoolHandle): ptr UncheckedArray[uint8] =
  ## The cell's bytes, for an extern to fill (DMA). It is PRESENT from here
  ## on: it was handed out to be filled, and the checker allows `addr` only
  ## on a pool whose element carries no invariant (TK-TY31), so whatever the
  ## extern leaves there is a value of the type.
  let i = pool.heldCell(h, "addr")
  pool.state[i] = csPresent
  cast[ptr UncheckedArray[uint8]](addr pool.storage[i])

# ---------------------------------------------------------------------------
# The slab (thoughts/shared/plans/2026-09-29-slab-proposal.md): a table of
# cells of one type, addressed by REFERENCES — which cell, and which tenancy
# of it. Three storages under one set of operations, each storage giving only
# "the cell at i" and "one more cell":
#   SlabChunked  the default: two levels, never copied (below)
#   SlabFixed    `[count: N]`: a static array, for a target with no heap
#   SlabSeq      `[storage: contiguous]`: one Seq, grown by doubling
#
# A cell is {tenancy, link, value}: the stale check and the read touch one
# cache line. `link` is SlabLive while the cell holds a value; a free cell
# keeps the next free cell's index + 1 there instead, so the free list lives
# in the dead cells and freeing allocates nothing. Every slab starts ZERO —
# no free cell, nothing handed out — so a slab is a global with a constant
# initialiser (its name) on every backend, Odin's included.

type
  SlabRef* = object
    ## Eight bytes: a cell's index and the tenancy the reference was made in.
    ## Opaque on the Tuck side: `<Slab>Ref` is emitted per slab as an alias of
    ## this, so the CHECKER keeps two slabs' references apart.
    slot*: uint32
    gen*: uint32

  SlabCell*[T] = object
    gen: uint32
    link: int32
    value*: T

const SlabLive = -1'i32   ## `link` of a cell holding a value

proc tuckSlabMisuse*(name, what: string) =
  ## A reference that no longer names a live cell. Stops, exit 1, as a stale
  ## pool handle does, on every backend.
  stderr.writeLine("TUCK SLAB [" & name & "]: " & what)
  quit(1)

# --- the default storage: two levels, never copied -------------------------
#
# A fixed top of directory pages, each a fixed array of chunk pointers, each
# chunk a fixed array of cells (ruled 2026-09-29, Q8: no resize may make a
# program wait). Every allocation is one of two fixed sizes, made when first
# needed; nothing is copied, ever. A chunk is sized in BYTES — 64 KiB rounded
# down to a power-of-two cell count, at least one — so a large element does
# not make a chunk of megabytes. 64 pages x 1024 chunks x 64 KiB is 4 TiB of
# cells, so the top never has to grow. Measured: benches/SCORES.md, "Slab
# storage" — the second level costs nothing once the accessor skips the
# bounds checks its own shifts and masks make redundant.

const
  SlabPageShift = 10
  SlabPageN = 1 shl SlabPageShift
  SlabTopN = 64
  SlabChunkBytes = 65536

proc slabChunkShift(cellBytes: int): int {.compileTime.} =
  ## log2 of the cells per chunk: the most that fit in SlabChunkBytes, >= 1.
  while (2 shl result) * cellBytes <= SlabChunkBytes: inc result

type
  SlabChunk[T] = UncheckedArray[SlabCell[T]]
  SlabPage[T] = array[SlabPageN, ptr SlabChunk[T]]
  SlabChunked*[T] = object
    name*: string
    top: array[SlabTopN, ptr SlabPage[T]]
    len: uint32        ## cells handed out since the last reset
    freeHead: int32    ## the first free cell + 1; 0 = none
    live*: int         ## cells holding a value now

  SlabFixed*[T; N: static int] = object
    name*: string
    cells: array[N, SlabCell[T]]
    len: uint32
    freeHead: int32
    live*: int

  SlabSeq*[T] = object
    name*: string
    cells: seq[SlabCell[T]]
    len: uint32
    freeHead: int32
    live*: int

  AnySlab[T] = SlabChunked[T] | SlabSeq[T]

{.push boundChecks: off.}
proc cellAt[T](s: SlabChunked[T], i: uint32): ptr SlabCell[T] {.inline.} =
  ## The cell at `i` (< len): every part in range by construction.
  const cs = slabChunkShift(sizeof(SlabCell[T]))
  addr s.top[i shr (cs + SlabPageShift)][(i shr cs) and (SlabPageN - 1)][
    i and ((1'u32 shl cs) - 1)]

proc cellAt[T; N: static int](s: SlabFixed[T, N], i: uint32): ptr SlabCell[T] {.inline.} =
  unsafeAddr s.cells[i]

proc cellAt[T](s: SlabSeq[T], i: uint32): ptr SlabCell[T] {.inline.} =
  unsafeAddr s.cells[i]
{.pop.}

proc growCell[T](s: var SlabChunked[T]): uint32 =
  ## One more cell: opens a page and a chunk when this is the first cell of
  ## one. A chunk left by a `reset` is reused as it stands.
  const cs = slabChunkShift(sizeof(SlabCell[T]))
  let i = s.len
  if (i and ((1'u32 shl cs) - 1)) == 0:
    let pi = int(i shr (cs + SlabPageShift))
    if pi >= SlabTopN: tuckSlabMisuse(s.name, "full (" & $i & " cells)")
    if s.top[pi] == nil:
      s.top[pi] = cast[ptr SlabPage[T]](allocShared0(sizeof(SlabPage[T])))
    let ci = int((i shr cs) and (SlabPageN - 1))
    if s.top[pi][ci] == nil:
      s.top[pi][ci] = cast[ptr SlabChunk[T]](
        allocShared0((1 shl cs) * sizeof(SlabCell[T])))
  inc s.len
  i

proc growCell[T](s: var SlabSeq[T]): uint32 =
  if int(s.len) == s.cells.len: tuckPush(s.cells, default(SlabCell[T]))
  result = s.len
  inc s.len

proc growCell[T; N: static int](s: var SlabFixed[T, N]): uint32 =
  result = s.len
  inc s.len

proc slabTake[S](s: var S): uint32 {.inline.} =
  ## A cell to fill: a freed one first, else one more.
  if s.freeHead != 0:
    result = uint32(s.freeHead - 1)
    s.freeHead = s.cellAt(result).link
  else:
    result = s.growCell()

proc slabFill[S, T](s: var S, i: uint32, v: sink T): SlabRef {.inline.} =
  let c = s.cellAt(i)
  c.gen = c.gen + 1'u32
  c.link = SlabLive
  tuckStore(c.value, v)          # `v` was built or moved for this cell
  inc s.live
  SlabRef(slot: i, gen: c.gen)

proc tuckSlabNew*[T](s: var AnySlab[T], v: sink T): SlabRef =
  ## A cell holding `v`. A growable slab never runs out.
  s.slabFill(s.slabTake(), v)

proc tuckSlabNew*[T; N: static int](s: var SlabFixed[T, N], v: sink T): TuckResult[SlabRef] =
  ## A cell holding `v`, or absent when every cell holds one (`[count: N]`).
  if s.freeHead == 0 and int(s.len) >= N: return tnone[SlabRef]()
  tok(s.slabFill(s.slabTake(), v))

proc tuckSlabCell*[S](s: S, r: SlabRef): auto {.inline.} =
  ## The cell `r` names, if it still holds the value `r` was made for.
  if r.slot >= s.len: tuckSlabMisuse(s.name, "stale reference to cell " & $r.slot)
  result = s.cellAt(r.slot)
  if result.link != SlabLive or result.gen != r.gen:
    tuckSlabMisuse(s.name, "stale reference to cell " & $r.slot)

proc tuckSlabLive*[S](s: S, r: SlabRef): bool =
  ## Does `r` still name a live cell? The question to ask before using one.
  if r.slot >= s.len: return false
  let c = s.cellAt(r.slot)
  c.link == SlabLive and c.gen == r.gen

proc tuckSlabFree*[S](s: var S, r: SlabRef) =
  ## The cell is free; every reference to it is stale from here on.
  let c = s.tuckSlabCell(r)
  tuckDrop(c.value)       # what it holds goes now, not at reuse
  c.link = s.freeHead
  s.freeHead = int32(r.slot) + 1
  dec s.live

proc slabDropLive[S](s: var S) =
  ## What the live cells hold goes with a reset. Only for a cell that owns
  ## storage: a slab of plain values keeps its O(1) reset.
  for i in 0'u32 ..< s.len:
    let c = s.cellAt(i)
    if c.link == SlabLive: tuckDrop(c.value)

proc tuckSlabReset*[S](s: var S) =
  ## Every cell free and every reference stale: the storage stays and is
  ## reused in order, each cell's tenancy moving on as it is. O(1) for a slab
  ## of plain values; a cell that owns storage drops it.
  when not supportsCopyMem(typeof(s.cellAt(0'u32).value)): slabDropLive(s)
  s.len = 0
  s.freeHead = 0
  s.live = 0

proc tuckSlabCount*[S](s: S): int = s.live

type ArenaBudget* = object
  ## An arena's `[size: N]` (slab proposal §9): the bytes its slabs may
  ## hold between resets, charged per `new` by a size the COMPILER computed
  ## from the Tuck type — the same on every backend, so a budget runs out at
  ## the same `new` everywhere. `size` 0 is an arena without a budget.
  size*: int
  used*: int

proc tuckArenaNew*[T](s: var SlabChunked[T], b: var ArenaBudget, cost: int,
                      v: sink T): TuckResult[SlabRef] =
  ## A cell of an arena's slab holding `v`, or absent when the arena's budget
  ## cannot cover it. `reset` gives the whole budget back.
  if b.used + cost > b.size: return tnone[SlabRef]()
  b.used += cost
  tok(s.tuckSlabNew(v))

proc tuckSlabReport*[S](s: S) =
  ## At exit: say how many cells were never freed (slab proposal Q3). A slab
  ## declared `[leaks: ok]` is not reported.
  if s.live > 0:
    stderr.writeLine("TUCK SLAB [" & s.name & "]: " & $s.live &
                     " cell(s) never freed")

# ---------------------------------------------------------------------------
# spec 7.4: the resource registry.
#
# Scope-based RAII is the wrong model for an OS handle: a hot loop that opens
# and closes a file per iteration thrashes on syscalls. The true model is the
# one the OS already uses — a global table of handles, the process fd table —
# so Tuck makes that table explicit and per kind.
#
# This is 7.2's pool machinery with three additions, each of which 7.4 asks
# for by name: an `isFinished` flag (marking and closing are SPLIT, so
# durability never depends on sweep timing), a registration order (close-all
# runs LIFO — a file flushes before the directory holding it closes), and an
# acquire site per entry (the OPEN RESOURCES report has to say WHERE).

type
  ResourceHandle* = object
    ## What an acquire hands back: WHICH entry, and WHICH TENANCY of it.
    ## A plain value — copyable, comparable, Tier 1 (7.1) — and never the
    ## resource itself. The ref stays in the table, which is what closes the
    ## fd-reuse bug class by construction: a handle whose generation no longer
    ## matches its slot is a caught error, not a write to the wrong file.
    ##
    ## Emitted per kind as `<Kind>Handle`, an alias of this, exactly as each
    ## pool emits `<Pool>Handle` over PoolHandle — so the CHECKER keeps two
    ## kinds' handles apart while the backends need only the one target type.
    slot*: int32
    gen*: uint32

  RtResourcePolicy* = enum
    ## When the OS handle actually closes. MARKING is identical under all
    ## three — the handle dies at mark time whichever is in force — so buggy
    ## code behaves the same way in every mode and a use-after-finish is the
    ## same caught error in a debug build and a shipped one.
    rtStrict   ## close at the mark. Deterministic; the embedded/debug default
    rtLazy     ## mark only; the inline watermark sweep reclaims
    rtExit     ## close-all at program end

  RtOnFull* = enum
    ## What a CAPPED table does when it fills.
    rtoAbsent  ## report absence; the caller decides (the default)
    rtoError   ## abort, naming the kind and its cap

  ResourceCloser* = proc(reference: int64) {.nimcall.}
    ## How THIS kind's OS handle is released, and what `on_finish` does for it.
    ## A callback because the runtime cannot know: closing an fd, an mmap and
    ## a TLS session are three different syscalls, and the library that
    ## declared the kind is the only thing that knows which. nil = no-op,
    ## which is what a kind with no OS side (a test, a counter) wants.

  ResourceEntry* = object
    ## One registered OS handle: the handle itself, its tenancy, whether the slot
    ## is in use and whether it has been finished, and where it was acquired.
    reference*: int64   ## the OS handle: an fd, or a pointer cast to int
    gen*: uint32        ## tenancy; bumped at the MARK, so the handle dies there
    live*: bool         ## this slot is occupied at all
    finished*: bool     ## marked; awaiting reclamation. Only these are evicted
    site*: string       ## where it was acquired — the report's whole value

  ResourceTable* = object
    ## The registry for one resource kind (spec §7.4): its knobs, its entries,
    ## registration order (close-all runs it backwards) and how many entries
    ## await reclamation.
    kind*: string            ## the declared kind name, for messages
    cap*: int                ## 0 = unbounded (seq-backed); >0 = the bound
    policy*: RtResourcePolicy
    onFull*: RtOnFull        ## only consulted when `cap` > 0
    sweepBatch*: int         ## 0 = evict every finished entry; >0 = that many
    onFinish*: ResourceCloser  ## runs at the MARK, always (file: flush)
    onClose*: ResourceCloser   ## runs at reclamation
    entries*: seq[ResourceEntry]
    order*: seq[int32]       ## registration order — close-all walks it backwards
    finishedCount*: int

proc tuckResourceMisuse*(table: string, what: string) =
  ## A registry operation that cannot be honoured. Aborts rather than
  ## returning, for the reason tuckPoolMisuse does: the alternative is silent
  ## corruption, and a stale handle that writes to a REUSED slot is exactly
  ## the bug 7.4 exists to make impossible.
  stderr.writeLine("TUCK RESOURCE [" & table & "]: " & what)
  quit(1)

proc initResourceTable*(t: var ResourceTable, kind: string, cap: int,
                        policy: RtResourcePolicy, sweepBatch: int,
                        onFull = rtoAbsent) =
  ## Sets a kind's knobs. A capped kind gets all its slots up front, since
  ## its cap is a memory budget, not a limit found at runtime.
  t.kind = kind
  t.cap = cap
  t.policy = policy
  t.sweepBatch = sweepBatch
  t.onFull = onFull
  if cap > 0 and t.entries.len < cap:
    # A capped kind is array-shaped from the start: the cap is a LINK-TIME
    # memory budget on a standalone target, not a limit discovered at runtime.
    t.entries.setLen(cap)

proc setResourceHooks*(t: var ResourceTable, onFinish, onClose: ResourceCloser) =
  ## The kind's two callbacks, bound by whichever library declared it.
  t.onFinish = onFinish
  t.onClose = onClose

proc reclaim(t: var ResourceTable, i: int) =
  ## Release one FINISHED entry's OS handle and free its slot. Never called on
  ## a live one: 7.4 has no time-based eviction, and an entry nobody finished
  ## is still in use by definition.
  if not t.entries[i].live or not t.entries[i].finished: return
  if t.onClose != nil: t.onClose(t.entries[i].reference)
  t.entries[i].live = false
  t.entries[i].site = ""
  t.finishedCount.dec
  for k in 0 ..< t.order.len:
    if t.order[k] == int32(i):
      t.order.delete(k)
      break

proc sweep*(t: var ResourceTable): int {.discardable.} =
  ## Reclaim finished entries, up to `sweepBatch` of them (0 = all). Returns
  ## how many were taken. Also the `kind::sweep` an explicit scheduled cleanup
  ## calls — the inline trigger below and the explicit one are the same code,
  ## so a program that sweeps by hand and one that lets the marks do it cannot
  ## drift apart.
  let limit = if t.sweepBatch > 0: t.sweepBatch else: t.entries.len
  for i in 0 ..< t.entries.len:
    if result >= limit: break
    if t.entries[i].live and t.entries[i].finished:
      t.reclaim(i)
      result.inc

proc watermarkReached(t: ResourceTable): bool =
  ## ~75% of cap, 7.4's trigger. An uncapped table has no watermark: its bound
  ## is the OS ulimit, and sweeping it early would be work with no budget to
  ## measure against.
  t.cap > 0 and (t.finishedCount * 4) >= (t.cap * 3)

proc acquire*(t: var ResourceTable, reference: int64,
              site: string): TuckResult[ResourceHandle] =
  ## Register a freshly opened OS handle. Exhaustion is ABSENCE, not an error —
  ## the caller decides what running out means, exactly as 7.2's pool does.
  ##
  ## Sizes a capped table on first use, so a table built as a plain literal
  ## behaves exactly as one built through initResourceTable. That is what lets
  ## each backend emit the declaration as a STATIC initializer with no
  ## start-up code at all — the knobs are the declaration, and the shape
  ## follows from them.
  if t.cap > 0 and t.entries.len < t.cap:
    t.entries.setLen(t.cap)
  for i in 0 ..< t.entries.len:
    if t.entries[i].live: continue
    t.entries[i].gen.inc
    t.entries[i].reference = reference
    t.entries[i].live = true
    t.entries[i].finished = false
    t.entries[i].site = site
    t.order.add(int32(i))
    return tok(ResourceHandle(slot: int32(i), gen: t.entries[i].gen))
  if t.cap > 0:
    # The cap is the leak alarm as much as the budget: a table that FILLS is a
    # bug surfacing early rather than an OOM three days in. Which of those two
    # readings applies is the kind's own `on_full`: shed load, or stop.
    if t.onFull == rtoError:
      tuckResourceMisuse(t.kind, "table is full (cap " & $t.cap &
                         ") and the kind declares `on_full: error`")
    return tnone[ResourceHandle]()
  t.entries.add(ResourceEntry(reference: reference, gen: 1, live: true,
                              site: site))
  t.order.add(int32(t.entries.len - 1))
  tok(ResourceHandle(slot: int32(t.entries.len - 1), gen: 1))

proc entryFor(t: var ResourceTable, h: ResourceHandle,
              what: string): int =
  ## The slot this handle names, or an abort. Every way of being wrong is
  ## caught rather than absorbed: out of range, never handed out, and — the
  ## one that matters — a generation that has moved on, which is a handle held
  ## past its finish.
  let i = int(h.slot)
  if i < 0 or i >= t.entries.len:
    tuckResourceMisuse(t.kind, what & " of a handle that names no slot (" & $i & ")")
  elif not t.entries[i].live:
    tuckResourceMisuse(t.kind, what & " of slot " & $i & ", which nobody holds")
  elif t.entries[i].gen != h.gen:
    tuckResourceMisuse(t.kind, what & " of a stale handle for slot " & $i &
                       ": tenancy " & $h.gen & ", slot is on " & $t.entries[i].gen)
  i

proc deref*(t: var ResourceTable, h: ResourceHandle): int64 =
  ## The OS handle behind a live tuck handle. This is the only way to reach
  ## one, which is what makes the generation check unavoidable rather than
  ## something a caller can forget.
  t.entries[t.entryFor(h, "use")].reference

proc finish*(t: var ResourceTable, h: ResourceHandle) =
  ## 7.4's mark: release INTENT, not necessarily release.
  ##
  ## Three things happen here under every policy — `on_finish` runs, the entry
  ## is marked, and the generation is bumped so the handle dies AT THE MARK.
  ## Only the fourth, reclaiming the OS handle, is policy. That split is what
  ## makes durability independent of sweep timing: a write-heavy loop under
  ## lazy policy has already flushed by the time anything is evicted.
  let i = t.entryFor(h, "finish")
  if t.onFinish != nil: t.onFinish(t.entries[i].reference)
  t.entries[i].finished = true
  t.entries[i].gen.inc
  t.finishedCount.inc
  case t.policy
  of rtStrict: t.reclaim(i)
  of rtLazy:
    # Sweeping is INLINE — no thread, no background actor. The trigger lives
    # in the mark itself, so a loop acquiring ten thousand times against a cap
    # in the thousands never blocks: each iteration's mark reclaims once the
    # watermark trips. Amortized, and on the thread that made the garbage.
    if t.watermarkReached(): t.sweep()
  of rtExit: discard

proc closeAll*(t: var ResourceTable) =
  ## Program end, or an explicit shutdown. LIFO in REGISTRATION order: files
  ## flush before the directories holding them close, a TLS session shuts down
  ## before the socket under it.
  for k in countdown(t.order.len - 1, 0):
    let i = int(t.order[k])
    if not t.entries[i].live: continue
    if not t.entries[i].finished and t.onFinish != nil:
      t.onFinish(t.entries[i].reference)
    if t.onClose != nil: t.onClose(t.entries[i].reference)
    t.entries[i].live = false
    t.entries[i].finished = false
    t.entries[i].site = ""
  t.order.setLen(0)
  t.finishedCount = 0

iterator openEntries*(t: ResourceTable): tuple[slot: int, site: string] =
  ## Everything acquired and never finished — the OPEN RESOURCES report, in
  ## the same spirit as PENDING and SHORTCUTS. In registration order, so the
  ## list reads as the program ran.
  for k in 0 ..< t.order.len:
    let i = int(t.order[k])
    if t.entries[i].live and not t.entries[i].finished:
      yield (i, t.entries[i].site)

proc openCount*(t: ResourceTable): int =
  ## How many handles of this kind were acquired and never finished.
  for _ in t.openEntries(): result.inc

proc reportOpenResources*(t: ResourceTable) =
  ## 7.4's OPEN RESOURCES report, in the same spirit as PENDING and SHORTCUTS:
  ## say what is unfinished and WHERE it was acquired, so the answer is a line
  ## number rather than a hunt.
  ##
  ## Debug builds only, and silent when there is nothing to say — a report
  ## that prints "0" every run is one people stop reading.
  when not defined(release) and not defined(danger):
    let n = t.openCount()
    if n == 0: return
    stderr.writeLine("OPEN RESOURCES [" & t.kind & "] (" & $n & "):")
    for e in t.openEntries():
      stderr.writeLine("  slot " & $e.slot & " acquired at " & e.site)

proc shutdownResources*(t: var ResourceTable) =
  ## What a program does with one registry at exit: SAY what leaked, then
  ## close everything. In that order — close-all empties the table, so a
  ## report after it would always be empty and always be silent.
  t.reportOpenResources()
  t.closeAll()

import std/atomics
when not defined(freestanding):
  import std/monotimes
  import std/times
when not defined(freestanding):
  import ./tuck_async   # batch staging registers its flush hook there; the
                      # stdlib externs below import it again for their own
                      # reason, which Nim is happy to ignore

const CacheLine* = 64
  ## x86-64 and arm64 alike. Only used to keep two hot fields apart, so an
  ## over-estimate costs padding and an under-estimate costs false sharing.

const MailboxNeedsLock* = not defined(tuckActorsSingle)
  ## `--actors:single` puts every actor on main's thread as a coroutine, so
  ## a send and a drain cannot interleave mid-operation and there is nothing
  ## for a lock to protect. It is compiled away rather than left uncontended:
  ## an uncontended atomic is still an atomic, and "no atomics on the send
  ## path" is the whole reason to choose the mode.

const
  TuckActorsBatch* = defined(tuckActorsBatch)
    ## `--actors:batch`. A send writes into a batch owned by the SENDING
    ## thread; the whole batch crosses to the actor at once, as a pointer.
    ##
    ## The message is written ONCE — into the staging batch — and read once,
    ## in place, by the handler. Nothing is copied into the mailbox and
    ## nothing is unpacked out of it: the mailbox carries batch POINTERS, so
    ## the crossing is the same O(1) handover the message queue already used,
    ## one level up. Per message that leaves an array write and a counter
    ## bump; the lock, and the wake behind it, are paid once per batch.
    ##
    ## ORDER is per actor, which is the only order Tuck promises. One
    ## sender's messages to one actor keep their sequence (a batch is
    ## ordered, and that sender's batches cross in order). Between actors
    ## there is no order to lose.
  TuckBatchCount* {.intdefine.} = 64
    ## `--batch-count`: hand over once this many messages are staged.
  TuckBatchTimeoutMs* {.intdefine.} = 0
    ## `--batch-timeout`: ...or this long after the batch was opened. 0
    ## disables the deadline, leaving only the count and the flush points.
  TuckBatchCheckEvery* = 200
    ## How often the deadline is actually consulted, in sends. The clock read
    ## is a vDSO call rather than a syscall (~20ns), so once every 200 sends
    ## is fractions of a nanosecond amortised — and the deadline does not
    ## need to be precise, it needs to exist. A sender that stops sending
    ## entirely is covered by the flush points, not by this.
  TuckMinBatches* = 4
    ## Floor on an actor's pool, so a small `[queue: N]` still lets a couple
    ## of senders hold a batch each while the actor drains another.

when not defined(freestanding):
  include "tuck_rt_stdlib_externs"
else:
  include "tuck_actors_metal"   # actors on metal: a ring per actor (roadmap 2.0)
