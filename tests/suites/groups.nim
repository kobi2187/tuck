## `group` — a compile-time bound for generics (spec §5.5).
##
## Distinct from `interface`: no dispatch, no tag, no copying-variant
## representation, and no attach statement. `fn f[T: Sortable]` checks, at
## each instantiation, that the concrete T has a free fn matching the
## requirement — the same shape-matching a `:fnRef` already gets against a
## `fnsig`. Fully resolved and discarded before codegen ever runs.

import ../harness

proc run*(t: var T) =
  # --- the declaration and a passing bound ----------------------------------
  t.src """
group Sortable:
  fn compare({self: Self, other: Self}) -> Order

type Order:
  | Before
  | Same
  | After

type Box = {value: int}

fn compare({self: Box, other: Box}) -> Order:
  if self.value < other.value:
    return Order.Before
  if self.value > other.value:
    return Order.After
  return Order.Same

fn smallerOf[T: Sortable]({a: T, b: T}) -> T:
  let c = {self: a, other: b} compare
  match c:
    Before: return a
    Same: return a
    After: return b

fn main() -> int:
  let b1 = {value: 1} Box
  let b2 = {value: 2} Box
  let s = {a: b1, b: b2} smallerOf
  return s.value - 1
"""
  t.okCheck "a group bound checks against a concrete type providing the shape"
  t.hostBuilds "...and every backend builds it"
  t.runs "...and runs", 0

  # --- a missing member names the group and the shape it required ----------
  t.src """
group Sortable:
  fn compare({self: Self, other: Self}) -> Order

type NoCompare = {value: int}

fn smallerOf[T: Sortable]({a: T, b: T}) -> T:
  return a

fn main() -> int:
  let n1 = {value: 1} NoCompare
  let n2 = {value: 2} NoCompare
  let s = {a: n1, b: n2} smallerOf
  return 0
"""
  t.badCheck "a concrete type missing the required shape fails, naming both",
    "'NoCompare', bound to 'T: Sortable' in 'smallerOf', does not provide"

  # --- multiple groups on one type param, `+`-joined ------------------------
  t.src """
group Sortable:
  fn compare({self: Self, other: Self}) -> Order

group Hashable:
  fn hashOf({self: Self}) -> u64

type Order:
  | Before
  | Same
  | After

type Box = {value: int}

fn compare({self: Box, other: Box}) -> Order:
  return Order.Same

fn hashOf({self: Box}) -> u64:
  return 0

fn needsBoth[T: Sortable + Hashable]({a: T}) -> u64:
  return {self: a} hashOf

fn main() -> int:
  let b = {value: 1} Box
  if {a: b} needsBoth != 0:
    return 1
  return 0
"""
  t.okCheck "multiple `+`-joined groups on one type param check"
  t.hostBuilds "...and every backend builds it"
  t.runs "...and runs", 0

  t.src """
group Sortable:
  fn compare({self: Self, other: Self}) -> Order

group Hashable:
  fn hashOf({self: Self}) -> u64

type Order:
  | Before
  | Same
  | After

type Box = {value: int}

fn compare({self: Box, other: Box}) -> Order:
  return Order.Same

fn needsBoth[T: Sortable + Hashable]({a: T}) -> u64:
  return 0

fn main() -> int:
  let b = {value: 1} Box
  return {a: b} needsBoth - 0
"""
  t.badCheck "one missing group among several names exactly that one",
    "'Box', bound to 'T: Hashable' in 'needsBoth', does not provide"

  # --- the bound written directly on a parameter's type ---------------------
  t.src """
group Sortable:
  fn compare({self: Self, other: Self}) -> Order

group Hashable:
  fn hashOf({self: Self}) -> u64

type Order:
  | Before
  | Same
  | After

type Box = {value: int}

fn compare({self: Box, other: Box}) -> Order:
  return Order.Same

fn hashOf({self: Box}) -> u64:
  return 0

fn describe({item: Sortable + Hashable}) -> u64:
  return {self: item} hashOf

fn main() -> int:
  let b = {value: 1} Box
  if {item: b} describe != 0:
    return 1
  return 0
"""
  t.okCheck "a bound written directly on a parameter's type checks too"
  t.hostBuilds "...and every backend builds it"
  t.runs "...and runs", 0

  t.src """
group Sortable:
  fn compare({self: Self, other: Self}) -> Order

group Hashable:
  fn hashOf({self: Self}) -> u64

type Order:
  | Before
  | Same
  | After

type NoHash = {value: int}

fn compare({self: NoHash, other: NoHash}) -> Order:
  return Order.Same

fn describe({item: Sortable + Hashable}) -> u64:
  return 0

fn main() -> int:
  let n = {value: 1} NoHash
  return {item: n} describe - 0
"""
  t.badCheck "an inline bound's error names the PARAMETER, not the synthesized type param",
    "'NoHash', bound to 'item: Hashable' in 'describe', does not provide"

  # --- wrong keyword, both directions ----------------------------------------
  t.src """
interface Speaker:
  fn speak({volume: int}) -> str

object Dog:
  satisfies Speaker
  name: str

  fn speak({volume: int}) -> str:
    return self.name

fn announce[T: Speaker]({who: T}) -> str:
  return {volume: 1} who.speak

fn main() -> int:
  let d = Dog {name: "Rex"}
  let s = {who: d} announce
  return s.len - 3
"""
  t.badCheck "naming an interface as a generic bound fails, distinctly from a missing group",
    "is an interface, not a group"

  t.src """
group Sortable:
  fn compare({self: Self, other: Self}) -> Order

type Order:
  | Before
  | Same
  | After

object Box:
  satisfies Sortable
  value: int

  fn compare({self: Self, other: Self}) -> Order:
    return Order.Same

fn main() -> int:
  return 0
"""
  t.badCheck "satisfying a group name fails, distinctly from a missing interface",
    "is a group.*not an interface"

  # --- a GENERIC group: the element type no container type can reveal -------
  # `Indexable[E]` is the shape every collection contract needs and no value
  # contract does: `Self` is the container, and nothing recovers what it holds.
  # E appears nowhere in firstOf's arguments, so the call site cannot infer it
  # the ordinary way — it is solved from the conformance itself, by unifying
  # the requirement against the `at` that Row actually declares. That is what
  # an associated type does in Rust and Swift, reached through the group's own
  # parameters instead of a second declaration form.
  t.src """
group Indexable[E]:
  fn at({self: Self, index: int}) -> E
  fn len({self: Self}) -> int

type Row = {cells: Seq[int]}

fn at({self: Row, index: int}) -> int:
  return self.cells[index]

fn len({self: Row}) -> int:
  return self.cells.len

fn firstOf[C: Indexable[E], E]({c: C}) -> E:
  return {self: c, index: 0} at

fn main() -> int:
  let r = {cells: [7, 8]} Row
  let v = {c: r} firstOf
  return v - 7
"""
  t.okCheck "a generic group's parameter is solved from the conformance"
  # E is mentioned by no parameter, so no host language can infer it. Each
  # backend is handed the solved arguments in its own spelling.
  t.emits "Nim gets explicit type arguments", r"tuckˑfnˑfirstOf\[tuckˑtypeˑRow, int\]"
  t.emitsOdin "Odin passes the typeid it declared", r"tuckˑfnˑfirstOf\(int, tuckˑvˑr\)"
  t.emitsD "D gets explicit template arguments",
           r"tuckˑfnˑfirstOf!\(tuckˑtypeˑRow, long\)"
  t.hostBuilds "...and every backend builds it"
  t.runs "...and runs", 0

  # The bound's arity is the group's, not a free choice.
  t.src """
group Indexable[E]:
  fn at({self: Self, index: int}) -> E

type Row = {cells: Seq[int]}

fn at({self: Row, index: int}) -> int:
  return self.cells[index]

fn firstOf[C: Indexable]({c: C}) -> int:
  return {self: c, index: 0} at

fn main() -> int:
  let r = {cells: [7, 8]} Row
  return {c: r} firstOf - 7
"""
  t.badCheck "a generic group named with no arguments is rejected", "E"

  # An explicit argument is a STATED requirement, never a hole to re-solve:
  # `Indexable[str]` against a Row whose `at` returns int has to fail.
  t.src """
group Indexable[E]:
  fn at({self: Self, index: int}) -> E

type Row = {cells: Seq[int]}

fn at({self: Row, index: int}) -> int:
  return self.cells[index]

fn firstOf[C: Indexable[str], E]({c: C}) -> E:
  return {self: c, index: 0} at

fn main() -> int:
  let r = {cells: [7, 8]} Row
  let v = {c: r} firstOf
  return 0
"""
  t.badCheck "an explicit group argument is not re-solved to fit", "str"

  # --- the bound written on the ARGUMENT, single and generic ---------------
  # `{item: Sortable + Hashable}` already worked; a SINGLE bound did not,
  # because only the `+`-joined form arrives as a tkUnion and that was the
  # only shape recognised. One bound is just the type.
  t.src """
group Sortable:
  fn compare({self: Self, other: Self}) -> Order

type Order:
  | Before
  | Same
  | After

type Box = {value: int}

fn compare({self: Box, other: Box}) -> Order:
  return Order.Same

fn describe({item: Sortable}) -> int:
  let c = {self: item, other: item} compare
  return 0

fn main() -> int:
  let b = {value: 1} Box
  return {item: b} describe
"""
  t.okCheck "a single group bound on a parameter, with no `+`, is a bound"
  t.hostBuilds "...and every backend builds it"
  t.runs "...and runs", 0

  # A GENERIC group on a parameter. The group's argument is an ordinary type
  # param of the fn — declared, not conjured, so nothing has to guess whether
  # `Indexable[int]` names a type or introduces one.
  t.src """
group Indexable[E]:
  fn at({self: Self, index: int}) -> E

type Row = {cells: Seq[int]}

fn at({self: Row, index: int}) -> int:
  return self.cells[index]

fn firstOf[E]({c: Indexable[E]}) -> E:
  return {self: c, index: 0} at

fn main() -> int:
  let r = {cells: [7, 8]} Row
  let v = {c: r} firstOf
  return v - 7
"""
  t.okCheck "a generic group bound written on the parameter"
  t.hostBuilds "...and every backend builds it"
  t.runs "...and runs", 0

  # --- the stdlib arrangement: contracts in one module, verbs in another ----
  # Three things had to cross the import boundary for this to work, and none
  # of them did: the GROUP itself (a bound naming it answered "not a declared
  # group"), the generic fn's BOUNDS (looked up from a declaration this module
  # does not have, so nothing was checked and nothing solved), and the solved
  # TYPE ARGUMENTS (recorded against a decl, so a cross-module call silently
  # emitted a type param no backend could instantiate).
  #
  # The satisfier is generic itself — one `at` for every element type — so the
  # provider has to be instantiated before the group's E can be read off it,
  # or E binds to the letter T.
  t.src """
import contracts
import seqops

fn main() -> int:
  let xs = [7, 8, 9]
  let a = {c: xs} firstOf
  let n = {c: xs} countOf
  if a != 7:
    return 1
  if n != 3:
    return 2
  return 0
"""
  t.addFile("contracts.tuck", """
group Indexable[E]:
  fn at({self: Self, index: int}) -> E

group Countable:
  fn count({self: Self}) -> int
""")
  t.addFile("seqops.tuck", """
import contracts

fn at[T]({self: Seq[T], index: int}) -> T:
  return self[index]

fn count[T]({self: Seq[T]}) -> int:
  return self.len

fn firstOf[C: Indexable[E] + Countable, E]({c: C}) -> E:
  return {self: c, index: 0} at

fn countOf[C: Countable]({c: C}) -> int:
  return {self: c} count
""")
  t.okCheck "a generic group, its satisfier and its verbs across modules"
  t.hostBuilds "...and every backend builds it"
  t.runs "...and runs", 0

  # --- a two-parameter group satisfied by a generic record -----------------
  # `Keyed[K, V]` is the shape the whole Hashable chain was built for: the
  # satisfier is a generic RECORD type, not a builtin, and the group has two
  # parameters of which only one is the element. `put` returns Self, so the
  # conformance check has to read Self as the concrete `Table[int]` and the
  # provider's own `V` as int at the same time.
  t.src """
import contracts
import table

fn getOr[M: Keyed[str, int]]({m: M, key: str, fallback: int}) -> int:
  let v = {self: m, key: key} get
  if not v.ok:
    return fallback
  return v.value

fn main() -> int:
  var t = {seed: 0} emptyTable
  t = {self: t, key: "x", value: 7} put
  let hit = {m: t, key: "x", fallback: 99} getOr
  let missed = {m: t, key: "y", fallback: 99} getOr
  if hit != 7:
    return 1
  if missed != 99:
    return 2
  return 0
"""
  t.addFile("contracts.tuck", """
group Keyed[K, V]:
  fn get({self: Self, key: K}) -> V?
  fn put({self: Self, key: K, value: V}) -> Self
""")
  t.addFile("table.tuck", """
import contracts
import seq

type Table[V] = {keys: Seq[str], vals: Seq[V]}

fn emptyTable[V]({seed: V}) -> Table[V]:
  var k: Seq[str] = []
  var v: Seq[V] = []
  return {keys: k, vals: v} Table

fn get[V]({self: Table[V], key: str}) -> V?:
  for i in 0 .. self.keys.len - 1:
    if self.keys[i] == key:
      return self.vals[i]
  return

fn put[V]({self: Table[V], key: str, value: V}) -> Table[V]:
  var out = self
  out.keys = {items: out.keys, value: key} push
  out.vals = {items: out.vals, value: value} push
  return out
""")
  t.okCheck "a two-parameter group satisfied by a generic record type"
  t.hostBuilds "...and every backend builds it"
  t.runs "...and the bounded verb reads through the contract", 0

  # --- the provider in a THIRD module the abstraction does not import ------
  # The arrangement a stdlib is made of: contracts in one module, a concrete
  # type's satisfier in another, the bounded verb in a third, and a caller
  # importing what it needs.
  #
  # Nim binds symbols in a generic body at DEFINITION scope, so the module
  # declaring the verb had no `compare` and answered "undeclared identifier".
  # `mixin` marks the requirement open and resolution moves to each
  # INSTANTIATION site — which is exactly what a group bound means. Odin and
  # D instead qualify and import the provider, which works here and is why
  # only Nim ever failed.
  t.src """
import types
import contracts
import ints

fn main() -> int:
  let s = {a: 3, b: 9} smallerOf
  return s - 3
"""
  t.addFile("types.tuck", """type Order:
  | Before
  | Same
  | After
""")
  t.addFile("contracts.tuck", """import types

group Sortable:
  fn compare({self: Self, other: Self}) -> Order

fn smallerOf[T: Sortable]({a: T, b: T}) -> T:
  let c = {self: a, other: b} compare
  match c:
    Before: return a
    Same: return a
    After: return b
""")
  t.addFile("ints.tuck", """import types

fn compare({self: int, other: int}) -> Order:
  if self < other:
    return Order.Before
  if self > other:
    return Order.After
  return Order.Same
""")
  t.okCheck "a group, its satisfier and its verb in three separate modules"
  # No emitted-text assertion: the `mixin` lands in contracts.nim, and these
  # assertions read the ENTRY module. hostBuilds is the guard that matters
  # anyway — without the mixin, nim rejects the emitted contracts.nim with
  # "undeclared identifier: 'tuck_fn_compare'".
  t.hostBuilds "...and every backend builds it"
  t.runs "...and the right provider is called", 0

  # BASELINE, captured before the object-member rule lands: a group provider
  # declared in ANOTHER module. This is the shape the whole v2 stdlib has —
  # the contract, the verb and the implementation each live in their own
  # module — so any rule about WHICH fn may satisfy a group has to leave it
  # working.
  t.src """
import shape
import impl

fn main() -> int:
  let p = {a: 1} A
  return {x: p} one
"""
  t.addFile("shape.tuck", """public:
  A

type A:
  a: u8
""")
  t.addFile("impl.tuck", """public:
  one
  reads
  Sensing

import shape

group Sensing:
  fn reads({self: Self}) -> int

fn reads({self: A}) -> int:
  return 7

fn one[T: Sensing]({x: T}) -> int:
  return {self: x} reads
""")
  t.okCheck "a group provider may live in another module"
  t.runs "...and the imported free fn is the one dispatched to", 7

  t.finish()
