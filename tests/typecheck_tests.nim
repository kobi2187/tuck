# tests/typecheck_tests.nim
# Positive and negative cases for the bidirectional type checker.
import strutils
import ../lexer
import ../compiler/parser
import ../compiler/semantics
import ../compiler/typecheck

proc checkSource(src: string): string =
  ## Returns "" on success, or the SemanticError message.
  var lex = Lexer(source: src, position: 0, line: 1, column: 1, indentStack: @[0])
  var tokens: seq[Token]
  while true:
    let t = lex.nextToken()
    tokens.add(t)
    if t.kind == tkEOF: break
  var p = Parser(source: src, tokens: tokens, cursor: 0)
  let m = p.parseModule()
  try:
    verifyModuleEffects(m)
    typecheckModule(m)
    return ""
  except SemanticError as err:
    return err.msg

var failures = 0

proc expectOk(name, src: string) =
  let msg = checkSource(src)
  if msg == "":
    echo "PASS (ok)     ", name
  else:
    echo "FAIL          ", name, " — unexpected error: ", msg
    failures.inc

proc expectError(name, src, needle: string) =
  let msg = checkSource(src)
  if msg.len > 0 and needle in msg:
    echo "PASS (error)  ", name, " — ", msg
  else:
    echo "FAIL          ", name, " — expected error containing '", needle,
         "' but got: ", (if msg == "": "<no error>" else: msg)
    failures.inc

# ---------- negative cases ----------

expectError "wrong field type in call", """
fn f({a: int}) -> int:
  return a

fn main() -> void:
  let x = {a: "oops"} f
  return
""", "field 'a'"

expectError "missing required field", """
fn send({email: str, name: str}) -> int:
  return 1

fn main() -> void:
  let x = {email: "a@b.c"} send
  return
""", "missing required field 'name"

expectError "mutation of let binding", """
fn main() -> void:
  let cfg = {port: 80}
  cfg ..port {8080}
  return
""", "declared with 'let'"

expectError "return type mismatch", """
fn f({a: int}) -> int:
  return "nope"
""", "return value"

expectError "unknown field on known record", """
fn f({a: int}) -> int:
  return a

fn g({p: {a: int}}) -> int:
  return p.bogus
""", "no field 'bogus'"

expectError "scalar arg type mismatch", """
fn addOne(x: int) -> int:
  return x + 1

fn main() -> void:
  let y = "hello" addOne
  return
""", "expects int"

expectError "arithmetic type clash", """
fn f({a: int, b: str}) -> int:
  return a + b
""", "arithmetic"

# ---------- transition tables ----------

expectError "transition endpoint typo", """
type Light:
  | Red
  | Green
  transitions:
    Red -> Grean
""", "not a variant"

expectError "sealed variant unreachable", """
type Session [sealed]:
  | Disconnected
  | Connecting({host: str})
  | Zombie
  transitions:
    Disconnected -> Connecting
    Connecting -> Disconnected
""", "unreachable from initial"

expectOk "valid sealed transition graph", """
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

# ---------- decision tables ----------

expectError "decision row unreachable", """
decision route({priority: int, encrypted: bool}) -> int:
  | high  _     -> 1
  | high  true  -> 2
  | _     _     -> 3
""", "unreachable"

expectError "decision missing catch-all", """
decision route({priority: int, encrypted: bool}) -> int:
  | high  true  -> 1
  | low   false -> 2
""", "catch-all"

expectOk "valid decision table", """
decision route({priority: int, encrypted: bool}) -> int:
  | high  true  -> 1
  | high  false -> 2
  | _     _     -> 3
"""

# ---------- decision tables: exact analysis over enumerable domains ----------

expectOk "enum-domain table complete without catch-all", """
type Priority:
  | High
  | Low

decision route({priority: Priority, encrypted: bool}) -> int:
  | High  true  -> 1
  | High  false -> 2
  | Low   _     -> 3
"""

expectError "enum-domain table gap found exactly", """
type Priority:
  | High
  | Low

decision route({priority: Priority, encrypted: bool}) -> int:
  | High  true  -> 1
  | Low   _     -> 3
""", "has a gap"

expectError "enum-domain symbol typo", """
type Priority:
  | High
  | Low

decision route({priority: Priority, encrypted: bool}) -> int:
  | Hgih  true  -> 1
  | _     _     -> 2
""", "not a value of"

expectError "enum-domain unreachable row proven", """
type Priority:
  | High
  | Low

decision route({priority: Priority, encrypted: bool}) -> int:
  | High  _     -> 1
  | Low   _     -> 2
  | High  true  -> 3
""", "unreachable"

# ---------- errors as values: !T / ?T / ? ----------

expectError "fallible fn must be [io]", """
fn mightFail({n: int}) -> !{value: int}:
  return {value: n}
""", "must be marked [io]"

expectError "unhandled !T in arithmetic", """
fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  return {n} mightFail + 1
""", "unhandled"

expectError "unhandled !T payload access", """
fn mightFail({n: int}) -> !{amount: int} [io]:
  return {amount: n}

fn use({n: int}) -> int [io]:
  let r = {n} mightFail
  return r.amount
""", "unhandled"

expectOk "result introspection (.ok/.value) is the handling", """
fn mightFail({n: int}) -> !{amount: int} [io]:
  return {amount: n}

fn use({n: int}) -> int [io]:
  let r = {n} mightFail
  if r.ok:
    return r.value.amount
  return 0
"""

expectError ".value outside the ok guard", """
fn mightFail({n: int}) -> !{amount: int} [io]:
  return {amount: n}

fn use({n: int}) -> int [io]:
  let r = {n} mightFail
  if r.ok:
    let x = 1
  return r.value.amount
""", "inside an `if"

expectError "err outside a fallible fn", """
fn use({n: int}) -> int:
  err 5
""", "must declare a !T return type"

expectError "'or' cannot unwrap results", """
fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  let r = {n} mightFail or {value: 0}
  return r.value
""", "unhandled"

expectError "discarded !T result", """
fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  {n} mightFail
  return 0
""", "discarded"

expectError "strict lists ALL unhandled sites", """
fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  {n} mightFail
  {n} mightFail
  return 0
""", "2 unhandled"

expectOk "continue policy legalizes statement drops", """
errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    ...

fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  {n} mightFail
  return 0
"""

expectError "continue policy needs a handler", """
errors [policy: continue]

fn f({n: int}) -> int:
  return n
""", "needs an 'on unhandled"

expectError "continue does not legalize value positions", """
errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    ...

fn mightFail({n: int}) -> !{value: int} [io]:
  return {value: n}

fn use({n: int}) -> int [io]:
  return {n} mightFail + 1
""", "unhandled"

expectOk "err raise: qualified and shorthand variants", """
type FsError:
  | NotFound
  | AccessDenied

fn readIt({path: str}) -> !{content: str} [io, error: FsError]:
  if {path} missing:
    return err FsError.NotFound
  err AccessDenied
"""

expectError "err raise: unknown variant", """
type FsError:
  | NotFound
  | AccessDenied

fn readIt({path: str}) -> !{content: str} [io, error: FsError]:
  err DiskFull
""", "not a variant"

expectError "err raise: enum not in the declared list", """
type FsError:
  | NotFound
  | AccessDenied
type NetError:
  | Timeout
  | Refused

fn readIt({path: str}) -> !{content: str} [io, error: FsError]:
  err NetError.Timeout
""", "declares [error: FsError]"

expectOk "err raise: multiple error enums", """
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

expectError "err raise: variant ambiguous across listed enums", """
type FsError:
  | NotFound
  | Timeout
type NetError:
  | Timeout
  | Refused

fn fetchIt({url: str}) -> !{content: str} [io, error: FsError | NetError]:
  err Timeout
""", "ambiguous"

expectOk "re-raise an existing code (err r.err)", """
fn mightFail({n: int}) -> !{amount: int} [io]:
  return {amount: n}

fn use({n: int}) -> !{total: int} [io]:
  let r = {n} mightFail
  if r.ok:
    return {total: r.value.amount}
  err r.err
"""

expectOk "option introspection on ?T", """
fn mightBeAbsent({n: int}) -> ?{amount: int}:
  return {amount: n}

fn use({n: int}) -> int:
  let r = {n} mightBeAbsent
  if r.ok:
    return r.value.amount
  return 0
"""

expectOk "postfix wrapper types: int? and combos", """
fn mightBeAbsent({n: int}) -> {amount: int}?:
  return {amount: n}

fn both({n: int}) -> {amount: int}?! [io]:
  return {amount: n}
"""

# ---------- distinct unit types (spec 4.2) ----------

const unitPrelude = """
distinct Milliseconds = u32
distinct Microseconds = u32

fn ms(value: u32) -> Milliseconds:
  value Milliseconds

fn us(value: u32) -> Microseconds:
  value Microseconds

fn delay({ms: Milliseconds}) -> {done: bool}:
  {done: true}
"""

expectError "unit mismatch rejected", unitPrelude & """
fn main() -> void:
  let r = {ms: 5.us} delay
  return
""", "field 'ms'"

expectError "bare int where unit expected", unitPrelude & """
fn main() -> void:
  let r = {ms: 5} delay
  return
""", "field 'ms'"

expectOk "matching unit accepted", unitPrelude & """
fn main() -> void:
  let r = {ms: 5.ms} delay
  return
"""

expectError "arithmetic between different units", unitPrelude & """
fn f({a: Milliseconds, b: Microseconds}) -> {v: Milliseconds}:
  {v: a + b}
""", "arithmetic"

expectOk "same-unit arithmetic", unitPrelude & """
fn f({a: Milliseconds, b: Milliseconds}) -> {v: Milliseconds}:
  {v: a + b}
"""

# ---------- implicit return + branch agreement ----------

expectOk "implicit tail return", """
fn double({n: int}) -> {v: int}:
  {v: n + n}
"""

expectError "implicit tail wrong type", """
fn f({n: int}) -> {v: int}:
  {v: "nope"}
""", "flows"

expectError "if branches disagree on type", """
fn f({flag: bool}) -> {v: int}:
  if flag:
    {v: 1}
  else:
    {v: "s"}
""", "different types"

expectOk "if branches agree", """
fn f({flag: bool}) -> {v: int}:
  if flag:
    return {v: 1}
  else:
    return {v: 2}
"""

# ---------- sealed construction (spec 4.4) ----------

expectError "sealed non-initial construction rejected", """
type Session [sealed]:
  | Disconnected
  | Connected({keepalive: int})
  transitions:
    Disconnected -> Connected
    Connected -> Disconnected

fn main() -> void:
  let s = Session.Connected {keepalive: 60}
  return
""", "cannot be constructed directly"

expectOk "sealed initial construction allowed", """
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

expectOk "sealed non-initial with unsafe escape", """
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

expectOk "unsealed type constructs any variant", """
type State:
  | Idle
  | Busy({job: int})

fn main() -> void:
  let s = State.Busy {job: 1}
  return
"""

# ---------- effect markers ----------

expectError "pure fn calling io fn", """
fn writeLog({msg: str}) -> void [io]:
  return

fn doWork({msg: str}) -> void:
  {msg} writeLog
""", "requires effect [io]"

expectOk "io propagation declared", """
fn writeLog({msg: str}) -> void [io]:
  return

fn doWork({msg: str}) -> void [io]:
  {msg} writeLog
"""

# ---------- pending feature ----------

expectError "pending sig strictly checked at call site", """
pending:
  fn fetchFeed({url: str}) -> {feed: int}

fn main() -> void:
  let x = {url: 42} fetchFeed
  return
""", "field 'url'"

expectError "implemented fn still in pending block", """
fn fetchFeed({url: str}) -> int:
  return 1

pending:
  fn fetchFeed({url: str}) -> int
""", "remove it from the pending block"

expectOk "correct call to pending fn", """
pending:
  fn fetchFeed({url: str}) -> {feed: int}

fn main() -> void:
  let x = {url: "https://x"} fetchFeed
  let y = x.feed
  return
"""

# ---------- positive cases ----------

expectOk "subset matching: extra fields ignored", """
fn send({email: str}) -> int:
  return 1

fn main() -> void:
  let x = {id: 5, email: "a@b.c", name: "Bo"} send
  return
"""

expectOk "unknown callee flows through", """
fn main() -> void:
  let feed = {url: "https://x"} fetch parse
  return
"""

expectOk "var mutation allowed", """
fn main() -> void:
  var cfg = {port: 80}
  cfg ..port {8080}
  return
"""

expectOk "'.' calls a fn when the name is not a field", """
type Server:
  port: int

fn describe({port: int}) -> str:
  return "server"

fn main() -> void:
  let server = {port: 80} Server
  let d = server.describe
  return
"""

expectOk "'..' reassigns from a mutator fn: arg1 is the receiver, returns its type", """
type Server:
  port: int

fn withPort({self: Server, value: int}) -> Server:
  return {port: value} Server

fn main() -> void:
  var server = {port: 0} Server
  server ..withPort {80}
  return
"""

expectError "'..' on a fn whose first param is not the receiver type", """
type Server:
  port: int

fn withPort({count: int, value: int}) -> Server:
  return {port: value} Server

fn main() -> void:
  var server = {port: 0} Server
  server ..withPort {80}
  return
""", "first parameter"

expectOk "'.fn {args}': receiver is the first param, braced args fill the rest", """
type Server:
  port: int

fn scaled({self: Server, factor: int}) -> int:
  return factor

fn main() -> void:
  let server = {port: 80} Server
  let n = server.scaled {factor: 2}
  return
"""

expectError "'.fn {args}': missing param not covered by the braced args", """
type Server:
  port: int

fn scaled({self: Server, factor: int}) -> int:
  return factor

fn main() -> void:
  let server = {port: 80} Server
  let n = server.scaled {}
  return
""", "missing required field 'factor"

expectError "'.field {args}': fields take no arguments", """
type Server:
  port: int

fn main() -> void:
  let server = {port: 80} Server
  let n = server.port {8080}
  return
""", "'port' is a field"

expectOk "bare value braces: {8080} is {value: 8080}", """
fn double({value: int}) -> int:
  return value * 2

fn main() -> void:
  let n = {8080} double
  return
"""

expectError "'..' fn call whose return type does not match the var", """
type Server:
  port: int

fn describe({self: Server}) -> str:
  return "server"

fn main() -> void:
  var server = {port: 0} Server
  server ..describe {}
  return
""", "cannot assign str to Server"

expectError "'.' on a name that is neither a field nor a fn", """
type Server:
  port: int

fn main() -> void:
  let server = {port: 0} Server
  let x = server.mystery
  return
""", "no field 'mystery'"

expectError "field set rejects a named-field payload", """
type Server:
  port: int
  host: str

fn main() -> void:
  var server = {port: 0, host: "a"} Server
  server ..port {host: 80}
  return
""", "takes one bare value"

expectOk "field set accepts a bare var payload (ident shorthand)", """
type Server:
  host: str

fn main() -> void:
  var server = {host: "a"} Server
  let name = "b"
  server ..host {name}
  return
"""

expectError "fn name colliding with a declared field name must rename", """
type Server:
  port: int

fn port({value: int}) -> int:
  return value

fn main() -> void:
  return
""", "rename"

expectError "'.' ambiguous on an anonymous struct: field and fn share the name", """
fn port({value: int}) -> int:
  return value

fn main() -> void:
  let cfg = {port: 80}
  let x = cfg.port
  return
""", "rename"

expectOk "alias restructures: renamed fields satisfy the consumer", """
fn playTrack({id: int, name: str}) -> void:
  return

fn main() -> void:
  let ext = {trackId: 42, title: "x"}
  let normalized = ext alias(trackId: id, title: name)
  normalized playTrack
  return
"""

expectError "alias result is typed: consumer catches a missing field", """
fn playTrack({id: int, name: str}) -> void:
  return

fn main() -> void:
  let ext = {trackId: 42, title: "x"}
  let normalized = ext alias(trackId: id)
  normalized playTrack
  return
""", "missing required field 'name"

expectError "alias source field must exist on the receiver", """
fn main() -> void:
  let ext = {trackId: 42}
  let normalized = ext alias(wrong: id)
  return
""", "does not exist"

expectOk "bake fills a fn slot and overrides values; result is typed", """
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

expectError "bake value override must keep the field's type", """
fn main() -> void:
  let x = {a: 5, b: 10}
  let y = x bake {a: "nope"}
  let r = y.a + 1
  return
""", "bake override 'a' expects int but got str"

expectOk "input: the whole incoming payload, typed", """
type Episode:
  title: str

fn header({episode: Episode, n: int}) -> str:
  return input.episode.title

fn main() -> void:
  return
"""

expectError "input: unknown field is caught", """
fn f({a: int}) -> int:
  return input.missing

fn main() -> void:
  return
""", "no field 'missing'"

expectOk "merge flattens member structs; consumer sees the union", """
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

expectError "merge: field name collision between members", """
type A:
  x: int

type B:
  x: str

fn f({a: A, b: B}) -> void:
  let ctx = {a, b} merge
  return

fn main() -> void:
  return
""", "collides"

expectError "merge member must be a struct", """
fn f({a: int}) -> void:
  let ctx = {a} merge
  return

fn main() -> void:
  return
""", "must be a struct"

expectError "top-level statements are not allowed", """
fn f({a: int}) -> int:
  return a

let x = {a: 1} f
""", "top-level statements"

expectError "top-level let is not allowed either", """
let x = 5
""", "top-level statements"

expectOk "const: compile-time data, usable from fns", """
const maxRetries = 3
const defaults = {port: 80, host: "local"}

fn f({n: int}) -> int:
  return n + maxRetries

fn main() -> void:
  let p = defaults.port + maxRetries
  return
"""

expectOk "const evaluates pure computation at compile time", """
distinct Milliseconds = u32

fn ms(value: u32) -> Milliseconds:
  value Milliseconds

fn plus({a: int, b: int}) -> int:
  return a + b

const timeout = 5.ms
const sum = {a: 2, b: 3} plus
"""

expectError "const initializer must be pure (no io)", """
fn readPort() -> int [io]:
  return 80

const p = {} readPort
""", "pure"

expectError "const cannot hold a record construction (ref semantics)", """
type Server:
  port: int

const s = {port: 80} Server
""", "record"

# ---------- static transition checking (spec 4.4b) ----------

const doorPrelude = """
type Door:
  | Closed
  | Open
  | Locked

  transitions:
    Closed -> Open
    Open   -> Closed
    Closed -> Locked
    Locked -> Closed

"""

expectOk "transition: legal reassignment", doorPrelude & """
fn main() -> void:
  var d = Door.Closed
  d = Door.Open
  return
"""

expectError "transition: illegal edge on reassignment", doorPrelude & """
fn main() -> void:
  var d = Door.Open
  d = Door.Locked
  return
""", "Open -> Locked"

expectOk "transition: same-variant reassignment allowed", doorPrelude & """
fn main() -> void:
  var d = Door.Closed
  d = Door.Closed
  return
"""

expectOk "transition: branch merge, next hop legal from both", doorPrelude & """
fn main() -> void:
  var d = Door.Closed
  if true:
    d = Door.Open
  d = Door.Closed
  return
"""

expectError "transition: branch merge, edge missing from one member", doorPrelude & """
fn main() -> void:
  var d = Door.Closed
  if true:
    d = Door.Open
  d = Door.Locked
  return
""", "Open -> Locked"

expectError "transition: param starts at the full set", doorPrelude & """
fn slam({d: Door}) -> void:
  var x = d
  x = Door.Locked
  return
""", "-> Locked"

expectOk "transition: match narrowing unlocks the edge", doorPrelude & """
fn slam({d: Door}) -> void:
  var x = d
  match x:
    Closed: x = Door.Locked
    Open: x = Door.Closed
    Locked: x = Door.Closed
  return
"""

expectOk "match arms take indented multi-statement blocks", doorPrelude & """
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

expectOk "transition: fn returning a construction narrows the caller", doorPrelude & """
fn fresh() -> Door:
  return Door.Closed

fn main() -> void:
  var d = {} fresh
  d = Door.Locked
  return
"""

expectOk "declarations-only module is fine", """
type Server:
  port: int

fn main() -> void:
  let s = {port: 80} Server
  return
"""

expectOk "mutual recursion via pre-collected sigs", """
fn isEven(n: int) -> bool:
  return n isOdd

fn isOdd(n: int) -> bool:
  return n isEven
"""

expectOk "numeric widening int literal to u8", """
fn setPort({port: u8}) -> int:
  return 1

fn main() -> void:
  let x = {port: 80} setPort
  return
"""

expectOk "qualified pending call, matching payload", """
pending:
  fn http::get({url: str}) -> !{body: str} [io]

fn go({url: str}) -> !{body: str} [io]:
  return {url} http::get
"""

expectOk "qualified call site before its pending decl (order-free)", """
fn go({url: str}) -> !{body: str} [io]:
  return {url} http::get

pending:
  fn http::get({url: str}) -> !{body: str} [io]
"""

expectError "qualified call: wrong field type", """
pending:
  fn http::get({url: str}) -> !{body: str} [io]

fn go() -> !{body: str} [io]:
  return {url: 42} http::get
""", "expects"

expectError "known module, missing function", """
pending:
  fn http::get({url: str}) -> !{body: str} [io]

fn go() -> void:
  let x = {url: "a"} http::post
""", "has no function"

expectOk "unknown module prefix stays gradual", """
fn go() -> void:
  {volume: 3} audio::play
"""

# ---------- real imports: whole-program, order-independent ----------
import os, tables
import ../compiler/ast
import ../compiler/modules

block:
  let dir = getTempDir() / "tuck_import_test"
  createDir(dir)
  writeFile(dir / "http.tuck", """
pending:
  fn get({url: str}) -> !{body: str} [io]
""")
  writeFile(dir / "main.tuck", """
import http

fn go({url: str}) -> !{body: str} [io]:
  return {url} http::get
""")
  try:
    let prog = loadProgram(dir / "main.tuck")
    var mods: seq[tuple[name, path: string, m: Module]]
    for lm in prog: mods.add((lm.name, lm.path, lm.m))
    discard typecheckProgram(mods)
    echo "PASS (ok)     real import: qualified call checks against module sig"
  except CatchableError as err:
    echo "FAIL          real import — ", err.msg
    failures.inc
  # wrong payload field across the module boundary must be caught
  writeFile(dir / "main.tuck", """
import http

fn go() -> !{body: str} [io]:
  return {target: 1} http::get
""")
  try:
    let prog = loadProgram(dir / "main.tuck")
    var mods: seq[tuple[name, path: string, m: Module]]
    for lm in prog: mods.add((lm.name, lm.path, lm.m))
    discard typecheckProgram(mods)
    echo "FAIL          real import bad payload — expected error, got none"
    failures.inc
  except SemanticError as err:
    echo "PASS (error)  real import bad payload — ", err.msg

  # signature index: a fresh entry resolves imports without loading the AST,
  # and the checker still enforces payload shapes through it
  writeFile(dir / "main.tuck", """
import http

fn go({url: str}) -> !{body: str} [io]:
  return {url} http::get
""")
  try:
    let prog = loadProgram(dir / "main.tuck")
    updateIndex(dir, prog, moduleSigs)
    let (full, sigOnly) = loadProgramIndexed(dir / "main.tuck")
    doAssert sigOnly.hasKey("http"), "http should resolve from the index"
    doAssert full.len == 1, "only main should load in full"
    var mods: seq[tuple[name, path: string, m: Module]]
    for lm in full: mods.add((lm.name, lm.path, lm.m))
    var preSigs = initTable[string, seq[SigInfo]]()
    for name, e in sigOnly: preSigs[name] = e.sigs
    discard typecheckProgram(mods, preSigs)
    echo "PASS (ok)     sig index: import resolved without AST load"
  except CatchableError as err:
    echo "FAIL          sig index — ", err.msg
    failures.inc
  # ...and a bad payload is still caught against the indexed signatures
  writeFile(dir / "main.tuck", """
import http

fn go() -> !{body: str} [io]:
  return {target: 1} http::get
""")
  try:
    let (full, sigOnly) = loadProgramIndexed(dir / "main.tuck")
    var mods: seq[tuple[name, path: string, m: Module]]
    for lm in full: mods.add((lm.name, lm.path, lm.m))
    var preSigs = initTable[string, seq[SigInfo]]()
    for name, e in sigOnly: preSigs[name] = e.sigs
    discard typecheckProgram(mods, preSigs)
    echo "FAIL          sig index bad payload — expected error, got none"
    failures.inc
  except SemanticError as err:
    echo "PASS (error)  sig index bad payload — ", err.msg
  removeDir(dir)

# ---------- generics (simple substitution, Nim/C# style — no variance) ----------

expectOk "generic fn call infers and flows return type", """
fn identity[T]({x: T}) -> T:
  return x

fn f() -> int:
  let y = {x: 5} identity
  return y + 1
"""

expectError "generic return type mismatch at call site", """
fn identity[T]({x: T}) -> T:
  return x

fn g() -> int:
  return {x: "s"} identity
""", "int"

expectError "generic binding conflict", """
fn pair[T]({a: T, b: T}) -> T:
  return a

fn main() -> void:
  let x = {a: 1, b: "s"} pair
  return
""", "'T'"

expectOk "generic param inside container type", """
fn firstOf[T]({xs: Seq[T]}) -> T:
  return {xs} head

fn f({nums: Seq[int]}) -> int:
  let n = {xs: nums} firstOf
  return n + 1
"""

expectOk "generic type alias in signature", """
type Box[T] = {value: T}

fn get({b: Box[int]}) -> int:
  return b.value
"""

expectError "generic type alias field mismatch", """
type Box[T] = {value: T}

fn get({b: Box[int]}) -> str:
  return b.value
""", "str"

expectOk "generic record construction infers instantiation", """
type Box[T] = {value: T}

fn f() -> int:
  let b = {value: 5} Box
  return b.value
"""

expectError "generic construction with uninferrable param", """
type Box[T] = {value: T}

fn f() -> int:
  let b = {} Box
  return 1
""", "cannot infer"

if failures > 0:
  echo failures, " test(s) failed"
  quit(1)
echo "All typecheck tests passed"
