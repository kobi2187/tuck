## Registry events (spec Part 10), extended for bare metal by the owner's
## rulings of 2026-11-22 (docs/bare-metal/DESIGN-interrupt-events.md §5):
## several handlers per event, a registry per module, delivery kinds, and
## `bind`. Each behaviour runs on all three backends where it can run.

import std/[os, strutils, sequtils]
import ../harness

proc eventsReportSays(t: var T, name: string, wanted: seq[string]) =
  ## `tuck audit FILE --events` names every line in `wanted`.
  let idx = t.needCmd(@["./tuck", "audit", t.curDir / "t.tuck", "--events"])
  if t.phase == pCollect: return
  let (rc, text) = resultOf(t, idx)
  if rc != 0: t.no name, "audit failed: " & text
  elif wanted.allIt(strutils.contains(text, it)): t.ok name
  else: t.no name, "the report missed a line. Got: " & text

proc multipleHandlers(t: var T) =
  ## Spec Part 10: "Multiple handlers for the same event are permitted and
  ## called in declaration order". They share a written name, so the
  ## duplicate-name rule exempts them and the mangler numbers the second
  ## and later (`_2`, `_3`).
  t.src """
import console

registry AppEvents:
  | Tick({n: int})

on AppEvents.Tick({n: int}) [io: console]:
  {text: "first"} console::printLine

on AppEvents.Tick({n: int}) [io: console]:
  {text: "second"} console::printLine

on AppEvents.Tick({n: int}) [io: console]:
  {text: "third"} console::printLine

fn main() -> int [io]:
  AppEvents.raise Tick {n: 1}
  return 4
"""
  t.hostRuns "three handlers for one event run in declaration order", 4,
             "first\\s+second\\s+third"

  # Across modules: the registry's own module first, then importers.
  t.src """
import console
import drv

on DrvEvents.Rx({b: int}) [io: console]:
  {text: "app 1"} console::printLine

on DrvEvents.Rx({b: int}) [io: console]:
  {text: "app 2"} console::printLine

fn main() -> int [io]:
  poke
  return 5
"""
  t.addFile "drv.tuck", """
import console

registry DrvEvents:
  | Rx({b: int})

on DrvEvents.Rx({b: int}) [io: console]:
  {text: "lib"} console::printLine

# A synchronous raise runs its handlers here, so it declares what they do
# (audit E5, ruled 2026-11-23) — the ones this module can see; its
# importers' handlers are theirs to answer for.
fn poke() [io: console]:
  DrvEvents.raise Rx {b: 7}
"""
  t.hostRuns "handlers in two modules all run, the declaring module's first",
             5, "lib\\s+app 1\\s+app 2"

  # A second fn with an ordinary name is still a duplicate.
  t.src """
fn f() -> int:
  return 1

fn f() -> int:
  return 2

fn main() -> int:
  return f
"""
  t.badCheck "an ordinary fn declared twice is still refused", "declared twice"

proc latestQuery(t: var T) =
  ## Spec Part 10, Query: `AppEvents.latest is LowMemory`. Its own node
  ## (exkLatestIs). False before anything is raised: Nim's slot is a nil
  ## ref until then, Odin's and D's a zeroed value, hence their
  ## `latestRaised<Registry>` flag.
  t.src """
registry AppEvents:
  | Tick({n: int})
  | Low()

on AppEvents.Tick({n: int}):
  let a = n

on AppEvents.Low():
  let b = 1

fn probe() -> int:
  if AppEvents.latest is Tick:
    return 1
  if AppEvents.latest is Low:
    return 2
  return 0

fn main() -> int:
  let before = probe
  AppEvents.raise Tick {n: 1}
  let mid = probe
  AppEvents.raise Low
  return before * 100 + mid * 10 + probe
"""
  t.hostRuns "latest is: false before a raise, then the last raised event", 12

  t.src """
import drv

fn main() -> int:
  poke
  if DrvEvents.latest is Rx:
    return 6
  return 0
"""
  t.addFile "drv.tuck", """
registry DrvEvents:
  | Rx({b: int})

on DrvEvents.Rx({b: int}):
  let c = b

fn poke():
  DrvEvents.raise Rx {b: 7}
"""
  t.hostRuns "latest is reads another module's registry", 6

  t.src """
registry AppEvents:
  | Tick({n: int})

on AppEvents.Tick({n: int}):
  let a = n

fn main() -> int:
  if AppEvents.latest is Tock:
    return 1
  return 0
"""
  t.badCheck "latest is names only a declared event", "TK-RG01.*no event 'Tock'"

  t.src """
fn main() -> int:
  let x = 3
  if x is Tick:
    return 1
  return 0
"""
  t.badCheck "`is` outside `Registry.latest is` is refused with the fix",
             "Registry.latest is Event.*use `match`"

proc actorHandlers(t: var T) =
  ## Spec Part 10: a handler may live "in a manager or actor". An actor's
  ## `on Registry.Event` runs in the actor's context, as a message: rewrite
  ## lifts a top-level forwarder that sends each raise to its mailbox. `on`
  ## is the same word everywhere; no task is needed to handle an event.
  t.src """
import console

registry AppEvents:
  | Tick({n: int})

on AppEvents.Tick({n: int}) [io: console]:
  {text: "top level"} console::printLine

actor Counter [queue: 8]:
  total: int = 0
  on AppEvents.Tick({n: int}) [io: console]:
    total += n
    {text: "actor"} console::printLine

fn main() -> int [io]:
  AppEvents.raise Tick {n: 2}
  return 7
"""
  t.hostRuns "an actor handles a registry event, beside a top-level handler",
             7, "top level[\\s\\S]*actor"

  t.src """
import console
import drv

actor Echo [queue: 8]:
  on DrvEvents.Rx({b: int}) [io: console]:
    {text: "echo actor"} console::printLine

fn main() -> int [io]:
  poke
  return 8
"""
  t.addFile "drv.tuck", """
registry DrvEvents:
  | Rx({b: int})

fn poke():
  DrvEvents.raise Rx {b: 7}
"""
  t.hostRuns "an actor in an importing module is the event's only handler",
             8, "echo actor"

const DrvWithEvents = """
registry DrvEvents:
  | Rx({b: int})
  | Overrun()

on DrvEvents.Overrun():
  let z = 0

fn poke():
  DrvEvents.raise Rx {b: 7}
"""

proc registryPerModule(t: var T) =
  ## Ruled 2026-11-22: a registry per module, so a driver declares the events
  ## it raises (TK-RG05 retired); names unique program-wide (TK-RG07); the
  ## whole surface is the `--events` report.
  t.src """
import console
import drv

registry AppEvents:
  | Started()

on AppEvents.Started() [io: console]:
  {text: "started"} console::printLine

on DrvEvents.Rx({b: int}) [io: console]:
  {text: "rx"} console::printLine

actor Echo [queue: 8]:
  on DrvEvents.Rx({b: int}) [io: console]:
    {text: "echo actor"} console::printLine

fn main() -> int [io]:
  AppEvents.raise Started
  poke
  return 3
"""
  t.addFile "drv.tuck", DrvWithEvents
  t.hostRuns "a library's registry and the application's run side by side", 3,
             "started\\s+rx\\s+echo actor"
  t.eventsReportSays "the --events report lists every registry, raiser and handler",
    @["EVENTS (2 registries, 3 events)",
      "DrvEvents  (module drv, drv.tuck:1)",
      "raised by:  drv.tuck:9 (poke)",
      "handled by: t.tuck:10 (top level), t.tuck:14 (actor Echo)",
      "AppEvents  (module t, t.tuck:4)",
      "raised by:  t.tuck:18 (main)"]

  t.src """
registry A:
  | X()

registry B:
  | Y()

on A.X():
  let a = 1

on B.Y():
  let b = 1

fn main() -> int:
  return 0
"""
  t.badCheck "a module declares at most one registry", "TK-RG06.*already declares registry 'A'"

  t.src """
import drv

registry DrvEvents:
  | Other()

on DrvEvents.Other():
  let a = 1

fn main() -> int:
  return 0
"""
  t.addFile "drv.tuck", DrvWithEvents
  t.badCheck "registry names are unique across the program",
             "TK-RG07.*also declared by another module"

  t.src """
registry AppEvents:
  | Started()

on AppEvents.Started():
  let z = 0

fn main() -> int:
  AppEvents.raise Startd
  return 0
"""
  t.badCheck "a payload-less raise is checked against the registry",
             "TK-RG01.*no event 'Startd'"

const UartKinds = """
registry UartEvents:
  | Rx({data: u8})   [stream, overflow: drop_newest]
  | Overrun()        [signal]
  | Level({v: u16})  [latest]
  | Plain()

on UartEvents.Rx({data: u8}):
  let a = data
on UartEvents.Overrun():
  let b = 1
on UartEvents.Level({v: u16}):
  let c = v
on UartEvents.Plain():
  let d = 1

fn onUart() [irq, irq_safe, no_alloc]:
  UartEvents.raise Rx {data: 3}
  UartEvents.raise Overrun
  return

fn main() -> int:
  return 0
"""

proc deliveryKinds(t: var T) =
  ## Ruled 2026-11-22: each event states how it travels from an interrupt
  ## to its handlers, and the driver fixes a stream's overflow policy.
  t.src UartKinds
  t.okCheck "delivery kinds on registry events, raised from interrupt code"
  t.eventsReportSays "the --events report shows each event's delivery",
    @["Rx{data: u8}  [stream, overflow: drop_newest]", "Overrun  [signal]",
      "Level{v: u16}  [latest]", "raised by:  t.tuck:17 (onUart)"]

  t.src UartKinds.replace("  UartEvents.raise Overrun\n", "  UartEvents.raise Plain\n")
  t.badCheck "interrupt code may raise only an event with a delivery kind",
             "TK-RG10.*'UartEvents.Plain'.*interrupt handler 'onUart'"

  t.src UartKinds.replace("| Overrun()        [signal]", "| Overrun({n: int}) [signal]")
            .replace("on UartEvents.Overrun():", "on UartEvents.Overrun({n: int}):")
            .replace("raise Overrun\n", "raise Overrun {n: 1}\n")
  t.badCheck "a signal carries no payload", "TK-RG08.*UartEvents.Overrun"

  t.src UartKinds.replace("[latest]", "[latest, overflow: drop_oldest]")
  t.badCheck "only a stream names an overflow policy", "TK-RG09.*not a `\\[stream\\]`"

  t.src UartKinds.replace("drop_newest", "wait")
  t.badCheck "an overflow policy never waits", "TK-RG09.*no overflow policy 'wait'"

  t.src UartKinds.replace("[signal]", "[sygnal]")
  t.badCheck "an unknown delivery word is a parse error", "`sygnal` is not an event delivery"

  t.src """
type Shape:
  | Circle({r: int}) [stream]
  | Square({s: int})

fn main() -> int:
  return 0
"""
  t.badCheck "a sum type's variant takes no delivery bracket",
             "a sum type's variants take none"

const BindBase = """
registry Ev:
  | Tick({n: int})  [stream, overflow: drop_newest]

on Ev.Tick({n: int}):
  let a = n

fn onLine() [irq, irq_safe, no_alloc]:
  Ev.raise Tick {n: 1}

fn notIrq():
  let z = 1

bind EXTI0 -> onLine [priority: 2, queue: 4]

fn main() -> int:
  return 0
"""

proc binds(t: var T) =
  ## `bind LINE -> module.fn [priority: N, queue: N]` (ruled 2026-11-22,
  ## built 2026-11-23): the application wires a line to a driver's `[irq]`
  ## fn. On a board build the fn becomes the line's vector entry; a
  ## kinded event's raise posts, and the handlers run from a delivery frame.
  t.src BindBase
  t.okCheck "a bind wires a line to an [irq] fn"
  t.emits "the bound fn is the line's vector symbol",
          "exportc: \"tuck_irq_EXTI0\""
  t.emits "on metal a [stream] raise posts and wakes the delivery frame",
          "when defined\\(freestanding\\):[\\s\\S]*tuckDeliveryPost"
  t.emits "the stream is sized by the bind's queue", "array\\[4, tuple\\[n: int\\]\\]"

  t.src BindBase.replace("bind EXTI0 -> onLine", "bind EXTI0 -> notIrq")
  t.badCheck "a bind names an [irq] fn", "TK-BD01.*'notIrq' is not declared `\\[irq\\]`"

  t.src BindBase & "\nbind EXTI0 -> onLine\n"
  t.badCheck "a line is bound once", "TK-BD02.*line EXTI0 is already bound"

  t.src BindBase & "\nbind EXTI1 -> onLine\n"
  t.badCheck "an [irq] fn is bound once (channels are not built)",
             "TK-BD03.*'onLine' is already bound to EXTI0"

  t.src BindBase.replace("bind EXTI0 -> onLine", "bind EXTI0 -> onLine as Console")
  t.badCheck "`as Name` is refused until channels are built", "TK-BD04"

  t.src BindBase.replace("queue: 4", "queue: 0")
  t.badCheck "a queue holds at least one message", "TK-BD05"

proc run*(t: var T) =
  t.multipleHandlers()
  t.latestQuery()
  t.actorHandlers()
  t.registryPerModule()
  t.deliveryKinds()
  t.binds()
  t.finish()
