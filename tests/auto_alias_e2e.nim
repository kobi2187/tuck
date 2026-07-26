# tests/auto_alias_e2e.nim
# End-to-end guard for type-based field/param auto-matching.
#
# A typecheck-only test cannot catch a MISALIGNED mapping: if two fields have
# compatible types, binding the wrong one to the wrong param still typechecks
# cleanly and still emits well-formed Nim. Only running the code and checking
# the VALUES proves the mapping is right. So: compile Tuck -> Nim, then append
# a plain-Nim assertion harness and run it.
#
# The Tuck fns here RETURN values rather than printing: that keeps the
# generated module free of any stdlib/runtime import, so these tests link
# without dragging in tuck_rt's async dependencies.
import os, osproc, strutils
import ../lexer
import ../compiler/parser
import ../compiler/lowering
import ../compiler/codegen
import ../compiler/semantics
import ../compiler/typecheck

const outDir = "tests/auto_alias_out"

var failures = 0

proc buildAndRun(name, src, harness: string): string =
  ## Tuck source -> Nim, plus an appended Nim `harness` that echoes results.
  ## Returns the program's stdout; raises if any stage fails.
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
  # Dashes are invalid in Nim module names.
  let modName = "t_" & name.replace("-", "_")
  var nimCode = emitNim(m, moduleName = modName)
  # Inline the two runtime helpers these programs use instead of importing
  # tuck_rt, whose async chain pulls in an unrelated broken dependency.
  const rtShim = """
proc toStr*[T](value: T): string = $value
proc tuckConcat*(a, b: string): string {.inline.} = a & b
"""
  nimCode = nimCode.replace("import ../compiler/tuck_rt\n", rtShim)
  nimCode.add("\n" & harness & "\n")
  let nimFile = outDir / (modName & ".nim")
  writeFile(nimFile, nimCode)
  let (output, rc) = execCmdEx("nim c --hints:off --warnings:off -r " &
                               quoteShell(nimFile))
  if rc != 0:
    raise newException(ValueError, "nim compile/run failed:\n" & output)
  return output

proc expectOutput(name, src, harness: string, expected: seq[string]) =
  try:
    let got = buildAndRun(name, src, harness)
    var missing: seq[string]
    for e in expected:
      if e notin got: missing.add(e)
    if missing.len == 0:
      echo "PASS (run)    ", name
    else:
      echo "FAIL          ", name, " — missing from output: ", missing.join(", ")
      echo "              got: ", got.strip()
      failures.inc
  except CatchableError as err:
    echo "FAIL          ", name, " — ", err.msg
    failures.inc

createDir(outDir)

# The core correctness case: every field has a DISTINCT type and a
# distinguishable value. A misaligned mapping still compiles, so only the
# values can prove each param received the field intended for it. The record
# is built and passed on the TUCK side, so `run` exercises auto-matching.
expectOutput "distinct-types-map-correctly", """
fn describe({id: int, name: str, ratio: float}) -> str:
  return name + "/" + id.toStr + "/" + ratio.toStr

fn run() -> str:
  let ext = {title: "SlowJam", weight: 0.5, trackId: 42}
  return ext describe

fn main() -> void:
  return
""", "echo run()", @["SlowJam/42/0.5"]

# Field ORDER in the source record is scrambled relative to param order:
# auto-matching must key on type, never on position.
expectOutput "source-field-order-is-irrelevant", """
fn join({first: str, second: int}) -> str:
  return first + "/" + second.toStr

fn run() -> str:
  let r = {num: 7, word: "hello"}
  return r join

fn main() -> void:
  return
""", "echo run()", @["hello/7"]

# Mixed: one param matched by NAME, the other by type. The name-matched field
# must not be stolen by the type pass, and vice versa.
expectOutput "name-match-and-type-match-together", """
fn join({count: int, label: str}) -> str:
  return label + "/" + count.toStr

fn run() -> str:
  let r = {count: 3, heading: "Total"}
  return r join

fn main() -> void:
  return
""", "echo run()", @["Total/3"]

# Two int fields, one matching a param by name. The name match must claim it,
# leaving the OTHER int for the remaining int param — not the reverse. A
# swapped mapping would print "999/1" here and still compile fine.
expectOutput "name-match-claims-its-field-before-type-pass", """
fn join({id: int, size: int}) -> str:
  return "n" + id.toStr + "/" + size.toStr

fn run() -> str:
  let r = {id: 1, byteCount: 999}
  return r join

fn main() -> void:
  return
""", "echo run()", @["n1/999"]

# Regression: explicit alias() must keep producing the correct assignment.
expectOutput "explicit-alias-still-correct", """
fn describe({id: int, name: str, length: int}) -> str:
  return name + "/" + id.toStr + "/" + length.toStr

fn run() -> str:
  let ext = {trackId: 42, title: "SlowJam", durationMs: 215000}
  let norm = ext alias(trackId: id, title: name, durationMs: length)
  return norm describe

fn main() -> void:
  return
""", "echo run()", @["SlowJam/42/215000"]

if failures > 0:
  echo failures, " e2e test(s) failed"
  quit(1)
echo "All auto-alias e2e tests passed"
