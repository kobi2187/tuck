## Every diagnostic code resolves, explains itself, and reaches the user.
##
## A code is a PROMISE: once published it names that diagnostic forever, so a
## user who searched for TK-TY05 last year must land on the same rule today.
## These tests hold the two halves of that promise — the code appears in the
## message the compiler prints, and `tuck explain` answers for it.

import std/[os, strutils, re, algorithm]
import ../harness

proc run*(t: var T) =
  # --- the code reaches the user -------------------------------------------

  t.src """
type A:
  x: int

type B:
  x: str

object C:
  + A
  + B

fn main() -> int:
  return 0
"""
  t.badCheck "a composed collision carries TK-TY05", "TK-TY05"

  t.src """
fn main() -> void:
  let x = 5.ms
  return
"""
  t.badCheck "an unresolvable name carries TK-TY03", "TK-TY03"

  # `while` is not a keyword — it's an ordinary identifier — so a `while
  # cond:` attempt must be caught by SHAPE (leading `while`, a `:` before the
  # line ends) and pointed at `for <cond>:`, not left to fail deep inside
  # expression parsing with no hint toward the real spelling.
  t.src """
fn main() -> void:
  var i = 0
  while i < 10:
    i = i + 1
"""
  t.badCheck "a while-shaped statement carries TK-PA10", "TK-PA10"

  # The real while-equivalent (`for <cond>:`, no `in`) must keep working —
  # this is the fix `for` covers both counted and conditional loops.
  t.src """
fn main() -> void:
  var i = 0
  for i < 10:
    i = i + 1
"""
  t.okCheck "for <condition>: (the while-equivalent) still typechecks"

  # `while` as a plain identifier (not statement-leading, no trailing `:`
  # at depth 0) must never trip the shape check.
  t.src """
fn main() -> void:
  let while = 5
  return
"""
  t.okCheck "'while' as an ordinary variable name is unaffected"

  # `mod`/`div` are word-operators elsewhere; here they'd parse as a postfix
  # call and DROP the right operand (`a mod b` -> `mod(a)`), typechecking
  # clean and emitting wrong code. Rejected by shape, naming the real spelling.
  t.src """
fn main() -> int:
  let a = 17
  let b = a mod 5
  return b
"""
  t.badCheck "an infix 'mod' carries TK-PA11 and names '%'", "TK-PA11"

  # TK-PA12 — a parameter named after a BACKEND's keyword. Every other user
  # name gets a `tuck_` prefix; a parameter keeps what the author wrote, so
  # the word reaches that host verbatim. alloc.string found it: `with` gave
  # dmd "found `with` when expecting `)`".
  t.src """
fn replace({t: str, what: str, with: str}) -> str:
  return t

fn main() -> int:
  return 0
"""
  t.badCheck "a param named after a backend keyword is refused", "TK-PA12"

  # The FIELD half of TK-PA12, unguarded until 2026-09-12. A field keeps the
  # author's name for the same reason a parameter does, so `out` emitted
  # `out*: string` and nim answered "identifier expected, but found 'keyword
  # out'"; dmd broke on the same shape. Odin ACCEPTS `out`, which is exactly
  # why the list is a union rather than one host's.
  #
  # Guarding only parameters was also inconsistent in a way an author feels:
  # a payload field binds to a parameter BY NAME, so a field you may declare
  # but may never pass is a worse hole than either half alone.
  t.src """
type T:
  out: str

fn main() -> int:
  return 0
"""
  t.badCheck "a type field named after a backend keyword is refused", "TK-PA12"

  t.src """
object O:
  out: str

fn main() -> int:
  return 0
"""
  t.badCheck "an object field named after a backend keyword is refused", "TK-PA12"

  t.src """
type S:
  | A({out: int})

fn main() -> int:
  return 0
"""
  t.badCheck "a variant payload field named after a backend keyword is refused",
             "TK-PA12"

  # An inline record reaches the same rule, which is what covers a `fnsig`'s
  # payload — it emits as a function-pointer signature carrying the names.
  t.src """
fnsig S = {out: int} -> bool

fn main() -> int:
  return 0
"""
  t.badCheck "a fnsig payload field named after a backend keyword is refused",
             "TK-PA12"

  # The near miss stays legal, and builds everywhere — the rule is the list,
  # not a prefix match on it.
  t.src """
type T:
  outer: str
  shortly: int

fn main() -> int:
  let v = {outer: "x", shortly: 1} T
  return v.shortly - 1
"""
  t.okCheck "a field merely RESEMBLING a backend keyword is fine"
  t.hostBuilds "...and every backend's host compiler accepts it"

  # The list is MEASURED against dmd/nim/odin, not copied from their manuals,
  # and these two are why that matters: both appear in D's reference keyword
  # list, and dmd accepts both as parameter names (`body` is contextual since
  # 2.101; `string` is an alias in object.d, not a keyword). Copying would
  # have rejected examples/14-task.tuck, which has used `body` all along.
  t.src """
fn take({body: str, string: str}) -> str:
  return body + string

fn main() -> int:
  return 0
"""
  t.okCheck "...but a word the hosts actually accept is still a legal param"


  t.src """
fn main() -> int:
  let a = 17
  let b = a div 5
  return b
"""
  t.badCheck "an infix 'div' points at '/i'", "did you mean `/i`"

  # The same shared table (diagnostics.ForeignSpellings) answers a wrong FN
  # name wherever it lands, not just keywords in the parser.
  t.src """
fn main() -> int:
  return sort
"""
  t.badCheck "an undeclared name someone reaches for gets the spelling",
             "Tuck has no `sort`"

  t.src """
type P:
  n: int

fn main() -> int:
  let p = {n: 1} P
  let x = p.toString {a: 1}
  return 0
"""
  t.badCheck "...and so does a `.fn {args}` call on one", "did you mean `toStr`"

  # A name std genuinely lacks says so, rather than reading as a typo the
  # user has to go hunting for.
  t.src """
fn main() -> int:
  return map
"""
  t.badCheck "a name std does not have says so, with what to write instead",
             "no iterator combinators in std yet"

  # `echo` is real but POSTFIX, so the prefix spelling reads as undeclared.
  t.src """
fn main() -> int:
  return echo
"""
  t.badCheck "a postfix-only builtin written prefix names the right shape",
             "`echo` is postfix"

  # A call written backwards. Calls are POSTFIX, so a LITERAL can never
  # continue a chain — reaching one means the argument was written after the
  # callee. Was: the chain just ended, `double` became one statement and `5`
  # another, and the argument was silently dropped (emitted `tuck_double`
  # and `5` as two dead statements, after typechecking clean).
  t.src """
fn double({n: int}) -> int:
  return n + n

fn main() -> int:
  double 5
  return 0
"""
  t.badCheck "a backwards call carries TK-PA04", "TK-PA04"
  t.badCheck "...and names the postfix spelling", "write `5 double`"

  # The correct spellings still parse.
  t.src """
fn double({n: int}) -> int:
  return n + n

fn main() -> int:
  let a = 5 double
  let b = {n: 5} double
  return a + b
"""
  t.okCheck "both postfix spellings still parse"

  # A parse rejection carries its code in the [stage code] tag rather than the
  # message body, so this asserts the tag the driver prints.
  t.src "ac:\n  t: int\n"
  let paIdx = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck"])

  # A KEYWORD in a name-only position must name the collision. Found writing
  # stdlib types (FRICTIONS #5/#5c): "expected a field name" while pointing AT
  # one reads as a parser fault, not a naming one.
  t.src "type Q = {pending: str}\n"
  let rwPendingIdx = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck"])
  t.src "type Z = {when: str}\n"
  let rwWhenIdx = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck"])

  # An ATTRIBUTE word is NOT a keyword: it is reserved only inside brackets, so
  # a name-only position takes it. `fn error(...)` is the log level's verb.
  # (FRICTIONS #5b — this used to be a parse error in a `pending:` block.)
  t.src """
pending:
  fn error({msg: str}) -> void
"""
  t.okCheck "an attribute word is a legal fn name in a pending block"

  # --- explain answers for every code --------------------------------------
  #
  # The registry is only useful if every code in it has an explanation. Walking
  # the enum by hand would go stale; this walks what the compiler actually
  # reports, so a code added without an explanation fails here.
  # Only DECLARED codes — `dcFoo = "TK-XX01"`. A bare TK-XX01 elsewhere in the
  # file is an illustration in a comment, not a registry entry, and matching
  # those reported two phantom codes the first time this ran.
  var codes: seq[string]
  for line in readFile("compiler/diagnostics.nim").splitLines():
    var m: array[1, string]
    if line.find(re"""= "(TK-[A-Z]{2}[0-9]{2})"""", m) >= 0:
      if m[0] notin codes: codes.add m[0]
  codes.sort()

  var explainIdx: seq[(string, int)]
  for c in codes:
    explainIdx.add (c, t.needCmd(@["./tuck", "explain", c]))

  # An unknown code must not be silently accepted.
  let unknownIdx = t.needCmd(@["./tuck", "explain", "TK-ZZ99"])
  # The short form is what a user actually types after reading an error.
  let shortIdx = t.needCmd(@["./tuck", "explain", "ty05"])

  if t.phase != pReport: return

  block:
    let (_, outp) = t.resultOf(paIdx)
    if outp.contains("TK-PA03"):
      t.ok "a misspelled top-level keyword carries TK-PA03"
    else:
      let ls = outp.splitLines()
      t.no "a misspelled top-level keyword carries TK-PA03",
           (if ls.len > 1: ls[1] else: outp)

  for (label, idx, word) in [("`pending`", rwPendingIdx, "pending"),
                             ("`when`", rwWhenIdx, "when")]:
    let name = "a reserved word as a field name names " & label & " (TK-PA08)"
    let (_, outp) = t.resultOf(idx)
    if outp.contains("TK-PA08") and outp.contains("`" & word & "` is a reserved word"):
      t.ok name
    else:
      let ls = outp.splitLines()
      t.no name, (if ls.len > 1: ls[1] else: outp)

  var missing = 0
  for (c, i) in explainIdx:
    let (_, outp) = t.resultOf(i)
    if outp.contains("no such diagnostic") or outp.contains("No code assigned"):
      echo "  no explanation: " & c
      missing.inc
  if missing == 0:
    t.ok "every code in the registry explains itself"
  else:
    t.no "every code in the registry explains itself", $missing & " without one"

  block:
    let (rc, _) = t.resultOf(unknownIdx)
    if rc == 0: t.no "an unknown code is rejected", "TK-ZZ99 was accepted"
    else: t.ok "an unknown code is rejected"

  block:
    let (_, outp) = t.resultOf(shortIdx)
    if outp.contains("set union"):
      t.ok "a code resolves without its TK- prefix, case-insensitively"
    else:
      let ls = outp.splitLines()
      t.no "a code resolves without its TK- prefix, case-insensitively",
           (if ls.len > 0: ls[0] else: "")

  t.finish()
