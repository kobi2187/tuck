## Positive and negative cases for the bidirectional type checker.
##
## Mechanically converted from tests/typecheck_tests.nim: each expectOk /
## expectError became an ok_check / bad_check on a real .tuck file driven
## through `tuck ch`. The old file linked the compiler as a Nim library, so
## running these 153 cases cost a full rebuild of the compiler first.
##
## Cases that shared a `const somePrelude` have it inlined — a file on disk
## cannot reference a const in another test.

import ../harness

proc run*(t: var T) =

  t.src """
fn f({a: int}) -> int:
  return a

fn main() -> void:
  let x = {a: "oops"} f
  return
"""
  t.badCheck "wrong field type in call", "field\\ 'a'"

  t.src """
fn send({email: str, name: str}) -> int:
  return 1

fn main() -> void:
  let x = {email: "a@b.c"} send
  return
"""
  t.badCheck "missing required field", "missing\\ required\\ field\\ 'name"

  t.src """
fn main() -> void:
  let cfg = {port: 80}
  cfg ..port {8080}
  return
"""
  t.badCheck "mutation of let binding", "declared\\ with\\ 'let'"

  t.src """
fn f({a: int}) -> int:
  return "nope"
"""
  t.badCheck "return type mismatch", "return\\ value"

  t.src """
fn f({a: int}) -> int:
  return a

fn g({p: {a: int}}) -> int:
  return p.bogus
"""
  t.badCheck "unknown field on known record", "no\\ field\\ 'bogus'"

  t.src """
fn addOne(x: int) -> int:
  return x + 1

fn main() -> void:
  let y = "hello" addOne
  return
"""
  t.badCheck "scalar arg type mismatch", "expects\\ int"

  t.src """
fn f({a: int, b: str}) -> int:
  return a + b
"""
  t.badCheck "arithmetic type clash", "arithmetic"

  t.src """
type Light:
  | Red
  | Green
  transitions:
    Red -> Grean
"""
  t.badCheck "transition endpoint typo", "not\\ a\\ variant"

  t.src """
type Session [sealed]:
  | Disconnected
  | Connecting({host: str})
  | Zombie
  transitions:
    Disconnected -> Connecting
    Connecting -> Disconnected
"""
  t.badCheck "sealed variant unreachable", "unreachable\\ from\\ initial"

  t.src """
type Session [sealed]:
  | Disconnected
  | Connecting({host: str})
  | Connected({keepalive: int})
  transitions:
    Disconnected -> Connecting
    Connecting -> Connected
    Connecting -> Disconnected
    Connected -> Disconnected
"""
  t.okCheck "valid sealed transition graph"

  t.src """
decision route({priority: int, encrypted: bool}) -> int:
  | high  _     -> 1
  | high  true  -> 2
  | _     _     -> 3
"""
  t.badCheck "decision row unreachable", "unreachable"

  t.src """
decision route({priority: int, encrypted: bool}) -> int:
  | high  true  -> 1
  | low   false -> 2
"""
  t.badCheck "decision missing catch-all", "catch\\-all"

  t.src """
decision route({priority: int, encrypted: bool}) -> int:
  | high  true  -> 1
  | high  false -> 2
  | _     _     -> 3
"""
  t.okCheck "valid decision table"

  t.src """
type Priority:
  | High
  | Low

decision route({priority: Priority, encrypted: bool}) -> int:
  | High  true  -> 1
  | High  false -> 2
  | Low   _     -> 3
"""
  t.okCheck "enum-domain table complete without catch-all"

  t.src """
type Priority:
  | High
  | Low

decision route({priority: Priority, encrypted: bool}) -> int:
  | High  true  -> 1
  | Low   _     -> 3
"""
  t.badCheck "enum-domain table gap found exactly", "has\\ a\\ gap"

  t.src """
type Priority:
  | High
  | Low

decision route({priority: Priority, encrypted: bool}) -> int:
  | Hgih  true  -> 1
  | _     _     -> 2
"""
  t.badCheck "enum-domain symbol typo", "not\\ a\\ value\\ of"

  t.src """
type Priority:
  | High
  | Low

decision route({priority: Priority, encrypted: bool}) -> int:
  | High  _     -> 1
  | Low   _     -> 2
  | High  true  -> 3
"""
  t.badCheck "enum-domain unreachable row proven", "unreachable"

  t.src """
fn mightFail({n: int}) -> !{value: int}:
  return {value: n}
"""
  t.badCheck "fallible fn must be [io]", "must\\ be\\ marked\\ \\[io\\]"

  t.src """
fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  return {n} mightFail + 1
"""
  t.badCheck "unhandled !T in arithmetic", "unhandled"

  t.src """
fn mightFail({n: int}) -> !{amount: int} [io]:
  return {amount: n}

fn use({n: int}) -> int [io]:
  let r = {n} mightFail
  return r.amount
"""
  t.badCheck "unhandled !T payload access", "unhandled"

  t.src """
fn mightFail({n: int}) -> !{amount: int} [io]:
  return {amount: n}

fn use({n: int}) -> int [io]:
  let r = {n} mightFail
  if r.ok:
    return r.value.amount
  return 0
"""
  t.okCheck "result introspection (.ok/.value) is the handling"

  t.src """
fn mightFail({n: int}) -> !{amount: int} [io]:
  return {amount: n}

fn use({n: int}) -> int [io]:
  let r = {n} mightFail
  if r.ok:
    let x = 1
  return r.value.amount
"""
  t.badCheck ".value outside the ok guard", "guard\\ it\\ first"

  t.src """
fn use({n: int}) -> int:
  err 5
"""
  t.badCheck "err outside a fallible fn", "must\\ declare\\ a\\ !T\\ return\\ type"

  t.src """
fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  let r = {n} mightFail or {value: 0}
  return r.value
"""
  t.badCheck "'or' cannot unwrap results", "unhandled"

  t.src """
fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  {n} mightFail
  return 0
"""
  t.badCheck "discarded !T result", "discarded"

  t.src """
fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  {n} mightFail
  {n} mightFail
  return 0
"""
  t.badCheck "strict lists ALL unhandled sites", "2\\ unhandled"

  t.src """
errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    ...

fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  {n} mightFail
  return 0
"""
  t.okCheck "continue policy legalizes statement drops"

  t.src """
errors [policy: continue]

fn f({n: int}) -> int:
  return n
"""
  t.badCheck "continue policy needs a handler", "needs\\ an\\ 'on\\ unhandled"

  t.src """
errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    ...

fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  return {n} mightFail + 1
"""
  t.badCheck "continue does not legalize value positions", "unhandled"

  t.src """
errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    ...

type ParseError:
  | Empty

fn parseTitle({raw: str}) -> !str [io, error: ParseError]:
  if raw == "":
    err Empty
  return raw
"""
  t.okCheck "a guard clause raising err is not a dropped result"
  # The guard exits on one path and falls through on the other, so nothing is
  # dropped. Reported as a drop under a continue policy, codegen wrapped a
  # branch that only returns in `(let tuckDrop1 = ...)` — not an expression,
  # so the emitted Nim died on `invalid indentation`. ok_check alone would not
  # catch a return of that bug: the spurious shortcut still CHECKS clean.
  t.omits "a guard clause emits no drop-site wrapper", "tuckDrop"

  t.src """
type FsError:
  | NotFound
  | AccessDenied

fn readIt({path: str}) -> !{content: str} [io, error: FsError]:
  if {path} missing:
    return err FsError.NotFound
  err AccessDenied
"""
  t.okCheck "err raise: qualified and shorthand variants"

  t.src """
type FsError:
  | NotFound
  | AccessDenied

fn readIt({path: str}) -> !{content: str} [io, error: FsError]:
  err DiskFull
"""
  t.badCheck "err raise: unknown variant", "not\\ a\\ variant"

  t.src """
type FsError:
  | NotFound
  | AccessDenied
type NetError:
  | Timeout
  | Refused

fn readIt({path: str}) -> !{content: str} [io, error: FsError]:
  err NetError.Timeout
"""
  t.badCheck "err raise: enum not in the declared list", "declares\\ \\[error:\\ FsError\\]"

  t.src """
type FsError:
  | NotFound
  | AccessDenied
type NetError:
  | Timeout
  | Refused

fn fetchIt({url: str}) -> !{content: str} [io, error: FsError | NetError]:
  if {url} slow:
    return err Timeout
  err FsError.NotFound
"""
  t.okCheck "err raise: multiple error enums"

  t.src """
type FsError:
  | NotFound
  | Timeout
type NetError:
  | Timeout
  | Refused

fn fetchIt({url: str}) -> !{content: str} [io, error: FsError | NetError]:
  err Timeout
"""
  t.badCheck "err raise: variant ambiguous across listed enums", "ambiguous"

  t.src """
fn mightFail({n: int}) -> !{amount: int} [io]:
  return {amount: n}

fn use({n: int}) -> !{total: int} [io]:
  let r = {n} mightFail
  if r.ok:
    return {total: r.value.amount}
  err r.err
"""
  t.okCheck "re-raise an existing code (err r.err)"

  t.src """
fn mightBeAbsent({n: int}) -> ?{amount: int}:
  return {amount: n}

fn use({n: int}) -> int:
  let r = {n} mightBeAbsent
  if r.ok:
    return r.value.amount
  return 0
"""
  t.okCheck "option introspection on ?T"

  t.src """
fn mightBeAbsent({n: int}) -> {amount: int}?:
  return {amount: n}

fn both({n: int}) -> {amount: int}?! [io]:
  return {amount: n}
"""
  t.okCheck "postfix wrapper types: int? and combos"

  t.src """
distinct Milliseconds = u32
distinct Microseconds = u32

fn ms(value: u32) -> Milliseconds:
  value Milliseconds

fn us(value: u32) -> Microseconds:
  value Microseconds

fn delay({ms: Milliseconds}) -> {done: bool}:
  {done: true}

fn main() -> void:
  let r = {ms: 5.us} delay
  return
"""
  t.badCheck "unit mismatch rejected", "field\\ 'ms'"

  t.src """
distinct Milliseconds = u32
distinct Microseconds = u32

fn ms(value: u32) -> Milliseconds:
  value Milliseconds

fn us(value: u32) -> Microseconds:
  value Microseconds

fn delay({ms: Milliseconds}) -> {done: bool}:
  {done: true}

fn main() -> void:
  let r = {ms: 5} delay
  return
"""
  t.badCheck "bare int where unit expected", "field\\ 'ms'"

  t.src """
distinct Milliseconds = u32
distinct Microseconds = u32

fn ms(value: u32) -> Milliseconds:
  value Milliseconds

fn us(value: u32) -> Microseconds:
  value Microseconds

fn delay({ms: Milliseconds}) -> {done: bool}:
  {done: true}

fn main() -> void:
  let r = {ms: 5.ms} delay
  return
"""
  t.okCheck "matching unit accepted"

  t.src """
distinct Milliseconds = u32
distinct Microseconds = u32

fn ms(value: u32) -> Milliseconds:
  value Milliseconds

fn us(value: u32) -> Microseconds:
  value Microseconds

fn delay({ms: Milliseconds}) -> {done: bool}:
  {done: true}

fn f({a: Milliseconds, b: Microseconds}) -> {v: Milliseconds}:
  {v: a + b}
"""
  t.badCheck "arithmetic between different units", "arithmetic"

  t.src """
distinct Milliseconds = u32
distinct Microseconds = u32

fn ms(value: u32) -> Milliseconds:
  value Milliseconds

fn us(value: u32) -> Microseconds:
  value Microseconds

fn delay({ms: Milliseconds}) -> {done: bool}:
  {done: true}

fn f({a: Milliseconds, b: Milliseconds}) -> {v: Milliseconds}:
  {v: a + b}
"""
  t.okCheck "same-unit arithmetic"

  t.src """
fn double({n: int}) -> {v: int}:
  {v: n + n}
"""
  t.okCheck "implicit tail return"

  t.src """
fn f({n: int}) -> {v: int}:
  {v: "nope"}
"""
  t.badCheck "implicit tail wrong type", "flows"

  t.src """
fn f({flag: bool}) -> {v: int}:
  if flag:
    {v: 1}
  else:
    {v: "s"}
"""
  t.badCheck "if branches disagree on type", "different\\ types"

  t.src """
fn f({flag: bool}) -> {v: int}:
  if flag:
    return {v: 1}
  else:
    return {v: 2}
"""
  t.okCheck "if branches agree"

  t.src """
type Session [sealed]:
  | Disconnected
  | Connected({keepalive: int})
  transitions:
    Disconnected -> Connected
    Connected -> Disconnected

fn main() -> void:
  let s = Session.Connected {keepalive: 60}
  return
"""
  t.badCheck "sealed non-initial construction rejected", "cannot\\ be\\ constructed\\ directly"

  t.src """
type Session [sealed]:
  | Disconnected
  | Connected({keepalive: int})
  transitions:
    Disconnected -> Connected
    Connected -> Disconnected

fn main() -> void:
  let s = Session.Disconnected
  return
"""
  t.okCheck "sealed initial construction allowed"

  t.src """
type Session [sealed]:
  | Disconnected
  | Connected({keepalive: int})
  transitions:
    Disconnected -> Connected
    Connected -> Disconnected

fn main() -> void:
  let s = Session.Connected [unsafe] {keepalive: 60}
  return
"""
  t.okCheck "sealed non-initial with unsafe escape"

  t.src """
type State:
  | Idle
  | Busy({job: int})

fn main() -> void:
  let s = State.Busy {job: 1}
  return
"""
  t.okCheck "unsealed type constructs any variant"

  t.src """
fn writeLog({msg: str}) -> void [io]:
  return

fn doWork({msg: str}) -> void:
  {msg} writeLog
"""
  t.badCheck "pure fn calling io fn", "requires\\ effect\\ \\[io\\]"

  t.src """
fn writeLog({msg: str}) -> void [io]:
  return

fn doWork({msg: str}) -> void [io]:
  {msg} writeLog
"""
  t.okCheck "io propagation declared"

  t.src """
pending:
  fn fetchFeed({url: str}) -> {feed: int}

fn main() -> void:
  let x = {url: 42} fetchFeed
  return
"""
  t.badCheck "pending sig strictly checked at call site", "field\\ 'url'"

  t.src """
fn fetchFeed({url: str}) -> int:
  return 1

pending:
  fn fetchFeed({url: str}) -> int
"""
  t.badCheck "implemented fn still in pending block", "remove\\ it\\ from\\ the\\ pending\\ block"

  t.src """
pending:
  fn fetchFeed({url: str}) -> {feed: int}

fn main() -> void:
  let x = {url: "https://x"} fetchFeed
  let y = x.feed
  return
"""
  t.okCheck "correct call to pending fn"

  t.src """
fn send({email: str}) -> int:
  return 1

fn main() -> void:
  let x = {id: 5, email: "a@b.c", name: "Bo"} send
  return
"""
  t.okCheck "subset matching: extra fields ignored"

  t.src """
fn main() -> void:
  let feed = {url: "https://x"} fetch parse
  return
"""
  t.okCheck "unknown callee flows through"

  t.src """
fn main() -> void:
  var cfg = {port: 80}
  cfg ..port {8080}
  return
"""
  t.okCheck "var mutation allowed"

  t.src """
type Server:
  port: int

fn describe({port: int}) -> str:
  return "server"

fn main() -> void:
  let server = {port: 80} Server
  let d = server.describe
  return
"""
  t.okCheck "'.' calls a fn when the name is not a field"

  t.src """
type Server:
  port: int

fn withPort({self: Server, value: int}) -> Server:
  return {port: value} Server

fn main() -> void:
  var server = {port: 0} Server
  server ..withPort {80}
  return
"""
  t.okCheck "'..' reassigns from a mutator fn: arg1 is the receiver, returns its type"

  t.src """
type Server:
  port: int

fn withPort({count: int, value: int}) -> Server:
  return {port: value} Server

fn main() -> void:
  var server = {port: 0} Server
  server ..withPort {80}
  return
"""
  t.badCheck "'..' on a fn whose first param is not the receiver type", "first\\ parameter"

  # An OBJECT MEMBER with no explicit self, called via `.fn {payload}`: the
  # receiver fills self IMPLICITLY (added later by lowering, not something
  # this signature carries), and every declared param — here just `step` —
  # is matched from the payload by name. Confused with the mutator case
  # above once: `crank`'s one declared param got checked against the
  # receiver's type instead of self's ("expects int but got Deck"), because
  # the two conventions share one proc (synthMethodCall) and only differ in
  # whether the receiver fills params[0] or params[0] is genuinely absent.
  t.src """
object Deck:
  volume: int

  fn crank({step: int}) -> int:
    return self.volume + step

fn main() -> int:
  var d = {volume: 5} Deck
  return d.crank {step: 1}
"""
  t.okCheck "a member fn with no explicit self is called via .fn {payload}"
  t.runs "the receiver fills self, the payload fills the rest: 5 + 1", 6
  # genOdinMemberFn gives EVERY member fn's self a pointer, ^T,
  # unconditionally — this call shape was unreachable before the checker
  # fix above, and the emitted call passed the receiver by value, which
  # Odin itself rejects ("Cannot assign value 'd' ... to '^tuck_Deck'").
  t.emitsOdin "Odin passes the receiver by address to match self: ^T",
              r"tuck_Deck_crank\(&d, 1\)"

  t.src """
type Server:
  port: int

fn scaled({self: Server, factor: int}) -> int:
  return factor

fn main() -> void:
  let server = {port: 80} Server
  let n = server.scaled {factor: 2}
  return
"""
  t.okCheck "'.fn {args}': receiver is the first param, braced args fill the rest"

  t.src """
type Server:
  port: int

fn scaled({self: Server, factor: int}) -> int:
  return factor

fn main() -> void:
  let server = {port: 80} Server
  let n = server.scaled {}
  return
"""
  t.badCheck "'.fn {args}': missing param not covered by the braced args", "missing\\ required\\ field\\ 'factor"

  t.src """
type Server:
  port: int

fn main() -> void:
  let server = {port: 80} Server
  let n = server.port {8080}
  return
"""
  t.badCheck "'.field {args}': fields take no arguments", "'port'\\ is\\ a\\ field"

  t.src """
fn double({value: int}) -> int:
  return value * 2

fn main() -> void:
  let n = {8080} double
  return
"""
  t.okCheck "bare value braces: {8080} is {value: 8080}"

  t.src """
type Server:
  port: int

fn describe({self: Server}) -> str:
  return "server"

fn main() -> void:
  var server = {port: 0} Server
  server ..describe {}
  return
"""
  t.badCheck "'..' fn call whose return type does not match the var", "cannot\\ assign\\ str\\ to\\ Server"

  t.src """
type Server:
  port: int

fn main() -> void:
  let server = {port: 0} Server
  let x = server.mystery
  return
"""
  t.badCheck "'.' on a name that is neither a field nor a fn", "no\\ field\\ 'mystery'"

  t.src """
type Server:
  port: int
  host: str

fn main() -> void:
  var server = {port: 0, host: "a"} Server
  server ..port {host: 80}
  return
"""
  t.badCheck "field set rejects a named-field payload", "takes\\ one\\ bare\\ value"

  t.src """
type Server:
  host: str

fn main() -> void:
  var server = {host: "a"} Server
  let name = "b"
  server ..host {name}
  return
"""
  t.okCheck "field set accepts a bare var payload (ident shorthand)"

  t.src """
type Server:
  port: int

fn port({value: int}) -> int:
  return value

fn main() -> void:
  return
"""
  t.badCheck "fn name colliding with a declared field name must rename", "rename"

  t.src """
fn port({value: int}) -> int:
  return value

fn main() -> void:
  let cfg = {port: 80}
  let x = cfg.port
  return
"""
  t.badCheck "'.' ambiguous on an anonymous struct: field and fn share the name", "rename"

  t.src """
fn playTrack({id: int, name: str}) -> void:
  return

fn main() -> void:
  let ext = {trackId: 42, title: "x"}
  let normalized = ext alias(trackId: id, title: name)
  normalized playTrack
  return
"""
  t.okCheck "alias restructures: renamed fields satisfy the consumer"

  t.src """
fn playTrack({id: int, name: str}) -> void:
  return

fn main() -> void:
  let ext = {trackId: 42, title: "x"}
  let normalized = ext alias(trackId: id)
  normalized playTrack
  return
"""
  t.badCheck "alias result is typed: consumer catches a missing field", "missing\\ required\\ field\\ 'name"

  t.src """
fn main() -> void:
  let ext = {trackId: 42}
  let normalized = ext alias(wrong: id)
  return
"""
  t.badCheck "alias source field must exist on the receiver", "does\\ not\\ exist"

  t.src """
fn add({a: int, b: int}) -> int:
  return a + b

fn consume({a: int, b: int}) -> int:
  return a + b

fn main() -> void:
  let x = {a: 5, b: 10}
  let y = x bake {op: :add}
  let z = y bake {b: 2}
  let r = {a: z.a, b: z.b} consume
  return
"""
  t.okCheck "bake fills a fn slot and overrides values; result is typed"

  t.src """
fn main() -> void:
  let x = {a: 5, b: 10}
  let y = x bake {a: "nope"}
  let r = y.a + 1
  return
"""
  t.badCheck "bake value override must keep the field's type", "bake\\ override\\ 'a'\\ expects\\ int\\ but\\ got\\ str"

  t.src """
type Episode:
  title: str

fn header({episode: Episode, n: int}) -> str:
  return input.episode.title

fn main() -> void:
  return
"""
  t.okCheck "input: the whole incoming payload, typed"

  t.src """
fn f({a: int}) -> int:
  return input.missing

fn main() -> void:
  return
"""
  t.badCheck "input: unknown field is caught", "no\\ field\\ 'missing'"

  t.src """
type Episode:
  title: str

type Prefs:
  volume: int

fn describe({title: str, volume: int}) -> str:
  return title

fn play({episode: Episode, prefs: Prefs}) -> void:
  let ctx = {episode, prefs} merge
  let d = ctx describe
  return

fn main() -> void:
  return
"""
  t.okCheck "merge flattens member structs; consumer sees the union"

  t.src """
type A:
  x: int

type B:
  x: str

fn f({a: A, b: B}) -> void:
  let ctx = {a, b} merge
  return

fn main() -> void:
  return
"""
  t.badCheck "merge: field name collision between members", "duplicate merge field"

  t.src """
fn f({a: int}) -> void:
  let ctx = {a} merge
  return

fn main() -> void:
  return
"""
  t.badCheck "merge member must be a struct", "must\\ be\\ a\\ struct"

  t.src """
fn f({a: int}) -> int:
  return a

let x = {a: 1} f
"""
  t.badCheck "top-level statements are not allowed", "top\\-level\\ statements"

  # A misspelled opening keyword used to fall through to an EXPRESSION statement
  # and die at the colon — `typ Light:` blamed column 10 for a typo in column 1.
  # Found by the fuzzer twice. The message names the valid openers rather than
  # guessing which was meant.
  t.src """
typ Light:
  a: int
"""
  t.badCheck "a misspelled top-level keyword names the valid ones", "does\\ not\\ start\\ a\\ declaration"

  # The first word alone decides — no second word needed to reach the same error.
  t.src """
ac:
  t: int
"""
  t.badCheck "a bare misspelled keyword is rejected on the first word", "does\\ not\\ start\\ a\\ declaration"

  # ...but an arena body holds ordinary STATEMENTS, parsed through the same
  # parseDecl. `ScratchSpace.reset` is a bare ident there and must stay legal —
  # which is why the check lives in parseModule, not parseDecl.
  t.src """
arena ScratchSpace [size: 2048]:
  ScratchSpace.reset

fn main() -> void:
  return
"""
  t.okCheck "an arena body still holds bare statements"

  # `satisfies` is a top-level declaration opener like any other, so it must not
  # be caught by the misspelled-keyword check above. (It used to be spelled
  # `Obj satisfies Iface`, deciding on the SECOND word — the one construct that
  # needed a two-token lookahead, and the reason that check has to be careful.)
  t.src """
object Dog:
  n: int
  fn noise({self: Dog}) -> int:
    return n

interface Animal:
  fn noise({self: Self}) -> int

satisfies Dog: Animal

fn main() -> void:
  return
"""
  t.okCheck "satisfies still parses at top level"

  t.src """
let x = 5
"""
  t.badCheck "top-level let is not allowed either", "top\\-level\\ statements"

  t.src """
const maxRetries = 3
const defaults = {port: 80, host: "local"}

fn f({n: int}) -> int:
  return n + maxRetries

fn main() -> void:
  let p = defaults.port + maxRetries
  return
"""
  t.okCheck "const: compile-time data, usable from fns"

  t.src """
distinct Milliseconds = u32

fn ms(value: u32) -> Milliseconds:
  value Milliseconds

fn plus({a: int, b: int}) -> int:
  return a + b

const timeout = 5.ms
const sum = {a: 2, b: 3} plus
"""
  t.okCheck "const evaluates pure computation at compile time"

  t.src """
fn readPort() -> int [io]:
  return 80

const p = {} readPort
"""
  t.badCheck "const initializer must be pure (no io)", "pure"

  t.src """
type Server:
  port: int

const s = {port: 80} Server
"""
  t.badCheck "const cannot hold a record construction (ref semantics)", "record"

  t.src """
const K = {1} mystery
"""
  t.badCheck "const rejects an unknown callee", "unknown"

  t.src """
fn double({n: int}) -> int:
  return n * 2

const K = {2} double
"""
  t.okCheck "const accepts a declared pure fn"

  t.src """
type Door:
  | Closed
  | Open
  | Locked

  transitions:
    Closed -> Open
    Open   -> Closed
    Closed -> Locked
    Locked -> Closed


fn main() -> void:
  var d = Door.Closed
  d = Door.Open
  return
"""
  t.okCheck "transition: legal reassignment"

  t.src """
type Door:
  | Closed
  | Open
  | Locked

  transitions:
    Closed -> Open
    Open   -> Closed
    Closed -> Locked
    Locked -> Closed


fn main() -> void:
  var d = Door.Open
  d = Door.Locked
  return
"""
  t.badCheck "transition: illegal edge on reassignment", "Open\\ \\->\\ Locked"

  t.src """
type Door:
  | Closed
  | Open
  | Locked

  transitions:
    Closed -> Open
    Open   -> Closed
    Closed -> Locked
    Locked -> Closed


fn main() -> void:
  var d = Door.Closed
  d = Door.Closed
  return
"""
  t.okCheck "transition: same-variant reassignment allowed"

  t.src """
type Door:
  | Closed
  | Open
  | Locked

  transitions:
    Closed -> Open
    Open   -> Closed
    Closed -> Locked
    Locked -> Closed


fn main() -> void:
  var d = Door.Closed
  if true:
    d = Door.Open
  d = Door.Closed
  return
"""
  t.okCheck "transition: branch merge, next hop legal from both"

  t.src """
type Door:
  | Closed
  | Open
  | Locked

  transitions:
    Closed -> Open
    Open   -> Closed
    Closed -> Locked
    Locked -> Closed


fn main() -> void:
  var d = Door.Closed
  if true:
    d = Door.Open
  d = Door.Locked
  return
"""
  t.badCheck "transition: branch merge, edge missing from one member", "Open\\ \\->\\ Locked"

  t.src """
type Door:
  | Closed
  | Open
  | Locked

  transitions:
    Closed -> Open
    Open   -> Closed
    Closed -> Locked
    Locked -> Closed


fn slam({d: Door}) -> void:
  var x = d
  x = Door.Locked
  return
"""
  t.badCheck "transition: param starts at the full set", "\\->\\ Locked"

  t.src """
type Door:
  | Closed
  | Open
  | Locked

  transitions:
    Closed -> Open
    Open   -> Closed
    Closed -> Locked
    Locked -> Closed


fn slam({d: Door}) -> void:
  var x = d
  match x:
    Closed: x = Door.Locked
    Open: x = Door.Closed
    Locked: x = Door.Closed
  return
"""
  t.okCheck "transition: match narrowing unlocks the edge"

  # Variant state is per BINDING. An inner `var s` is a different variable
  # whose state must not merge into the outer one when its scope ends —
  # keyed by name alone it did, widening the outer to {Idle|Running} and
  # rejecting a Running -> Done edge that is declared and legal.
  t.src """
type Phase [sealed]:
  | Idle
  | Running
  | Done
  transitions:
    Idle -> Running
    Running -> Done

fn main({b: bool}) -> int:
  var s = Phase.Idle
  s = Phase.Running
  if b:
    var s = Phase.Idle
  s = Phase.Done
  return 0
"""
  t.okCheck "an inner binding's variant state does not leak to the outer one"

  t.src """
type Door:
  | Closed
  | Open
  | Locked

  transitions:
    Closed -> Open
    Open   -> Closed
    Closed -> Locked
    Locked -> Closed


fn cycle({d: Door}) -> int:
  var x = d
  var n = 0
  match x:
    Closed:
      x = Door.Open
      n = 1
    Open:
      x = Door.Closed
      n = 2
    Locked: n = 3
  return n
"""
  t.okCheck "match arms take indented multi-statement blocks"

  t.src """
type Door:
  | Closed
  | Open
  | Locked

  transitions:
    Closed -> Open
    Open   -> Closed
    Closed -> Locked
    Locked -> Closed


fn fresh() -> Door:
  return Door.Closed

fn main() -> void:
  var d = {} fresh
  d = Door.Locked
  return
"""
  t.okCheck "transition: fn returning a construction narrows the caller"

  t.src """
type ParseError:
  | Empty
  | TooLong

fn parseTitle({raw: str}) -> !str [io, error: ParseError]:
  if raw == "":
    err Empty
  return raw


fn use({raw: str}) -> int [io]:
  let r = {raw} parseTitle
  if r.ok:
    return 0
  match r.err:
    Empty: return 1
    TooLong: return 2
"""
  t.okCheck "match r.err validates arms against the declared enum"

  t.src """
type ParseError:
  | Empty
  | TooLong

fn parseTitle({raw: str}) -> !str [io, error: ParseError]:
  if raw == "":
    err Empty
  return raw


fn use({raw: str}) -> int [io]:
  let r = {raw} parseTitle
  if r.ok:
    return 0
  match r.err:
    Emtpy: return 1
    TooLong: return 2
"""
  t.badCheck "match r.err catches a variant typo", "not\\ a\\ variant\\ of\\ ParseError"

  t.src """
type Server:
  port: int

fn main() -> void:
  let s = {port: 80} Server
  return
"""
  t.okCheck "declarations-only module is fine"

  t.src """
fn isEven(n: int) -> bool:
  return n isOdd

fn isOdd(n: int) -> bool:
  return n isEven
"""
  t.okCheck "mutual recursion via pre-collected sigs"

  t.src """
fn setPort({port: u8}) -> int:
  return 1

fn main() -> void:
  let x = {port: 80} setPort
  return
"""
  t.okCheck "numeric widening int literal to u8"

  t.src """
pending:
  fn http::get({url: str}) -> !{body: str} [io]

fn go({url: str}) -> !{body: str} [io]:
  return {url} http::get
"""
  t.okCheck "qualified pending call, matching payload"

  t.src """
fn go({url: str}) -> !{body: str} [io]:
  return {url} http::get

pending:
  fn http::get({url: str}) -> !{body: str} [io]
"""
  t.okCheck "qualified call site before its pending decl (order-free)"

  t.src """
pending:
  fn http::get({url: str}) -> !{body: str} [io]

fn go() -> !{body: str} [io]:
  return {url: 42} http::get
"""
  t.badCheck "qualified call: wrong field type", "expects"

  t.src """
pending:
  fn http::get({url: str}) -> !{body: str} [io]

fn go() -> void:
  let x = {url: "a"} http::post
"""
  t.badCheck "known module, missing function", "has\\ no\\ function"

  t.src """
fn go() -> void:
  {volume: 3} audio::play
"""
  t.okCheck "unknown module prefix stays gradual"

  t.src """
fn identity[T]({x: T}) -> T:
  return x

fn f() -> int:
  let y = {x: 5} identity
  return y + 1
"""
  t.okCheck "generic fn call infers and flows return type"

  t.src """
fn identity[T]({x: T}) -> T:
  return x

fn g() -> int:
  return {x: "s"} identity
"""
  t.badCheck "generic return type mismatch at call site", "int"

  t.src """
fn pair[T]({a: T, b: T}) -> T:
  return a

fn main() -> void:
  let x = {a: 1, b: "s"} pair
  return
"""
  t.badCheck "generic binding conflict", "'T'"

  t.src """
fn firstOf[T]({xs: Seq[T]}) -> T:
  return {xs} head

fn f({nums: Seq[int]}) -> int:
  let n = {xs: nums} firstOf
  return n + 1
"""
  t.okCheck "generic param inside container type"

  t.src """
type Box[T] = {value: T}

fn get({b: Box[int]}) -> int:
  return b.value
"""
  t.okCheck "generic type alias in signature"

  t.src """
type Box[T] = {value: T}

fn get({b: Box[int]}) -> str:
  return b.value
"""
  t.badCheck "generic type alias field mismatch", "str"

  t.src """
type Box[T] = {value: T}

fn f() -> int:
  let b = {value: 5} Box
  return b.value
"""
  t.okCheck "generic record construction infers instantiation"

  t.src """
type Box[T] = {value: T}

fn f() -> int:
  let b = {} Box
  return 1
"""
  t.badCheck "generic construction with uninferrable param", "cannot\\ infer"

  t.src """
fn main() -> int:
  var n = 0
  loop:
    n += 1
    if n == 3:
      break
  for n > 0:
    n -= 1
    if n == 1:
      continue
  return n
"""
  t.okCheck "loop with break, for-cond with continue"

  t.src """
fn main() -> int:
  var acc = 0
  for i in 0 .. 3:
    acc += i
  for i in 0 ..< 3:
    acc += i
  let xs = [10, 20, 30]
  for idx, item in xs:
    acc += idx
  return acc
"""
  t.okCheck "ranges and indexed for"

  t.src """
fn inline bump({x: int}) -> int:
  return x + 1

fn main() -> int:
  return bump {x: 41}
"""
  t.okCheck "fn inline parses and typechecks"

  t.src """
fn main() -> int:
  break
  return 0
"""
  t.badCheck "break outside loop", "break\\ outside"

  t.src """
fn main() -> int:
  continue
  return 0
"""
  t.badCheck "continue outside loop", "continue\\ outside"

  t.src """
fn main() -> int:
  for 5:
    return 1
  return 0
"""
  t.badCheck "non-bool loop condition", "must\\ be\\ bool"

  t.src """
type Box:
  n: int

fn main() -> int:
  let b = Box[128]
  return 0
"""
  t.okCheck "single-arg type application is not indexing"

  t.src """
type Array:
  n: int

fn main() -> int:
  let b = Array[128, 8]
  return 0
"""
  t.okCheck "multi-arg type application in expression position"

  t.src """
import seq

fn main() -> int:
  var xs = [10, 20, 30]
  return xs[1, 2]
"""
  t.badCheck "multi-arg bracket on a value is not an index", "index"

  t.src """
fn readIt({n: int}) -> !{v: int} [io]:
  return {v: n}

fn main() -> int [io]:
  let r = {n: 5} readIt
  if not r.ok:
    return 0
  return r.value.v
"""
  t.okCheck "early-return guard narrows the rest of the fn"

  t.src """
fn readIt({n: int}) -> !{v: int} [io]:
  return {v: n}

fn main() -> int [io]:
  let r = {n: 5} readIt
  if not r.ok:
    let x = 1
  return r.value.v
"""
  t.badCheck "a guard that falls through does NOT narrow", "guard\\ it\\ first"

  t.src """
fn readIt({n: int}) -> !{v: int} [io]:
  return {v: n}

fn main() -> int [io]:
  let r = {n: 5} readIt
  return r.value.v
"""
  t.badCheck "no guard at all is still an error", "guard\\ it\\ first"

  # Narrowing is keyed by BINDING, not by name. An inner `r` is a different
  # result that nothing has guarded, so it must not inherit the outer's
  # narrowing just for sharing a spelling.
  t.src """
fn readIt({n: int}) -> !{v: int} [io]:
  return {v: n}

fn main({b: bool}) -> int [io]:
  let r = {n: 5} readIt
  if not r.ok:
    return 0
  if b:
    let r = {n: 9} readIt
    return r.value.v
  return r.value.v
"""
  t.badCheck "an inner binding does not inherit the outer's narrowing",
             "guard\\ it\\ first"

  t.src """
type Slot:
  id: int

pool Slots = Slot [count: 2]

fn main() -> int:
  let s = Slots.acquire
  if not s.ok:
    return 0
  return s.value.id
"""
  t.okCheck "early-return guard works for ?T from a pool"

  t.src """
fn main() -> int:
  let p = {flag: true}
  if not p.flag:
    return 0
  return 1
"""
  t.okCheck "unary `not` binds looser than field access"

  t.src """
type Conn:
  id: int

pool Conns = Conn [count: 16]

fn main() -> int:
  return 0
"""
  t.okCheck "pool declares an element type and a count"

  t.src """
pool Bufs = Array[64, u8] [count: 8]

fn main() -> int:
  return 0
"""
  t.okCheck "pool of a primitive array"

  t.src """
pool Bufs = Array[64, u8] [count: 4]

fn main() -> int:
  let b = Bufs.acquire
  if not b.ok:
    return 1
  Bufs.release {b.value}
  return 0
"""
  t.okCheck "acquire yields an optional handled with .ok"

  t.src """
pool Bufs = Array[64, u8] [count: 4]

fn use({n: int}) -> int:
  let b = Bufs.acquire
  return b.n
"""
  t.badCheck "acquire result is an unhandled optional", "unhandled"

  t.src """
fn main() -> int:
  let a = 5 or 3
  return 0
"""
  t.badCheck "'or' rejects non-bool operands", "expects\\ bool"

  t.src """
fn main() -> int:
  let a = "x" and "y"
  return 0
"""
  t.badCheck "'and' rejects non-bool operands", "expects\\ bool"

  t.src """
fn main() -> int:
  let x = 1
  let a = x > 0 or x < 10
  return 0
"""
  t.okCheck "'or' on bools is fine"

  t.src """
fn find({n: int}) -> ?{value: int} [io]:
  return {value: n}

fn main() -> int [io]:
  let a = {n: 1} find
  let b = {n: 2} find
  if a and b:
    return 1
  return 0
"""
  t.okCheck "?T reads as presence in a boolean guard"

  t.src """
type Door:
  | Closed
  | Open
  | Locked

  transitions:
    Closed -> Open
    Open   -> Closed
    Closed -> Locked
    Locked -> Closed


fn label({d: Door}) -> int:
  var n = 0
  match d:
    Closed: n = 1
    Open: n = 2
  return n
"""
  t.badCheck "match missing a variant is rejected", "Locked"

  t.src """
type Door:
  | Closed
  | Open
  | Locked

  transitions:
    Closed -> Open
    Open   -> Closed
    Closed -> Locked
    Locked -> Closed


fn label({d: Door}) -> int:
  var n = 0
  match d:
    Closed: n = 1
    Open: n = 2
    Locked: n = 3
  return n
"""
  t.okCheck "match covering all variants is exhaustive"

  t.src """
type Door:
  | Closed
  | Open
  | Locked

  transitions:
    Closed -> Open
    Open   -> Closed
    Closed -> Locked
    Locked -> Closed


fn label({d: Door}) -> int:
  var n = 0
  match d:
    Closed: n = 1
    _: n = 0
  return n
"""
  t.okCheck "a catch-all _ makes a match exhaustive"

  t.src """
fnsig Adder = {a: int, b: int} -> {sum: int}

type Calc = {op: Adder}
"""
  t.okCheck "fnsig declares a named signature usable as a field type"

  t.src """
fnsig Predicate = {x: int} -> bool

type Filter = {test: Predicate}
"""
  t.okCheck "fnsig with a bare return type"

  t.src """
fnsig Adder = {a: int, b: int} -> {sum: int}

type Calc = {op: Adder}

fn use({c: Calc}) -> int:
  let r = {a: 1} c.op
  return r.sum
"""
  t.badCheck "a call through a fnsig slot checks arity", "Adder"

  t.src """
fn playTrack({id: int, name: str, ok: bool}) -> void:
  ...

fn main() -> void:
  let ext = {trackId: 42, title: "Slow Jam", active: true}
  ext playTrack
  return
"""
  t.okCheck "auto-match by type when names differ"

  t.src """
fn playTrack({id: int, length: int}) -> void:
  ...

fn main() -> void:
  let ext = {trackId: 42, durationMs: 215000}
  ext playTrack
  return
"""
  t.badCheck "ambiguous same-typed fields need an alias", "missing\\ required\\ field"

  t.src """
fn f({a: int, b: int}) -> void:
  ...

fn main() -> void:
  let r = {b: 2, a: 1}
  r f
  return
"""
  t.okCheck "name match wins over a same-typed rival field"

  t.src """
fn f({count: int, label: str}) -> void:
  ...

fn main() -> void:
  let r = {count: 7, title: "x"}
  r f
  return
"""
  t.okCheck "name matches first, then type fills the rest"

  t.src """
fn f({count: int, label: str}) -> void:
  ...

fn main() -> void:
  let r = {count: 7, other: 9}
  r f
  return
"""
  t.badCheck "no candidate of the required type", "missing\\ required\\ field\\ 'label"

  t.src """
fn f({id: int, name: str}) -> void:
  ...

fn main() -> void:
  {userId: 3, handle: "kobi"} f
  return
"""
  t.okCheck "auto-match on a struct literal argument"

  t.src """
fn f({n: int, x: float}) -> void:
  ...

fn main() -> void:
  let r = {alpha: 1, beta: 2.5}
  r f
  return
"""
  t.okCheck "strict equality distinguishes int from float"

  t.src """
fn f({n: int, m: int}) -> void:
  ...

fn main() -> void:
  let r = {alpha: 1, beta: 2}
  r f
  return
"""
  t.badCheck "same-typed numerics are still ambiguous", "missing\\ required\\ field"

  t.src """
distinct Milliseconds = u32

fn delay({ms: Milliseconds}) -> void:
  ...

fn main() -> void:
  let r = {timeout: 5}
  r delay
  return
"""
  t.badCheck "a distinct type does not auto-match its base", "missing\\ required\\ field\\ 'ms"

  t.src """
distinct Milliseconds = u32

fn ms(value: u32) -> Milliseconds:
  value Milliseconds

fn delay({ms: Milliseconds, label: str}) -> void:
  ...

fn main() -> void:
  let r = {timeout: 5.ms, name: "boot"}
  r delay
  return
"""
  t.okCheck "a distinct type auto-matches its own type"

  t.src """
fn playTrack({id: int, name: str, length: int}) -> void:
  ...

fn main() -> void:
  let ext = {trackId: 42, title: "Slow Jam", durationMs: 215000}
  let norm = ext alias(trackId: id, title: name, durationMs: length)
  norm playTrack
  return
"""
  t.okCheck "explicit alias still works alongside auto-matching"

  # --- discard: an explicit, checked no-op / value-drop ---------------------
  # Was previously an unresolved bare identifier riding synthBareVariant's
  # silent Unknown fallback — parsed and typechecked as a sketch placeholder,
  # then failed at the TARGET compiler with "undeclared name: discard" on
  # Odin/D (Nim's own real `discard` keyword masked the gap by coincidence).
  t.src """
fn main() -> int:
  discard
  return 7
"""
  t.runs "bare discard is a real no-op, not a sketch placeholder", 7

  t.src """
import fs

fn main() -> int:
  {path: "/tmp/tuck-typecheck-discard.txt"} fs::readFile
  return 3
"""
  t.badCheck "dropping a fallible result without discard is still rejected",
             "unhandled error result"

  t.src """
import fs

fn main() -> int:
  discard {path: "/tmp/tuck-typecheck-discard.txt"} fs::readFile
  return 3
"""
  t.okCheck "discard <expr> is the sanctioned way to drop it"

  # A ':' with nothing inside — no statement, no discard — is a parse error
  # (TK-PA09), not silently accepted as an empty body.
  t.src "fn main() -> void:\n\nfn other() -> int:\n  return 0\n"
  t.badCheck "an empty block is rejected, not silently accepted", "TK-PA09"

  t.finish()
