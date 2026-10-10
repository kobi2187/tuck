## Rule G. Native/generated runtime tests keep failures independent of
## compiler lowering; end-to-end tests gate each later integration step.
import std/os
import ../harness

proc run*(t: var T) =
  t.src """
type Bag:
  rows: Seq[str]

actor Store [queue: 8]:
  bag: Bag = {rows: ["row"]} Bag
  on ping({n: int}):
    ...

fn main() -> int:
  let rows = Store.bag.rows
  return rows[0].len
"""
  t.emitsOdin "G: a nested singleton projection is explicitly copied on the common tree",
              r"tuckˑvˑrows := tuckG_\d+_copy\(tuckˑactorˑStoreSingleton\.bag\.rows\)"
  t.hostRuns "G: a nested singleton snapshot survives ordinary backend teardown", 3
  t.odinTracked "G: a nested singleton snapshot has its own deep storage", 3
  t.src readFile("tests/ownership_glue/actor_read.tuck")
  t.odinTracked "G: handler and explicit singleton reads retain their own storage", 7
  t.src """
type Order:
  | Before
  | Same
  | After

fn choose[T]({a: T, b: T, order: Order}) -> T:
  match order:
    Before: return a
    Same: return a
    After: return b

fn main() -> int:
  let a = ["first"]
  let b = ["second"]
  let first = {a: a, b: b, order: Order.Before} choose
  let last = {a: a, b: b, order: Order.After} choose
  return first[0].len + last[0].len + a.len + b.len
"""
  t.odinTracked "G: exhaustive generic exits reset moves and drop unselected parameters", 13
  t.src """
fn take({title: str, count: int}) -> str:
  return title

fn main() -> int:
  let payload = {title: "kept", count: 2, unused: ["drop me"]}
  let title = payload take
  return title.len + payload.unused.len
"""
  t.odinTracked "G: record payload arguments expose field sinks without consuming unused fields", 5
  t.src """
type Bag:
  label: str
  rows: Seq[str]

fn rename({b: Bag}) -> Bag:
  return b with {label: "new"}

fn main() -> int:
  let a = {label: "old", rows: ["row"]} Bag
  var b = {b: a} rename
  b.rows[0] = "changed"
  let renamed = a alias(label -> title, rows -> entries)
  let merged = {first: renamed, second: {count: 2}} merge
  if a.rows[0] != "row" or merged.title != "old":
    return 9
  return merged.entries.len + merged.count
"""
  t.odinTracked "common reconstruction: owning update/alias/merge fields are independent", 3
  t.src """
import seq

type Bag:
  label: str
  items: Seq[str]

fn make({label: str}) -> Bag:
  return {label: label, items: ["one", "two"]} Bag

fn main() -> int:
  var original = {label: "bag"} make
  var copied = original
  copied.items[0] = "changed"
  if original.items[0] != "one":
    return 9
  copied = {label: "replacement"} make
  return original.items.len
"""
  t.odinTracked "G integration: strings in records/sequences own safe storage", 2, rules = true
  t.src """
type Expr:
  | Num({value: int})
  | Neg({operand: Expr})
  | Add({left: Expr, right: Expr})

fn eval({e: Expr}) -> int:
  match e:
    Num: return e.value
    Neg: return 0 - {e: e.operand} eval
    Add: return {e: e.left} eval + {e: e.right} eval

fn main() -> int:
  var i = 0
  for i < 100:
    let n = Expr.Num {value: 3}
    let tree = Expr.Add {left: n, right: Expr.Neg {operand: n}}
    if {e: tree} eval != 0:
      return 9
    i = i + 1
  return 0
"""
  t.odinTracked "G integration: recursive sums copy/drop every box", 0, rules = true
  t.src """
fn twice[T]({value: T}) -> Seq[T]:
  return [value, value]

fn main() -> int:
  let xs: Seq[str] = ["one", "two"]
  let copied = {value: xs} twice
  return copied[0].len + copied[1].len + xs.len
"""
  t.odinTracked "G integration: generic owning values have recursive glue", 6, rules = true
  t.src """
fn main() -> int:
  let xs = [1, 2]
  let filled = [xs; 2]
  return filled[0].len + filled[1].len + xs.len
"""
  t.badCheck "G: an owning fill remains outside the scalar-fill contract", "TK-TY37"
  t.src """
import scheduler

actor Inbox [queue: 8]:
  seen: int = 0
  on take({xs: Seq[str]}):
    seen = xs.len

fn done() -> bool:
  return Inbox.seen == 2

fn main() -> int:
  let xs: Seq[str] = ["one", "two"]
  Inbox send take {xs: xs}
  Inbox.waitUntil {pred: :done}
  return xs.len + Inbox.seen
"""
  t.odinTracked "G integration: a mailbox owns and releases its nested payload", 4, rules = true
  t.src """
task duplicate({xs: Seq[str]}) -> Seq[str]:
  let local: Seq[str] = ["temporary"]
  return xs

fn main() -> int:
  let xs: Seq[str] = ["one", "two"]
  let copied = {xs: xs} duplicate
  return copied.len + xs.len
"""
  t.odinTracked "G integration: task parameters/results and locals are owned", 4, rules = true
  t.src """
actor Store [queue: 8]:
  label: str = "initial"
  rows: Seq[Seq[str]] = [["initial"]]
  count: int = 0
  on select:
    | replace -> {nextLabel: str, nextRows: Seq[Seq[str]]}:
      label = nextLabel
      rows = nextRows
      count = count + 1

fn done() -> bool:
  return Store.count == 1

fn main() -> int:
  Store send replace {nextLabel: "new", nextRows: [["new"]]}
  Store.waitUntil {pred: :done}
  return Store.rows.len
"""
  t.odinTracked "G integration: select payloads and singleton nested state are released", 1, rules = true
  t.src """
import str

fn main() -> int:
  let text = "one\ntwo"
  let lines = {s: text} str::splitLines
  let copied = lines
  return copied.len + lines.len
"""
  t.odinTracked "G integration: runtime split lines returns deep owned storage", 4, rules = true
  t.src """
type Bag:
  rows: Seq[Seq[str]]
slab Bags = Bag

fn main() -> int:
  let original = {rows: [["one", "two"]]} Bag
  let cell = Bags.new {rows: original.rows}
  let snapshot = Bags.get {r: cell}
  let replacement = {rows: [["replacement"]]} Bag
  Bags.set {r: cell, value: replacement}
  Bags.free {r: cell}
  return snapshot.rows[0].len + original.rows[0].len
"""
  t.odinTracked "G integration: slab snapshots copy and replaced cells drop deeply", 4, rules = true
  t.src """
type Bag:
  rows: Seq[Seq[str]]
pool Bags = Bag [count: 1]

fn main() -> int:
  let handle = Bags.acquire
  if not handle.ok:
    return 9
  let original = {rows: [["one", "two"]]} Bag
  Bags.write {h: handle.value, value: original}
  let snapshot = Bags.read {h: handle.value}
  let replacement = {rows: [["replacement"]]} Bag
  Bags.write {h: handle.value, value: replacement}
  Bags.release {h: handle.value}
  if snapshot.ok:
    return snapshot.value.rows[0].len
  return 8
"""
  t.odinTracked "G integration: pool snapshots and replacement/release have deep glue", 2, rules = true
  t.src """
type Leaf:
  label: str
  items: Seq[str]
type Bundle:
  leaf: Leaf
  other: Seq[str]

fn choose({bundle: Bundle, take: bool}) -> Bundle:
  if take:
    return bundle
  let leaf = {label: "fresh", items: ["fresh"]} Leaf
  return {leaf: leaf, other: ["fresh"]} Bundle

fn main() -> int:
  var total = 0
  for i in 0 ..< 100:
    let leaf = {label: "original", items: ["original"]} Leaf
    let bundle = {leaf: leaf, other: ["original"]} Bundle
    let result = {bundle: bundle, take: i % 2 == 0} choose
    total = total + result.leaf.items.len + result.other.len
  return total
"""
  t.odinTracked "G integration: conditional whole moves reset every nested owning slot", 200, rules = true
  t.src """
fn choose[T]({values: Seq[T], take: bool}) -> Seq[T]:
  if take:
    return values
  return []

fn main() -> int:
  let values: Seq[Seq[str]] = [["one", "two"]]
  let empty = {values: values, take: false} choose
  return values[0].len + empty.len
"""
  t.odinTracked "G integration: consuming generic parameter drops nested actual elements", 2, rules = true
  t.src """
import seq

fn main() -> int:
  let xs: Seq[Seq[str]] = [["one"]]
  let extra: Seq[str] = ["two"]
  var ys = {items: xs, value: extra} push
  ys[0][0] = "changed"
  if xs[0][0] != "one":
    return 9
  return ys.len + xs.len + extra.len
"""
  t.odinTracked "G integration: non-self runtime push deep-copies existing elements", 4
  t.src """
import str

fn main() -> int:
  let parts: Seq[str] = ["one", "two"]
  let joined = {parts: parts, sep: ","} joinStr
  return joined.len
"""
  t.odinTracked "G integration: a same-type read argument certifies a fresh result", 7
  t.src """
task duplicate({xs: Seq[str]}) -> Seq[str]:
  return xs

fn main() -> int:
  var result: Seq[str] = []
  for i in 0 ..< 100:
    let next = {xs: ["replacement"]} duplicate
    result = next
  return result.len
"""
  t.odinTracked "G integration: replacing an awaited task result drops the old value", 1
  t.src """
type Bag:
  rows: Seq[Seq[str]]
slab Bags = Bag [count: 1]

fn main() -> int:
  let first = Bags.new {rows: [["first"]]}
  if not first.ok:
    return 8
  let rejected = Bags.new {rows: [["rejected"]]}
  if rejected.ok:
    return 9
  Bags.reset
  return 0
"""
  t.odinTracked "G integration: fixed slab failure releases its rejected owned operand", 0
  t.src """
import seq

fn first({xs: Seq[Seq[int]]}) -> Seq[int]:
  var copied = xs
  return copied[0]

fn main() -> int:
  let xs: Seq[Seq[int]] = [[1, 2], [3]]
  let row = {xs: xs} first
  return row[0] + xs[1][0]
"""
  t.emitsD "G: D copy nodes invoke recursive glue", "rt.tuckCopyG\\("
  t.hostRuns "G: nested copies preserve results across backends", 4
  t.src """
fn identity({xs: Seq[Seq[int]]}) -> Seq[Seq[int]]:
  return xs

fn main() -> int:
  let xs: Seq[Seq[int]] = [[1, 2]]
  let ys = {xs: xs} identity
  return xs[0][0] + ys[0][1]
"""
  t.emitsD "G: D borrowing twin wrappers invoke recursive glue", "rt.tuckCopyG\\("
  t.src """
actor Inbox [queue: 8]:
  on receive({xs: Seq[Seq[int]]}):
    let n = xs.len

fn main() -> int:
  let xs: Seq[Seq[int]] = [[1, 2]]
  Inbox send receive {xs: xs}
  return xs.len
"""
  t.emitsD "G: D mailbox sink copies invoke recursive glue", "rt.tuckCopyG\\("
  let shape = t.needCmd(@["nim", "c", "--hints:off", "--warnings:off",
                          "-r", "-o:" & (t.dir / "glue_shapes"),
                          t.root / "tests" / "ownership_glue" / "shapes.nim"],
                        verb = vBuild)
  if t.phase == pReport:
    if t.skippedCmd(shape):
      t.skip "G: shared type graph covers nested and recursive owning types"
    else:
      let (rc, output) = t.resultOf(shape)
      if rc == 0: t.ok "G: shared type graph covers nested and recursive owning types"
      else: t.no "G: shared type graph covers nested and recursive owning types", output
  let commonExe = t.dir / "common"
  let commonBuild = t.needCmd(@["nim", "c", "--hints:off", "--warnings:off",
    "-o:" & commonExe, t.root / "tests" / "ownership_glue" / "common.nim"], verb = vBuild)
  for backend in ["nim", "odin", "d"]:
    let run = t.needCmdAfter(@["env", "TUCK_OWN=rules", commonExe, backend],
      commonBuild, proc (dir: string) = discard, t.dir, verb = vRun)
    if t.phase == pReport:
      let (rc, output) = t.resultOf(run)
      if rc == 0: t.ok "G: common ownership elaborates before the " & backend & " clone"
      else: t.no "G: common ownership elaborates before the " & backend & " clone", output
  let dmd = findDmd()
  if dmd.len > 0:
    let dExe = t.dir / "glue_d"
    let dBuild = t.needCmd(@[dmd, "-i",
      "-I" & (t.root / "compiler" / "tuckrt_d"),
      t.root / "compiler" / "tuckrt" / "minicoro.a",
      "-of=" & dExe, t.root / "tests" / "ownership_glue" / "copy.d"], verb = vBuild)
    let dRun = t.needCmdAfter(@["timeout", "10", dExe], dBuild,
                             proc (dir: string) = discard, t.dir, verb = vRun)
    if t.phase == pReport:
      if t.skippedCmd(dRun):
        t.skip "G: D deep copies preserve nested value semantics with native GC"
      else:
        let (rc, output) = t.resultOf(dRun)
        if rc == 0: t.ok "G: D deep copies preserve nested value semantics with native GC"
        else:
          let (buildRc, buildOutput) = t.resultOf(dBuild)
          t.no "G: D deep copies preserve nested value semantics with native GC",
               if buildRc != 0: buildOutput else: output
  let odin = findOdin()
  if odin.len == 0:
    if t.phase == pReport:
      t.no "G: recursive sequence copy/drop requires Odin", "odin not installed"
    return
  let generated = t.dir / "generated"
  let genericExe = t.dir / "generic_glue"
  let genericBuild = t.needCmd(@[odin, "build", t.root / "tests" / "ownership_glue",
    OdinThreads, "-define:TUCK_TRACK=true", "-out:" & genericExe], verb = vBuild)
  let genericRun = t.needCmdAfter(@["timeout", "10", genericExe], genericBuild,
    proc (dir: string) = discard, t.dir, verb = vRun)
  if t.phase == pReport:
    let (rc, output) = t.resultOf(genericRun)
    if rc == 0: t.ok "G: polymorphic native glue is deep and leak-free"
    else:
      let (brc, boutput) = t.resultOf(genericBuild)
      t.no "G: polymorphic native glue is deep and leak-free", if brc != 0: boutput else: output
  let gen = t.needCmd(@["nim", "c", "--hints:off", "--warnings:off", "-r",
    "-o:" & (t.dir / "glue_generator"),
    t.root / "tests" / "ownership_glue" / "generate.nim", generated], verb = vBuild)
  let genBuild = t.needCmdAfter(@[odin, "build", generated, OdinThreads,
    "-define:TUCK_TRACK=true", "-out:" & (generated / "prog")],
    gen, proc (dir: string) = discard, t.dir, verb = vBuild)
  let genRun = t.needCmdAfter(@["timeout", "10", generated / "prog"],
    genBuild, proc (dir: string) = discard, t.dir, verb = vRun)
  if t.phase == pReport:
    if t.skippedCmd(genRun):
      t.skip "G: generated Odin record/sum/array/result glue is leak-free"
    else:
      let (rc, output) = t.resultOf(genRun)
      if rc == 0:
        t.ok "G: generated Odin record/sum/array/result glue is leak-free"
      else:
        let (buildRc, buildOutput) = t.resultOf(genBuild)
        t.no "G: generated Odin record/sum/array/result glue is leak-free",
             if buildRc != 0: buildOutput else: output
