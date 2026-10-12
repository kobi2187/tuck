## The ownership rules, end to end: one program per shape that once leaked,
## freed twice or read a value after it moved. Each is built and run on every
## backend, which must agree on the answer, and on Odin with every allocation
## tracked (`TUCK_TRACK`): a leak or a bad free exits 90 there.
##
## The shapes were found by running the rules over programs the corpus did not
## contain, with valgrind on Nim (`--mm:none`, so nothing frees but the rules'
## drops), the allocation tracker on D (collector off) and on Odin:
##   * a `for`/`match` binding is a VIEW, so a sink of it copies; moving it
##     out freed an element of the Seq it came from;
##   * `xs = push(xs, … xs …)` built the value after the target was moved;
##   * a task never dropped the parameters it owns, and a discarded result
##     was never dropped;
##   * an interface value's payload was copied by its dispatch and not freed.
import ../harness

proc run*(t: var T) =
  ## Registers one run-and-track assertion per program.
  # a Seq of recursive sums, a loop variable moved into a local, and an append that reads its own target.
  t.src """
import seq

type Shape:
  | Circle({r: int})
  | Named({name: str, tags: Seq[str]})
  | Many({items: Seq[Shape]})

type Rec = {name: str, tags: Seq[str], n: int}

fn mkRec({name: str, n: int}) -> Rec:
  return {name: name, tags: [name, name + "x"], n: n} Rec

fn describe({s: Shape}) -> str:
  match s:
    Circle: return "circle"
    Named: return s.name + "/" + "named"
    Many: return "many"

fn total({xs: Seq[str]}) -> int:
  var t = 0
  for x in xs:
    t = t + x.len
  return t

fn longest({xs: Seq[str]}) -> str:
  var best = ""
  for x in xs:
    if x.len > best.len:
      best = x
  return best

fn grow({r: Rec}) -> Rec:
  let more = {items: r.tags, value: "extra"} push
  return {name: r.name, tags: more, n: r.n + 1} Rec

fn pick({a: Rec, b: Rec}) -> Rec:
  if a.n > b.n:
    return a
  return b

fn main() -> int:
  let a = {name: "alpha", n: 1} mkRec
  let b = {name: "be", n: 2} mkRec
  let g = {r: a} grow
  let p = {a: g, b: b} pick
  var shapes: Seq[Shape] = []
  shapes = {items: shapes, value: Shape.Circle {r: 1}} push
  shapes = {items: shapes, value: Shape.Named {name: "nm", tags: ["t1", "t2"]}} push
  shapes = {items: shapes, value: Shape.Many {items: shapes}} push
  var out = ""
  for s in shapes:
    out = out + {s: s} describe
  let lg = {xs: p.tags} longest
  let tt = {xs: p.tags} total
  if out.len == 0:
    return 1
  return tt + lg.len + p.n
"""
  t.okCheck "a Seq of recursive sums, a loop variable moved into a local, and an append that reads its own target: checks"
  t.hostRuns "...and every backend answers the same", 10
  t.odinTracked "...and Odin frees all of it", 10

  # records holding Seqs of records, an early return out of a loop, nested Seqs.
  t.src """
import seq

type Item = {name: str, parts: Seq[str]}
type Box = {items: Seq[Item], label: str}

fn mkItem({name: str}) -> Item:
  return {name: name, parts: [name, name]} Item

fn firstBig({b: Box, min: int}) -> Item?:
  for it in b.items:
    if it.name.len >= min:
      return it
  return

fn labelOf({b: Box}) -> str:
  var out = b.label
  for it in b.items:
    out = out + "," + it.name
  return out

fn nest({n: int}) -> Seq[Seq[str]]:
  var rows: Seq[Seq[str]] = []
  var i = 0
  for i < n:
    var row: Seq[str] = []
    var j = 0
    for j <= i:
      row = {items: row, value: "c"} push
      j = j + 1
    rows = {items: rows, value: row} push
    i = i + 1
  return rows

fn flat({rows: Seq[Seq[str]]}) -> int:
  var t = 0
  for r in rows:
    for c in r:
      t = t + c.len
  return t

fn pickLabel({b: Box, other: Box}) -> str:
  if b.items.len > other.items.len:
    return b.label
  return other.label

fn main() -> int:
  var items: Seq[Item] = []
  let i1 = {name: "a"} mkItem
  let i2 = {name: "bbb"} mkItem
  items = {items: items, value: i1} push
  items = {items: items, value: i2} push
  let box = {items: items, label: "L"} Box
  let big = {b: box, min: 2} firstBig
  let lab = {b: box} labelOf
  let rows = {n: 4} nest
  let f = {rows: rows} flat
  let pl = {b: box, other: box} pickLabel
  if not big.ok:
    return 1
  return big.value.name.len + lab.len + f + pl.len
"""
  t.okCheck "records holding Seqs of records, an early return out of a loop, nested Seqs: checks"
  t.hostRuns "...and every backend answers the same", 21
  t.odinTracked "...and Odin frees all of it", 21

  # a push that is not an append leaves its source readable.
  t.src """
import seq

fn main() -> int:
  let xs: Seq[str] = ["ab", "cd"]
  let ys = {items: xs, value: "ef"} push
  let zs = {items: xs, value: "gh"} push
  return xs.len + ys.len * 10 + zs.len * 100
"""
  t.okCheck "a push that is not an append leaves its source readable: checks"
  t.hostRuns "...and every backend answers the same", 76
  t.odinTracked "...and Odin frees all of it", 76

  # a task owns the str and Seq it is given.
  t.src """
import str

task measure({name: str, tags: Seq[str]}) -> int:
  var t = name.len
  for x in tags:
    t = t + x.len
  return t

fn main() -> int:
  let name = "alpha"
  let tags: Seq[str] = ["b", "cc"]
  let n = {name: name, tags: tags} measure
  return n + name.len + tags.len
"""
  t.okCheck "a task owns the str and Seq it is given: checks"
  t.hostRuns "...and every backend answers the same", 15
  t.odinTracked "...and Odin frees all of it", 15

  # an interface value owns its payload.
  t.src """
interface Animal:
  fn noise({self: Self}) -> int

object Dog:
  satisfies Animal
  name: str

  fn noise({self: Dog}) -> int:
    return self.name.len

fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  let d = {name: "rex"} Dog
  let a: Animal = d
  return {a: a} hear
"""
  t.okCheck "an interface value owns its payload: checks"
  t.hostRuns "...and every backend answers the same", 3
  t.odinTracked "...and Odin frees all of it", 3

  # an Array field of strs, read and rebuilt.
  t.src """
import seq

type Grid = {cells: Array[3, str], n: int}

fn fill({g: Grid, s: str}) -> Grid:
  var cells = g.cells
  cells[1] = s
  return {cells: cells, n: g.n + 1} Grid

fn main() -> int:
  let g = {cells: ["a", "b", "c"], n: 0} Grid
  let h = {g: g, s: "xyz"} fill
  let k = {g: h, s: "q"} fill
  return g.cells[1].len + h.cells[1].len * 10 + k.n * 100
"""
  t.okCheck "an Array field of strs, read and rebuilt: checks"
  t.hostRuns "...and every backend answers the same", 231
  t.odinTracked "...and Odin frees all of it", 231

  # a generic record holding a Seq of owned values.
  t.src """
import seq

type Box[T]:
  items: Seq[T]
  tag: str

fn put[T]({b: Box[T], v: T}) -> Box[T]:
  let more = {items: b.items, value: v} push
  return {items: more, tag: b.tag} Box

fn main() -> int:
  var b: Box[str] = {items: [], tag: "t"} Box
  b = {b: b, v: "one"} put
  b = {b: b, v: "three"} put
  var c: Box[int] = {items: [], tag: "n"} Box
  c = {b: c, v: 4} put
  return b.items.len * 10 + b.items[1].len + c.items[0] * 100
"""
  t.okCheck "a generic record holding a Seq of owned values: checks"
  t.hostRuns "...and every backend answers the same", 169
  t.odinTracked "...and Odin frees all of it", 169

  # an arena and a slab whose cells own a str and a Seq.
  t.src """
import seq

type Note:
  text: str
  tags: Seq[str]

arena Scratch [size: 65536]

slab Notes = Note

fn work({n: int}) -> int:
  var total = 0
  var i = 0
  for i < n:
    var tags: Seq[str] = []
    tags = {items: tags, value: "a"} push
    tags = {items: tags, value: "bb"} push
    let note = {text: "note", tags: tags} Note
    let r = Scratch.new {value: note}
    if r.ok:
      total = total + r.value.tags.len + r.value.text.len
    i = i + 1
  Scratch.reset
  return total

fn keep({n: int}) -> int:
  var i = 0
  var live = 0
  for i < n:
    let r = Notes.new {text: "kept", tags: ["x"]}
    let g = Notes.get {r: r}
    live = live + g.text.len
    Notes.free {r: r}
    i = i + 1
  return live

fn main() -> int:
  return {n: 20} work + {n: 5} keep
"""
  t.okCheck "an arena and a slab whose cells own a str and a Seq: checks"
  t.hostRuns "...and every backend answers the same", 140
  t.odinTracked "...and Odin frees all of it", 140

