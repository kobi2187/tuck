## Value semantics: a callee can never write through to its caller.
##
## Spec §7.1 says every Tier 1 record is a value. That is the claim the whole
## concurrency story rests on — no aliasing means a data race cannot be
## SPELLED, so there is no race checker to build, no `Send`/`Sync`, no borrow
## rules to memorise. It is also the claim that was quietly false: the Nim
## backend emitted `var T` for every record parameter, which in Nim is a
## by-reference pass, so this compiled and returned 70:
##
##   fn afterFee({acct: Account, fee: int}) -> int:   # reads like a preview
##     acct ..balance {acct.balance - fee}
##     return acct.balance
##
## The Odin backend never did this (its fnParamList passes records by value
## and says why), so the same program was a hard compile error there — a
## backend divergence hiding a semantic hole.
##
## These cases state the guarantee POSITIVELY, so they keep holding rather
## than merely recording that a bug was once fixed. If one fails, the language
## has stopped being value-semantic, whatever the emitted text looks like.

import std/strutils
import ../harness

proc run*(t: var T) =
  # --- the guarantee, end to end -------------------------------------------
  #
  # `afterFee` is the shape that motivated the rule: a name that reads as a
  # question ("what WOULD the balance be?") must not be able to answer it by
  # changing the caller's account.

  t.src """
type Account:
  balance: int
  frozen: bool

fn afterFee({acct: Account, fee: int}) -> Account:
  var s = acct
  s ..balance {acct.balance - fee}
  return s

fn main() -> int:
  var savings = {balance: 100, frozen: false} Account
  let preview = {acct: savings, fee: 30} afterFee
  if preview.balance == 70 and savings.balance == 100:
    return 1
  return 0
"""
  t.runs "a preview does not spend the caller's money", 1

  # The conditional variant is worse than the plain one: it only corrupts on
  # SOME inputs, so it reads as a heisenbug rather than a wrong answer.
  t.src """
type Reading:
  celsius: int

fn clamped({r: Reading}) -> Reading:
  var s = r
  if r.celsius > 100:
    s ..celsius {100}
  return s

fn main() -> int:
  var sample = {celsius: 150} Reading
  let once = {r: sample} clamped
  let twice = {r: sample} clamped
  if sample.celsius == 150 and once.celsius == 100 and twice.celsius == 100:
    return 1
  return 0
"""
  t.runs "a validator does not clamp its caller's reading", 1

  # --- the rule that makes it hold ------------------------------------------

  t.src """
type Cfg:
  port: int

fn bump({c: Cfg}) -> int:
  c ..port {99}
  return c.port

fn main() -> int:
  return 0
"""
  t.badCheck "mutating a parameter with '..' is rejected", "TK-TY15"
  t.badCheck "...and the message says to copy it first", "copy it first"

  # The rejection must not be confused with the `let` one: a `let` becomes a
  # `var`, but a parameter can never become one, so "use 'var'" would send the
  # user somewhere that does not exist.
  t.src """
type Cfg:
  port: int

fn main() -> int:
  let c = {port: 1} Cfg
  c ..port {99}
  return c.port
"""
  t.badCheck "'..' on a let still reports the let rule, not the param one",
             "TK-TY13"

  # --- what stays legal ------------------------------------------------------
  #
  # The corpus idiom. Every mutator in examples/ and std/ already looked like
  # this, which is why the ruling broke no real code.

  t.src """
type Cfg:
  port: int
  timeout: int

fn withDefaults({self: Cfg}) -> Cfg:
  var s = self
  s ..port {80}
  s ..timeout {30}
  return s

fn main() -> int:
  var cfg = {port: 0, timeout: 0} Cfg
  cfg ..withDefaults
  return cfg.port + cfg.timeout
"""
  t.runs "a builder that copies first still works", 110

  # An object member mutating its own `self` is the stated exception (§5.1):
  # that is state the object OWNS, not a caller's value.
  t.src """
type Sound = {volume: int}

object Player:
  + Sound

  fn louder({self: Self}) -> Self:
    self ..volume {11}
    return self

fn main() -> int:
  return 0
"""
  t.okCheck "an object member may still mutate its own self"

  # ...and an actor mutating its own fields, likewise (§9.1).
  t.src """
actor Counter [queue: 8]:
  total: int = 0

  on add({n: int}) -> void:
    total += n

fn main() -> int:
  return 0
"""
  t.okCheck "an actor handler may still mutate its own fields"

  # --- the emitted shape, on both backends ----------------------------------
  #
  # The Nim assertion is the fix itself: no `var` on a record parameter. Odin
  # never had one, so asserting it there guards the parity rather than the fix.

  t.src """
type Big:
  a: int
  b: int

fn total({v: Big}) -> int:
  return v.a + v.b

fn main() -> int:
  let x = {a: 1, b: 2} Big
  return {v: x} total
"""
  t.omits     "the Nim backend passes a record param without 'var'", "v: var tuck_Big"
  t.emits     "...as a plain value parameter", "v: tuck_Big"
  t.omitsOdin "the Odin backend agrees (it always did)", "v: \\^tuck_Big"

  # --- actor isolation, pinned deliberately ---------------------------------
  #
  # A handler binds its payload `let s = msg.s` — a COPY out of the mailbox
  # ring (tuck_rt's Mailbox is `array[Cap, T]`, values, not pointers). Nothing
  # crosses the actor boundary by reference, which is why "messages race" is
  # not a sentence this language can form.
  #
  # This held even while parameters were leaky, but it held BY ACCIDENT: Nim
  # refused to pass a `let` to the `var` param the old emitter produced. The
  # accident is now a rule, and this pins it so it stays one.
  t.src """
type Sample:
  v: int

actor Collector [queue: 8]:
  last: int = 0

  on take({s: Sample}) -> void:
    last = s.v

fn main() -> int:
  return 0
"""
  t.emits "an actor handler binds its payload as an immutable copy",
          "let s = msg\\.s"

  t.finish()
