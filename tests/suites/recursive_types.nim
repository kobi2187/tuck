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

  # --- 7. a variant construction's payload is CHECKED ---------------------
  # It was not, because it was never synthesized: `Type.Variant {payload}`
  # parses as an exkField carrying a dotArg, and asVariantConstruction
  # answered with the owner's type and returned. So both of these passed
  # `tuck ch`, and — the same cause — nothing inside a payload had a stamped
  # type, which is why a field access in one lost its variant projection and
  # emitted `n.left` where `n.tuck_add.left` was meant.
  t.src """
type N:
  | Num({value: int})

fn main() -> int:
  let a = N.Num {value: "a string, not an int"}
  return 0
"""
  t.badCheck "a wrong-typed variant payload field is rejected", "TK-TY22"
  t.badCheck "...and the message names the variant and the field",
             "variant 'Num' field 'value' expects int"

  t.src """
type N:
  | Num({value: int})

fn main() -> int:
  let a = N.Num {nosuchfield: 1}
  return 0
"""
  t.badCheck "a misspelled variant payload field is rejected", "TK-TY22"
  t.badCheck "...and the message lists what the variant does declare",
             "it declares value"

  # The projection that the missing stamp broke.
  t.src """
type N:
  | Num({value: int})
  | Add({left: int, right: int})

fn shifted({n: N, by: int}) -> N:
  match n:
    Num: return n
    Add: return N.Add {left: n.left + by, right: n.right + by}

fn main() -> int:
  let a = N.Add {left: 1, right: 2}
  let b = {n: a, by: 10} shifted
  return b.left - 11
"""
  t.okCheck "a field read INSIDE a variant payload checks"
  t.hostBuilds "...and every backend projects it through the right variant"
  t.runs "...and reads the value it was narrowed to", 0

  # --- 8. `.len` on a Seq -------------------------------------------------
  # Nim spells it `.len`, D `.length`, Odin `len(xs)`. The D backend
  # translated it during its own audit ("hidden Nim-ism #3"); Odin did not,
  # so `xs.len` reported "has no field 'len'". Nothing in the corpus took
  # the length of a Seq.
  t.src """
fn main() -> int:
  let xs = [1, 2, 3]
  return xs.len - 3
"""
  t.okCheck "`.len` on a Seq checks"
  t.hostBuilds "...and every backend spells it its own way"
  t.runs "...and counts", 0

  # --- 9. a variant payload field HAS a type ------------------------------
  # It did not, to the checker. getFieldsForType answers `@[]` for a sum on
  # purpose (a sum has no fields of its own), so a payload access matched no
  # arm of the field-form chain and fell through to Unknown. Gradual typing
  # then carried that Unknown to codegen, where variantOwningField did the
  # projection independently and correctly — so nothing looked wrong until
  # something needed the TYPE.
  t.src """
type Bag:
  | Empty
  | Items({xs: Seq[int]})

fn first({b: Bag}) -> int:
  match b:
    Empty: return 0
    Items: return b.xs[0]

fn main() -> int:
  let b = Bag.Items {xs: [7, 8]}
  return {b: b} first - 7
"""
  t.okCheck "indexing a Seq-typed payload field inside a match arm checks"
  t.hostBuilds "...and builds on every backend"
  t.runs "...and reads the element", 0

  # Outside a match too: the variant that DECLARES the name decides, which is
  # the rule codegen already followed.
  t.src """
type Bag:
  | Empty
  | Items({xs: Seq[int]})

fn noMatch({b: Bag}) -> int:
  return b.xs[0]

fn main() -> int:
  return 0
"""
  t.okCheck "a payload field types outside a match as well"

  # --- 10. THE FEATURE: a recursive sum, written the obvious way ----------
  # `| Add({left: Expr, right: Expr})` has no finite size as written, which
  # is what TK-TY17 rejected, and its advice was to write `Seq[Expr]` by
  # hand. lowering_recursive writes it instead: the edge declaration becomes
  # `Seq[T]`, a construction wraps (`@[x]`), and a read unwraps (`tuckAt(x, 0)`).
  t.src """
type Expr:
  | Num({value: int})
  | Add({left: Expr, right: Expr})

fn total({e: Expr}) -> int:
  match e:
    Num: return e.value
    Add: return {e: e.left} total + {e: e.right} total

fn main() -> int:
  let a = Expr.Num {value: 3}
  let b = Expr.Num {value: 4}
  let s = Expr.Add {left: a, right: b}
  let t = Expr.Add {left: s, right: s}
  return {e: t} total - 14
"""
  t.okCheck "a sum whose variant holds its own type is accepted"
  t.emits "the edge declaration becomes a handle", r"left: seq\[tuck_Expr\]"
  t.emits "a construction wraps the value", r"left: @\[tuck_a\]"
  t.emits "a read unwraps it", r"tuckAt\(e\.tuck_add\.left, 0\)"
  t.hostBuilds "...and every backend's host compiler accepts the result"
  t.runs "...and the tree walks: (3+4)+(3+4)", 0

  # Value semantics all the way down: a Seq handle COPIES on assignment, so
  # a subtree used twice is two subtrees, not one shared node.
  t.src """
type Expr:
  | Num({value: int})
  | Add({left: Expr, right: Expr})

fn main() -> int:
  var a = Expr.Num {value: 3}
  let s = Expr.Add {left: a, right: a}
  a = Expr.Num {value: 99}
  match s:
    Num: return 1
    Add: return s.left.value - 3
"""
  t.okCheck "a subtree is a value, not a reference"
  t.runs "...so rebinding its source does not change the tree", 0

  # What is still rejected, and why each is different.
  t.src """
type Cell = {next: Cell, v: int}

fn main() -> int:
  return 0
"""
  t.badCheck "a RECORD containing itself is still rejected", "TK-TY17"
  t.badCheck "...because it has no variant to end the chain", "field 'next'"

  t.src """
type Tree:
  | Leaf({v: int})
  | Node({kids: Array[4, Tree]})

fn main() -> int:
  return 0
"""
  t.badCheck "an Array edge is still rejected — N inline copies is no handle",
             "TK-TY17"

  t.finish()
