## Effect propagation tells the user what to write (issue #14).
##
## The ruling (2026-09-13) is that effects stay DECLARED in the code — reading
## a signature tells you at a glance what the body may do — and the compiler,
## which already works out what is required, says what to add or remove. So
## TK-EF01 points at the call that needs the effect and spells the fix, and
## TK-EF02 warns about a declared `[io]` nothing in the body needs.

import ../harness

proc run*(t: var T) =
  ## Registers the effect-guidance assertions.
  t.src """
import console

fn inner() -> void [io]:
  {text: "x"} printLine

fn outer() -> void:
  {} inner

fn main() -> int:
  {} outer
  return 0
"""
  t.badCheck "an undeclared effect is still an error (TK-EF01)", "TK-EF01"
  t.badCheck "...naming the call that needs it", "'inner' is \\[io\\]"
  t.badCheck "...and the fix: declare it on the fn it names",
             "Fix: declare \\[io\\] on 'outer'"
  t.badCheck "...reported at the call, not at the fn", "t\\.tuck:7:"

  t.src """
import console

fn inner() -> void [io]:
  {text: "x"} printLine

fn outer() -> void [io]:
  {} inner

fn main() -> int:
  {} outer
  return 0
"""
  t.okCheck "declared at every level, it checks clean"
  t.checkSilent "...and says nothing", "TK-EF0"

  t.src """
fn quiet({n: int}) -> int [io]:
  return n + 1

fn main() -> int:
  return {n: 1} quiet
"""
  t.checkSays "a declared [io] nothing needs is a warning (TK-EF02)",
              "Effect\\ Warning\\ \\[TK-EF02\\]"
  t.okCheck "...not an error: the build carries on"

  t.src """
fn later({n: int}) -> int [io]:
  ...

fn main() -> int:
  return 0
"""
  t.checkSilent "a `...` stub's bracket is its contract, so no warning", "TK-EF02"

  # --- marker families (issue #64): restrictions propagate DOWN --------------
  #
  # The effect pass treated every marker as an obligation passed up. That is
  # right for `io` and backwards for `no_alloc` / `irq_safe` / `pure`: a plain
  # fn may call a restricted one, and a restricted fn may only call restricted
  # ones. Both directions were wrong before.
  t.src """
fn tiny({x: int}) -> int [no_alloc, irq_safe]:
  return x + 1

fn normal({x: int}) -> int:
  return {x: x} tiny

fn main() -> int:
  return {x: 1} normal
"""
  t.okCheck "a plain fn may call a restricted one (was wrongly rejected)"

  t.src """
fn plain({x: int}) -> int:
  return x + 1

fn isr({x: int}) -> int [irq_safe, no_alloc]:
  return {x: x} plain

fn main() -> int:
  return {x: 1} isr
"""
  t.badCheck "a restricted fn calling a plain one is refused (TK-EF03)", "TK-EF03"
  t.badCheck "...naming the callee and the fix",
             "calls 'plain', which is not.*Fix: declare \\[irq_safe\\] on 'plain'"

  t.src """
fn leaf({x: int}) -> int [irq_safe, no_alloc]:
  return x + 1

fn mid({x: int}) -> int [irq_safe, no_alloc]:
  return {x: x} leaf

fn main() -> int:
  return {x: 1} mid
"""
  t.okCheck "a chain of restricted fns checks clean"

  t.src """
fn isr({x: int}) -> int [irq_safe]:
  return x
"""
  t.badCheck "irq_safe must also be no_alloc, and says so (TK-EF04)",
             "TK-EF04.*requires \\[no_alloc\\].*Fix: add \\[no_alloc\\]"

  t.src """
fn isr({x: int}) -> int [irq_safe, no_alloc, io]:
  return x
"""
  t.badCheck "irq_safe excludes io (TK-EF04)", "excludes"

  t.src """
fn p({x: int}) -> int [pure, io]:
  return x
"""
  t.badCheck "pure excludes io", "TK-EF04"

  t.src """
extern:
  fn rawRead({n: int}) -> int

fn isr({x: int}) -> int [irq_safe, no_alloc]:
  return {n: x} rawRead
"""
  t.badCheck "an extern with no marker is not known to be restricted (TK-EF03)",
             "TK-EF03"

  t.src """
extern:
  fn rawRead({n: int}) -> int [irq_safe, no_alloc]

fn isr({x: int}) -> int [irq_safe, no_alloc]:
  return {n: x} rawRead
"""
  t.okCheck "...and passes once the extern declares the marker"

  t.src """
pending:
  fn later({x: int}) -> int

fn isr({x: int}) -> int [irq_safe, no_alloc]:
  return x
"""
  t.okCheck "a pending stub declared alongside is not itself a violation"

  t.src """
task worker({x: int}) -> int:
  return x

fn isr({x: int}) -> int [irq_safe, no_alloc]:
  let r = {x: x} worker
  return r
"""
  t.badCheck "a restricted fn may not spawn a task", "spawns task"

  t.src """
fn sq({x: int}) -> int [pure]:
  return x * x

fn cube({x: int}) -> int [pure]:
  return x * ({x: x} sq)

fn main() -> int:
  return {x: 2} cube
"""
  t.okCheck "pure calling pure checks clean"

  t.src """
fn build({x: int}) -> int [no_alloc]:
  let xs: Seq[int] = [x, x]
  return xs.len
"""
  t.badCheck "a Seq literal allocates in a no_alloc fn", "TK-EF05"

  t.src """
fn join({a: str, b: str}) -> str [no_alloc]:
  return a + b
"""
  t.badCheck "str concatenation allocates in a no_alloc fn", "TK-EF05"

  t.src """
fn fixed({x: int}) -> int [no_alloc]:
  let a: Array[2, int] = [x, x]
  return a[0] + a[1]

fn lit() -> str [no_alloc]:
  return "hello"
"""
  t.okCheck "an Array and a string literal do not allocate"

  t.src """
fn build({x: int}) -> int:
  let xs: Seq[int] = [x, x]
  return xs.len
"""
  t.okCheck "an unrestricted fn may allocate"

  t.src """
fn fact({n: int}) -> int [stack: 256]:
  if n < 2:
    return 1
  return n * ({n: n - 1} fact)
"""
  t.badCheck "a stack-bounded fn may not recurse", "TK-EF06"

  t.src """
fn ping({n: int}) -> int:
  return {n: n} pong

fn pong({n: int}) -> int:
  return {n: n} ping

fn top({n: int}) -> int [stack: 256]:
  return {n: n} ping
"""
  t.badCheck "a stack-bounded fn may not reach a cycle", "TK-EF06"

  t.src """
fn leaf({n: int}) -> int:
  return n + 1

fn top({n: int}) -> int [stack: 256]:
  return {n: n} leaf

fn walk({n: int}) -> int:
  if n < 1:
    return 0
  return {n: n - 1} walk
"""
  t.okCheck "an acyclic stack-bounded fn is fine; recursion elsewhere is not its business"

  t.src """
import bits
import math

fn mask({a: u64}) -> u64 [pure, no_alloc]:
  return {a: a, b: a} bitAnd

fn root({v: f64}) -> f64 [no_alloc]:
  return {value: v} sqrt

fn main() -> int:
  return 0
"""
  t.okCheck "annotated std externs are callable from restricted fns"

  t.src """
import seq

fn grow({xs: Seq[int]}) -> Seq[int] [no_alloc]:
  return {items: xs, value: 1} push

fn main() -> int:
  return 0
"""
  t.badCheck "an allocating std fn (push) is not no_alloc", "TK-EF03"

  t.finish()
