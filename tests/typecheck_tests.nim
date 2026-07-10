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

let x = {a: "oops"} f
""", "field 'a'"

expectError "missing required field", """
fn send({email: str, name: str}) -> int:
  return 1

let x = {email: "a@b.c"} send
""", "missing required field 'name"

expectError "mutation of let binding", """
let cfg = {port: 80}
cfg ..port {8080}
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

let y = "hello" addOne
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
let r = {ms: 5.us} delay
""", "field 'ms'"

expectError "bare int where unit expected", unitPrelude & """
let r = {ms: 5} delay
""", "field 'ms'"

expectOk "matching unit accepted", unitPrelude & """
let r = {ms: 5.ms} delay
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

let s = Session.Connected {keepalive: 60}
""", "cannot be constructed directly"

expectOk "sealed initial construction allowed", """
type Session [sealed]:
  | Disconnected
  | Connected({keepalive: int})
  transitions:
    Disconnected -> Connected
    Connected -> Disconnected

let s = Session.Disconnected
"""

expectOk "sealed non-initial with unsafe escape", """
type Session [sealed]:
  | Disconnected
  | Connected({keepalive: int})
  transitions:
    Disconnected -> Connected
    Connected -> Disconnected

let s = Session.Connected [unsafe] {keepalive: 60}
"""

expectOk "unsealed type constructs any variant", """
type State:
  | Idle
  | Busy({job: int})

let s = State.Busy {job: 1}
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

let x = {url: 42} fetchFeed
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

let x = {url: "https://x"} fetchFeed
let y = x.feed
"""

# ---------- positive cases ----------

expectOk "subset matching: extra fields ignored", """
fn send({email: str}) -> int:
  return 1

let x = {id: 5, email: "a@b.c", name: "Bo"} send
"""

expectOk "unknown callee flows through", """
let feed = {url: "https://x"} fetch parse
"""

expectOk "var mutation allowed", """
var cfg = {port: 80}
cfg ..port {8080}
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

let x = {port: 80} setPort
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

if failures > 0:
  echo failures, " test(s) failed"
  quit(1)
echo "All typecheck tests passed"
