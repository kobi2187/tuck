## Registry events (spec Part 10), extended for bare metal by the owner's
## rulings of 2026-11-22 (docs/bare-metal/DESIGN-interrupt-events.md §5):
## several handlers per event, a registry per module, delivery kinds, and
## `bind`. Each behaviour runs on all three backends where it can run.

import ../harness

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

fn poke():
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

proc run*(t: var T) =
  t.multipleHandlers()
  t.finish()
