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

  t.finish()
