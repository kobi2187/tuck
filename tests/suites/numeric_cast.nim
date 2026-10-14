## `x ~T` and `x ^T` — the explicit numeric conversion (issue #16, step 2).
##
## Crossing a numeric type boundary is written in the source, in the author's
## own code (ruled 2026-08-24): `~T` where the conversion can lose a value,
## `^T` where it cannot. The sigil names the direction and is CHECKED, and a
## cast of a value the compiler can fold is checked for range, so `~` means "I
## checked this" wherever the compiler can confirm it.
##
## The runs assertion builds and runs on every backend: the claim is that all
## three convert alike.

import ../harness

proc run*(t: var T) =
  ## Registers the cast assertions: the accepted spellings, each refusal, and
  ## one program run on Nim, Odin and D.
  t.src """
fn setDuty({channel: int, permille: u16}) -> int:
  return permille ^int

fn main() -> int:
  let wide: u32 = 1200
  let r = {channel: 1, permille: wide ~u16} setDuty
  let small: u8 = 7
  let w = small ^int
  let k = 300 ~u16
  return r - 1190 + w + (k ^int) - 300
"""
  t.okCheck "a narrowing `~`, a widening `^` and a folded constant check"
  t.hostRuns "...and convert alike on every backend", 17

  t.src """
fn main() -> int:
  let a: u8 = 5
  let b = a ~u16
  return 0
"""
  t.badCheck "`~` on a conversion that cannot lose is refused (TK-TY40)", "TK-TY40"

  t.src """
fn main() -> int:
  let a: int = 5
  let b = a ^u8
  return 0
"""
  t.badCheck "`^` on a conversion that can lose is refused (TK-TY40)", "TK-TY40"

  t.src """
fn main() -> int:
  let a: i16 = 5
  let b = a ~u32
  return 0
"""
  t.okCheck "a sign crossing is a `~`, even into a wider type"

  t.src """
fn main() -> int:
  let b = 70000 ~u16
  return 0
"""
  t.badCheck "a constant that does not fit is an error (TK-TY41)", "TK-TY41"

  t.src """
const Limit = 300

fn main() -> int:
  let b = Limit ~u8
  return 0
"""
  t.badCheck "...and so is a `const` (TK-TY41)", "TK-TY41"

  t.src """
fn main() -> int:
  let b = 1200 ~u16
  return 0
"""
  t.okCheck "a constant that fits passes silently"

  t.src """
fn main() -> int:
  let s = "x"
  let b = s ~u8
  return 0
"""
  t.badCheck "only a number can be cast (TK-TY39)", "TK-TY39"

  t.src """
type Point:
  x: int

fn main() -> int:
  let b = 5 ~Point
  return 0
"""
  t.badCheck "...and only to a numeric type", "TK-TY39"

  t.finish()
