## ROADMAP.md's status claims, as assertions (2026-10-26).
##
## A roadmap row is prose, and it goes stale the day the work lands: this pass
## found `mod::Type`, recursive types, hashing, numeric sigils and memoization
## all still listed as missing, months after each was built. Each entry here
## states how a roadmap item behaves when it is BUILT, plus a marker:
##
##   featureDone     -> built; a permanent guard, like `bugFixed`.
##   featureMissing  -> not built: expected to fail, printed as a TODO. When
##                      it starts passing the suite fails and says so — flip
##                      the marker and correct the ROADMAP line it names.
##
## One short assertion per item, naming the ROADMAP section it checks. Deep
## coverage lives in each feature's own suite; this one answers "is the
## roadmap telling the truth" in a single run.

import std/os
import ../harness

proc doneItems(t: var T) =
  ## Items ROADMAP listed as missing, deferred or unverified, found built.

  # "## Missing — Stack-depth budgets `[stack: N]` §6.2". Retired instead:
  # `[no_recursion]` forbids recursion below a fn, `[recursion: N]` traps
  # beyond N nested calls, and `[stack: N]` itself says so (TK-EF06).
  t.src """
fn deep({n: int}) -> int [stack: 64]:
  return n

fn main() -> int:
  return {n: 1} deep
"""
  t.quietly: t.badCheck "§6.2 stack budgets: [stack: N] is retired", "retired"
  t.featureDone "§6.2 stack budgets: [stack: N] is retired"
  t.src """
fn walk({n: int}) -> int [recursion: 5]:
  if n == 0:
    return 0
  return {n: n - 1} walk + 1

fn main() -> int:
  return {n: 3} walk
"""
  t.quietly: t.hostRuns "§6.2 stack budgets: [recursion: N] replaces it", 3
  t.featureDone "§6.2 stack budgets: [recursion: N] replaces it"

  # "## Missing — Visibility ... STILL MISSING: `mod::Type` in a TYPE position".
  t.src """
import geo

fn main() -> int:
  let p: geo::Point = {x: 3, y: 4} Point
  return p.x + p.y
"""
  t.addFile "geo.tuck", "type Point:\n  x: int\n  y: int\n"
  t.quietly: t.runs "Visibility: mod::Type in a type position", 7
  t.featureDone "Visibility: mod::Type in a type position"

  # "### Deferred — #11 recursive types".
  t.src """
type Expr:
  | Num({value: int})
  | Add({left: Expr, right: Expr})

fn total({e: Expr}) -> int:
  match e:
    Num: return e.value
    Add: return {e: e.left} total + {e: e.right} total

fn main() -> int:
  let a = Expr.Num {value: 3}
  let s = Expr.Add {left: a, right: a}
  return {e: s} total
"""
  t.quietly: t.hostRuns "Deferred #11: recursive sum types", 6
  t.featureDone "Deferred #11: recursive sum types"

  # "### Deferred — #12 hashing".
  t.src """
import hash

fn main() -> int:
  let a = {data: "abc"} hash
  let b = {data: "abc"} hash
  let c = {data: "abd"} hash
  if a == b and a != c:
    return 0
  return 1
"""
  t.quietly: t.hostRuns "Deferred #12: std/hash", 0
  t.featureDone "Deferred #12: std/hash"

  # "### Deferred — #16 numeric sigils": `~T` may lose, `^T` cannot.
  t.src """
fn main() -> int:
  let wide: u32 = 300
  let narrow = wide ~u8
  return narrow ^int
"""
  t.quietly: t.hostRuns "Deferred #16: numeric sigils ~T and ^T", 44
  t.featureDone "Deferred #16: numeric sigils ~T and ^T"

  # "### Deferred — #69" and S4.1's "fn memo BUILT": both said, one row each.
  t.src """
fn memo(64) fib({n: int}) -> int [pure]:
  if n < 2:
    return n
  return {n: n - 1} fib + {n: n - 2} fib

fn main() -> int:
  return {n: 40} fib % 256
"""
  t.quietly: t.hostRuns "Deferred #69: fn memo", 203
  t.featureDone "Deferred #69: fn memo"

  # "### Deferred — #74": an actor's liveness, answered by its drain loop.
  t.src """
actor Counter [queue: 16]:
  total: int = 0

  on add({n: int}):
    total += n

fn main() -> int:
  Counter send add {n: 1}
  if not Counter.alive {withinMs: 500}:
    return 1
  return 0
"""
  t.quietly: t.hostRuns "Deferred #74: Actor.alive", 0
  t.featureDone "Deferred #74: Actor.alive"

  # "## Partial — Type composition `+` | conflict detection unverified".
  t.src """
type A:
  x: int
type B:
  x: str
type C = A + B

fn main() -> int:
  return 0
"""
  t.quietly: t.badCheck "Partial: composition detects a field clash", "TK-TY05"
  t.featureDone "Partial: composition detects a field clash"

  # "## Partial — Static transition checking ... Ceilings: match arms
  # single-line". A multi-line arm narrows the same as a one-line one.
  t.src """
type Door:
  | Closed
  | Open
  | Locked
  transitions:
    Closed -> Open
    Open -> Closed
    Closed -> Locked
    Locked -> Closed

fn step({start: Door}) -> int:
  var d = start
  match d:
    Open:
      let x = 1
      d = Door.Locked
    _: return 0
  return 1

fn main() -> int:
  return 0
"""
  t.quietly: t.badCheck "Partial: transitions narrow inside a multi-line arm",
                        "Open -> Locked"
  t.featureDone "Partial: transitions narrow inside a multi-line arm"

  # "S3.2 — D: `[saturating]`". 70000 clamps to 65535 on every backend.
  t.src """
type SafeRPM = u16 [saturating]

fn main() -> int:
  let over = 70000 SafeRPM
  if over == 65535 SafeRPM:
    return 0
  return 1
"""
  t.quietly: t.hostRuns "S3.2: [saturating] clamps on every backend", 0
  t.featureDone "S3.2: [saturating] clamps on every backend"

  # "S5.1 — #22 callParamsFor pending fns". A pending fn's payload now
  # explodes like any fn's (A96).
  t.src """
pending:
  fn put({a: int, b: str}) -> int

fn main() -> int:
  let q = {a: 2, b: "y"}
  return q put + 5
"""
  t.quietly: t.hostRuns "S5.1 #22: call params for pending fns", 5
  t.featureDone "S5.1 #22: call params for pending fns"

proc crossModuleItems(t: var T) =
  ## "### S6 — R13 ... an interface as a generic fn's bound ... Not yet:
  ## calling such a fn from another module". Built 2026-10-27: the clone is
  ## made in the CALLING module, the usual shape being a library declaring
  ## the interface and the fn, an app declaring the object. Here both: an
  ## object of the app, one of a third module, and the library's own helper
  ## called from the generic body.
  t.src """
import audio
import codecs

object Mp3:
  satisfies AudioSource
  bitrate: int
  fn sampleRate({self: Mp3}) -> int:
    return 44100

fn main() -> int:
  let m = Mp3{bitrate: 3}
  let f = Flac{bits: 16}
  return {a: m} rateOf + {a: f} rateOf + {} flacRate
"""
  t.addFile "audio.tuck", """
interface AudioSource:
  fn sampleRate({self: Self}) -> int

fn khz({hz: int}) -> int:
  return hz /i 1000

fn rateOf[T: AudioSource]({a: T}) -> int:
  return {hz: a.sampleRate} khz
"""
  t.addFile "codecs.tuck", """
import audio

object Flac:
  satisfies AudioSource
  bits: int
  fn sampleRate({self: Flac}) -> int:
    return 96000

fn flacRate() -> int:
  let f = Flac{bits: 24}
  return {a: f} rateOf
"""
  t.quietly: t.hostRuns "R13: an interface-bounded generic called across modules", 236
  t.featureDone "R13: an interface-bounded generic called across modules"

proc missingItems(t: var T) =
  ## Items ROADMAP lists as not built, still not built.

  # "Message priority (owner, 2026-09-28) ... `on reset() [urgent]:`". Built
  # 2026-10-27; what it DOES (jumps the queue, on every backend and actor
  # mode) is asserted in `mailbox_full`.
  t.src """
actor Box:
  n: int = 0

  on bump():
    n += 1

  on reset() [urgent]:
    n = 0

fn main() -> int:
  return 0
"""
  t.quietly: t.okCheck "Message priority: an [urgent] handler"
  t.featureDone "Message priority: an [urgent] handler"

  # "## Partial — Resource registry ... MISSING: §7.4's static
  # acquire-must-finish check". Built 2026-10-27 as a warning (TK-RS12), the
  # build-time twin of the OPEN RESOURCES report at exit: a handle whose only
  # use is `.ok`.
  t.src """
resources:
  conn [cap: 4]

extern:
  fn dial({port: int}) -> int [io]

fn leak({port: int}) -> int [io, resource: conn]:
  let raw = {port: port} dial
  let h = acquire raw, conn
  if h.ok:
    return 1
  return 0

fn main() -> int:
  return 0
"""
  t.quietly: t.checkSays "§7.4: an acquire never finished is reported", "TK-RS12"
  t.featureDone "§7.4: an acquire never finished is reported"

proc registryItems(t: var T) =
  ## "## Partial — Event registry" (2026-11-22). The registry is the planned
  ## home of hardware interrupts on bare metal (docs/bare-metal/
  ## DESIGN-interrupt-events.md), so what it does today is pinned before it is extended.
  ## Until this, it had no behavioural assertion at all (LANGUAGE-OVERVIEW §15).
  t.src """
import console

registry AppEvents:
  | Tick({n: int})
  | Byte({b: u8})

on AppEvents.Tick({n: int}) [io: console]:
  {text: "tick"} console::printLine

on AppEvents.Byte({b: u8}) [io: console]:
  {text: "byte"} console::printLine

fn main() -> int [io]:
  AppEvents.raise Tick {n: 1}
  AppEvents.raise Byte {b: 7}
  return 3
"""
  t.quietly: t.hostRuns "Part 10: raise runs the handler, on every backend", 3,
                        "tick\\s+byte"
  t.featureDone "Part 10: raise runs the handler, on every backend"

  # Spec Part 10: "Multiple handlers for the same event are permitted and
  # called in declaration order". Run-gated in event_registry.
  t.src """
registry AppEvents:
  | Tick({n: int})

on AppEvents.Tick({n: int}):
  let a = n

on AppEvents.Tick({n: int}):
  let b = n

fn main() -> int:
  AppEvents.raise Tick {n: 1}
  return 0
"""
  t.quietly: t.okCheck "Part 10: two handlers for one event"
  t.featureDone "Part 10: two handlers for one event"

  # Spec Part 10, Query: `AppEvents.latest is LowMemory`. Not implemented.
  t.src """
registry AppEvents:
  | Tick({n: int})

on AppEvents.Tick({n: int}):
  let a = n

fn main() -> int:
  AppEvents.raise Tick {n: 1}
  if AppEvents.latest is Tick:
    return 1
  return 0
"""
  t.quietly: t.okCheck "Part 10: latest queries the last raised event"
  t.featureMissing "Part 10: latest queries the last raised event"

  # Spec Part 10: a handler lives "in a manager or actor". An actor's
  # `on AppEvents.X` is not counted as a handler today (TK-RG03).
  t.src """
registry AppEvents:
  | Tick({n: int})

actor Counter [queue: 8]:
  total: int = 0
  on AppEvents.Tick({n: int}):
    total += n

fn main() -> int:
  AppEvents.raise Tick {n: 2}
  return 0
"""
  t.quietly: t.okCheck "Part 10: an actor handles a registry event"
  t.featureMissing "Part 10: an actor handles a registry event"

proc metalItems(t: var T) =
  ## docs/bare-metal/ROADMAP.md "Where it stands" and Phase 1, pinned where a
  ## check or an emit can say it without QEMU (the QEMU half is in
  ## metal_runtime, sim_tick and crash_decode). Items whose spelling waits on
  ## the owner's design round (interrupt binding, w1c fields, priorities)
  ## have no assertion yet: there is nothing to write until the syntax is.

  # "`critical:` saves/restores PRIMASK and restores on every exit".
  t.src """
register FLAG at 0x20000100:
  VALUE: bits 0..7 [read, write]

fn early({x: int}) -> int:
  critical:
    if x > 0:
      return 1
    FLAG.VALUE = 3
  return 0

fn main() -> int:
  return {x: 1} early
"""
  t.quietly: t.emits "Bare metal: critical: restores the mask on every exit",
                     "finally:\\s+tuckCriticalExit\\(tuckCs"
  t.featureDone "Bare metal: critical: restores the mask on every exit"
  t.quietly: t.emits "Bare metal: a register field write is volatile",
                     "tuckVolatileStore"
  t.featureDone "Bare metal: a register field write is volatile"

  # "interrupt code is strict and complete under any policy" (TK-PO04).
  t.src """
fn helper({n: int}) -> int [irq_safe, no_alloc]:
  ...

fn isr() [irq, irq_safe, no_alloc]:
  let x = {n: 1} helper
  return

fn main() -> int:
  return 0
"""
  t.quietly: t.badCheck "Bare metal: interrupt code may not reach a stub",
                        "TK-PO04"
  t.featureDone "Bare metal: interrupt code may not reach a stub"

  # "TK-EF11 (no I/O, waits or allocation inside critical:)".
  t.src """
extern [impl: nim "./host_sim/hal_shim", odin "./host_sim", d "./host_sim/hal_shim"]:
  fn say({text: str}) -> void [io]

fn main() -> int [io]:
  critical:
    {text: "hi"} say
  return 0
"""
  t.quietly: t.badCheck "Bare metal: no I/O inside critical:", "TK-EF11"
  t.featureDone "Bare metal: no I/O inside critical:"

  # Roadmap 1.3: "stage10 compiles with no annotation (two spawn sites,
  # count inferred)" under --frames:static. Refused today: each fire-and-
  # forget spawn's frame comes from the heap.
  t.src """
task worker({id: int}) -> void [io]:
  return

fn main() -> int [io]:
  {id: 1} worker
  {id: 2} worker
  return 0
"""
  let name13 = "Bare metal 1.3: two spawn sites build under --frames:static"
  let idx = t.needCmd(@["./tuck", "c", t.curDir / "t.tuck", "--frames:static",
                        "--concurrency:stackless", "-o:" & t.curDir,
                        "--root:" & t.root], vEmit)
  t.quietly:
    if t.phase != pCollect:
      let (rc, text) = t.resultOf(idx)
      if rc == 0: t.ok name13 else: t.no name13, text
  t.featureMissing name13

proc run*(t: var T) =
  ## Registers every ROADMAP claim as an assertion of the built behaviour,
  ## marked `featureDone` (a guard) or `featureMissing` (expected to fail).
  t.doneItems()
  t.crossModuleItems()
  t.missingItems()
  t.registryItems()
  t.metalItems()
  t.finish()
