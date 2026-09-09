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

  t.finish()
