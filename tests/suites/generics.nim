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

  t.finish()
