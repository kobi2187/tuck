## One Tuck module using another — the thing a standard library is.
##
## `stdlib-project` designs 72 modules across five tiers, explicitly layered so
## the lower ones are used by the higher ones. Nothing had ever done it with a
## TYPE, and two of three backends could not:
##
##     import cmp
##     let f = {o: Order.Before} flipped
##
## emitted `tuck_type_Order.Before` — a bare name — beside a correctly qualified
## `cmp.tuck_fn_flipped` on the same line. Odin reported "Undeclared name" and D
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
              r"cmp\.tuck_type_Order\.Before"
  t.emitsD "D reaches it through its import alias", r"cmp\.tuck_type_Order\.Before"
  t.hostBuilds "...and every backend's host compiler accepts the pair"
  t.runs "...and the imported flip and generic min both work", 0

  # The match-arm labels are a second value position, reached by a different
  # path (enumTagOwner, which answers a bare owner name), and were bare too.
  t.emitsOdin "an imported sum's match labels are qualified as well",
              r"case cmp\.tuck_type_Order\."
  t.emitsD "...on D as well", r"case cmp\.tuck_type_Order\."

  # --- a fn reference filling an imported module's fnsig slot ---------------
  # Four separate gaps, each hiding the next. The parser dropped the module
  # from `:provider::firstWins`, leaving a bare `:firstWins`; synthQualified
  # typed a module-qualified reference Unknown; Unknown satisfies every slot,
  # so the call checked clean; and Nim's and Odin's own scope merge then
  # emitted a bare name that linked anyway. Only D said anything, because it
  # decides "reference, not call" from the checker's type and so emitted
  # `provider.tuck_fn_firstWins` where `&provider.tuck_fn_firstWins` was meant.
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
           r"&provider\.tuck_fn_firstWins"
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

  # --- `public:` — the module's export list --------------------------------
  # Bare names, whitespace-separated. Tuck has no overloading, so a name IS
  # the signature: an export list repeating parameters would be a second copy
  # to keep in step with the declaration, and the first thing to go stale.
  #
  # The case it exists for: two modules implementing ONE contract share their
  # internal helper names by nature. Before this, importing both collided on
  # a helper neither meant to share.
  t.src """
import lib

fn main() -> int:
  let m = {v: 7} Box
  return {self: m} get - 7
"""
  t.addFile("lib.tuck", """public:
  get Box

type Box = {v: int}

fn get({self: Box}) -> int:
  return self.v

fn helper({n: int}) -> int:
  return n + 1
""")
  # Check-level only: CONSTRUCTING an imported record is broken on the D
  # backend independently of `public:` (without a public block the same
  # program fails as "undefined identifier tuck_type_Box"), so building this one
  # would assert someone else's bug.
  t.okCheck "an exported name and type are visible to the importer"
  t.src """
import lib

fn main() -> int:
  return {n: 1} helper - 2
"""
  t.addFile("lib.tuck", """public:
  get

fn get({n: int}) -> int:
  return n

fn helper({n: int}) -> int:
  return n + 1
""")
  t.badCheck "a name left out of the list is not visible", "'helper' is not a declared callable"

  # `public:` reaches the EMITTED ARTIFACT, not just the checker. A private
  # helper appearing as a public symbol in a library someone links against is
  # wrong on its own terms, and is a link-time collision waiting to happen.
  # Each backend in its own spelling: Nim's `*`, D's `private`, Odin's
  # `@(private)` — file scope, the closest thing Odin has to module-private
  # and exactly the scope one Tuck module occupies.
  t.src """
public:
  shown

fn shown({n: int}) -> int:
  return n + 1

fn hidden({n: int}) -> int:
  return n + 2

fn main() -> int:
  let a = {n: 1} shown
  let b = {n: 1} hidden
  return a + b - 5
"""
  t.okCheck "a module may export some of its own names"
  t.emits "Nim stars the exported name", r"proc tuck_fn_shown\*"
  t.omits "...and leaves the unexported one unstarred", r"proc tuck_fn_hidden\*"
  t.emitsD "D marks the unexported one private", r"private long tuck_fn_hidden"
  t.emitsOdin "Odin marks the unexported one private", r"@\(private\)"
  t.hostBuilds "...and every backend still builds it"
  t.runs "...and a private name is still callable from inside its module", 0

  # Private means private: qualifying does not reach past the list.
  t.src """
import lib

fn main() -> int:
  return {n: 1} lib::helper - 2
"""
  t.addFile("lib.tuck", """public:
  get

fn get({n: int}) -> int:
  return n

fn helper({n: int}) -> int:
  return n + 1
""")
  t.badCheck "...not even qualified", "module 'lib' has no function 'helper'"

  # A name in the list that nothing declares is a typo, and a silent one: the
  # module would simply export less than its author believes.
  t.src """
import lib

fn main() -> int:
  return 0
"""
  t.addFile("lib.tuck", """public:
  get nosuch

fn get({n: int}) -> int:
  return n
""")
  t.badCheck "an exported name the module does not declare is refused",
    "'nosuch' is exported by the `public:` block"

  # The payoff: two implementations of one contract, each with its own
  # internal `step`, both imported.
  t.src """
import alpha
import beta

fn main() -> int:
  let a = {n: 1} alpha::run
  let b = {n: 1} beta::run
  return a + b - 103
"""
  t.addFile("alpha.tuck", """public:
  run

fn step({n: int}) -> int:
  return n + 1

fn run({n: int}) -> int:
  return {n: n} step
""")
  t.addFile("beta.tuck", """public:
  run

fn step({n: int}) -> int:
  return n + 100

fn run({n: int}) -> int:
  return {n: n} step
""")
  t.okCheck "two implementations sharing a private helper name both import"
  t.hostBuilds "...and every backend builds it"
  t.runs "...and each reaches its own helper", 0

  # --- an actor declared in an IMPORTED module -----------------------------
  #
  # This SEGFAULTED. The library emitted a perfectly good
  # `registerActor<Name>`, and nobody called it: tuck.nim collected actor and
  # task names from the ENTRY module's decls only, so a program whose actors
  # all live in libraries looked like a program with no actors. The scheduler
  # was never initialised, the drain coroutine never started, and the first
  # `send` ran tuckNotifySend against an uninitialised runtime.
  #
  # Both halves were individually valid, which is why it compiled clean; the
  # defect lived in the gap between them. Same shape as #61 (a fact about the
  # program derived from one place while another place derived it differently)
  # and the same scope error as #73 (`m.decls` is the entry module, imports
  # invisible), but the symptom here is a crash rather than a diagnostic.
  t.src """
import lib

fn main() -> int [io]:
  return {n: 6} stash
"""
  t.addFile("lib.tuck", """import scheduler

actor Tally [queue: 4]:
  last: int = 0

  on put({v: int}):
    last = v

fn ready() -> bool:
  return Tally.last > 0

fn stash({n: int}) -> int [io]:
  Tally send put {v: n}
  Tally.waitUntil {pred: :ready}
  return Tally.last
""")
  t.okCheck "an actor may be declared in an imported module"
  # Asserted by RUNNING, not by reading the emitted module: the entry prologue
  # that boots the runtime and calls registerActor is appended by `tuck b`,
  # so `tuck c` output does not contain it and an `emits` here would be
  # checking the wrong file.
  t.runs "...and the message is delivered", 6

  # Odin and D build the same program but do not run it correctly: their entry
  # builders have the identical entry-module-only scope, and fixing them needs
  # more than collecting names — an imported actor's drain is in another
  # package, so the call has to be QUALIFIED. Odin hangs, D returns 0.
  t.quietly: t.hostRuns("an imported actor runs on every backend", 6)
  t.bugOpen "an imported actor runs on every backend"

  # --- the msgpack AST cache (.tuck-cache) ---------------------------------
  #
  # Incremental compilation, and nothing covered it. The cache stores a module
  # ALREADY REWRITTEN and, since 2026-09-17, already generic-actor-expanded, so
  # a stale entry does not merely cost time — it would serve a tree built by a
  # different compiler.
  #
  # Two keys guard that: `srcHash` (this file's text) and `buildStamp` (the
  # compiler's own build time). These assert the first; the second cannot be
  # exercised without rebuilding the compiler mid-suite.
  t.src """
import lib

fn main() -> int:
  return {} answer
"""
  t.addFile("lib.tuck", """fn answer() -> int:
  return 1
""")
  t.runs "a cold build of an imported module", 1

  # ...now EDIT the library and build again in the same directory. A cache
  # keyed only on the compiler's stamp would serve the old tree and answer 1.
  let coldRun = t.needCmd @[tuckExe, "b", t.cur / "t.tuck", "--root:" & t.root]
  let edited = t.needCmdAfter(@[tuckExe, "b", t.cur / "t.tuck",
                                "--root:" & t.root],
                              coldRun,
                              proc (dir: string) =
                                writeFile(dir / "lib.tuck",
                                          "fn answer() -> int:\n  return 2\n"),
                              t.cur, vBuild)
  if t.phase == pReport:
    if t.skippedCmd(edited):
      t.ok "editing a module invalidates its cache entry (skipped)"
    else:
      let (rc, outp) = t.resultOf(edited)
      if rc == 0: t.ok "editing a module invalidates its cache entry"
      else: t.no "editing a module invalidates its cache entry", outp

  # --- a const declared in an IMPORTED module ------------------------------
  #
  # `constIntOf` resolved against the CURRENT module only, so an imported const
  # named a size that could not be evaluated — and the three callers disagreed
  # about what that meant. Two reported "must be a whole number the compiler
  # knows", a false error about a const that plainly is one. The third,
  # failIfArrayLengthMismatched, DECLINED TO CHECK.
  #
  # That third one is why this mattered: the same source, with one line moved
  # across a module boundary, went from correctly rejected to silently
  # accepted, and a wrong array length rode to the backend. It is the same
  # failure #59 fixed for an UNDECLARED size, reappearing for a size that is
  # declared, just not here (#73).
  t.src """
import lim

fn main() -> int:
  let a: Array[Cap, int] = [1, 2, 3]
  return 0
"""
  t.addFile("lim.tuck", """const Cap = 4

type Point:
  x: int
""")
  t.badCheck "a wrong Array length is caught when the size is an IMPORTED const",
             "needs exactly 4"

  t.src """
import lim

pool Slots = Point [count: Cap]

fn main() -> int:
  return 0
"""
  t.addFile("lim.tuck", """const Cap = 4

type Point:
  x: int
""")
  t.okCheck "...and a pool count takes one, rather than a false rejection"

  t.src """
import lim

actor Sink [queue: Cap]:
  n: int = 0

  on go():
    n = 1

fn main() -> int:
  return 0
"""
  t.addFile("lim.tuck", """const Cap = 4

type Point:
  x: int
""")
  t.okCheck "...and so does an actor queue"

  # The local module is consulted FIRST, so a module's own const shadows any
  # other's. Asserted by VALUE — the list has 4 elements and the LOCAL Cap is
  # 2, so an answer of "needs exactly 2" proves which one was read. A test
  # that merely checked "no error" would pass on a lookup that resolved
  # nothing at all.
  t.src """
import lim

const Cap = 2

fn main() -> int:
  let a: Array[Cap, int] = [1, 2, 3, 4]
  return 0
"""
  t.addFile("lim.tuck", """const Cap = 4

type Point:
  x: int
""")
  t.badCheck "a module's own const shadows an imported one of the same name",
             "needs exactly 2"

  # --- `mod::Type` in a type position (#36) ---------------------------------
  # `geo::mk` worked in an expression; `geo::Point` in a type was a parse
  # error. The parser now keeps the qualifier and the checker confirms the
  # module declares the type; every later stage reads the bare name, which
  # already resolves to the imported type.
  t.src """
import geo

fn main() -> int:
  let p: geo::Point = {x: 5} geo::mk
  return p.x
"""
  t.addFile("geo.tuck", """type Point:
  x: int

fn mk({x: int}) -> Point:
  return {x: x} Point
""")
  t.hostRuns "a module-qualified type in a binding builds and runs", 5
  t.src """
import geo

type Wrap:
  inner: geo::Point

fn bump({p: geo::Point}) -> geo::Point:
  return {x: p.x + 1} geo::mk

fn main() -> int:
  let first = {x: 5} geo::mk
  let w = {inner: first} Wrap
  let b = {p: w.inner} bump
  return b.x
"""
  t.addFile("geo.tuck", """type Point:
  x: int

fn mk({x: int}) -> Point:
  return {x: x} Point
""")
  t.hostRuns "...as a field, a parameter and a return type", 6
  t.src """
import geo

fn main() -> int:
  let p: nope::Point = {x: 5} geo::mk
  return p.x
"""
  t.addFile("geo.tuck", """type Point:
  x: int

fn mk({x: int}) -> Point:
  return {x: x} Point
""")
  t.badCheck "a qualifier naming the wrong module is refused", "comes from 'geo', not 'nope'"
  t.src """
import geo

fn main() -> int:
  let p: geo::Nope = {x: 5} geo::mk
  return p.x
"""
  t.addFile("geo.tuck", """type Point:
  x: int

fn mk({x: int}) -> Point:
  return {x: x} Point
""")
  t.badCheck "...and one naming a type the module lacks", "declares a public type 'Nope'"

  t.finish()
