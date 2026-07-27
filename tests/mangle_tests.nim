# tests/mangle_tests.nim
# The name-mangling lowering pass (compiler/mangle.nim).
#
# The failure mode this guards against is subtle: renaming a DECLARATION but
# missing one of its reference sites produces output that looks fine and
# fails to compile — or worse, silently binds a runtime proc of the same
# name. So every case here checks the declaration AND a reference together.
import strutils
import ../lexer
import ../compiler/parser
import ../compiler/semantics
import ../compiler/typecheck
import ../compiler/lowering
import ../compiler/mangle
import ../compiler/codegen

var failures = 0

proc emit(src: string): string =
  ## Full pipeline through to emitted Nim, with the mangle pass in place.
  var lex = Lexer(source: src, position: 0, line: 1, column: 1, indentStack: @[0])
  var tokens: seq[Token]
  while true:
    let t = lex.nextToken()
    tokens.add(t)
    if t.kind == tkEOF: break
  var p = Parser(source: src, tokens: tokens, cursor: 0)
  var m = p.parseModule()
  verifyModuleEffects(m)
  typecheckModule(m)
  lowerModule(m)
  mangleProgram(@[m])   # single-module closure
  emitNim(m)

proc check(name, src: string, mustHave: seq[string], mustNotHave: seq[string] = @[]) =
  let code = emit(src)
  var bad: seq[string]
  for s in mustHave:
    if s notin code: bad.add("missing: " & s)
  for s in mustNotHave:
    if s in code: bad.add("present but should not be: " & s)
  if bad.len == 0:
    echo "PASS  ", name
  else:
    echo "FAIL  ", name
    for b in bad: echo "        ", b
    echo "      --- emitted ---"
    for line in code.splitLines():
      if line.strip() != "": echo "      ", line
    failures.inc

# A fn declaration and its call site must move together.
check "fn decl and call both mangled", """
fn helper({a: int}) -> int:
  return a

fn main() -> int:
  return {a: 5} helper
""", @["proc tuck_helper", "tuck_helper("], @["proc helper"]

# The whole point: a user fn named like a runtime proc must not collide.
check "a fn named `ready` is safe", """
fn ready() -> bool:
  return true

fn main() -> int:
  if ready:
    return 1
  return 0
""", @["proc tuck_ready", "tuck_ready("], @["proc ready*"]

# Type declarations and every mention of the type.
check "type decl and its uses mangled", """
type Config:
  url: str

fn use({c: Config}) -> str:
  return c.url

fn main() -> void:
  let cfg = {url: "x"} Config
  return
""", @["tuck_Config"], @["type Config*"]

# FIELDS stay bare — they are namespaced by their record and mangling them
# would only make literals unreadable.
check "fields are NOT mangled", """
type Point:
  x: int
  y: int

fn main() -> int:
  let p = {x: 1, y: 2} Point
  return p.x
""", @["x*: int", "p.x"], @["tuck_x"]

# Locals and params shadow: a local named like a global keeps its own name.
check "params and locals stay bare", """
fn helper({value: int}) -> int:
  return value

fn main() -> int:
  let value = 7
  return {value: value} helper
""", @["value: int"], @["tuck_value"]

# Externs bind a foreign symbol BY NAME, so they must survive verbatim —
# this is the FFI escape hatch an explicit attribute would extend.
check "externs are NOT mangled", """
extern:
  fn readFile({path: str}) -> str

fn main() -> void:
  let c = {path: "f"} readFile
  return
""", @["readFile("], @["tuck_readFile"]

# Idempotence matters: each backend lowers its own deepCopy, and a pass that
# double-prefixed would produce tuck_tuck_helper on the second run.
block:
  let src = """
fn helper({a: int}) -> int:
  return a

fn main() -> int:
  return {a: 1} helper
"""
  let once = emit(src)
  if "tuck_tuck_" in once:
    echo "FAIL  idempotence: double prefix in single pass"
    failures.inc
  else:
    echo "PASS  no double prefix"

if failures > 0:
  echo failures, " mangle test(s) failed"
  quit(1)
echo "All mangle tests passed"
