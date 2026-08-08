## One program using most of the language at once, driven through the whole
## pipeline and BOTH backends, plus the effect checker's negative case.
##
## The value here is breadth, not depth: registers, compositions, invariants,
## transitions, a decision table and a sum type all in one module, so a change
## that breaks an interaction between two features shows up even when each
## feature's own test still passes.
##
## Replaces tests/end_to_end.nim, which ran the stages in-process and dumped the
## AST/Nim/Odin to stdout for a human to eyeball. Nothing asserted on the dump,
## so the real test was "no stage crashed" — that is what runs here, via the
## binary, with the AST dump kept as an explicit `tuck p --ast` check.

import std/[os, strutils, re]
import ../harness

proc run*(t: var T) =
  t.src """
fn addOne(x: int) -> int:
  return x + 1

type Controls:
  volume: int
  muted: bool

type Connection:
  latency: int

type PlayerComposition = Controls + Connection {latency -> delay}

register RCC_CR at 0x40021000:
  HSION: bit 0 [read, write]
  HSIRDY: bit 1 [read]

type Temperature:
  celsius: float
  invariant:
    celsius >= -273.15

type TrafficLight:
  | Red
  | Yellow
  | Green
  transitions:
    Red -> Green
    Green -> Yellow
    Yellow -> Red

decision classifyPacket({priority: int, size: int, encrypted: bool}) -> int:
  | 2    128   true  -> 1
  | 2    128   false -> 2
  | 2    64    _     -> 3
  | 1     _     _     -> 4
  | _       _     _     -> 5

fn main() -> int:
  let val1 = 9 addOne
  let val2 = {priority: 2, size: 64, encrypted: false} classifyPacket
  return val2
"""
  t.okCheck "the kitchen-sink module typechecks"
  # Row `| 2 64 _ -> 3` is the first one matching (2, 64, false).
  t.runs      "decision table picks the first matching row", 3
  t.emits     "Nim backend emits the decision fn",  "classifyPacket"
  t.emitsOdin "Odin backend emits the decision fn", "classifyPacket"

  # The AST serializer has to survive every one of those node kinds. A decision
  # table is a dkFn carrying isDecision, not a kind of its own — checking the
  # flag proves the table reached the serializer rather than being flattened.
  let astIdx = t.needCmd(@["./tuck", "p", t.curDir / "t.tuck", "--ast"])

  # A pure function calling an [io] one is the effect checker's core rejection.
  t.src """
fn writeLog() [io]:
  discard

fn doWork() -> void:
  {} writeLog
"""
  t.badCheck "a pure fn cannot call an [io] fn", "requires effect \\[io\\]"

  # scheduler::stop ends the loop even with a coroutine still parked. The
  # scheduler otherwise returns only when NOTHING is waiting, so a program that
  # parks on an fd nobody will feed — a server's accept loop — runs forever.
  # `runs` would HANG rather than fail without it, which is why this is here
  # rather than only in a bench.
  t.src """
import scheduler

actor Worker [queue: 8]:
  done: bool = false

  on go({n: int}):
    done = true

fn ready() -> bool:
  return Worker.done

fn main() -> int:
  Worker send go {n: 1}
  scheduler::waitUntil {pred: :ready}
  {} scheduler::stop
  return 7
"""
  t.runs "scheduler::stop ends the loop", 7

  # std/net over the reactor: a server task and a client task in ONE program,
  # real TCP on loopback. Proves listen/accept/connect/send/recv/close all
  # suspend through the reactor rather than blocking — a regression here HANGS
  # rather than failing, which is why it is a `runs` and not an `emits`.
  t.src """
import net
import scheduler

actor Result [queue: 8]:
  code: int = 0
  ready: bool = false

  on put({c: int}):
    code = c
    ready = true

task serve({lfd: int}) -> {n: int} [io]:
  let c = {fd: lfd} net::accept
  if c.ok:
    let req = {fd: c.value.fd, max: 256} net::recv
    let s = {fd: c.value.fd, data: "pong"} net::send
    {fd: c.value.fd} net::close
  return {n: 0}

task client({port: int}) -> {n: int} [io]:
  let c = {host: "127.0.0.1", port: port} net::connect
  if c.ok:
    let s = {fd: c.value.fd, data: "ping"} net::send
    let r = {fd: c.value.fd, max: 256} net::recv
    {fd: c.value.fd} net::close
    if r.ok:
      if r.value.data == "pong":
        Result send put {c: 9}
        return {n: 0}
    Result send put {c: 3}
    return {n: 0}
  Result send put {c: 4}
  return {n: 0}

fn done() -> bool:
  return Result.ready

fn main() -> int [io]:
  let l = {port: 34599} net::listen
  if l.ok:
    {lfd: l.value.fd} serve
    {port: 34599} client
    scheduler::waitUntil {pred: :done}
    {fd: l.value.fd} net::close
    {} scheduler::stop
    return Result.code
  return 1
"""
  t.runs "std/net does a real TCP round trip", 9

  if t.phase != pReport: return

  block:
    let (_, outp) = t.resultOf(astIdx)
    if outp.contains("\"isDecision\": true"):
      t.ok "AST serializes the whole module"
    else:
      t.no "AST serializes the whole module", "no decision fn in tuck p --ast output"

  # MISSING-FEATURES.md claims a specific number of open bugs. It had drifted
  # badly once — listing four fixed bugs as open, two working examples as broken,
  # and a shipped feature as an unbuilt proposal — because nothing checked it.
  # The count is objective, so pin it: fixing a bug now forces the doc to be
  # updated in the same change, which is when the context is still in hand.
  #
  # RETARGETED to tests/suites/*.nim when the suite left bash. The old glob was
  # tests/*.sh matching `^bug_open `; against the ported tree that matches
  # nothing at all, so the check would have passed vacuously forever while
  # claiming to guard the doc.
  var declared = -1
  for line in readFile("MISSING-FEATURES.md").splitLines():
    var m: array[1, string]
    if line.find(re"^## A\. Open bugs \(([0-9]+)", m) >= 0:
      declared = parseInt(m[0])
      break
  # known_bugs is the pinned subset; other suites carry their own bugOpen
  # lines, so the doc counts those too. Compare against the whole suite.
  var suite = 0
  for f in walkFiles("tests/suites/*.nim"):
    for line in readFile(f).splitLines():
      if line.strip().startsWith("t.bugOpen "): suite.inc
  if declared == suite:
    t.ok "MISSING-FEATURES open-bug count matches the suite (" & $suite & ")"
  else:
    t.no "MISSING-FEATURES open-bug count matches the suite",
         "doc says " & $declared & ", suite has " & $suite & " bugOpen assertions"

  t.finish()
