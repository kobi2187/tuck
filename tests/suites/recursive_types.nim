## Recursive sum types, and the three bugs that stood between them and working.
##
## `typecheck_recursion.nim:15-18` says the way to write a tree is to hold the
## recursive part as `Seq[Self]`, and that it "builds today". Nothing in the
## corpus had ever done it — zero trees, lists or JSON values in examples/ or
## std/, and the only recursive shapes in the tree were the REJECTION fixtures
## in declarations.nim. Spiking it found the claim false on two of three
## backends, for reasons that had nothing to do with recursion:
##
##   1. D could not construct any payload variant after the FIRST. The tagged
##      struct is `{Kind kind; union {A a; B b;}}` and the constructor was
##      emitted POSITIONALLY, so the payload bound to the union's first member
##      whatever variant it was: `Shape.Rect` built a `Shape_Circle` slot.
##   2. Odin could not build a `Seq` literal in a record field at all —
##      "Compound literals of dynamic types are disabled by default". Tuck's
##      `Seq[T]` is `[dynamic]T`, so `{items: [3, 4]} Bag` never compiled.
##
## Neither was recursion-specific, and both are covered here by the plain
## non-recursive case first, because that is what they actually are.
##
## The third bug is why the first two survived: `tuck b --odin` and
## `--dlang` printed the host compiler's failure and then exited 0, so every
## assertion that reads an exit code was blind. d_backend's example sweep also
## ran `tuck c` (emission only) rather than `tuck b`. Fixed in tuck.nim and
## d_backend.nim respectively; `t.hostBuilds` is the assertion that keeps all
## three honest here.

import ../harness

proc run*(t: var T) =
  # --- 1. a payload variant that is not the first ------------------------
  t.src """
type Shape:
  | Circle({r: int})
  | Rect({w: int, h: int})

fn main() -> int:
  let s = Shape.Rect {w: 3, h: 4}
  return s.w + s.h - 7
"""
  t.okCheck "a non-first payload variant checks"
  t.hostBuilds "...and every backend's host compiler accepts it"
  t.runs "...and it carries the right payload", 0

  # The first variant always worked, which is why this went unnoticed: the
  # union's members are only the payload-CARRYING variants, so a sum whose
  # first payload variant is the one being built binds correctly by accident.
  t.src """
type Shape:
  | Circle({r: int})
  | Rect({w: int, h: int})

fn main() -> int:
  let s = Shape.Circle {r: 7}
  return s.r - 7
"""
  t.okCheck "the first payload variant checks too"
  t.hostBuilds "...and still builds everywhere"
  t.runs "...and carries its payload", 0

  # --- 2. a Seq literal in a record field --------------------------------
  t.src """
type Bag:
  items: Seq[int]

fn main() -> int:
  let b = {items: [3, 4]} Bag
  return b.items[0] + b.items[1] - 7
"""
  t.okCheck "a Seq literal in a record field checks"
  t.hostBuilds "...and every backend can emit it"
  t.runs "...and reads back", 0

  # --- 3. the actual point: a recursive sum through Seq[Self] ------------
  t.src """
type Expr:
  | Num({value: int})
  | Add({kids: Seq[Expr]})

fn total({e: Expr}) -> int:
  match e:
    Num: return e.value
    Add:
      var s = 0
      for k in e.kids:
        s = s + {e: k} total
      return s

fn main() -> int:
  let a = Expr.Num {value: 3}
  let b = Expr.Num {value: 4}
  let sum = Expr.Add {kids: [a, b]}
  return {e: sum} total - 7
"""
  t.okCheck "a sum type reaching itself through Seq is accepted"
  t.hostBuilds "...and all three backends emit code their host compiler takes"
  t.runs "...and the tree walk computes 3 + 4", 0

  # --- 4. value semantics through a Seq-carrying record -------------------
  # The language's central claim, and it did not hold on Odin: a
  # `[dynamic]T` assignment copies the HEADER, so two names viewed one
  # buffer. The same program exited 1 on Nim and D and 99 here. D was
  # already correct only because lowering_d inserted `.dup`; that analysis
  # is backend-neutral and now lives in lowering_seqcopy, shared by both.
  t.src """
type Bag:
  items: Seq[int]

fn main() -> int:
  var a = {items: [1, 2]} Bag
  var b = a
  b.items[0] = 99
  return a.items[0] - 1
"""
  t.okCheck "copying a record that carries a Seq checks"
  t.hostBuilds "...and builds on every backend"
  t.runs "...and the copy does NOT alias its source", 0

  # A bare Seq, the same question one level down.
  t.src """
fn main() -> int:
  var a = [1, 2]
  var b = a
  b[0] = 99
  return a[0] - 1
"""
  t.okCheck "copying a bare Seq checks"
  t.hostBuilds "...and builds on every backend"
  t.runs "...and that copy does not alias either", 0

  # --- 5. mutual recursion, both shapes ----------------------------------
  # typecheck_recursion.nim used to say this failed in codegen with
  # `undeclared identifier`, a decl-ordering bug. It does not: both shapes
  # build and run on all three backends, in the order that forward-references.
  # The comment outlived whatever fixed it.
  t.src """
type Stmt:
  | Emit({args: Seq[Expr]})
  | Nop

type Expr:
  | Num({value: int})
  | Group({body: Seq[Stmt]})

fn main() -> int:
  let n = Expr.Num {value: 7}
  return n.value - 7
"""
  t.okCheck "two sum types that reach each other are accepted"
  t.hostBuilds "...and build on every backend, declared forward-referencing"
  t.runs "...and run", 0

  t.src """
type Outer:
  label: int
  inner: Seq[Inner]

type Inner:
  tag: int
  back: Seq[Outer]

fn depth({o: Outer}) -> int:
  var d = 1
  for i in o.inner:
    for b in i.back:
      d = d + 1
  return d

fn main() -> int:
  let leaf = {label: 2, inner: []} Outer
  let mid = {tag: 5, back: [leaf]} Inner
  let top = {label: 1, inner: [mid]} Outer
  return {o: top} depth - 2
"""
  t.okCheck "two RECORDS that reach each other are accepted"
  t.hostBuilds "...and build on every backend"
  t.runs "...and a walk crosses the cycle", 0

  # A cycle with no handle in it is still a sizing error, which is what
  # TK-TY17 is actually for.
  t.src """
type Cell:
  value: int
  next: Cell

fn main() -> int:
  return 0
"""
  t.badCheck "a record containing itself by value is still rejected", "TK-TY17"

  # --- 6. a variant named after a host keyword ---------------------------
  # The payload field was the variant name lowercased, an identifier the
  # author never wrote: `| Block({...})` emitted `of Block: block*:` and Nim
  # said "identifier expected, but got 'keyword block'". Every realistic AST
  # type has a Block, If, Case, Var or Return.
  t.src """
type Node:
  | Block({count: int})
  | Case({tag: int})

fn main() -> int:
  let b = Node.Block {count: 7}
  match b:
    Block: return b.count - 7
    Case: return 1
"""
  t.okCheck "variants named after host keywords check"
  t.hostBuilds "...and every backend emits a name that cannot collide"
  t.runs "...and the payload reads back through a match", 0

  t.finish()
