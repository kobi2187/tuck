## Integer overflow is a policy the author chose, and trapping is the default
## (issue #16, step 3; ROADMAP 2026-08-25 ruling 4).
##
## A wrapped counter is a hang; a saturated reading is a silently wrong
## measurement; either keeps travelling after the site that made it is
## forgotten. So `+ - *` on a narrow integer TRAPS unless the type says
## otherwise — `[wrapping]` for a sequence number that genuinely wraps,
## `[saturating]` for a reading that genuinely clamps. `int` and `i64` stay
## plain: 64 bits is enough. Every assertion that runs, runs on all three
## backends, because the claim is that they behave alike (before this, Nim and
## Odin wrapped silently and D did not compile a narrow `+`).

import ../harness

proc run*(t: var T) =
  ## Registers the overflow-policy assertions.
  t.src """
fn main() -> int:
  var x: u8 = 250
  x = x + 10
  return 0
"""
  t.hostRuns "a narrow integer traps on overflow by default", 1,
             "Arithmetic overflow on"

  t.src """
fn main() -> int:
  var x: u8 = 5
  x = x - 10
  return 0
"""
  t.hostRuns "...subtraction below zero traps too", 1, "Arithmetic overflow on"

  t.src """
fn main() -> int:
  var x: u16 = 300
  x = x * 300
  return 0
"""
  t.hostRuns "...and multiplication", 1, "Arithmetic overflow on"

  t.src """
fn main() -> int:
  var x: u8 = 200
  x += 100
  return 0
"""
  t.hostRuns "...a compound `+=` is checked like the `+` it stands for", 1,
             "Arithmetic overflow on"

  t.src """
fn main() -> int:
  let a: u8 = 100
  let b: u8 = 100
  let c = a + b
  let big: int = 9000000000
  let d = big + big
  return (c ^int) - 200 + (d /i 18000000000)
"""
  t.hostRuns "arithmetic that fits is unchanged, and `int` is never checked", 1

  t.src """
type Seq16 = u16 [wrapping]

fn main() -> int:
  let s: Seq16 = 65535 Seq16
  let n = s + (1 Seq16)
  return n ^int
"""
  t.hostRuns "[wrapping] wraps: 65535 + 1 is 0", 0

  t.src """
type Strict = i16 [trapping]

fn main() -> int:
  let s: Strict = 32767 Strict
  let n = s + (1 Strict)
  return 0
"""
  t.hostRuns "[trapping] says so out loud, and traps", 1, "Arithmetic overflow on"

  t.src """
fn main() -> int:
  var x: i32 = -2147483647
  x = x - 10
  return 0
"""
  t.hostRuns "a signed type traps below its minimum too", 1,
             "Arithmetic overflow on"

  t.src """
fn main() -> int:
  var x: u64 = 18446744073709551615
  x = x + 1
  return 0
"""
  t.hostRuns "...and u64, which has no wider intermediate to hide in", 1,
             "Arithmetic overflow on"

  t.finish()
