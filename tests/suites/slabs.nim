## Slabs (thoughts/shared/plans/2026-09-29-slab-proposal.md): cells of one
## type, handed out as REFERENCES — a 32-bit cell and a 32-bit tenancy — so
## one value can point at another (a parent, a next node, a shared child)
## without a pointer and without leaving value semantics anywhere else.
##
## Ruled 2026-09-29:
##   * `free` per cell and `reset` for all, each making every reference to
##     what it freed stale; a stale reference stops the program (Q1);
##   * a field through a reference, `r.data`, reads and writes the cell (Q2);
##   * cells never freed are reported at exit, unless `[leaks: ok]` (Q3);
##   * a link is `NodesRef?`, and `none` writes "no link yet" (Q4);
##   * storage is chunked and never copies (Q8); `[count: N]` is a fixed
##     array, `[storage: contiguous]` one growable array.
##
## Every runtime fact is asserted on all three backends (`hostRuns`): the
## slab is a runtime structure in each, three implementations of one
## behaviour.

import ../harness

proc run*(t: var T) =
  ## Registers the slab assertions: references and links, every operation,
  ## the three storages, the stale-reference stop, the exit report, memory a
  ## cell's value owns, an imported slab, and what the checker refuses.
  # --- references link cells ------------------------------------------------
  t.src """
type Node:
  data: int
  prev: NodesRef?
  next: NodesRef?

slab Nodes = Node

fn main() -> int:
  let a = Nodes.new {data: 1, prev: none, next: none}
  let b = Nodes.new {data: 2, prev: a, next: none}
  a.next = b
  a.data += 10
  let n = Nodes.count
  let back = b.prev
  if back.ok:
    return back.value.data + n
  return 0
"""
  t.okCheck "a slab of linked nodes checks"
  # a.data is 11 through `a` itself AND through b's link to it: one cell.
  t.hostRuns "a write through one reference is read through another",
             13, "TUCK SLAB \\[Nodes\\]: 2 cell\\(s\\) never freed"
  # `a.data += 10` reads and writes ONE target node; lowering met it twice
  # and routed it through the cell twice.
  t.omits "a compound assignment goes through the cell once",
          "tuckSlabCell\\([^()]*tuckSlabCell"
  # `prev: a` in `new`'s payload is wrapped into the `?` like any
  # construction's — the backend's own copy of the payload is what prints.
  t.emits "a reference into a `?` field is wrapped", "prev: TuckResult\\[SlabRef\\]\\(status: tsOk"

  # --- every operation, on every storage --------------------------------------
  t.src """
type Node:
  data: int
  next: NodesRef?

slab Nodes = Node
slab Small = Node [count: 2]
slab Flat = Node [storage: contiguous, leaks: ok]
slab Ints = int [leaks: ok]

fn freed() -> int:
  let a = Nodes.new {data: 5, next: none}
  let b = Nodes.new {data: 6, next: a}
  let same = a == a
  let diff = a == b
  Nodes.free {r: a}
  var score = 0
  if not Nodes.live {r: a}:
    score += 1
  if Nodes.live {r: b}:
    score += 2
  if same and not diff:
    score += 4
  let c = Nodes.new {data: 7, next: none}
  if c != a:
    score += 8
  Nodes.free {r: b}
  Nodes.free {r: c}
  score

fn whole() -> int:
  let r = Flat.new {data: 1, next: none}
  var v = Flat.get {r: r}
  v.data = 40
  Flat.set {r: r, value: v}
  let i = Ints.new {value: 2}
  let w = Flat.get {r: r}
  w.data + Ints.get {r: i}

fn fixed() -> int:
  let a = Small.new {data: 1, next: none}
  let b = Small.new {data: 2, next: none}
  let c = Small.new {data: 3, next: none}
  var score = 0
  if a.ok and b.ok and not c.ok:
    score = 100
  Small.reset
  if a.ok:
    if not Small.live {r: a.value}:
      score += 50
  score + Small.count

fn main() -> int:
  let a = {} freed
  let b = {} whole
  let c = {} fixed
  a + b + c
"""
  t.okCheck "new, free, live, get, set, reset and count check"
  # freed: 15 — a freed reference is not live, its cell's next tenant is a
  # different reference, identity is cell AND tenancy. whole: 42 — get and set
  # copy the value out and in. fixed: 150 — a third `new` into two cells is
  # absent, and `reset` makes every reference stale.
  t.hostRuns "each operation does what it says, on all three storages", 207

  # --- the stale-reference stop -----------------------------------------------
  t.src """
type Node:
  data: int

slab Nodes = Node

fn main() -> int:
  let a = Nodes.new {data: 5}
  Nodes.free {r: a}
  a.data
"""
  t.hostRuns "a freed cell's reference stops the program",
             1, "TUCK SLAB \\[Nodes\\]: stale reference to cell 0"

  # The proposal's opening example, in the ruled form (Q4: `none`).
  t.src """
type Node:
  data: int
  prev: NodesRef?
  next: NodesRef?

slab Nodes = Node

fn main() -> int:
  let a = Nodes.new {data: 1, prev: none, next: none}
  let b = Nodes.new {data: 2, prev: a, next: none}
  a.next = b
  let back = b.prev
  if not back.ok:
    return 0
  back.value.data += 10
  Nodes.free {r: a}
  return back.value.data
"""
  t.hostRuns "a link to a freed cell is stale through the link too",
             1, "stale reference to cell 0"

  # --- what a cell's value owns ------------------------------------------------
  # Odin has no destructors: a value that owns a Seq leaves through the
  # slab's own free, set and reset, which delete it first. The budget is what
  # proves it — without them this loop peaks at 106 MB on Odin; with them,
  # 2 MB. Nim (ARC) and D (GC) reclaim it on their own.
  t.src """
import seq

type Bag:
  items: Seq[int]
  tag: int

slab Bags = Bag

fn main() -> int:
  var i = 0
  var total = 0
  for i < 200000:
    var xs: Seq[int] = []
    var j = 0
    for j < 64:
      xs = {items: xs, value: j} push
      j = j + 1
    let r = Bags.new {items: xs, tag: i}
    total = total + r.items.len
    Bags.free {r: r}
    i = i + 1
  if total != 12800000:
    return 1
  return 0
"""
  t.hostPeakRss "200k cells holding a Seq, each freed, stay in budget", 16384
  t.emitsOdin "Odin's free deletes what the value owns",
              "_free :: proc\\(r: rt.SlabRef\\) \\{\\n\\tc := rt.tuckSlabCell\\([^\\n]*\\n\\tdelete\\(c.value.items\\)"

  # A value handed to `new` or `set` is the slab's: Odin must not also free
  # it at scope exit (a double free once the slab's own free runs).
  t.src """
import seq

type Bag:
  items: Seq[int]
  tag: int

slab Bags = Bag
slab Lists = Seq[int]

fn main() -> int:
  var x4: Seq[int] = []
  x4 = {items: x4, value: 4} push
  var x2: Seq[int] = []
  x2 = {items: x2, value: 2} push
  var x5: Seq[int] = []
  x5 = {items: x5, value: 5} push
  x5 = {items: x5, value: 6} push
  let b = Bags.new {items: x4, tag: 8}
  Bags.set {r: b, value: {items: x2, tag: 9}}
  let t = b.tag
  let l = Lists.new {value: x5}
  let k = Lists.get {r: l}
  Bags.reset
  Lists.free {r: l}
  t + k.len
"""
  t.hostRuns "set replaces a value that owns heap; reset and free drop it", 11
  t.omitsOdin "a Seq handed to `new` is not also freed at scope exit",
              "defer delete\\(tuckˑvˑx5\\)"
  t.omitsOdin "...nor one handed to `set` inside its new value",
              "defer delete\\(tuckˑvˑx2\\)"

  # --- an imported slab ---------------------------------------------------------
  t.src """
import lib

fn main() -> int:
  let a = Nodes.new {data: 3, next: none}
  let b = Nodes.new {data: 4, next: a}
  b.data += 1
  let f = Few.new {data: 9, next: none}
  var extra = 0
  if f.ok:
    extra = f.value.data
  let n = b.next
  var total = b.data + extra
  if n.ok:
    total += n.value.data
  Nodes.free {r: a}
  total
"""
  t.addFile("lib.tuck", """type Node:
  data: int
  next: NodesRef?

slab Nodes = Node
slab Few = Node [count: 4, leaks: ok]
""")
  # The report names an imported slab's unfreed cell too; `Few` says
  # `[leaks: ok]` and is not reported.
  t.hostRuns "a slab declared in an imported module works on every backend",
             17, "TUCK SLAB \\[Nodes\\]: 1 cell\\(s\\) never freed"

  # --- what the checker refuses -----------------------------------------------
  t.src """
type Node:
  data: int

slab Nodes = Node
slab Others = Node

fn main() -> int:
  let a = Nodes.new {data: 5}
  Others.free {r: a}
  0
"""
  t.badCheck "a reference into one slab is not another slab's",
             "expects r: OthersRef but got NodesRef"

  t.src """
type Node:
  data: int

slab Nodes = Node

fn main() -> int:
  let a = Nodes.new {data: 5}
  a.size
"""
  t.badCheck "a field the element lacks is refused",
             "a NodesRef names a Node, which has no field 'size'"

  t.src """
type Node:
  data: int

slab Nodes = Node

fn main() -> int:
  let a = Nodes.new {data: 5}
  let n: int = a
  n
"""
  t.badCheck "a reference is not its cell's index", "expects int but got NodesRef"

  t.src """
type Node:
  data: int

slab Nodes = Node

fn main() -> int:
  Nodes.grow
  0
"""
  t.badCheck "an operation a slab lacks is named as such",
             "a slab has no 'grow'"

  t.src """
slab Ints = int

fn main() -> int:
  let r = Ints.new {data: 1}
  0
"""
  t.badCheck "an element without fields takes `{value: ...}`",
             "a int has no fields to name"

  t.src """
slab Nodes = Missing

fn main() -> int:
  0
"""
  t.badCheck "the element type must exist", "TK-TY03.*no type named 'Missing'"

  t.src """
type Node:
  data: int

slab Nodes = Node [count: 0]

fn main() -> int:
  0
"""
  t.badCheck "a fixed slab holds at least one cell", "TK-ME01.*at least 1"

  t.src """
type Node:
  data: int

slab Nodes = Node [storage: linked]

fn main() -> int:
  0
"""
  t.badCheck "storage is chunked or contiguous", "storage is `chunked`"

  t.finish()
