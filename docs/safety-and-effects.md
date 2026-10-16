# Safety, effects and numbers: a guide to what is new

This guide covers the features added in the last stretch of work, and the
handful of Tuck behaviours that are different enough from other languages to
be worth knowing before you write code. It describes what the compiler does
today. Where something is planned but not built, it says so.

If this guide and the compiler disagree, the compiler is right.

Contents

1. [Effect markers](#1-effect-markers)
2. [Seeing what the compiler derives: `tuck effects`](#2-seeing-what-the-compiler-derives-tuck-effects)
3. [Recursion: `no_recursion` and `recursion: N`](#3-recursion-no_recursion-and-recursion-n)
4. [Host checks and `-O:inline`](#4-host-checks-and--oinline)
5. [Numbers are always named](#5-numbers-are-always-named)
6. [Things that are special in Tuck](#6-things-that-are-special-in-tuck)
7. [What is not built yet](#7-what-is-not-built-yet)

---

## 1. Effect markers

A function's signature says what its body may do. The markers go in a bracket
after the return type:

```tuck
fn readSensor({port: u8}) -> u16 [io]:
  ...

fn queuePush({msg: Msg}) -> void [irq_safe, no_alloc]:
  ...
```

Markers are **written, not inferred**. A reader sees the whole contract in the
signature, without tracing the call graph. The compiler's job is to check the
body against it and, when it disagrees, to say exactly what to write.

### The three families

Markers fall into three families, and the family decides how a marker travels
through calls.

| family | markers | rule |
|---|---|---|
| **capability** | `io`, `may_block` | what the body *does*. Whoever calls it must declare it too. The obligation travels **up** the call chain. |
| **restriction** | `no_alloc`, `irq_safe`, `pure` | what the body *promises not to do*. A restricted fn may only call fns that make the same promise. The obligation travels **down**. |
| **attribute** | `unsafe`, `no_recursion`, `priority: N` | configuration. Nothing propagates. |

The direction matters. A plain fn calling a `[no_alloc]` fn is fine. A
`[no_alloc]` fn calling a plain fn is an error, because the plain one might
allocate.

### Capabilities: `io`, `may_block`

```tuck
fn inner() -> void [io]:
  {text: "x"} printLine

fn outer() -> void:        # error TK-EF01
  {} inner
```

```
Effect Error [TK-EF01]: 'outer' calls 'inner', which is [io], but 'outer' does
not declare it. Fix: declare [io] on 'outer'
```

The reverse is a warning (`TK-EF02`): declaring `[io]` on a fn whose body never
needs it makes every caller carry the marker for nothing.

### Which part of the world: `[io: kind]`

`[io]` says "touches the world". A kind says which part:

```tuck
fn fetch({url: str}) -> !{body: str} [io: net, error: NetError]: ...
fn save({path: str, data: str}) -> !void [io: fs, error: FsError]: ...
```

The kinds are `net`, `fs`, `clock`, `console` and `sys` (arguments, environment,
exit). The list is closed: `[io: banana]` is a parse error that names the kinds,
so a typo can never become a new kind. Adding a kind is one entry in
`compiler/ast_ops.nim`.

| a fn declaring | may call |
|---|---|
| `[io]` | any I/O fn, of any kind |
| `[io: net]` | `[io: net]` fns only; not `[io: fs]`, and not bare `[io]` (that one may do any kind) |
| `[io: net, io: fs]` | both kinds |

So "this library is `[io: net]`, therefore it never writes to disk" is a
statement the compiler checks. The standard library's fns carry their kind
(`printLine` is `[io: console]`, `readFile` is `[io: fs]`, `nowMs` is
`[io: clock]`). A caller that wrote plain `[io]` keeps working. `irq_safe` and
`pure` exclude every kind. Async lowering treats any kind like `[io]`.

### Restrictions: `no_alloc`, `irq_safe`, `pure`

```tuck
import bits

fn mask({a: u64}) -> u64 [pure, no_alloc]:
  return {a: a, b: a} bitAnd        # ok: bitAnd is declared [pure, no_alloc]

fn grow({xs: Seq[int]}) -> Seq[int] [no_alloc]:
  return {items: xs, value: 1} push   # error TK-EF03: push is not no_alloc
```

What the checker enforces for a restricted fn:

- **Every call** must reach a callee that declares the same marker (`TK-EF03`).
  Spawning a task is never allowed from a restricted fn. Calls to `pending`
  stubs are ignored, since an unwritten body is not a claim. A call to an
  extern with no marker is rejected, because it is not *known* to be safe; the
  fix is to declare the marker on the extern, if it is true.
- **`no_alloc` also covers the body itself** (`TK-EF05`): a `Seq` literal or a
  `str + str` allocates. A fixed `Array[N, T]`, a stack record, `pool` / `slab`
  / `arena` operations and string literals do not.
- **`irq_safe`** may not send to an actor (`TK-EF07`). A mailbox takes a lock,
  and an interrupt that preempts the thread holding it would deadlock. The
  workaround is for the interrupt to set a flag or write a fixed ring buffer
  that a task drains.

No function or type names are special-cased anywhere. `push`, `sqrt` and your
own functions are judged only by the markers on their declarations. The
standard library's externs carry `[pure, no_alloc]` where it is true (the bit
operations, `sqrt`, `pow`, `hash`, `count`, `at`, and so on), so restricted
code can call them.

### Combinations (`TK-EF04`)

Some markers contradict each other, and some imply another that must be
written out:

| declared | rule |
|---|---|
| `irq_safe` | may not also be `io` or `may_block` |
| `irq_safe` | must also be `no_alloc` (an interrupt cannot take the allocator's lock) |
| `pure` | may not also be `io` or `may_block` |
| `no_recursion` | may not also have `recursion: N` |
| `pure` | may not also have `recursion: N` (the counter is a side effect) |

Implications are errors with a fix, never silent additions, so the signature
keeps telling the whole truth.

### Local escape: `unsafe`

`[unsafe]` marks a site where you deliberately step outside a check. It is
reported, and it does **not** force its callers to declare anything.

---

## 2. Seeing what the compiler derives: `tuck effects`

```sh
tuck effects file.tuck       # alias: tuck ef
```

For every top-level fn in the file it prints the markers it declares, the
capabilities its body needs, the restrictions the compiler can **derive**, and
the markers you could add:

```
mask: declares [-], needs [-], derived: pure, no_alloc, bounded-depth
  suggest: add [pure, no_alloc]
say: declares [io], needs [-], derived: no_alloc, bounded-depth
  suggest: add [no_alloc]
spin: declares [-], needs [-], derived: -
```

How to read it:

- **derived** is what the compiler can prove from the code it can see. It is
  computed bottom-up through the calls to a fixed point.
- **suggest** lists restrictions that already hold but are not declared. Adding
  the marker turns an observation into a promise that is checked from then on.
- **Unknown means no fact.** A callee the compiler cannot place (an unmarked
  extern, a function from an imported module) gives no derived fact. The report
  never guesses optimistically.
- A recursive fn derives nothing, and `bounded-depth` is absent for it.

Actor `on` handlers are listed too, as `Actor.handler`. One that declares no
markers, needs none and reaches no other actor, pool or register is reported
**isolated**: it can touch nothing but its own actor's state, and the checker
has already proved it.

Because the output is deterministic (source order), `tuck effects f.tuck >
effects.txt` checked into a repository turns effect creep into a reviewable diff.

Derived facts are module-local today. A fn imported from another module
contributes its *declared* markers, not its derived ones.

---

## 3. Recursion: `no_recursion` and `recursion: N`

Two markers, because they make two different promises. (The older
`[stack: N]` read like a byte budget but only ever forbade recursion; it is
retired, and using it is an error that names both replacements.)

| marker | meaning | checked |
|---|---|---|
| `[no_recursion]` | nothing below this fn may recurse | at compile time (`TK-EF06`) |
| `[recursion: N]` | recursion is allowed, up to N nested calls | at run time |

```tuck
fn fact({n: int}) -> int [no_recursion]:     # error TK-EF06: fact calls itself
  if n < 2:
    return 1
  return n * ({n: n - 1} fact)

fn walk({n: int}) -> int [recursion: 1000]:  # fine; stops if nested deeper
  ...
```

`[recursion: N]` keeps a per-function, per-thread counter. Entering the fn more
than N levels deep stops the program:

```
Recursion depth exceeded in walk: limit 1000
```

Exit status is 1, and the check stays in release builds. The counter is
emitted on all three backends.

`[no_recursion]` follows calls through the functions defined in the same
module. A function reached through an import is treated as a leaf.

---

## 4. Host checks and `-O:inline`

### Host checks (on by default)

A `[pure]` fn is emitted to the host language with the host's own purity
attribute (Nim: `{.noSideEffect.}`). The host compiler then re-checks the claim
independently. If Tuck's analysis is ever wrong, the host disagrees at build
time, and you have found a compiler bug instead of a miscompile.

```sh
tuck build file.tuck --no-host-checks    # opt out
```

Only the Nim backend emits the attribute so far. D's `pure @nogc nothrow` and
the Odin equivalents are not emitted yet.

### `-O:inline` (opt in)

```sh
tuck compile file.tuck -O:inline,report
```

Marks small `[pure]` functions (at most 12 AST nodes) as inline, so the host
compiler may expand them at their call sites. It is off unless named, so the
default output is unchanged. It skips generic fns and fns with
`[recursion: N]`. `report` lists each function it marked.

---

## 4b. Memoization: `fn memo`

```tuck
fn memo(64) fib({n: int}) -> int [pure]:     # 64-slot cache
  if n < 2:
    return n
  let a = n - 1
  let b = n - 2
  return ({n: a} fib) + ({n: b} fib)

fn memo slow({n: int}) -> int [pure]: ...    # no size: warns, cache grows
```

A `memo` fn remembers its results by argument, so a repeated call with the same
arguments returns the stored answer. Recursive calls go through the cache,
which turns the exponential `fib` into a linear one.

- **With a size, `fn memo(N)`:** a fixed table of N slots per thread. A new
  entry that lands on an occupied slot overwrites it. A forgotten entry only
  costs a recompute, never a wrong answer, and memory never grows.
- **Without a size, `fn memo`:** every distinct argument list is kept forever.
  The compiler warns (`TK-EF09`) because that is a slow leak on a long-running
  program.
- **Requirements (`TK-EF08`):** the fn must be `[pure]`, non-generic, take
  only integer and bool parameters, and return an integer, bool or float.
  Strings, sequences and references are refused, because equal-looking values
  are not always equal and a cached copy would have to be owned.
- **Small input spaces become direct tables.** If every parameter is a `bool`,
  `u8`, `i8`, `u16` or `i16` and the whole input space is small (at most
  65,536 combinations, and at most N when you wrote `memo(N)`), the arguments
  index a table directly: no hashing, no stored keys, no collisions, nothing
  ever evicted. Such a memo cannot grow, so it gets no TK-EF09 warning. Entries
  fill on first call, never ahead of time, so an input that would trap is never
  evaluated unless the program calls it.
- The cache is per thread, so it needs no lock. That is correct because the fn
  is pure.
- It only pays when the fn costs more than hashing its arguments. For `x * x`
  a memo is slower, which is why it is explicit and never automatic.

---

## 4c. Property tests from the program: `tuck test`

```sh
tuck test file.tuck --properties [--cases:200] [--seed:1] [--except:a,b] [--out:FILE]
tuck test some/folder --properties        # every .tuck file under it
```

You have often already written both halves of a property test. A fn that
declares no capability effect is safe to call with any input (deterministic,
nothing to set up or mock), and a return type's `invariant:` block is the
property. `tuck test` finds every top-level fn in the file that

- declares no `io` or `may_block`,
- takes parameters it can generate (below), and
- returns a type that carries an `invariant:`,

calls each with generated arguments, and lets the invariant fire. Nothing is
marked in the source; the only control is the opt-out `--except:name,name`.

**What is generated.** Integers (in their type's range, small for the 32- and
64-bit types), `bool`, `f32`/`f64`, `str` (a small mixed set including the
empty string), fieldless enums, records and payload sums built from those,
`Seq[T]` and `T?` of them. A type that contains itself is not generated.
Values are chosen freely: a parameter type's own `invariant:` is *not* used to
steer them, so a generated value that breaks it fails where it is built, which
is the program's bug being found. The stream is seeded and repeatable, and half
of the cases lean on edge values (bounds, 0, 1, -1, an empty `Seq`, `none`).

**What you get.** Every case runs on its own, so you see how many fail, not
just the first:

```
flat: FAILED 6 of 30 cases
  {a: -2000, b: true} flat    # Invariant violated on Result: (self.total >= 0)
  ... and 3 more (see property-failures.txt)
fine: 200 cases, Result invariant held
```

`property-failures.txt` (or `--out:FILE`) holds every distinct failing call as
a Tuck call with its literals written out, with the violation after the `#`:

```
# downloader.tuck
{total: 1, parts: 0, i: 10, have: -1} spanOf    # Invariant violated on Chunk: (self.have >= 0)
{index: 0, first: 5, last: 3} Chunk ...
```

The exit status is 1 when any target fails. A fn that crashes on an input
(rather than violating the invariant) is reported the same way, with the crash
text. Parameters that are generic, or of a type the generator does not know,
leave the fn out.

---

## 5. Numbers are always named

Tuck never converts between numeric types behind your back, and never picks an
arithmetic meaning for you.

### Conversions are written: `~T` and `^T`

```tuck
fn setDuty({channel: int, permille: u16}) -> int:
  return permille ^int            # widening: cannot lose anything

fn main() -> int:
  let wide: u32 = 1200
  let narrow = wide ~u16          # narrowing: can lose a value
  let k = 300 ~u16                # a constant: checked at compile time
  ...
```

| sigil | means | checked |
|---|---|---|
| `x ~T` | this conversion **can** lose a value, and I checked it | refused if it cannot lose (`TK-TY40`) |
| `x ^T` | this conversion **cannot** lose anything | refused if it can (`TK-TY40`) |

So the sigil is a statement about direction, and the compiler verifies it. A
sign change is always `~`, even into a wider type (`i16 ~u32`). A constant that
does not fit is rejected at compile time: `70000 ~u16` is `TK-TY41`.

To find every place where accuracy can be lost, list them:

```sh
tuck check file.tuck --report-narrowing
```

### Literals adopt the expected type

A bare number takes the type its context expects, so you write `let n: u8 = 5`
without a cast. An operation between two *different* integer types needs a cast
on one side. There is no type named `float`: write `f64` or `f32`.

### Division is named

`/` is not an operator. Write `/i` for integer division and `/f` for float
division. Mixed operands are a type error, not a silent widening.

### Overflow is a property of the type

```tuck
type SafeRPM    = u16 [saturating]   # clamps at the maximum
type PacketSeq  = u8  [wrapping]     # wraps around
type ErrorCount = u32 [trapping]     # stops the program on overflow
```

Narrow integer types without an attribute **trap** on overflow, on all three
backends, including release builds. An overflow attribute implies `distinct`:
a `SafeRPM` is not interchangeable with a plain `u16`.

`[saturating]` clamps when the value is **stored** into the type. `a + b - c`
is computed exactly first and clamped once, so it does not depend on the order
of the operations.

---

## 6. Things that are special in Tuck

A short tour of behaviour that surprises people arriving from other languages.
`LANGUAGE-OVERVIEW.md` section 0 has the full table, each entry with the test
that proves it.

**Calls read left to right, with a named payload.**

```tuck
let response = request fetch parse selectEpisodes
{name: "ada", age: 36} greet
```

Every function takes one record and returns one record. A payload field fills
a parameter by name, or by type when that is unambiguous, so one function's
output can feed the next without renaming. Extra fields are ignored.

**A bare name is a call.** `getFive` invokes the function. `:getFive` is the
reference to it.

**`..` mutates; a range has spaces.** `server ..port {8080}` sets a field (or
calls a mutator) on `server` and reassigns it. `0 .. n` is a range. Whitespace
is what tells them apart.

**Value semantics, without copying.** Records are passed without a copy, but a
callee cannot write through a parameter (`TK-TY15`).

**Actors are singletons.** There is exactly one instance per declared actor
type: no construction, no reference. You talk to it by sending a message:

```tuck
actor Counter [queue: 128]:
  total: int = 0
  on add({n: int}):
    total += n

fn main() -> int:
  Counter send add {n: 1}
  return 0
```

Each `on` arm handles one message. The actor handles one message at a time and
nothing else touches its state. How actors get their threads is a build-time
choice (`--actors:thread`, `single`, or `batch`), not a source-level one.

**Tasks look synchronous.** A task is async code written in straight lines;
`[io]` marks where it may suspend.

**Interfaces are tagged copies.** An interface value owns its data and dispatch
is a switch on a tag, not a pointer through a vtable.

**Errors are values.** `!T` is a result and `?T` is an optional, and a fn
declares which error enums it may raise.

**Invariants stay on in release.** A violated invariant stops the program in
every build, as overflow traps and `[recursion: N]` do. Only an explicit opt-out
disables them.

**Compile-time structure is checked, not trusted.** Effects, ownership of slab
and arena cells, resource kinds and state-machine transitions are all verified
by the compiler. The pattern in this guide, a written declaration that the
compiler checks and a report that tells you what to add, is the one the whole
language follows.

---

## 7. What is not built yet

So you can tell a missing feature from a bug:

- **Compile-time evaluation of pure fns** (a `const` table built by a pure fn,
  and folding calls with constant arguments). It needs an evaluator for the
  scalar `[pure]` subset whose arithmetic matches the backends exactly.
- **Derived facts across modules.** The signature index records declared
  markers only.
- **D and Odin host attributes** for `pure` / `no_alloc` (Nim has the pure one).
- **Debug assertions** for the compiler's claims (a counter that would catch an
  extern that lied about `no_alloc`).
- **A lock-free mailbox**, so an interrupt could send to an actor. For now an
  `irq_safe` fn may not send; use a flag or ring buffer.
- **`no_alloc` gaps**: appends and copies are introduced after checking and are
  not seen, and building a record from a non-literal `Seq` or `str` field is
  not flagged. Calls are always covered by the call rule.
- **Timing.** The effect markers say nothing about how long a function takes.
