# R11 scan cases: each construct declared in module `lib`, used from `main`.
# want = the expected exit code of main. Run by scan.py beside this file.
CASES = []
def case(name, lib, main, want, imports="", libimports=""):
    CASES.append(dict(name=name, lib=libimports + lib, main=main, want=want, imports=imports))

case("object member call", """object Counter:
  n: int
  fn read({self: Counter}) -> int:
    return self.n
""", """fn main() -> int:
  let c = {n: 7} Counter
  return c.read
""", 7)

case("object changing member on a var", """object Counter:
  n: int
  fn bump({self: Counter}):
    self.n = self.n + 1
""", """fn main() -> int:
  var c = {n: 7} Counter
  c.bump
  return c.n
""", 8)

case("dotdot chain on an imported object", """object Box:
  a: int
  fn put({self: Box, v: int}) -> Box:
    return self with {a: v}
""", """fn main() -> int:
  var b = {a: 1} Box
  b ..put {v: 9}
  return b.a
""", 9)

case("interface + satisfies in lib, value in main", """interface Shape:
  fn area({self: Self}) -> int

object Sq:
  satisfies Shape
  s: int
  fn area({self: Sq}) -> int:
    return self.s * self.s

object Rc:
  satisfies Shape
  w: int
  h: int
  fn area({self: Rc}) -> int:
    return self.w * self.h
""", """fn total({a: Shape, b: Shape}) -> int:
  return a.area + b.area

fn main() -> int:
  let x: Shape = {s: 3} Sq
  let y: Shape = {w: 2, h: 5} Rc
  return {a: x, b: y} total
""", 19)

case("interface in lib, satisfier in main", """interface Shape:
  fn area({self: Self}) -> int
""", """object Sq:
  satisfies Shape
  s: int
  fn area({self: Sq}) -> int:
    return self.s * self.s

fn main() -> int:
  let x: Shape = {s: 4} Sq
  return x.area
""", 16)

case("type test on an imported interface", """interface Shape:
  fn area({self: Self}) -> int

object Sq:
  satisfies Shape
  s: int
  fn area({self: Sq}) -> int:
    return self.s * self.s

object Rc:
  satisfies Shape
  w: int
  h: int
  fn area({self: Rc}) -> int:
    return self.w * self.h
""", """fn side({v: Shape}) -> int:
  match v:
    | Sq q -> return q.s
    | _ -> return 0

fn main() -> int:
  let x: Shape = {s: 6} Sq
  return {v: x} side
""", 6)

case("interface-bounded generic fn in lib", """interface Shape:
  fn area({self: Self}) -> int

object Sq:
  satisfies Shape
  s: int
  fn area({self: Sq}) -> int:
    return self.s * self.s

fn twice[T: Shape]({a: T, b: T}) -> int:
  return a.area + b.area
""", """fn main() -> int:
  let p = {s: 2} Sq
  let q = {s: 3} Sq
  return {a: p, b: q} twice
""", 13)

case("mixin composed from lib", """mixin Doubler:
  fn double({self: Self}) -> int:
    return self.n * 2
""", """object Num:
  n: int
  + Doubler

fn main() -> int:
  let x = {n: 21} Num
  return x.double
""", 42)

case("record composed from lib", """type Pos:
  x: int
  y: int
""", """object Sprite:
  + Pos
  id: int

fn main() -> int:
  let s = {x: 3, y: 4, id: 1} Sprite
  return s.x + s.y + s.id
""", 8)

case("group bound, provider in lib", """group Sized:
  fn size({self: Self}) -> int

fn big[T: Sized]({x: T}) -> bool:
  return {self: x} size > 10
""", """type Blob:
  n: int

fn size({self: Blob}) -> int:
  return self.n

fn main() -> int:
  let b = {n: 20} Blob
  if {x: b} big:
    return 1
  return 0
""", 1)

case("decision table in lib", """type Light:
  | Red
  | Green

decision act(light: Light, busy: bool) -> int:
  | Red   _     -> 1
  | Green true  -> 2
  | Green false -> 3
""", """fn main() -> int:
  return {light: Light.Green, busy: false} act
""", 3)

case("distinct/saturating type in lib", """type Level = u8 [saturating]
""", """fn main() -> int:
  let l = {value: 300} Level
  return {value: l} int
""", 255)

case("invariant type from lib validates", """type Temp:
  c: int
  invariant:
    c >= -273
""", """fn main() -> int:
  let t = {c: -300} Temp
  return 0
""", 1)

case("fallible fn and its error enum in lib", """type FsError:
  | NotFound
  | Denied

fn open({p: int}) -> !int [io, error: FsError]:
  if p == 0:
    err FsError.NotFound
  return p
""", """fn main() -> int [io]:
  let r = {p: 0} open
  if not r.ok:
    match r.err:
      NotFound: return 4
      _: return 5
  return r.value
""", 4)

case("optional return from lib", """fn find({n: int}) -> ?int:
  if n > 5:
    return n
  return
""", """fn main() -> int:
  let r = {n: 9} find
  if r.ok:
    return r.value
  return 0
""", 9)

case("pool declared in lib", """pool Cells = int [count: 2]
""", """fn main() -> int:
  let h = Cells.acquire
  if not h.ok:
    return 0
  Cells.write {h: h.value, value: 5}
  let v = Cells.read {h: h.value}
  if v.ok:
    return v.value
  return 1
""", 5)

case("task declared in lib", """task work({n: int}) -> int:
  return n * 2
""", """fn main() -> int:
  let r = {n: 21} work
  return r
""", 42)

case("transition table in lib", """type Door:
  | Open
  | Closed

  transitions:
    Open -> Closed
    Closed -> Open

fn shut({d: Door}) -> Door:
  match d:
    Open: return Door.Closed
    Closed: return Door.Closed
""", """fn main() -> int:
  let d = {d: Door.Open} shut
  match d:
    Closed: return 1
    Open: return 2
""", 1)

case("registry in lib, raised and handled in main", """registry AppEvents:
  | Low({left: int})
""", """on AppEvents.Low({left: int}) [io]:
  {text: "low"} console::printLine

fn main() -> int [io]:
  AppEvents.raise Low {left: 3}
  return 0
""", 0, imports="import console\n")

case("actor in lib (A18)", """actor Acc [queue: 8]:
  total: int = 0
  on add({n: int}):
    total += n
""", """fn done() -> bool:
  return Acc.total > 0

fn main() -> int:
  Acc send add {n: 6}
  Acc.waitUntil {pred: :done}
  return Acc.total
""", 6, imports="import scheduler\n", libimports="")

case("actor member fn in lib", """actor Acc [queue: 8]:
  total: int = 0
  fn addIt({n: int}):
    total += n
  on add({n: int}):
    {n: n} addIt
""", """fn done() -> bool:
  return Acc.total > 0

fn main() -> int:
  Acc send add {n: 6}
  Acc.waitUntil {pred: :done}
  return Acc.total
""", 6, imports="import scheduler\n")

case("const Array size and fill from lib", """const Cap = 4
""", """fn main() -> int:
  let a: Array[Cap, int] = [5; Cap]
  return a[0] + a[3]
""", 10)

case("generic record from lib", """type Box[T]:
  value: T
""", """fn main() -> int:
  let b = {value: 11} Box
  return b.value
""", 11)

case("fnsig type from lib", """fnsig Op = {a: int, b: int} -> int

fn apply({f: Op, a: int, b: int}) -> int:
  return {a: a, b: b} f
""", """fn plus({a: int, b: int}) -> int:
  return a + b

fn main() -> int:
  return {f: :plus, a: 3, b: 4} apply
""", 7)
