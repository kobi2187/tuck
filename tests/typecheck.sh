#!/bin/bash
# Positive and negative cases for the bidirectional type checker.
#
# Mechanically converted from tests/typecheck_tests.nim: each expectOk /
# expectError became an ok_check / bad_check on a real .tuck file driven
# through `tuck ch`. The old file linked the compiler as a Nim library, so
# running these 153 cases cost a full rebuild of the compiler first.
#
# Cases that shared a `const somePrelude` have it inlined — a file on disk
# cannot reference a const in another test.
cd "$(dirname "$0")/.."
. tests/lib.sh

src <<'TUCKEOF'
fn f({a: int}) -> int:
  return a

fn main() -> void:
  let x = {a: "oops"} f
  return
TUCKEOF
bad_check 'wrong field type in call' 'field\ '\''a'\'''

src <<'TUCKEOF'
fn send({email: str, name: str}) -> int:
  return 1

fn main() -> void:
  let x = {email: "a@b.c"} send
  return
TUCKEOF
bad_check 'missing required field' 'missing\ required\ field\ '\''name'

src <<'TUCKEOF'
fn main() -> void:
  let cfg = {port: 80}
  cfg ..port {8080}
  return
TUCKEOF
bad_check 'mutation of let binding' 'declared\ with\ '\''let'\'''

src <<'TUCKEOF'
fn f({a: int}) -> int:
  return "nope"
TUCKEOF
bad_check 'return type mismatch' 'return\ value'

src <<'TUCKEOF'
fn f({a: int}) -> int:
  return a

fn g({p: {a: int}}) -> int:
  return p.bogus
TUCKEOF
bad_check 'unknown field on known record' 'no\ field\ '\''bogus'\'''

src <<'TUCKEOF'
fn addOne(x: int) -> int:
  return x + 1

fn main() -> void:
  let y = "hello" addOne
  return
TUCKEOF
bad_check 'scalar arg type mismatch' 'expects\ int'

src <<'TUCKEOF'
fn f({a: int, b: str}) -> int:
  return a + b
TUCKEOF
bad_check 'arithmetic type clash' 'arithmetic'

src <<'TUCKEOF'
type Light:
  | Red
  | Green
  transitions:
    Red -> Grean
TUCKEOF
bad_check 'transition endpoint typo' 'not\ a\ variant'

src <<'TUCKEOF'
type Session [sealed]:
  | Disconnected
  | Connecting({host: str})
  | Zombie
  transitions:
    Disconnected -> Connecting
    Connecting -> Disconnected
TUCKEOF
bad_check 'sealed variant unreachable' 'unreachable\ from\ initial'

src <<'TUCKEOF'
type Session [sealed]:
  | Disconnected
  | Connecting({host: str})
  | Connected({keepalive: int})
  transitions:
    Disconnected -> Connecting
    Connecting -> Connected
    Connecting -> Disconnected
    Connected -> Disconnected
TUCKEOF
ok_check 'valid sealed transition graph'

src <<'TUCKEOF'
decision route({priority: int, encrypted: bool}) -> int:
  | high  _     -> 1
  | high  true  -> 2
  | _     _     -> 3
TUCKEOF
bad_check 'decision row unreachable' 'unreachable'

src <<'TUCKEOF'
decision route({priority: int, encrypted: bool}) -> int:
  | high  true  -> 1
  | low   false -> 2
TUCKEOF
bad_check 'decision missing catch-all' 'catch\-all'

src <<'TUCKEOF'
decision route({priority: int, encrypted: bool}) -> int:
  | high  true  -> 1
  | high  false -> 2
  | _     _     -> 3
TUCKEOF
ok_check 'valid decision table'

src <<'TUCKEOF'
type Priority:
  | High
  | Low

decision route({priority: Priority, encrypted: bool}) -> int:
  | High  true  -> 1
  | High  false -> 2
  | Low   _     -> 3
TUCKEOF
ok_check 'enum-domain table complete without catch-all'

src <<'TUCKEOF'
type Priority:
  | High
  | Low

decision route({priority: Priority, encrypted: bool}) -> int:
  | High  true  -> 1
  | Low   _     -> 3
TUCKEOF
bad_check 'enum-domain table gap found exactly' 'has\ a\ gap'

src <<'TUCKEOF'
type Priority:
  | High
  | Low

decision route({priority: Priority, encrypted: bool}) -> int:
  | Hgih  true  -> 1
  | _     _     -> 2
TUCKEOF
bad_check 'enum-domain symbol typo' 'not\ a\ value\ of'

src <<'TUCKEOF'
type Priority:
  | High
  | Low

decision route({priority: Priority, encrypted: bool}) -> int:
  | High  _     -> 1
  | Low   _     -> 2
  | High  true  -> 3
TUCKEOF
bad_check 'enum-domain unreachable row proven' 'unreachable'

src <<'TUCKEOF'
fn mightFail({n: int}) -> !{value: int}:
  return {value: n}
TUCKEOF
bad_check 'fallible fn must be [io]' 'must\ be\ marked\ \[io\]'

src <<'TUCKEOF'
fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  return {n} mightFail + 1
TUCKEOF
bad_check 'unhandled !T in arithmetic' 'unhandled'

src <<'TUCKEOF'
fn mightFail({n: int}) -> !{amount: int} [io]:
  return {amount: n}

fn use({n: int}) -> int [io]:
  let r = {n} mightFail
  return r.amount
TUCKEOF
bad_check 'unhandled !T payload access' 'unhandled'

src <<'TUCKEOF'
fn mightFail({n: int}) -> !{amount: int} [io]:
  return {amount: n}

fn use({n: int}) -> int [io]:
  let r = {n} mightFail
  if r.ok:
    return r.value.amount
  return 0
TUCKEOF
ok_check 'result introspection (.ok/.value) is the handling'

src <<'TUCKEOF'
fn mightFail({n: int}) -> !{amount: int} [io]:
  return {amount: n}

fn use({n: int}) -> int [io]:
  let r = {n} mightFail
  if r.ok:
    let x = 1
  return r.value.amount
TUCKEOF
bad_check '.value outside the ok guard' 'guard\ it\ first'

src <<'TUCKEOF'
fn use({n: int}) -> int:
  err 5
TUCKEOF
bad_check 'err outside a fallible fn' 'must\ declare\ a\ !T\ return\ type'

src <<'TUCKEOF'
fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  let r = {n} mightFail or {value: 0}
  return r.value
TUCKEOF
bad_check ''\''or'\'' cannot unwrap results' 'unhandled'

src <<'TUCKEOF'
fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  {n} mightFail
  return 0
TUCKEOF
bad_check 'discarded !T result' 'discarded'

src <<'TUCKEOF'
fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  {n} mightFail
  {n} mightFail
  return 0
TUCKEOF
bad_check 'strict lists ALL unhandled sites' '2\ unhandled'

src <<'TUCKEOF'
errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    ...

fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  {n} mightFail
  return 0
TUCKEOF
ok_check 'continue policy legalizes statement drops'

src <<'TUCKEOF'
errors [policy: continue]

fn f({n: int}) -> int:
  return n
TUCKEOF
bad_check 'continue policy needs a handler' 'needs\ an\ '\''on\ unhandled'

src <<'TUCKEOF'
errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    ...

fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  return {n} mightFail + 1
TUCKEOF
bad_check 'continue does not legalize value positions' 'unhandled'

src <<'TUCKEOF'
errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    ...

type ParseError:
  | Empty

fn parseTitle({raw: str}) -> !str [io, error: ParseError]:
  if raw == "":
    err Empty
  return raw
TUCKEOF
ok_check 'a guard clause raising err is not a dropped result'
# The guard exits on one path and falls through on the other, so nothing is
# dropped. Reported as a drop under a continue policy, codegen wrapped a
# branch that only returns in `(let tuckDrop1 = ...)` — not an expression,
# so the emitted Nim died on `invalid indentation`. ok_check alone would not
# catch a return of that bug: the spurious shortcut still CHECKS clean.
omits 'a guard clause emits no drop-site wrapper' 'tuckDrop'

src <<'TUCKEOF'
type FsError:
  | NotFound
  | AccessDenied

fn readIt({path: str}) -> !{content: str} [io, error: FsError]:
  if {path} missing:
    return err FsError.NotFound
  err AccessDenied
TUCKEOF
ok_check 'err raise: qualified and shorthand variants'

src <<'TUCKEOF'
type FsError:
  | NotFound
  | AccessDenied

fn readIt({path: str}) -> !{content: str} [io, error: FsError]:
  err DiskFull
TUCKEOF
bad_check 'err raise: unknown variant' 'not\ a\ variant'

src <<'TUCKEOF'
type FsError:
  | NotFound
  | AccessDenied
type NetError:
  | Timeout
  | Refused

fn readIt({path: str}) -> !{content: str} [io, error: FsError]:
  err NetError.Timeout
TUCKEOF
bad_check 'err raise: enum not in the declared list' 'declares\ \[error:\ FsError\]'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'err raise: multiple error enums'

src <<'TUCKEOF'
type FsError:
  | NotFound
  | Timeout
type NetError:
  | Timeout
  | Refused

fn fetchIt({url: str}) -> !{content: str} [io, error: FsError | NetError]:
  err Timeout
TUCKEOF
bad_check 'err raise: variant ambiguous across listed enums' 'ambiguous'

src <<'TUCKEOF'
fn mightFail({n: int}) -> !{amount: int} [io]:
  return {amount: n}

fn use({n: int}) -> !{total: int} [io]:
  let r = {n} mightFail
  if r.ok:
    return {total: r.value.amount}
  err r.err
TUCKEOF
ok_check 're-raise an existing code (err r.err)'

src <<'TUCKEOF'
fn mightBeAbsent({n: int}) -> ?{amount: int}:
  return {amount: n}

fn use({n: int}) -> int:
  let r = {n} mightBeAbsent
  if r.ok:
    return r.value.amount
  return 0
TUCKEOF
ok_check 'option introspection on ?T'

src <<'TUCKEOF'
fn mightBeAbsent({n: int}) -> {amount: int}?:
  return {amount: n}

fn both({n: int}) -> {amount: int}?! [io]:
  return {amount: n}
TUCKEOF
ok_check 'postfix wrapper types: int? and combos'

src <<'TUCKEOF'
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
TUCKEOF
bad_check 'unit mismatch rejected' 'field\ '\''ms'\'''

src <<'TUCKEOF'
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
TUCKEOF
bad_check 'bare int where unit expected' 'field\ '\''ms'\'''

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'matching unit accepted'

src <<'TUCKEOF'
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
TUCKEOF
bad_check 'arithmetic between different units' 'arithmetic'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'same-unit arithmetic'

src <<'TUCKEOF'
fn double({n: int}) -> {v: int}:
  {v: n + n}
TUCKEOF
ok_check 'implicit tail return'

src <<'TUCKEOF'
fn f({n: int}) -> {v: int}:
  {v: "nope"}
TUCKEOF
bad_check 'implicit tail wrong type' 'flows'

src <<'TUCKEOF'
fn f({flag: bool}) -> {v: int}:
  if flag:
    {v: 1}
  else:
    {v: "s"}
TUCKEOF
bad_check 'if branches disagree on type' 'different\ types'

src <<'TUCKEOF'
fn f({flag: bool}) -> {v: int}:
  if flag:
    return {v: 1}
  else:
    return {v: 2}
TUCKEOF
ok_check 'if branches agree'

src <<'TUCKEOF'
type Session [sealed]:
  | Disconnected
  | Connected({keepalive: int})
  transitions:
    Disconnected -> Connected
    Connected -> Disconnected

fn main() -> void:
  let s = Session.Connected {keepalive: 60}
  return
TUCKEOF
bad_check 'sealed non-initial construction rejected' 'cannot\ be\ constructed\ directly'

src <<'TUCKEOF'
type Session [sealed]:
  | Disconnected
  | Connected({keepalive: int})
  transitions:
    Disconnected -> Connected
    Connected -> Disconnected

fn main() -> void:
  let s = Session.Disconnected
  return
TUCKEOF
ok_check 'sealed initial construction allowed'

src <<'TUCKEOF'
type Session [sealed]:
  | Disconnected
  | Connected({keepalive: int})
  transitions:
    Disconnected -> Connected
    Connected -> Disconnected

fn main() -> void:
  let s = Session.Connected [unsafe] {keepalive: 60}
  return
TUCKEOF
ok_check 'sealed non-initial with unsafe escape'

src <<'TUCKEOF'
type State:
  | Idle
  | Busy({job: int})

fn main() -> void:
  let s = State.Busy {job: 1}
  return
TUCKEOF
ok_check 'unsealed type constructs any variant'

src <<'TUCKEOF'
fn writeLog({msg: str}) -> void [io]:
  return

fn doWork({msg: str}) -> void:
  {msg} writeLog
TUCKEOF
bad_check 'pure fn calling io fn' 'requires\ effect\ \[io\]'

src <<'TUCKEOF'
fn writeLog({msg: str}) -> void [io]:
  return

fn doWork({msg: str}) -> void [io]:
  {msg} writeLog
TUCKEOF
ok_check 'io propagation declared'

src <<'TUCKEOF'
pending:
  fn fetchFeed({url: str}) -> {feed: int}

fn main() -> void:
  let x = {url: 42} fetchFeed
  return
TUCKEOF
bad_check 'pending sig strictly checked at call site' 'field\ '\''url'\'''

src <<'TUCKEOF'
fn fetchFeed({url: str}) -> int:
  return 1

pending:
  fn fetchFeed({url: str}) -> int
TUCKEOF
bad_check 'implemented fn still in pending block' 'remove\ it\ from\ the\ pending\ block'

src <<'TUCKEOF'
pending:
  fn fetchFeed({url: str}) -> {feed: int}

fn main() -> void:
  let x = {url: "https://x"} fetchFeed
  let y = x.feed
  return
TUCKEOF
ok_check 'correct call to pending fn'

src <<'TUCKEOF'
fn send({email: str}) -> int:
  return 1

fn main() -> void:
  let x = {id: 5, email: "a@b.c", name: "Bo"} send
  return
TUCKEOF
ok_check 'subset matching: extra fields ignored'

src <<'TUCKEOF'
fn main() -> void:
  let feed = {url: "https://x"} fetch parse
  return
TUCKEOF
ok_check 'unknown callee flows through'

src <<'TUCKEOF'
fn main() -> void:
  var cfg = {port: 80}
  cfg ..port {8080}
  return
TUCKEOF
ok_check 'var mutation allowed'

src <<'TUCKEOF'
type Server:
  port: int

fn describe({port: int}) -> str:
  return "server"

fn main() -> void:
  let server = {port: 80} Server
  let d = server.describe
  return
TUCKEOF
ok_check ''\''.'\'' calls a fn when the name is not a field'

src <<'TUCKEOF'
type Server:
  port: int

fn withPort({self: Server, value: int}) -> Server:
  return {port: value} Server

fn main() -> void:
  var server = {port: 0} Server
  server ..withPort {80}
  return
TUCKEOF
ok_check ''\''..'\'' reassigns from a mutator fn: arg1 is the receiver, returns its type'

src <<'TUCKEOF'
type Server:
  port: int

fn withPort({count: int, value: int}) -> Server:
  return {port: value} Server

fn main() -> void:
  var server = {port: 0} Server
  server ..withPort {80}
  return
TUCKEOF
bad_check ''\''..'\'' on a fn whose first param is not the receiver type' 'first\ parameter'

src <<'TUCKEOF'
type Server:
  port: int

fn scaled({self: Server, factor: int}) -> int:
  return factor

fn main() -> void:
  let server = {port: 80} Server
  let n = server.scaled {factor: 2}
  return
TUCKEOF
ok_check ''\''.fn {args}'\'': receiver is the first param, braced args fill the rest'

src <<'TUCKEOF'
type Server:
  port: int

fn scaled({self: Server, factor: int}) -> int:
  return factor

fn main() -> void:
  let server = {port: 80} Server
  let n = server.scaled {}
  return
TUCKEOF
bad_check ''\''.fn {args}'\'': missing param not covered by the braced args' 'missing\ required\ field\ '\''factor'

src <<'TUCKEOF'
type Server:
  port: int

fn main() -> void:
  let server = {port: 80} Server
  let n = server.port {8080}
  return
TUCKEOF
bad_check ''\''.field {args}'\'': fields take no arguments' ''\''port'\''\ is\ a\ field'

src <<'TUCKEOF'
fn double({value: int}) -> int:
  return value * 2

fn main() -> void:
  let n = {8080} double
  return
TUCKEOF
ok_check 'bare value braces: {8080} is {value: 8080}'

src <<'TUCKEOF'
type Server:
  port: int

fn describe({self: Server}) -> str:
  return "server"

fn main() -> void:
  var server = {port: 0} Server
  server ..describe {}
  return
TUCKEOF
bad_check ''\''..'\'' fn call whose return type does not match the var' 'cannot\ assign\ str\ to\ Server'

src <<'TUCKEOF'
type Server:
  port: int

fn main() -> void:
  let server = {port: 0} Server
  let x = server.mystery
  return
TUCKEOF
bad_check ''\''.'\'' on a name that is neither a field nor a fn' 'no\ field\ '\''mystery'\'''

src <<'TUCKEOF'
type Server:
  port: int
  host: str

fn main() -> void:
  var server = {port: 0, host: "a"} Server
  server ..port {host: 80}
  return
TUCKEOF
bad_check 'field set rejects a named-field payload' 'takes\ one\ bare\ value'

src <<'TUCKEOF'
type Server:
  host: str

fn main() -> void:
  var server = {host: "a"} Server
  let name = "b"
  server ..host {name}
  return
TUCKEOF
ok_check 'field set accepts a bare var payload (ident shorthand)'

src <<'TUCKEOF'
type Server:
  port: int

fn port({value: int}) -> int:
  return value

fn main() -> void:
  return
TUCKEOF
bad_check 'fn name colliding with a declared field name must rename' 'rename'

src <<'TUCKEOF'
fn port({value: int}) -> int:
  return value

fn main() -> void:
  let cfg = {port: 80}
  let x = cfg.port
  return
TUCKEOF
bad_check ''\''.'\'' ambiguous on an anonymous struct: field and fn share the name' 'rename'

src <<'TUCKEOF'
fn playTrack({id: int, name: str}) -> void:
  return

fn main() -> void:
  let ext = {trackId: 42, title: "x"}
  let normalized = ext alias(trackId: id, title: name)
  normalized playTrack
  return
TUCKEOF
ok_check 'alias restructures: renamed fields satisfy the consumer'

src <<'TUCKEOF'
fn playTrack({id: int, name: str}) -> void:
  return

fn main() -> void:
  let ext = {trackId: 42, title: "x"}
  let normalized = ext alias(trackId: id)
  normalized playTrack
  return
TUCKEOF
bad_check 'alias result is typed: consumer catches a missing field' 'missing\ required\ field\ '\''name'

src <<'TUCKEOF'
fn main() -> void:
  let ext = {trackId: 42}
  let normalized = ext alias(wrong: id)
  return
TUCKEOF
bad_check 'alias source field must exist on the receiver' 'does\ not\ exist'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'bake fills a fn slot and overrides values; result is typed'

src <<'TUCKEOF'
fn main() -> void:
  let x = {a: 5, b: 10}
  let y = x bake {a: "nope"}
  let r = y.a + 1
  return
TUCKEOF
bad_check 'bake value override must keep the field'\''s type' 'bake\ override\ '\''a'\''\ expects\ int\ but\ got\ str'

src <<'TUCKEOF'
type Episode:
  title: str

fn header({episode: Episode, n: int}) -> str:
  return input.episode.title

fn main() -> void:
  return
TUCKEOF
ok_check 'input: the whole incoming payload, typed'

src <<'TUCKEOF'
fn f({a: int}) -> int:
  return input.missing

fn main() -> void:
  return
TUCKEOF
bad_check 'input: unknown field is caught' 'no\ field\ '\''missing'\'''

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'merge flattens member structs; consumer sees the union'

src <<'TUCKEOF'
type A:
  x: int

type B:
  x: str

fn f({a: A, b: B}) -> void:
  let ctx = {a, b} merge
  return

fn main() -> void:
  return
TUCKEOF
bad_check 'merge: field name collision between members' 'collides'

src <<'TUCKEOF'
fn f({a: int}) -> void:
  let ctx = {a} merge
  return

fn main() -> void:
  return
TUCKEOF
bad_check 'merge member must be a struct' 'must\ be\ a\ struct'

src <<'TUCKEOF'
fn f({a: int}) -> int:
  return a

let x = {a: 1} f
TUCKEOF
bad_check 'top-level statements are not allowed' 'top\-level\ statements'

src <<'TUCKEOF'
let x = 5
TUCKEOF
bad_check 'top-level let is not allowed either' 'top\-level\ statements'

src <<'TUCKEOF'
const maxRetries = 3
const defaults = {port: 80, host: "local"}

fn f({n: int}) -> int:
  return n + maxRetries

fn main() -> void:
  let p = defaults.port + maxRetries
  return
TUCKEOF
ok_check 'const: compile-time data, usable from fns'

src <<'TUCKEOF'
distinct Milliseconds = u32

fn ms(value: u32) -> Milliseconds:
  value Milliseconds

fn plus({a: int, b: int}) -> int:
  return a + b

const timeout = 5.ms
const sum = {a: 2, b: 3} plus
TUCKEOF
ok_check 'const evaluates pure computation at compile time'

src <<'TUCKEOF'
fn readPort() -> int [io]:
  return 80

const p = {} readPort
TUCKEOF
bad_check 'const initializer must be pure (no io)' 'pure'

src <<'TUCKEOF'
type Server:
  port: int

const s = {port: 80} Server
TUCKEOF
bad_check 'const cannot hold a record construction (ref semantics)' 'record'

src <<'TUCKEOF'
const K = {1} mystery
TUCKEOF
bad_check 'const rejects an unknown callee' 'unknown'

src <<'TUCKEOF'
fn double({n: int}) -> int:
  return n * 2

const K = {2} double
TUCKEOF
ok_check 'const accepts a declared pure fn'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'transition: legal reassignment'

src <<'TUCKEOF'
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
TUCKEOF
bad_check 'transition: illegal edge on reassignment' 'Open\ \->\ Locked'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'transition: same-variant reassignment allowed'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'transition: branch merge, next hop legal from both'

src <<'TUCKEOF'
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
TUCKEOF
bad_check 'transition: branch merge, edge missing from one member' 'Open\ \->\ Locked'

src <<'TUCKEOF'
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
TUCKEOF
bad_check 'transition: param starts at the full set' '\->\ Locked'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'transition: match narrowing unlocks the edge'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'match arms take indented multi-statement blocks'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'transition: fn returning a construction narrows the caller'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'match r.err validates arms against the declared enum'

src <<'TUCKEOF'
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
TUCKEOF
bad_check 'match r.err catches a variant typo' 'not\ a\ variant\ of\ ParseError'

src <<'TUCKEOF'
type Server:
  port: int

fn main() -> void:
  let s = {port: 80} Server
  return
TUCKEOF
ok_check 'declarations-only module is fine'

src <<'TUCKEOF'
fn isEven(n: int) -> bool:
  return n isOdd

fn isOdd(n: int) -> bool:
  return n isEven
TUCKEOF
ok_check 'mutual recursion via pre-collected sigs'

src <<'TUCKEOF'
fn setPort({port: u8}) -> int:
  return 1

fn main() -> void:
  let x = {port: 80} setPort
  return
TUCKEOF
ok_check 'numeric widening int literal to u8'

src <<'TUCKEOF'
pending:
  fn http::get({url: str}) -> !{body: str} [io]

fn go({url: str}) -> !{body: str} [io]:
  return {url} http::get
TUCKEOF
ok_check 'qualified pending call, matching payload'

src <<'TUCKEOF'
fn go({url: str}) -> !{body: str} [io]:
  return {url} http::get

pending:
  fn http::get({url: str}) -> !{body: str} [io]
TUCKEOF
ok_check 'qualified call site before its pending decl (order-free)'

src <<'TUCKEOF'
pending:
  fn http::get({url: str}) -> !{body: str} [io]

fn go() -> !{body: str} [io]:
  return {url: 42} http::get
TUCKEOF
bad_check 'qualified call: wrong field type' 'expects'

src <<'TUCKEOF'
pending:
  fn http::get({url: str}) -> !{body: str} [io]

fn go() -> void:
  let x = {url: "a"} http::post
TUCKEOF
bad_check 'known module, missing function' 'has\ no\ function'

src <<'TUCKEOF'
fn go() -> void:
  {volume: 3} audio::play
TUCKEOF
ok_check 'unknown module prefix stays gradual'

src <<'TUCKEOF'
fn identity[T]({x: T}) -> T:
  return x

fn f() -> int:
  let y = {x: 5} identity
  return y + 1
TUCKEOF
ok_check 'generic fn call infers and flows return type'

src <<'TUCKEOF'
fn identity[T]({x: T}) -> T:
  return x

fn g() -> int:
  return {x: "s"} identity
TUCKEOF
bad_check 'generic return type mismatch at call site' 'int'

src <<'TUCKEOF'
fn pair[T]({a: T, b: T}) -> T:
  return a

fn main() -> void:
  let x = {a: 1, b: "s"} pair
  return
TUCKEOF
bad_check 'generic binding conflict' ''\''T'\'''

src <<'TUCKEOF'
fn firstOf[T]({xs: Seq[T]}) -> T:
  return {xs} head

fn f({nums: Seq[int]}) -> int:
  let n = {xs: nums} firstOf
  return n + 1
TUCKEOF
ok_check 'generic param inside container type'

src <<'TUCKEOF'
type Box[T] = {value: T}

fn get({b: Box[int]}) -> int:
  return b.value
TUCKEOF
ok_check 'generic type alias in signature'

src <<'TUCKEOF'
type Box[T] = {value: T}

fn get({b: Box[int]}) -> str:
  return b.value
TUCKEOF
bad_check 'generic type alias field mismatch' 'str'

src <<'TUCKEOF'
type Box[T] = {value: T}

fn f() -> int:
  let b = {value: 5} Box
  return b.value
TUCKEOF
ok_check 'generic record construction infers instantiation'

src <<'TUCKEOF'
type Box[T] = {value: T}

fn f() -> int:
  let b = {} Box
  return 1
TUCKEOF
bad_check 'generic construction with uninferrable param' 'cannot\ infer'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'loop with break, for-cond with continue'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'ranges and indexed for'

src <<'TUCKEOF'
fn inline bump({x: int}) -> int:
  return x + 1

fn main() -> int:
  return bump {x: 41}
TUCKEOF
ok_check 'fn inline parses and typechecks'

src <<'TUCKEOF'
fn main() -> int:
  break
  return 0
TUCKEOF
bad_check 'break outside loop' 'break\ outside'

src <<'TUCKEOF'
fn main() -> int:
  continue
  return 0
TUCKEOF
bad_check 'continue outside loop' 'continue\ outside'

src <<'TUCKEOF'
fn main() -> int:
  for 5:
    return 1
  return 0
TUCKEOF
bad_check 'non-bool loop condition' 'must\ be\ bool'

src <<'TUCKEOF'
type Box:
  n: int

fn main() -> int:
  let b = Box[128]
  return 0
TUCKEOF
ok_check 'single-arg type application is not indexing'

src <<'TUCKEOF'
type Array:
  n: int

fn main() -> int:
  let b = Array[128, 8]
  return 0
TUCKEOF
ok_check 'multi-arg type application in expression position'

src <<'TUCKEOF'
import seq

fn main() -> int:
  var xs = [10, 20, 30]
  return xs[1, 2]
TUCKEOF
bad_check 'multi-arg bracket on a value is not an index' 'index'

src <<'TUCKEOF'
fn readIt({n: int}) -> !{v: int} [io]:
  return {v: n}

fn main() -> int [io]:
  let r = {n: 5} readIt
  if not r.ok:
    return 0
  return r.value.v
TUCKEOF
ok_check 'early-return guard narrows the rest of the fn'

src <<'TUCKEOF'
fn readIt({n: int}) -> !{v: int} [io]:
  return {v: n}

fn main() -> int [io]:
  let r = {n: 5} readIt
  if not r.ok:
    let x = 1
  return r.value.v
TUCKEOF
bad_check 'a guard that falls through does NOT narrow' 'guard\ it\ first'

src <<'TUCKEOF'
fn readIt({n: int}) -> !{v: int} [io]:
  return {v: n}

fn main() -> int [io]:
  let r = {n: 5} readIt
  return r.value.v
TUCKEOF
bad_check 'no guard at all is still an error' 'guard\ it\ first'

src <<'TUCKEOF'
type Slot:
  id: int

pool Slots = Slot [count: 2]

fn main() -> int:
  let s = Slots.acquire
  if not s.ok:
    return 0
  return s.value.id
TUCKEOF
ok_check 'early-return guard works for ?T from a pool'

src <<'TUCKEOF'
fn main() -> int:
  let p = {flag: true}
  if not p.flag:
    return 0
  return 1
TUCKEOF
ok_check 'unary `not` binds looser than field access'

src <<'TUCKEOF'
type Conn:
  id: int

pool Conns = Conn [count: 16]

fn main() -> int:
  return 0
TUCKEOF
ok_check 'pool declares an element type and a count'

src <<'TUCKEOF'
pool Bufs = Array[64, u8] [count: 8]

fn main() -> int:
  return 0
TUCKEOF
ok_check 'pool of a primitive array'

src <<'TUCKEOF'
pool Bufs = Array[64, u8] [count: 4]

fn main() -> int:
  let b = Bufs.acquire
  if not b.ok:
    return 1
  Bufs.release {b.value}
  return 0
TUCKEOF
ok_check 'acquire yields an optional handled with .ok'

src <<'TUCKEOF'
pool Bufs = Array[64, u8] [count: 4]

fn use({n: int}) -> int:
  let b = Bufs.acquire
  return b.n
TUCKEOF
bad_check 'acquire result is an unhandled optional' 'unhandled'

src <<'TUCKEOF'
fn main() -> int:
  let a = 5 or 3
  return 0
TUCKEOF
bad_check ''\''or'\'' rejects non-bool operands' 'expects\ bool'

src <<'TUCKEOF'
fn main() -> int:
  let a = "x" and "y"
  return 0
TUCKEOF
bad_check ''\''and'\'' rejects non-bool operands' 'expects\ bool'

src <<'TUCKEOF'
fn main() -> int:
  let x = 1
  let a = x > 0 or x < 10
  return 0
TUCKEOF
ok_check ''\''or'\'' on bools is fine'

src <<'TUCKEOF'
fn find({n: int}) -> ?{value: int} [io]:
  return {value: n}

fn main() -> int [io]:
  let a = {n: 1} find
  let b = {n: 2} find
  if a and b:
    return 1
  return 0
TUCKEOF
ok_check '?T reads as presence in a boolean guard'

src <<'TUCKEOF'
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
TUCKEOF
bad_check 'match missing a variant is rejected' 'Locked'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'match covering all variants is exhaustive'

src <<'TUCKEOF'
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
TUCKEOF
ok_check 'a catch-all _ makes a match exhaustive'

src <<'TUCKEOF'
fnsig Adder = {a: int, b: int} -> {sum: int}

type Calc = {op: Adder}
TUCKEOF
ok_check 'fnsig declares a named signature usable as a field type'

src <<'TUCKEOF'
fnsig Predicate = {x: int} -> bool

type Filter = {test: Predicate}
TUCKEOF
ok_check 'fnsig with a bare return type'

src <<'TUCKEOF'
fnsig Adder = {a: int, b: int} -> {sum: int}

type Calc = {op: Adder}

fn use({c: Calc}) -> int:
  let r = {a: 1} c.op
  return r.sum
TUCKEOF
bad_check 'a call through a fnsig slot checks arity' 'Adder'

src <<'TUCKEOF'
fn playTrack({id: int, name: str, ok: bool}) -> void:
  ...

fn main() -> void:
  let ext = {trackId: 42, title: "Slow Jam", active: true}
  ext playTrack
  return
TUCKEOF
ok_check 'auto-match by type when names differ'

src <<'TUCKEOF'
fn playTrack({id: int, length: int}) -> void:
  ...

fn main() -> void:
  let ext = {trackId: 42, durationMs: 215000}
  ext playTrack
  return
TUCKEOF
bad_check 'ambiguous same-typed fields need an alias' 'missing\ required\ field'

src <<'TUCKEOF'
fn f({a: int, b: int}) -> void:
  ...

fn main() -> void:
  let r = {b: 2, a: 1}
  r f
  return
TUCKEOF
ok_check 'name match wins over a same-typed rival field'

src <<'TUCKEOF'
fn f({count: int, label: str}) -> void:
  ...

fn main() -> void:
  let r = {count: 7, title: "x"}
  r f
  return
TUCKEOF
ok_check 'name matches first, then type fills the rest'

src <<'TUCKEOF'
fn f({count: int, label: str}) -> void:
  ...

fn main() -> void:
  let r = {count: 7, other: 9}
  r f
  return
TUCKEOF
bad_check 'no candidate of the required type' 'missing\ required\ field\ '\''label'

src <<'TUCKEOF'
fn f({id: int, name: str}) -> void:
  ...

fn main() -> void:
  {userId: 3, handle: "kobi"} f
  return
TUCKEOF
ok_check 'auto-match on a struct literal argument'

src <<'TUCKEOF'
fn f({n: int, x: float}) -> void:
  ...

fn main() -> void:
  let r = {alpha: 1, beta: 2.5}
  r f
  return
TUCKEOF
ok_check 'strict equality distinguishes int from float'

src <<'TUCKEOF'
fn f({n: int, m: int}) -> void:
  ...

fn main() -> void:
  let r = {alpha: 1, beta: 2}
  r f
  return
TUCKEOF
bad_check 'same-typed numerics are still ambiguous' 'missing\ required\ field'

src <<'TUCKEOF'
distinct Milliseconds = u32

fn delay({ms: Milliseconds}) -> void:
  ...

fn main() -> void:
  let r = {timeout: 5}
  r delay
  return
TUCKEOF
bad_check 'a distinct type does not auto-match its base' 'missing\ required\ field\ '\''ms'

src <<'TUCKEOF'
distinct Milliseconds = u32

fn ms(value: u32) -> Milliseconds:
  value Milliseconds

fn delay({ms: Milliseconds, label: str}) -> void:
  ...

fn main() -> void:
  let r = {timeout: 5.ms, name: "boot"}
  r delay
  return
TUCKEOF
ok_check 'a distinct type auto-matches its own type'

src <<'TUCKEOF'
fn playTrack({id: int, name: str, length: int}) -> void:
  ...

fn main() -> void:
  let ext = {trackId: 42, title: "Slow Jam", durationMs: 215000}
  let norm = ext alias(trackId: id, title: name, durationMs: length)
  norm playTrack
  return
TUCKEOF
ok_check 'explicit alias still works alongside auto-matching'

finish
