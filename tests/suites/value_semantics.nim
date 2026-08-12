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

  # --- the rule that makes it hold: EVERY way to write, not just `..` -------
  #
  # `..` is one door. Plain assignment is another, and it was unguarded — the
  # checker said OK and NIM rejected it, with a message naming generated code
  # ("'c.n' cannot be assigned to") that the user never wrote. Every case
  # below must be caught HERE, by Tuck, with a code, so none of them reach a
  # backend. Any that regresses will show up as a clean check followed by a
  # backend error, which is the failure mode the codes exist to prevent.

  const paramWrites = [
    ("'..' on the parameter",        "  c ..port {99}\n"),
    ("assigning the parameter",      "  c = {port: 99} Cfg\n"),
    ("assigning one of its fields",  "  c.port = 99\n"),
    ("compound-assigning a field",   "  c.port += 99\n"),
  ]
  for (what, body) in paramWrites:
    t.src """
type Cfg:
  port: int

fn bump({c: Cfg}) -> int:
""" & body & """  return c.port

fn main() -> int:
  return 0
"""
    t.badCheck what & " is rejected", "TK-TY15"

  # A scalar parameter is a value too — the rule is about ownership, not size.
  t.src """
fn bump({n: int}) -> int:
  n = 99
  return n

fn main() -> int:
  return 0
"""
  t.badCheck "assigning a scalar parameter is rejected", "TK-TY15"

  # Depth does not launder it: writing through `o.inner` still writes through
  # `o`, so the check follows a field path to its root binding.
  t.src """
type Inner:
  n: int
type Outer:
  inner: Inner

fn bump({o: Outer}) -> int:
  o.inner ..n {99}
  return 0

fn main() -> int:
  return 0
"""
  t.badCheck "mutating a NESTED field of a parameter is rejected", "TK-TY15"

  t.src """
type Inner:
  n: int
type Outer:
  inner: Inner

fn bump({o: Outer}) -> int:
  o.inner.n = 99
  return 0

fn main() -> int:
  return 0
"""
  t.badCheck "assigning a nested field of a parameter is rejected", "TK-TY15"

  # The message has to name the fix, not just the rule.
  t.src """
type Cfg:
  port: int

fn bump({c: Cfg}) -> int:
  c ..port {99}
  return c.port

fn main() -> int:
  return 0
"""
  t.badCheck "...and the message says to copy it first", "copy it first"

  # --- the `let` rule, which shares the machinery ---------------------------
  #
  # The rejections must not be confused: a `let` becomes a `var`, but a
  # parameter can never become one, so "use 'var'" would send the user
  # somewhere that does not exist. Both directions are asserted so a future
  # refactor cannot collapse them into one message.

  const letWrites = [
    ("'..' on a let",                 "  c ..port {99}\n"),
    ("reassigning a let",             "  c = {port: 99} Cfg\n"),
    ("assigning a let's field",       "  c.port = 99\n"),
  ]
  for (what, body) in letWrites:
    t.src """
type Cfg:
  port: int

fn main() -> int:
  let c = {port: 1} Cfg
""" & body & """  return c.port
"""
    t.badCheck what & " reports the let rule, not the param one", "TK-TY13"

  # --- independence of copies, at runtime -----------------------------------
  #
  # The rules above are the checker's half. These run the program, because a
  # rule that is enforced but emits aliasing code would still be wrong — and
  # the original bug was exactly that shape (checker silent, emitter aliasing).

  # A copy taken from a parameter is independent of the caller's value, and a
  # nested record copies with it (records are values all the way down, not a
  # shallow header over shared innards — the Go trap).
  t.src """
type Inner:
  n: int
type Outer:
  inner: Inner
  tag: int

fn deepen({o: Outer}) -> Outer:
  var s = o
  s.inner ..n {99}
  s ..tag {7}
  return s

fn main() -> int:
  var orig = {inner: {n: 1} Inner, tag: 0} Outer
  let changed = {o: orig} deepen
  let origOk = orig.inner.n == 1 and orig.tag == 0
  let newOk = changed.inner.n == 99 and changed.tag == 7
  if origOk and newOk:
    return 1
  return 0
"""
  t.runs "a nested record copies deeply, not shallowly", 1

  # Passing the same record to two functions gives each its own value — no
  # order dependence, no shared state between calls.
  t.src """
type Cfg:
  n: int

fn plus({c: Cfg, by: int}) -> Cfg:
  var s = c
  s ..n {c.n + by}
  return s

fn main() -> int:
  var base = {n: 10} Cfg
  let a = {c: base, by: 1} plus
  let b = {c: base, by: 2} plus
  if base.n == 10 and a.n == 11 and b.n == 12:
    return 1
  return 0
"""
  t.runs "two calls on one record do not see each other's changes", 1

  # A record round-tripped through a call comes back as a value, so mutating
  # the RESULT cannot reach back into what produced it.
  t.src """
type Cfg:
  n: int

fn identity({c: Cfg}) -> Cfg:
  return c

fn main() -> int:
  var orig = {n: 1} Cfg
  var back = {c: orig} identity
  back ..n {99}
  if orig.n == 1 and back.n == 99:
    return 1
  return 0
"""
  t.runs "a returned record is a value, not a view of the argument", 1

  # A record stored into a collection is copied in; mutating the local
  # afterwards must not reach the stored element.
  t.src """
import seq

type Cfg:
  n: int

fn main() -> int [io]:
  var one = {n: 1} Cfg
  var xs = [one]
  one ..n {99}
  let stored = {items: xs, index: 0} seq::at
  if stored.n == 1 and one.n == 99:
    return 1
  return 0
"""
  t.runs "a record put in a collection is copied in", 1

  # A record crossing an actor boundary is copied into the mailbox ring, so
  # the sender's value is not shared with the handler. This is the property
  # the whole concurrency story rests on (spec Part 1: a data race needs two
  # references to one location, and there is only ever one).
  t.src """
import scheduler

type Sample:
  v: int

actor Sink [queue: 8]:
  seen: int = 0

  on take({s: Sample}) -> void:
    seen = s.v

fn done() -> bool:
  return Sink.seen == 42

fn main() -> int [io]:
  var mine = {v: 42} Sample
  Sink send take {s: mine}
  scheduler::waitUntil {pred: :done}
  {} scheduler::stop
  if mine.v == 42 and Sink.seen == 42:
    return 1
  return 0
"""
  t.runs "a record sent to an actor is copied into the mailbox", 1

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
