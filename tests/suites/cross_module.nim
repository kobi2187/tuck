## One Tuck module using another — the thing a standard library is.
##
## `stdlib-project` designs 72 modules across five tiers, explicitly layered so
## the lower ones are used by the higher ones. Nothing had ever done it with a
## TYPE, and two of three backends could not:
##
##     import cmp
##     let f = {o: Order.Before} flipped
##
## emitted `tuck_Order.Before` — a bare name — beside a correctly qualified
## `cmp.tuck_flipped` on the same line. Odin reported "Undeclared name" and D
## "undefined identifier". Nim never showed it: `import cmp` merges names, so
## the bare form resolves there.
##
## The mechanism to fix it already existed on both sides and was simply not
## reached from VALUE position. `injectImportedTypes` inserts a copy of the
## imported decl into the importer, stamped with its origin module, so asking
## `findDecl` whether a type is local answers "yes" for both kinds — the
## marker is the only thing that tells them apart. D already qualified foreign
## CALLABLES (importDeclaring) and Odin already qualified foreign types in TYPE
## position (importedTypeQualifier); neither qualified a type used as a value
## receiver or as a match-arm label.

import os
import ../harness

proc run*(t: var T) =
  # A sum declared in one module, constructed and matched in another.
  t.src """
import cmp

fn main() -> int:
  let s = {a: 3, b: 9} smaller
  let f = {o: Order.Before} flipped
  match f:
    After: return s - 3
    Before: return 1
    Same: return 2
"""
  t.addFile("cmp.tuck", """type Order:
  | Before
  | Same
  | After

fn flipped({o: Order}) -> Order:
  match o:
    Before: return Order.After
    Same: return Order.Same
    After: return Order.Before

fn smaller[T]({a: T, b: T}) -> T:
  if a < b:
    return a
  return b
""")
  t.okCheck "a type and a generic fn cross a module boundary"
  t.emitsOdin "Odin reaches the imported type through its package",
              r"cmp\.tuck_Order\.Before"
  t.emitsD "D reaches it through its import alias", r"cmp\.tuck_Order\.Before"
  t.hostBuilds "...and every backend's host compiler accepts the pair"
  t.runs "...and the imported flip and generic min both work", 0

  # The match-arm labels are a second value position, reached by a different
  # path (enumTagOwner, which answers a bare owner name), and were bare too.
  t.emitsOdin "an imported sum's match labels are qualified as well",
              r"case cmp\.tuck_Order\."
  t.emitsD "...on D as well", r"case cmp\.tuck_Order\."

  # --- a fn reference filling an imported module's fnsig slot ---------------
  # Four separate gaps, each hiding the next. The parser dropped the module
  # from `:provider::firstWins`, leaving a bare `:firstWins`; synthQualified
  # typed a module-qualified reference Unknown; Unknown satisfies every slot,
  # so the call checked clean; and Nim's and Odin's own scope merge then
  # emitted a bare name that linked anyway. Only D said anything, because it
  # decides "reference, not call" from the checker's type and so emitted
  # `provider.tuck_firstWins` where `&provider.tuck_firstWins` was meant.
  # Under it all, an imported `fnsig` was not recognised as a signature type
  # at all: fnSigNames never crossed the import boundary.
  t.src """
import verbs
import provider

fn main() -> int:
  let r = {a: 3, b: 9, better: :provider::firstWins} pick
  return r - 3
"""
  t.addFile("verbs.tuck", """fnsig Better[T] = {x: T, y: T} -> bool

fn pick[T]({a: T, b: T, better: Better[T]}) -> T:
  let ok = {x: a, y: b} better
  if ok:
    return a
  return b
""")
  t.addFile("provider.tuck", """fn firstWins({x: int, y: int}) -> bool:
  return x < y
""")
  t.okCheck "a fn reference fills an imported module's generic fnsig slot"
  t.emitsD "D takes the address of the qualified fn, not a no-arg call",
           r"&provider\.tuck_firstWins"
  t.hostBuilds "...and every backend builds it"
  t.runs "...and the imported callback is the one invoked", 0

  # --- two imports exporting one name -------------------------------------
  # The name gives up its BARE form and stays reachable qualified; the error
  # moves from import time to use. This is what makes an implementation
  # swappable: two modules implementing one contract share their internal
  # helper names by nature, and Tuck has no way to mark a name private, so
  # failing at the import meant a program could not use two implementations
  # at once — an ordinary thing to want (a str-keyed map and an int-keyed one).
  t.src """
import alpha
import beta

fn main() -> int:
  return {n: 1} alpha::step - 2
"""
  t.addFile("alpha.tuck", """fn step({n: int}) -> int:
  return n + 1
""")
  t.addFile("beta.tuck", """fn step({n: int}) -> int:
  return n + 100
""")
  t.okCheck "two imports may export one name, reached qualified"
  t.hostBuilds "...and every backend builds it"
  t.runs "...and the qualified one is the one called", 0

  t.src """
import alpha
import beta

fn main() -> int:
  return {n: 1} step
"""
  t.addFile("alpha.tuck", """fn step({n: int}) -> int:
  return n + 1
""")
  t.addFile("beta.tuck", """fn step({n: int}) -> int:
  return n + 100
""")
  t.badCheck "...but writing it bare names both owners and asks which",
    "'step' is exported by 2 imports"


  # --- the signature index must not hide an imported type ------------------
  # An IndexEntry carries a module's fn signatures and NOTHING else, so a
  # module served from the index contributed no type declarations:
  # injectImportedTypes found none to copy and the importer could not see the
  # name at all. The same hole swallows imported groups, their bounds, and
  # fnsig names, all of which are gathered from fully loaded modules only.
  #
  # It stayed invisible because the missing name resolved to Unknown, which is
  # compatible with everything — the program checked clean on a warm cache and
  # failed on a cold one, or the reverse, depending on which ran first.
  # Removing Unknown turned it into the hard error it always was.
  #
  # Pinning it needs TWO checks in one directory: the first writes the index,
  # the second reads it. Every other assertion here runs `tuck ch` once, which
  # is exactly why the suite never caught this.
  t.src """
import base

fn main() -> int:
  let o = Order.Before
  match o:
    Before: return 0
    _: return 1
"""
  t.addFile("base.tuck", """type Order:
  | Before
  | Same
  | After
""")
  t.addFile("second.tuck", """import base

fn main() -> int:
  let o = Order.After
  match o:
    After: return 0
    _: return 1
""")
  let cold = t.needCmd @[tuckExe, "ch", t.cur / "t.tuck", "--root:" & t.root]
  let warm = t.needCmdAfter(@[tuckExe, "ch", t.cur / "second.tuck",
                              "--root:" & t.root],
                            cold, proc (dir: string) = discard, t.cur, vCheck)
  if t.phase == pReport:
    let (rc1, out1) = t.resultOf(cold)
    if rc1 == 0: t.ok "an imported sum resolves on a cold index"
    else: t.no "an imported sum resolves on a cold index", out1
    if t.skippedCmd(warm):
      t.ok "...and on a warm one (skipped)"
    else:
      let (rc2, out2) = t.resultOf(warm)
      if rc2 == 0: t.ok "...and still resolves once the index is warm"
      else: t.no "...and still resolves once the index is warm", out2

  t.finish()
