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

  # Temperature's invariant must survive -d:release: genType used to gate it
  # behind `when not defined(release)` AND emit Nim's own `assert(...)`,
  # itself release-stripped — a double bug (fixed 2026-09-01), never pinned.
  # The opt-out is tuckNoInvariants, independent of release/danger.
  t.emits "an invariant check survives -d:release (tuckNoInvariants, not release)",
          r"when not defined\(tuckNoInvariants\):"
  t.emits "...and calls tuckInvariantFailed, not Nim's own release-stripped assert",
          r"tuckInvariantFailed\(""\(self\.celsius"

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

  # ...and the effect must be seen wherever the call HIDES. The audit's walker
  # used to list fourteen Expr kinds and `else: discard`, so a call inside a
  # send payload, a select arm or a field access was never reached: this
  # program passed clean until 2026-08-14. An unseen [io] is also an unmarked
  # suspend point, so codegen would skip the async transform for it.
  t.src """
actor Sink:
  hits: int
  on ping({n: int}):
    self.hits = n

fn noisy() -> int [io]:
  return 5

fn quiet() -> void:
  Sink send ping {n: noisy}
  return
"""
  t.badCheck "an [io] call inside a send payload is still an effect",
             "requires effect \\[io\\]"

  # A SEND CARRIES A FN, and the actor invokes it. This is the answer to
  # "when is a send's payload evaluated": a value is computed by the sender,
  # a fn reference is computed by the RECEIVER, and the second is what you
  # want when the work belongs on the actor's side.
  #
  # It also dissolves the question TK-PA13 raised. A call nested in a payload
  # (`{n: {} noisy}`) is refused, and hoisting it to a `let` is WRONG for a
  # send — that evaluates once, where the nested call ran per send. `:fnRef`
  # is neither: nothing is computed at the send at all.
  #
  # What this needed: calling a fnsig-typed BINDING by bare name. That path
  # typed as Unknown, because asIndirectCall — which already validates a call
  # through a fnsig slot — was unreachable for a bare-name callee. Nim and
  # Odin infer a local from its initialiser and never noticed; D declares one
  # and refused.
  t.src """
fnsig Thunk = {} -> int

actor Sink:
  total: int

  on ping({make: Thunk}) -> void:
    let v = {} make
    self.total = self.total + v

fn five() -> int:
  return 5

fn main() -> int:
  Sink send ping {make: :five}
  return 0
"""
  t.okCheck "a send may carry a fn reference"
  t.hostBuilds "...and every backend emits the actor that invokes it"
  t.runs "...and it runs", 0

  # The same, with ARGUMENTS: the fn and what to apply it to travel together,
  # and the actor does the applying.
  t.src """
fnsig Adder = {n: int} -> int

actor Sink:
  total: int

  on add({op: Adder, n: int}) -> void:
    let v = {n: n} op
    self.total = self.total + v

fn twice({n: int}) -> int:
  return n * 2

fn main() -> int:
  Sink send add {op: :twice, n: 21}
  return 0
"""
  t.okCheck "a send may carry a fn and its argument"
  t.hostBuilds "...on every backend"
  t.runs "...and the actor applies it", 0

  # `.invoke` reaches a BARE fn reference too, not only a fnsig-typed slot.
  # All four spellings of "call this fn value" now agree:
  #
  #   :twice .invoke {n: 21}    a bare reference
  #   c.op.invoke {n: 10}       a slot on a record
  #   f.invoke {n: 5}           a fnsig-typed binding
  #   {n: n} op                 the same binding, payload-first
  #
  # The first typed as Unknown: a `:fnRef` resolves straight to a tkFunc
  # carrying its signature, and checkThroughFnSig looks names up in
  # fnSigNames — so it answered nil for the one case where the signature was
  # sitting on the type already.
  #
  # D also needed the `&` taken off in CALLEE position: `&f` is how D spells
  # taking a fn's address, and `&f(x)` takes the address of the RESULT —
  # "cannot take address of expression because it is not an lvalue".
  t.src """
fnsig Adder = {n: int} -> int

type Calc:
  op: Adder

fn twice({n: int}) -> int:
  return n * 2

fn viaSlot({c: Calc}) -> int:
  return c.op.invoke {n: 10}

fn viaBinding({f: Adder}) -> int:
  return f.invoke {n: 5}

fn main() -> int:
  let c = {op: :twice} Calc
  let a = :twice .invoke {n: 21}
  let b = {c: c} viaSlot
  let d = {f: :twice} viaBinding
  return a + b + d - 72
"""
  t.okCheck "invoke reaches a bare fn reference, a slot and a binding alike"
  t.hostBuilds "...on every backend"
  t.runs "...and all three spellings compute the same way", 0



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
    {fd: c.value.fd, max: 256} net::recv discard
    {fd: c.value.fd, data: "pong"} net::send discard
    {fd: c.value.fd} net::close
  return {n: 0}

task client({port: int}) -> {n: int} [io]:
  let c = {host: "127.0.0.1", port: port} net::connect
  if c.ok:
    {fd: c.value.fd, data: "ping"} net::send discard
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

  # The pool must drain a child that outruns the 64K pipe buffer. It did not
  # until 2026-09-12: it polled for exit and read afterwards, so a child
  # blocked in `write()` never exited, was never selected, and was never
  # drained — the pool spun forever. Nothing in the suite emits that much
  # today, which is why it stayed latent; this assertion is the thing that
  # emits that much.
  let big = t.needCmd(@["/bin/sh", "-c", "yes ABCDEFGHIJ | head -c 200000"])
  if t.phase == pReport:
    let (rc, outp) = t.resultOf(big)
    if rc == 0 and outp.len >= 200000:
      t.ok "the pool drains a child that outruns the pipe buffer (" &
           $outp.len & " bytes)"
    else:
      t.no "the pool drains a child that outruns the pipe buffer",
           "rc " & $rc & ", got " & $outp.len & " bytes of 200000"

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
