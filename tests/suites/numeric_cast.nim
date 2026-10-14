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

import std/[os, strutils]
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

  # --- no implicit conversion (issue #16, step 1) ---------------------------
  #
  # The repro from the issue: a u32 of 70000 flowed into a u16 parameter with
  # no diagnostic and was mangled at the boundary.
  t.src """
fn setDuty({channel: int, permille: u16}) -> void:
  return

fn main() -> int:
  let wide: u32 = 70000
  {channel: 1, permille: wide} setDuty
  return 0
"""
  t.badCheck "a u32 into a u16 parameter needs a cast", "expects u16 but got u32"

  t.src """
fn main() -> int:
  let b: int = 7
  let c: u8 = b
  return 0
"""
  t.badCheck "...and so does an int binding into a u8", "expects u8 but got int"

  t.src """
fn main() -> int:
  let small: u8 = 7
  let wide: int = small
  return 0
"""
  t.badCheck "...in the widening direction too: widening is written (`^`)",
             "expects int but got u8"

  t.src """
fn main() -> int:
  let a: u8 = 250
  let b: u16 = 5
  let c = a + b
  return 0
"""
  t.badCheck "mixed-width arithmetic is refused", "arithmetic between"

  t.src """
fn main() -> int:
  let a: u8 = 250
  let b: u16 = 5
  let c = (a ^u16) + b
  return 0
"""
  t.okCheck "...and passes with a cast on one side"

  # A literal has no width of its own: it takes the place's, and a value that
  # does not fit the place is an error rather than a silent wrap.
  t.src """
fn main() -> int:
  let a: u8 = 5
  var b: u16 = 7
  b = b + 1
  let xs: Array[16, u8] = [0; 16]
  if a == 0:
    return 1
  if a + 1 > 3:
    return 2
  return 0
"""
  t.okCheck "a literal adopts the width of its place, operand or fill"

  t.src """
fn main() -> int:
  let a: u8 = 300
  return 0
"""
  t.badCheck "a literal that does not fit its place is refused (TK-TY41)", "TK-TY41"

  t.src """
fn main() -> int:
  let a: u8 = 5
  if a == 300:
    return 1
  return 0
"""
  t.badCheck "...in a comparison too", "TK-TY41"

  # --- there is no type `float` --------------------------------------------
  t.src """
fn half({x: float}) -> float:
  return x
"""
  t.badCheck "the type `float` is gone: write f64 or f32 (TK-PA19)", "TK-PA19"

  t.src """
fn area({r: f32}) -> f32:
  let k: f32 = 3.0
  let wide: f64 = 2.5
  let narrow = wide ~f32
  return r * r * k + narrow
"""
  t.okCheck "a float literal takes its place's width, and f64 to f32 is a `~`"

  t.src """
fn main() -> int:
  let x: u8 = 2.5
  return 0
"""
  t.badCheck "...but a float literal never becomes an integer", "expects u8"

  # --- the audit report (issue #16, step 4) ---------------------------------
  #
  # Every `~` is a place the author accepted a possible loss; the compiler
  # already knows them all, so `--report-narrowing` lists them: where, the two
  # types, and whether the value was confirmed to fit (a folded constant) or the
  # risk is the author's. `^` casts lose nothing and are not listed.
  t.src """
import lib

const Limit = 200

fn main() -> int:
  let wide: u32 = 1200
  let a = wide ~u16
  let b = 1200 ~u16
  let c = Limit ~u8
  let w: u8 = 3
  let e = w ^int
  return {v: 5} clip
"""
  t.addFile("lib.tuck", """fn clip({v: int}) -> int:
  let small = v ~u8
  return small ^int
""")
  let rep = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck",
                        "--root:" & t.root, "--report-narrowing"])
  let quiet = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck",
                          "--root:" & t.root])
  if t.phase != pCollect:
    let (rc, outp) = t.resultOf(rep)
    if rc != 0: t.no "--report-narrowing lists the casts", "exit " & $rc & ": " & outp
    elif "NARROWING (4 casts):" in outp: t.ok "--report-narrowing counts the `~` casts"
    else: t.no "--report-narrowing counts the `~` casts", outp
    if "u32 -> u16  [unproven]" in outp: t.ok "...a variable is unproven"
    else: t.no "...a variable is unproven", outp
    if "int -> u16  [checked: 1200 fits]" in outp and
       "int -> u8  [checked: 200 fits]" in outp:
      t.ok "...a literal or const is confirmed"
    else: t.no "...a literal or const is confirmed", outp
    if "lib.tuck:2:" in outp and "t.tuck:" in outp:
      t.ok "...in every module, each under its own file"
    else: t.no "...in every module, each under its own file", outp
    if "^" in outp.split("NARROWING")[1].split("SIZE")[0]:
      t.no "...`^` casts are not listed", outp
    else: t.ok "...`^` casts are not listed"
    let (qrc, qout) = t.resultOf(quiet)
    if qrc == 0 and "NARROWING" notin qout: t.ok "...and nothing is printed without the flag"
    else: t.no "...and nothing is printed without the flag", qout

  t.finish()
