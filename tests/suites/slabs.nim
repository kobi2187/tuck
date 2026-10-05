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

  # --- who may touch a slab (proposal §7, ruled Q6) ----------------------------
  # A slab inside an actor is that actor's: its handlers make and follow
  # references, and its fields may hold them.
  t.src """
import scheduler

type Item:
  n: int
  next: ItemsRef?

actor Stack [queue: 64]:
  slab Items = Item [leaks: ok]
  top: ItemsRef? = none
  total: int = 0

  on push({n: int}):
    let r = Items.new {n: n, next: top}
    top = r
    total += r.n

fn ready() -> bool:
  return Stack.total == 55

fn main() -> int:
  for i in 1 .. 10:
    Stack send push {n: i}
  Stack.waitUntil {pred: :ready}
  return Stack.total
"""
  t.okCheck "an actor declares a slab of its own"
  t.hostRuns "...and its handlers link cells its fields hold", 55

  # A top-level slab belongs to main's thread: an actor reaching it, through
  # any chain of calls, is refused — and the message names the chain.
  t.src """
type Node:
  n: int

slab Nodes = Node [leaks: ok]

fn record({n: int}) -> int:
  let r = Nodes.new {n: n}
  r.n

fn helper({n: int}) -> int:
  {n: n} record

actor Log:
  total: int = 0

  on add({n: int}):
    total += {n: n} helper

fn main() -> int:
  Log send add {n: 1}
  {n: 2} record
"""
  t.badCheck "an actor reaching a top-level slab through calls is refused",
             "TK-AC08.*actor 'Log' reaches slab 'Nodes', which belongs to " &
             "main's thread: on add → helper → record → Nodes.new"

  # ...through a fn handed on as a value, too.
  t.src """
type Node:
  n: int

slab Nodes = Node [leaks: ok]

fnsig Adder = {a: int, b: int} -> int

type Calc = {add: Adder}

fn touch({a: int, b: int}) -> int:
  let r = Nodes.new {n: a + b}
  r.n

actor Log:
  total: int = 0

  on bump({n: int}):
    let c = {add: :touch} Calc
    total += {a: n, b: 1} c.add

fn main() -> int:
  Log send bump {n: 1}
  0
"""
  t.badCheck "...or through a callback", "TK-AC08.*on bump → touch → Nodes.new"

  # An actor's slab is its own: main reaching it is refused, and so is
  # another actor.
  t.src """
type Item:
  n: int

actor Stack:
  slab Items = Item [leaks: ok]
  total: int = 0

  on push({n: int}):
    let r = Items.new {n: n}
    total += r.n

fn peek() -> int:
  Items.count

fn main() -> int:
  Stack send push {n: 1}
  {} peek
"""
  t.badCheck "main reaching an actor's slab is refused",
             "TK-AC08.*main's thread reaches slab 'Items', which belongs to " &
             "actor 'Stack': main → peek → Items.count"

  t.src """
type Item:
  n: int

actor A:
  slab Mine = Item [leaks: ok]
  total: int = 0

  on put({n: int}):
    let r = Mine.new {n: n}
    total += r.n

actor B:
  total: int = 0

  on peek({n: int}):
    total += Mine.count

fn main() -> int:
  A send put {n: 1}
  B send peek {n: 1}
  0
"""
  t.badCheck "one actor reaching another's slab is refused",
             "TK-AC08.*actor 'B' reaches slab 'Mine', which belongs to actor 'A'"

  # A main's-thread program with actors beside it is untouched by the rule.
  t.src """
type Node:
  n: int

slab Nodes = Node [leaks: ok]

fn record({n: int}) -> int:
  let r = Nodes.new {n: n}
  r.n

actor Log:
  total: int = 0

  on add({n: int}):
    total += n

fn main() -> int:
  Log send add {n: 1}
  {n: 4} record
"""
  t.okCheck "main using its own slab beside an actor checks"

  # --- a reference crossing an actor boundary ------------------------------------
  t.src """
type Node:
  n: int

slab Nodes = Node [leaks: ok]

actor Log:
  total: int = 0

  on take({r: NodesRef}):
    total += 1

fn main() -> int:
  let r = Nodes.new {n: 1}
  Log send take {r: r}
  0
"""
  t.badCheck "a reference in a handler's payload is refused",
             "TK-AC09.*handler 'take' takes a NodesRef in 'r'"

  t.src """
type Node:
  n: int

type Pair:
  a: int
  link: NodesRef?

slab Nodes = Node [leaks: ok]

actor Log:
  total: int = 0

  on take({p: Pair}):
    total += p.a

fn main() -> int:
  let p = {a: 1, link: none} Pair
  Log send take {p: p}
  0
"""
  t.badCheck "...and one inside a record in the payload",
             "TK-AC09.*takes 'p', which can hold a NodesRef"

  t.src """
type Node:
  n: int

slab Nodes = Node [leaks: ok]

actor Log:
  last: NodesRef? = none

  on tick({n: int}):
    last = none

fn main() -> int:
  Log send tick {n: 1}
  0
"""
  t.badCheck "an actor's field holding another owner's reference is refused",
             "TK-AC09.*field 'last' holds a NodesRef"

  # --- a slab is not part of a value ------------------------------------------------
  t.src """
type Node:
  n: int

object Box:
  slab Nodes = Node
  size: int

fn main() -> int:
  0
"""
  t.badCheck "a slab inside an object is refused",
             "(?s)TK-ME03.*slab 'Nodes' is declared inside object 'Box'"

  # --- the arena (proposal §9, ruled Q5) -----------------------------------------
  # One lifetime over a slab per element type: `new` puts a value in the
  # arena's slab for its type, references link them, `reset` ends them all.
  t.src """
type Header:
  len: int

type Body:
  bytes: int
  head: FrameRef[Header]

arena Frame

fn main() -> int:
  let h = {len: 3} Header
  let hr = Frame.new {value: h}
  let b = {bytes: 10, head: hr} Body
  let br = Frame.new {value: b}
  hr.len += 1
  let total = br.bytes + br.head.len
  Frame.reset
  if Frame.live {r: hr}:
    return 1
  if Frame.live {r: br}:
    return 2
  total
"""
  t.okCheck "an arena holds values of several types, linked by reference"
  t.hostRuns "...a write through one reference reads through another, and " &
             "reset ends them all", 14

  t.src """
type Item:
  n: int

arena Frame

fn main() -> int:
  let it = {n: 5} Item
  let r = Frame.new {value: it}
  Frame.reset
  r.n
"""
  t.hostRuns "a reference kept past a reset stops the program", 1,
             "TUCK SLAB \\[Frame\\]: stale reference to cell 0"

  # `[size: N]` is a byte budget the COMPILER counts from the Tuck type, the
  # same on every backend: an Item costs 16 (8 + 8), so 3 fit in 48.
  t.src """
type Item:
  n: int

arena Small [size: 48]

fn fill() -> int:
  var made = 0
  var i = 0
  for i < 5:
    let it = {n: i} Item
    let r = Small.new {value: it}
    if r.ok:
      made += 1
    i = i + 1
  made

fn main() -> int:
  let a = {} fill
  Small.reset
  let b = {} fill
  a * 10 + b
"""
  t.hostRuns "a budget runs out at the same new on every backend, and reset " &
             "gives it back", 33

  # Odin: what a value owns goes when the arena resets — 200 rounds of 1000
  # Seqs stay in 3 MB.
  t.src """
import seq

arena Frame

fn main() -> int:
  var round = 0
  var total = 0
  for round < 200:
    var i = 0
    for i < 1000:
      var xs: Seq[int] = []
      var j = 0
      for j < 64:
        xs = {items: xs, value: j} push
        j = j + 1
      let r = Frame.new {value: xs}
      let back = Frame.get {r: r}
      total = total + back.len
      i = i + 1
    Frame.reset
    round = round + 1
  if total != 12800000:
    return 1
  return 0
"""
  t.hostPeakRss "an arena of Seqs reset 200 times stays in budget", 16384

  # An actor's own arena: its handlers fill it and reset it.
  t.src """
import scheduler

type Item:
  n: int
  next: ScratchRef[Item]?

actor Batch [queue: 64]:
  arena Scratch
  top: ScratchRef[Item]? = none
  sum: int = 0
  done: int = 0

  on add({n: int}):
    let it = {n: n, next: top} Item
    let r = Scratch.new {value: it}
    top = r
    sum += r.n

  on flush({n: int}):
    Scratch.reset
    top = none
    done += 1

fn ready() -> bool:
  return Batch.done == 1

fn main() -> int:
  for i in 1 .. 10:
    Batch send add {n: i}
  Batch send flush {n: 0}
  Batch.waitUntil {pred: :ready}
  return Batch.sum
"""
  t.okCheck "an actor declares an arena of its own, its references linking cells"
  t.hostRuns "...and its handlers fill and reset it", 55

  t.src """
type A:
  n: int

type B:
  n: int

arena Frame

fn main() -> int:
  let a = {n: 1} A
  let r = Frame.new {value: a}
  let s: FrameRef[B] = r
  0
"""
  t.badCheck "a reference names its element type, structurally equal or not",
             "expects FrameRef\\[B\\] but got FrameRef\\[A\\]"

  t.src """
type Item:
  n: int

arena Frame

fn main() -> int:
  let it = {n: 1} Item
  let r = Frame.new {value: it}
  Frame.free {r: r}
  0
"""
  t.badCheck "an arena has no per-cell free", "an arena has no 'free'"

  t.src """
type Item:
  n: int

arena Frame

actor Log:
  total: int = 0

  on tick({n: int}):
    Frame.reset

fn main() -> int:
  Log send tick {n: 1}
  0
"""
  t.badCheck "an actor resetting main's arena is refused",
             "TK-AC08.*actor 'Log' reaches arena 'Frame'.*on tick → Frame.reset"

  t.src """
type Item:
  n: int

arena Frame

actor Log:
  total: int = 0

  on take({r: FrameRef[Item]}):
    total += 1

fn main() -> int:
  let it = {n: 1} Item
  let r = Frame.new {value: it}
  Log send take {r: r}
  0
"""
  t.badCheck "an arena reference in a payload is refused",
             "TK-AC09.*takes a FrameRef\\[Item\\] in 'r'"

  # A slab of a generic record: the element's type arguments come from the
  # slab's declaration, so `new`'s fields, `set`'s record literal and a
  # plain reference into the `next: R?` link all check and build. (Found
  # 2026-10-04 probing generic code over slabs: `new` read the element as
  # having no fields, and the link built on no backend.)
  t.src """
type Link[T, R]:
  value: T
  next: R?

slab Ints = Link[int, IntsRef] [leaks: ok]

fn main() -> int:
  let a = Ints.new {value: 1, next: none}
  let b = Ints.new {value: 2, next: a}
  Ints.set {r: a, value: {value: 4, next: none}}
  var n = 0
  var cur: IntsRef? = b
  for cur.ok:
    n = n + cur.value.value
    cur = cur.value.next
  return n
"""
  t.hostRuns "a slab of a generic record: new, set and a link through it", 6

  t.finish()
