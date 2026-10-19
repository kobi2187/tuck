## Effect propagation tells the user what to write (issue #14).
##
## The ruling (2026-09-13) is that effects stay DECLARED in the code — reading
## a signature tells you at a glance what the body may do — and the compiler,
## which already works out what is required, says what to add or remove. So
## TK-EF01 points at the call that needs the effect and spells the fix, and
## TK-EF02 warns about a declared `[io]` nothing in the body needs.

import std/[os, strutils]
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
fn fact({n: int}) -> int [no_recursion]:
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

fn top({n: int}) -> int [no_recursion]:
  return {n: n} ping
"""
  t.badCheck "a stack-bounded fn may not reach a cycle", "TK-EF06"

  t.src """
fn leaf({n: int}) -> int:
  return n + 1

fn top({n: int}) -> int [no_recursion]:
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

  t.src """
import bits

fn mask({a: u64}) -> u64:
  return {a: a, b: a} bitAnd

fn twice({a: u64}) -> u64:
  let m = {a: a} mask
  return {a: m} mask

fn spin({n: int}) -> int:
  return {n: n} spin

fn main() -> int:
  return 0
"""
  let ef = t.needCmd(@["./tuck", "ef", t.curDir / "t.tuck", "--root:" & t.root])
  if t.phase != pCollect:
    let (rc, outp) = t.resultOf(ef)
    if rc != 0: t.no "tuck effects runs", outp
    elif "twice: declares [-]" notin outp or "suggest: add [pure, no_alloc]" notin outp:
      t.no "derived facts reach through a call chain", outp
    elif "spin: declares [-], needs [-], derived: -" notin outp:
      t.no "a recursive fn derives nothing", outp
    else:
      t.ok "tuck effects derives pure/no_alloc through calls, none for recursion"

  t.src """
actor Counter:
  total: int = 0
  on add({n: int}):
    total += n

fn isr() -> void [irq_safe, no_alloc]:
  Counter send add {n: 1}

fn main() -> int:
  return 0
"""
  t.badCheck "an irq_safe fn may not send (the mailbox locks)", "TK-EF07"

  t.src """
fn sq({x: int}) -> int [pure]:
  return x * x

fn main() -> int:
  return {x: 3} sq
"""
  let hc = t.needCmd(@["./tuck", "c", t.curDir / "t.tuck", "--root:" & t.root])
  if t.phase != pCollect:
    let (rc, outp) = t.resultOf(hc)
    let nimFile = t.curDir / "t.nim"
    if rc != 0: t.no "host checks compile", outp
    elif not fileExists(nimFile) or "{.noSideEffect.}" notin readFile(nimFile):
      t.no "[pure] reaches the host as noSideEffect by default", outp
    else:
      t.ok "[pure] reaches the host as noSideEffect by default"

  t.src """
fn walk({n: int}) -> int [recursion: 5]:
  if n < 1:
    return 0
  let m = n - 1
  return {n: m} walk

fn main() -> int:
  return {n: 50} walk
"""
  t.okCheck "a [recursion: N] fn checks clean"
  t.emits "recursion: the counter is declared per fn (Nim)", "threadvar"
  t.emits "recursion: entering past N traps (Nim)", "tuckDepthExceeded"
  t.emitsOdin "recursion: entering past N traps (Odin)", "rt.tuckDepthExceeded"
  t.emitsD "recursion: entering past N traps (D)", "rt.tuckDepthExceeded"
  t.runs "recursion: recursing past N stops with status 1", 1
  t.outputs "recursion: and says which fn and what limit", "Recursion depth exceeded in walk: limit 5"

  t.src """
fn walk({n: int}) -> int [recursion: 5]:
  if n < 1:
    return 0
  let m = n - 1
  return {n: m} walk

fn main() -> int:
  return {n: 3} walk
"""
  t.runs "recursion: recursion within N runs normally", 0

  t.src """
fn f({n: int}) -> int [stack: 128]:
  return n
"""
  t.badCheck "[stack: N] is retired and says what replaced it", "no_recursion"

  t.src """
fn f({n: int}) -> int [no_recursion, recursion: 4]:
  return n
"""
  t.badCheck "no_recursion and depth contradict", "TK-EF04"

  t.src """
fn f({n: int}) -> int [pure, recursion: 4]:
  return n
"""
  t.badCheck "a pure fn cannot carry a depth counter", "TK-EF04"

  t.src """
fn sq({x: int}) -> int [pure]:
  return x * x

fn main() -> int:
  return {x: 3} sq
"""
  t.emits "a pure fn is not marked inline by default", "proc tuckˑfnˑsq\\*\\(x: int\\): int \\{\\.noSideEffect\\.\\}"
  let inl = t.needCmd(@["./tuck", "c", t.curDir / "t.tuck", "-O:inline", "--root:" & t.root])
  if t.phase != pCollect:
    let (rc, outp) = t.resultOf(inl)
    let nimFile = t.curDir / "t.nim"
    if rc != 0: t.no "-O:inline compiles", outp
    elif not fileExists(nimFile) or "{.inline, noSideEffect.}" notin readFile(nimFile):
      t.no "-O:inline marks a small pure fn inline", outp
    else:
      t.ok "-O:inline marks a small pure fn inline"

  t.src """
actor Counter [queue: 8]:
  total: int = 0
  on add({n: int}):
    total += n

actor Logger [queue: 8]:
  seen: int = 0
  on note({n: int}):
    Counter send add {n: n}

fn main() -> int:
  return 0
"""
  let hand = t.needCmd(@["./tuck", "ef", t.curDir / "t.tuck", "--root:" & t.root])
  if t.phase != pCollect:
    let (rc, outp) = t.resultOf(hand)
    if rc != 0: t.no "tuck effects lists actor handlers", outp
    elif "Counter.add: handler, declares [-], needs [-], isolated" notin outp:
      t.no "a handler that touches only its own state is reported isolated", outp
    elif "Logger.note: handler, declares [-], needs [-]\n" notin outp:
      t.no "a handler that sends to another actor is not isolated", outp
    else:
      t.ok "tuck effects reports isolated handlers (issue #67)"

  t.src """
extern:
  fn netSend({n: int}) -> int [io: net]
  fn diskWrite({n: int}) -> int [io: fs]
  fn anything({n: int}) -> int [io]

fn sameKind({n: int}) -> int [io: net]:
  return {n: n} netSend

fn bareCoversAll({n: int}) -> int [io]:
  let x = {n: n} netSend
  return {n: x} diskWrite

fn twoKinds({n: int}) -> int [io: net, io: fs]:
  let x = {n: n} netSend
  return {n: x} diskWrite

fn main() -> int:
  return 0
"""
  t.okCheck "a kind covers itself; bare [io] covers every kind; kinds combine"

  t.src """
extern:
  fn diskWrite({n: int}) -> int [io: fs]

fn wrongKind({n: int}) -> int [io: net]:
  return {n: n} diskWrite
"""
  t.badCheck "[io: net] may not call an [io: fs] fn (TK-EF01)", "\\[io: fs\\]"

  t.src """
extern:
  fn anything({n: int}) -> int [io]

fn narrow({n: int}) -> int [io: net]:
  return {n: n} anything
"""
  t.badCheck "a named kind does not admit bare [io] (the callee may do any kind)", "TK-EF01"

  t.src """
fn f({n: int}) -> int [io: banana]:
  return n
"""
  t.badCheck "an unknown io kind is a parse error naming the kinds", "net, fs, clock, console, sys"

  t.src """
fn f({n: int}) -> int [irq_safe, no_alloc, io: net]:
  return n
"""
  t.badCheck "irq_safe excludes every io kind (TK-EF04)", "TK-EF04"

  t.src """
import console

fn say() -> void [io: console]:
  {text: "x"} printLine

fn wrong() -> void [io: net]:
  {text: "x"} printLine
"""
  t.badCheck "the std console fns are [io: console]", "io: console"

  t.src """
fn memo(64) fib({n: int}) -> int [pure]:
  if n < 2:
    return n
  let a = n - 1
  let b = n - 2
  let x = {n: a} fib
  let y = {n: b} fib
  return x + y

fn memo wide({n: int, k: u8}) -> int [pure]:
  return n + 1

fn main() -> int:
  let r = {n: 40} fib
  let w = {n: 3, k: 2} wide
  return r - 102334155 + w - 4
"""
  t.checkSays "an unbounded memo warns that its cache grows (TK-EF09)", "TK-EF09"
  t.hostRuns "fn memo gives the same answer on every backend (fib 40 is instant)", 0
  t.emitsD "memo: the D wrapper keeps a thread-local slot table", "Slot\\[64\\]"

  t.src """
fn memo(8) f({n: int}) -> int:
  return n
"""
  t.badCheck "memo needs [pure]", "TK-EF08"

  t.src """
fn memo(8) f({s: str}) -> int [pure]:
  return 1
"""
  t.badCheck "memo takes only integer and bool parameters", "TK-EF08"

  t.src """
fn memo pick({a: i8, flag: bool}) -> int [pure]:
  let w = a ^int
  if flag:
    return 100 + w
  return w * 2

fn memo(4) tiny({n: u8}) -> int [pure]:
  return 1

fn main() -> int:
  let x = {a: -5, flag: true} pick
  let y = {a: 7, flag: false} pick
  let z = {a: -5, flag: true} pick
  let m = {a: -127, flag: false} pick
  return x + y + z + m + 50
"""
  t.checkSilent "a small input space is a direct table, so no unbounded warning", "TK-EF09"
  t.emits "memo: i8 x bool is a 512-entry table indexed directly", "array\\[512, "
  t.hostRuns "memo: direct-index tables agree on every backend, signed and bool keys included", 0

  t.finish()
