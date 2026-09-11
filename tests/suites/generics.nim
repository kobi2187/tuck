## Generic fns, and the one thing they exposed: whether Tuck's `int` is the
## same width on every backend.
##
## Nothing in the corpus is a generic fn. So two of three backends could not
## emit one, and nothing noticed:
##
##   Odin declared the type param as an ARGUMENT — `proc($T: typeid, a: T,
##   b: T)` — which the call site never passed, giving "Parameter 'b' of type
##   'typeid' is missing in procedure call".
##
##   D refused outright: `dUnsupported "generic fn"`. An entire language
##   feature was absent from a backend, with nothing to report it.
##
## Both now use the form each backend's own RUNTIME already hand-writes for
## exactly these shapes: inference from the first parameter that mentions the
## param on Odin (`tuckAt :: proc(items: []$T, index: int) -> T`), a template
## on D (`T[] push(T)(T[] items, T value)`).
##
## THE WIDTH TEST BELONGS HERE because generics are what found it. Tuck's
## `int` is D's `long`, but a bare D integer literal is `int` — 32-bit.
## Everywhere else there is a declared type to convert to, so it never showed;
## a generic call is the first place D INFERS from a literal, and `twice(5)`
## instantiated `T = int` and then would not assign to the `long[]` the
## declared return type says it is. A Tuck int literal now carries `L`.
##
## Same semantics on every backend is the rule this protects: a program whose
## arithmetic silently changes width depending on which backend built it is
## not one program.

import ../harness

proc run*(t: var T) =
  # --- generic fns ---------------------------------------------------------
  t.src """
fn smaller[T]({a: T, b: T}) -> T:
  if a < b:
    return a
  return b

fn firstOr[T]({xs: Seq[T], fallback: T}) -> T:
  if xs.len == 0:
    return fallback
  return xs[0]

fn twice[T]({x: T}) -> Seq[T]:
  return [x, x]

fn main() -> int:
  let s = {a: 3, b: 5} smaller
  let f = {xs: [7, 8], fallback: 0} firstOr
  let d = {x: 5} twice
  return s + f + d.len - 12
"""
  t.okCheck "generic fns check"
  t.emitsOdin "Odin infers the type param from a parameter",
              r"proc \(a: \$T, b: T\)"
  t.emitsD "D emits a template", r"T tuck_smaller\(T\)\(T a, T b\)"
  t.hostBuilds "...and every backend builds them"
  t.runs "...including a Seq[T] param and a Seq[T] return", 0

  # --- `int` is 64 bits, on every backend ----------------------------------
  # 2^40 does not fit in 32. If a backend's `int` were narrower, this would
  # not merely be slower or larger — it would compute something else.
  t.src """
fn main() -> int:
  let big = 1099511627776
  let back = big /i 1099511627776
  return back - 1
"""
  t.okCheck "a 2^40 literal checks"
  t.hostBuilds "...and every backend accepts it"
  t.runs "...and round-trips, so int is 64-bit everywhere", 0

  t.emitsD "a D int literal carries L, or D would infer 32 bits",
           r"1099511627776L"

  # Every narrower width still narrows. The `L` suffix must not break the
  # sized types, which is the risk a blanket literal change carries.
  t.src """
type Sizes:
  a: u8
  b: u16
  c: u32
  d: i8
  e: i16
  f: i32
  g: int

fn total({s: Sizes}) -> int:
  return 0

fn main() -> int:
  let s = {a: 200, b: 8080, c: 70000, d: 100, e: 300, f: 90000, g: 5} Sizes
  return {s: s} total
"""
  t.okCheck "every integer width checks"
  t.hostBuilds "...and a widened literal still narrows to each of them"
  t.runs "...and runs", 0

  # --- the width survives a `?T` wrapper -----------------------------------
  # `return 0` in an `-> i64?` fn is wrapped by codegen (`tok(0)`), so the
  # width the literal has to carry is the PAYLOAD's. synthLit read the
  # expected-type channel but only recognised a bare numeric name; `?i64` is
  # a tkApp, so the hint was dropped and the literal stayed `int` — Nim
  # refused `TuckResult[int]` for `TuckResult[int64]` and Odin refused
  # `TuckResult($T=int)` for `TuckResult($T=i64)`. Found writing core.num.
  t.src """
fn zeroOr({n: i64}) -> i64?:
  if n < 0:
    return 0
  if n > 100:
    return
  return n

fn main() -> int:
  let r = {n: 5} zeroOr
  if not r.ok:
    return 1
  return {value: r.value} int - 5
"""
  t.okCheck "a literal in a ?T return checks"
  t.hostBuilds "...and every backend accepts its width"

  # --- a NARROWING conversion ----------------------------------------------
  # `{value: wide} u8` is explicit by construction — the author wrote the type
  # name — but D's `ubyte(x)` is a type constructor that only performs the
  # conversions it would do implicitly, so a ulong argument was "cannot
  # implicitly convert expression of type ulong to ubyte". It emits a `cast`.
  t.src """
import bits

fn lowByte({x: u64}) -> u8:
  return {value: {a: x, b: 255} bitAnd} u8

fn main() -> int:
  let v = {value: 258} u64
  return {value: {x: v} lowByte} int - 2
"""
  t.okCheck "a narrowing conversion checks"
  t.emitsD "D casts rather than constructing", r"cast\(ubyte\)"
  t.hostBuilds "...and every backend narrows it"
  t.runs "...to the low byte", 0

  # --- an arm body does not inherit the SUBJECT's width --------------------
  # The expected-type channel is set to the match subject so a bare variant
  # in an arm body resolves (it was called `expectedVariantType`). Offering
  # it for anything else is a hint the body never asked for: an error match
  # has a u16 subject, and `42 sys::exit` came out `exit(42'u16)`, which
  # Nim's `exit(int)` refuses. Only a SUM subject is offered now.
  t.src """
type E:
  | Empty
  | TooLong

fn parse({raw: str}) -> !str [io, error: E]:
  if raw == "":
    err Empty
  return raw

fn pick({n: int}) -> int [io]:
  let r = {raw: ""} parse
  if r.ok:
    return 0
  match r.err:
    Empty: return 42
    TooLong: return 7

fn main() -> int [io]:
  return {n: 1} pick - 42
"""
  t.okCheck "a match over r.err checks"
  t.hostBuilds "...and its arm bodies keep their own widths"

  # --- a generic extern reached through an IMPORT --------------------------
  # `push` used bare resolves to the runtime; `import seq` routes it through
  # the emitted library module instead, and only THAT path goes through the
  # extern forwarder. Odin's forwarder marked the type param with its own
  # copy of the rule, testing for a bare named `T` — which `Seq[T]`
  # (`[dynamic]T`) is not, so the sigil landed on the second parameter and
  # the first named an undeclared `T`. Found writing core.num.
  t.src """
import seq

fn noInts() -> Seq[int]:
  return []

fn main() -> int:
  var xs = noInts
  xs = {items: xs, value: 7} push
  return xs.len - 1
"""
  t.okCheck "an imported generic extern checks"
  # The forwarder lands in the emitted mod_seq PACKAGE, not this module's
  # own .odin, so hostBuilds is what sees it — an unbound `T` there is a
  # compile error in a file no `emits` assertion can reach.
  t.hostBuilds "...and every backend builds the forwarder"
  t.runs "...and the pushed element is there", 0

  # --- a generic TYPE, and constructing one inside a generic fn ------------
  # The gate on the whole `alloc` tier: `Table[K, V]`, `Deque[T]`, `List[T]`
  # are all this shape. Two things were missing.
  #
  # D had no generic types at all (`dUnsupported "generic type"`). Its
  # parameterisation IS templates, the same answer the generic-FN fix
  # reached: `struct Pair(K, V)`, instantiated `Pair!(string, long)` at the
  # use site — which the construction has to spell, since D cannot infer a
  # template's arguments from a named-argument literal.
  #
  # And every `T` in a generic body collapsed to ONE nameless abstraction, so
  # a fn could not construct its own return type: the checker saw two
  # indistinguishable sentinels and said "cannot infer generic parameter
  # 'K'". A type param now carries which one it is.
  t.src """
type Pair[K, V]:
  key: K
  value: V

fn mk[K, V]({k: K, v: V}) -> Pair[K, V]:
  return {key: k, value: v} Pair

fn main() -> int:
  let p = {k: "a", v: 5} mk
  let q = {key: "b", value: 7} Pair
  return p.value + q.value - 12
"""
  t.okCheck "a generic type checks, built from a generic fn's own params"
  t.emitsD "D declares it as a template struct",
           r"struct tuck_Pair\(K, V\)"
  t.emitsD "...and the use site names the instantiation",
           r"tuck_Pair!\(string, long\)"
  t.hostBuilds "...and every backend builds it"
  t.runs "...and the fields hold what was put in them", 0

  # --- a STATED type on a local -------------------------------------------
  # `let x: T = v` / `var x: T = v`. Inference is still the normal case; this
  # exists for the values that carry no type of their own. Before it, the only
  # way to name an empty collection's element type was a fn whose RETURN type
  # said it, and `alloc.map` needed five such fns to say "empty".
  t.src """
fn main() -> int:
  var acc: Seq[int] = []
  for i in 0 .. 2:
    acc = {items: acc, value: i} push
  let n: int = 3
  var total: u64 = 0
  total = total + 1
  return acc.len - n + {value: total} int - 1
"""
  t.okCheck "a stated type on a local checks"
  t.emits "Nim states it too rather than re-inferring", r"var tuck_acc: seq\[int\]"
  t.hostBuilds "...and every backend accepts the declaration"
  t.runs "...and the empty seq fills up", 0

  t.src """
fn main() -> int:
  let n: int = "nope"
  return 0
"""
  t.badCheck "a value that does not match the stated type is rejected",
             "expects int but got str"

  # A generic construction under a stated type binds the type params from the
  # ANNOTATION — so there is no need for a nullary `newTable[K, V]()`, which
  # nothing could ever infer K and V for.
  t.src """
type Box[K, V]:
  keys: Seq[K]
  vals: Seq[V]

fn main() -> int:
  var b: Box[str, int] = {keys: [], vals: []} Box
  b = {keys: {items: b.keys, value: "a"} push, vals: b.vals} Box
  return b.keys.len - b.vals.len - 1
"""
  t.okCheck "a generic construction takes its params from the stated type"
  t.hostBuilds "...on every backend"
  t.runs "...and the two fields are independent", 0

  # A Tuck module may be named after a HOST type. `import seq` bound the
  # module symbol to `seq` in the emitted Nim, shadowing Nim's own `seq`, and
  # the next `seq[tuck_Entry[K, V]]` in that file was "cannot instantiate the
  # 'seq' module". Imports are aliased now.
  t.src """
import seq

fn main() -> int:
  var xs: Seq[int] = []
  xs = {items: xs, value: 4} push
  return xs.len - 1
"""
  t.okCheck "a module named after a host type checks"
  t.hostBuilds "...and does not shadow it in the emitted code"
  t.runs "...and Seq still works beside it", 0

  # --- a user fn whose name folds into a runtime intrinsic ----------------
  # Nim identifiers ignore underscores and case after the first character, so
  # `fn at` — mangled `tuck_at` — IS `tuckAt`, the intrinsic every `xs[i]`
  # lowers to. The module rebound indexing to itself, then reported the
  # user's own call as ambiguous. alloc.vec found it: its API deliberately
  # keeps std/seq's `at`/`setAt` spellings.
  t.src """
fn at({items: Seq[int], index: int}) -> int?:
  if index < 0 or index >= items.len:
    return
  return items[index]

fn main() -> int:
  let xs: Seq[int] = [10, 20, 30]
  let r = {items: xs, index: 1} at
  if not r.ok:
    return 1
  return r.value - xs[1]
"""
  t.okCheck "a fn named after a runtime intrinsic checks"
  t.emits "it is mangled out of the intrinsic's way", r"tuckfn_at"
  t.hostBuilds "...and every backend builds it"
  t.runs "...with indexing still reaching the intrinsic", 0

  # --- an already-wrapped return is a pass-through ------------------------
  # `return {..} at` inside a fn that itself returns `?T` wraps a value that
  # is already a carrier — TuckResult[TuckResult[T]], which typechecks clean
  # and fails in the host compile. Nim learned this when `!void` pass-through
  # bit it; Odin and D never got the twin.
  t.src """
fn lookUp({items: Seq[int], index: int}) -> int?:
  if index < 0 or index >= items.len:
    return
  return items[index]

fn firstOf({items: Seq[int]}) -> int?:
  return {items: items, index: 0} lookUp

fn main() -> int:
  let r = {items: [7, 8]} firstOf
  if not r.ok:
    return 1
  return r.value - 7
"""
  t.okCheck "returning an already-wrapped value checks"
  t.omits "Nim does not wrap it twice", r"tok\(tuck_lookUp"
  t.hostBuilds "...and no backend does"
  t.runs "...and the payload survives one level", 0

  # --- an append assigned back to itself is an IN-PLACE append ------------
  # `push` returns a NEW seq because value semantics forbid writing through a
  # parameter, so a build loop copied the whole sequence every iteration:
  # 50k/100k appends took 1.29s/5.24s in release, a ratio of 4.06 on a
  # doubled input — textbook O(n^2).
  #
  # `xs = push(xs, v)` is provably a MOVE: the old value dies the instant the
  # new one lands, so nothing can observe the copy. Every host already has an
  # amortised append, so the emitters just recognise the shape. 100k appends
  # now measure 0.00s on all three.
  t.src """
import seq

fn main() -> int:
  var a: Seq[int] = [1, 2]
  # `b` is a COPY — appending to `a` must not reach it.
  let b = a
  a = {items: a, value: 3} push
  if a.len != 3:
    return 1
  if b.len != 2:
    return 2
  # A NON-self append still copies: `c` must not be `a`.
  let c = {items: a, value: 9} push
  if c.len != 4:
    return 3
  if a.len != 3:
    return 4
  return 0
"""
  t.okCheck "a self-append checks"
  t.emits "Nim appends in place", r"tuck_a\.add\(3\)"
  t.emitsOdin "Odin appends in place", r"append\(&tuck_a, 3\)"
  t.emitsD "D appends in place", r"tuck_a ~= 3L"
  t.hostBuilds "...on every backend"
  t.runs "...and a copy taken beforehand is untouched", 0

  # A STATED type names a declaration like any other type reference, so it
  # has to rename with the rest — the mangle pass did not walk the new
  # declType field, and the annotation emitted the user's own `Bag` beside
  # the declaration's `tuck_Bag`.
  t.src """
type Bag:
  items: Seq[int]

fn main() -> int:
  var bag: Bag = {items: [1, 2]} Bag
  return bag.items.len - 2
"""
  t.okCheck "a stated USER type on a local checks"
  t.emits "the annotation is mangled with the declaration", r"tuck_bag: tuck_Bag"
  t.hostBuilds "...on every backend"
  t.runs "...and the value is there", 0

  t.finish()
