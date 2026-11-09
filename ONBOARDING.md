# Onboarding: read this first when you start a new thread

You are working on **Tuck**, a systems language whose compiler (written in Nim)
transpiles one checked AST into **Nim, Odin and D**. This file is the shortest
path from "I know nothing" to "I can write correct Tuck and change the compiler
safely". It points at the code so you can verify everything yourself; where it
and the compiler disagree, **the compiler wins** (trust order, from
`README.md`: compiler > `LANGUAGE-OVERVIEW.md` > `tuck-spec.md` > the rest).

Budget: 20 minutes to read the "must read" list in section 2, then work.

---

## 1. What the project is

* **A language** for programs designed top-down: name the big parts (interfaces,
  managers, actors), run the program with typed holes (`pending:`), fill them in
  later. Every function takes **one named payload struct** and returns one, so
  composition is data flowing left to right: `request fetch parse selectEpisodes`.
* **A compiler**: lexer -> parser -> rewrite -> typecheck -> semantics ->
  lowering -> codegen, to three backends from one checked AST
  (`COMPILER-TOUR.md` has the 8-stage pipeline and why each stage exists).
* **A standard library** in Tuck itself: `std/` (the core, small) and
  `stdlib-project/modules/` (the larger, tiered library: `core`, `alloc`,
  `std`, `sys`, `platform`). Each module has a `main` of self-checks that runs
  on all three backends.
* **Guarantees the compiler enforces**: value semantics (a callee cannot write
  through a parameter), declared effects (`[io]`, `[pure]` and other restrictions), no unhandled
  `!T` / `T?`, exhaustive `match`, ownership/last-use analysis (no GC, no
  borrow annotations), actors as the concurrency unit.

The owner's goals, in order: memory safety/ownership first, finish partial
features, defer missing features. Speed comes from the compiler/runtime, never
from micro-tuning programs.

## 2. Read in this order

Must read (in the repo root):

1. `CLAUDE.md` – build/test commands, invariants a change must not break.
2. `ROADMAP.md`, the section "THE WORK QUEUE" at the top – what to do next, and
   a list of traps that each cost a session.
3. `LANGUAGE-OVERVIEW.md` section 0 ("What will surprise you"), then sections
   2 (calls), 3 (types), 4 (errors), 10 (actors/tasks), 11 (effects),
   12 (modules), 13 (externs).
4. `MISSING-FEATURES.md` – the pinned open bugs (currently **0 open**) and
   what is known not to exist.

Reference when needed:

| Question | Where |
|---|---|
| How does the compiler fit together? | `COMPILER-TOUR.md` |
| What was the design intent? | `tuck-spec.md` (can be ahead of the code) |
| How do I learn the language by example? | `TUTORIAL.md`, `TOUR.md`, `examples/*.tuck` (each has its emitted `.nim`/`.odin`/`.d` next to it) |
| What does diagnostic X mean? | `./tuck explain TK-TY15` (registry: `compiler/diagnostics.nim`) |
| Effects, ownership | `docs/safety-and-effects.md`, `docs/ownership-and-ssa.md`, `docs/resources.md`, `docs/interfaces.md` |
| Stdlib decisions | `stdlib-project/DECISIONS.md`, `ROADMAP.md`, `DIRECTION.md`, `INDEX.md` |
| Which tests pin which behaviour? | `tests/suites/*.nim` (named after the feature; grep a suite name for evidence a behaviour is intended) |

Do not read whole Nim files. The compiler is large (`typecheck.nim` is ~6600
lines). Use the outline (`nimoutline file.nim`, if installed) or
`grep -n "^proc \|^func \|^template " file.nim`, then `Read` a line range.

## 3. Set up, build, test

Toolchains live in `~/toolchains` in these sessions (CI pins Nim 2.2.4, Odin
`b2354a04` on LLVM 18, dmd 2.112.0). If a command says `nim: not found`:

```sh
export PATH=/root/toolchains/nim/bin:/root/toolchains/odin:/root/toolchains/ldc2/bin:/root/toolchains/dmd2/linux/bin64:$PATH
nim c --hints:off -o:tuck tuck.nim     # build the compiler
./quick-test.sh                        # inner loop, check-only, ~2 s
./tests/run known_bugs end_to_end      # named suites
./tests/run                            # everything, ~8 min with all backends
./tests/run --bless                    # rewrite goldens (read the diff!)
tools/emit_examples.sh                 # after ANY codegen change; then read `git diff examples/`
./tools/cyc lexer.nim tuck.nim compiler/*.nim | head   # complexity, worst first
```

Running the compiler:

```sh
./tuck ch  f.tuck            # check only (types + effects)
./tuck c   f.tuck [--odin|--dlang]   # emit source for one backend
./tuck b   f.tuck [--odin|--dlang]   # emit and build a binary next to the file
./tuck p   f.tuck --ast      # the parse tree – first stop when a construct acts odd
./tuck b f.tuck --stdlib:stdlib-project   # build against stdlib-project's modules
```

`tuck b` writes generated files **next to the source**. Build in a scratch
directory (`mkdir /tmp/x`), not inside the repo.

## 4. Writing Tuck: the working subset you need first

A module is declarations only (no top-level statements). This program was
checked and run on the Nim backend; it exits 14:

```tuck
import seq

type Point:
  x: int
  y: int

type Shape:                       # a sum type; variants may carry payloads
  | Circle({r: int})
  | Rect({w: int, h: int})

type MathError:                   # an error enum
  | Negative

fn area({s: Shape}) -> int:
  match s:
    Circle: return 3 * s.r * s.r
    Rect: return s.w * s.h

fn half({n: int}) -> !{value: int} [io, error: MathError]:   # !T is fallible
  if n < 0:
    err MathError.Negative
  return {value: n /i 2}

fn find({xs: Seq[int], want: int}) -> int?:                  # T? is optional
  for i in 0 .. xs.len - 1:
    if xs[i] == want:
      return i
  return none

fn main() -> int [io]:
  var xs: Seq[int] = []
  xs = {items: xs, value: 7} push
  xs = {items: xs, value: 9} push
  let p = {x: 1, y: 2} Point
  let r = {n: 10} half
  if not r.ok:                    # a guard stands ALONE in its condition (TK-TY46)
    return 1
  let at = {xs: xs, want: 9} find
  if not at.ok:
    return 2
  let rect = {w: 2, h: 3} Shape.Rect
  let a = {s: rect} area
  return a + r.value.value + at.value + p.y
```

### The rules that explain most compile errors

* **Calls.** `{a: 1, b: 2} f`, `x f`, `x.f` and `f {a: 1}` are one convention: a
  payload flows into `f`. A bare name (`getFive`) **is a call**; `:getFive` is
  the reference. Payload fields bind by name, then by unambiguous type; extra
  fields are ignored; a wrong type is an error (`LANGUAGE-OVERVIEW.md` section 2).
* **TK-PA13: no call inside a payload.** `{n: x f} g` is refused. Bind to a
  `let` first. This is the single most common mistake.
* **Names.** Fields and fns share the call namespace: a field named `count`,
  `at` or `scale` can collide with a fn of that name. Reserved words you will
  trip on: `none`, `on`, `from`, `to`, `sealed`, `where`, `stack`, `priority`,
  `input`, `task`, `context`, `distinct`, `new`. Rename the parameter/field.
* **No operators for division or bits.** `/i` integer, `/f` float. Bitwise ops
  are functions in `std/bits`. No `\u` escapes in string literals.
* **Mutation.** `..name` on a `var` either sets a field or calls a mutator fn
  (first parameter is the receiver's type, returns that type, result reassigned):
  `server ..withDefaults ..port {8080}` (`examples/02-builder-mutation.tuck`).
  For Seqs the verified spelling is `xs = {items: xs, value: 7} push`. A range
  is spaced: `0 .. n` (inclusive; use `n - 1` for an upper bound).
* **Optional / fallible.** `.ok` guards, then `.value`; `.err` for the error.
  There is no `?` propagation: re-raise with `err r.err`. A fallible fn is
  `[io]`. `not <optional>` is an error (TK-TY49): write `not x.ok`.
* **Seq.** `Seq[T]` grows with the verbs in `import seq` (`push`, `pop`...); `a + b` on
  Seqs is refused (TK-TY48). An empty `[]` needs a typed binding (TK-TY20).
* **Effects are declared, not inferred**, at every level: `[io]`, `[io: net]`,
  `[pure]` and other restrictions The compiler tells you the exact marker to add (TK-EF01) or remove
  (TK-EF02).
* **No `try`, no destructors, no stored pointers, no `ref`.** Handles to
  foreign resources are small integers kept in shim-owned tables.
* **Imports are flat by file name** (`import seq`, not `import core.seq`).
  Two imports offering the same bare name is an **explicit error at the use**;
  qualify the call (`mod::fn`) or fix the definition. **Collisions are never
  resolved silently** (owner's standing rule). If the language cannot express
  the disambiguation you need, that is a design gap to record, not to paper over.
* **`case` over an enum takes no `else`** (compiler code): a new AST node kind
  must break every backend that has not handled it.

### Actors and tasks (concurrency)

```tuck
actor Counter [queue: 128]:
  total: int = 0
  on add({n: int}):
    total += n

# elsewhere:  Counter send add {n: 5}     Counter.total
```

Actors are singletons with a mailbox; `on` handlers are sent to, never called.
Stackful coroutines on a cooperative scheduler plus an epoll/kqueue reactor.
`fdRead`/`fdWrite` suspend only the calling task.

## 5. Writing tests for what you build

* Language-level behaviour: add an assertion to a suite in `tests/suites/`
  (`okCheck`/`badCheck` for the checker, `emits`/`omits` for text, `runs`/
  `outputs` for exit code/stdout; `t.quietly:` for an outcome you read with
  `bugOpen`/`bugFixed`). A bug is pinned *before* it is fixed:
  `bugOpen` (expected to fail), then flipped to `bugFixed` as a permanent guard.
  `MISSING-FEATURES.md`'s open-bug count must equal the number of `bugOpen`s.
* Stdlib modules: each `stdlib-project/modules/<tier>/<name>/<name>.tuck` ends
  in a `main` returning 0 when its checks pass; register it in the `Modules`
  list in `tests/suites/stdlib_project.nim`, which runs it on Nim, Odin and D.
* **Shim modules** (`extern [impl: nim "./shim/x", odin "./shim", d "./shim/x"]:`)
  keep three hand-written shim files (`shim/x.nim`, `shim/x.odin`,
  `shim/x.d`) with identical behaviour. Algorithm-heavy modules (crypto,
  compress, tz, sqlite, tls) are shims over vetted C libraries; basic building
  blocks (cli, http, env, process) are native Tuck on `std/sys` primitives.
  Handles are integers; bytes cross as `Seq[u8]`; a fallible byte result is
  `[0]`-prefixed ok / `[1]`-prefixed error.

## 6. How to change the compiler safely

1. Reproduce with the smallest `.tuck`, then `./tuck p --ast` and the emitted
   source of each backend.
2. Write the failing assertion first (suite + `bugOpen`).
3. Locate by the naming taxonomy in `typecheck.nim`: `synth*` returns a type,
   `as*` returns nil for "not mine", `check*` asserts, `fail*` raises,
   `collect*` builds tables.
4. Walk code with `ast_ops` (`allDecls`, `bodies`, `nodes`, `children`), never
   by hand. A call's callee is `ast_query.calleeDecl`, never re-derived from a
   name. Each construct gets its own AST node kind. Each backend lowers its own
   deep copy of the AST.
5. Pass order is load-bearing (typechecking resets the semantic side table;
   `semantics.nim` runs after it). Write new constraints on `checkOrDie` in
   `tuck.nim`.
6. After a codegen change: `tools/emit_examples.sh` and read
   `git diff examples/` – that diff is the review.
7. **Ratchets only move one way.** `tests/suites/complexity.nim`: ceiling 20,
   heavy (cc>=15) 10. If you exceed it, split a helper; do not raise it.
8. **Diagnostic numbers are permanent.** Add new codes at the end of their
   category in `compiler/diagnostics.nim` (latest TY code: TK-TY49) with a
   `tuck explain` text. Never reuse a retired number.
9. Run the affected suites, then `./tests/run`. CI (`.github/workflows/tests.yml`)
   builds Nim 2.2.4, Odin, D and runs the same suite on every PR.

## 7. Where things stand (update this section when it changes)

* Open pinned bugs: **0**. A105, A107, A108, A110, A112 were fixed after the
  stdlib week (call edges follow the module that owns the name; externs are
  filed per module; group satisfiers are matched by receiver type).
* The stdlib has a module for every planned design except `std.serde-derive`
  (deferred: needs compile-time type introspection) and the eight designs the
  owner dropped as dissolved (`alloc.box`, `alloc.rc`, `alloc.allocator`,
  `alloc.fmt`, `core.ptr`, `core.atomic`, `core.sync-cell`, `core.slice`).
* The live Bluetooth scan is untested (no adapter in the sandbox).
* **Next work, per the owner: only `std.testing` and property-test generator
  ergonomics** among the stdlib modules. Compiler bug fixes are in scope when
  found.

## 8. Working agreements

* Branch: develop on the branch the session names, push plain fast-forwards,
  open a **draft** PR if none exists. Commit message ends with the
  `Co-Authored-By` / `Claude-Session` trailers the harness gives you.
* Profile, do not guess; keep test timeouts short; test a gain by hand before
  building it into the compiler; no exotic tricks.
* Decide a new stdlib module by four questions: does it fit Tuck's rules? does
  a builtin make it superfluous? shim or Tuck? what is the testable core?
  (`stdlib-project/DECISIONS.md`).
* Report outcomes faithfully: a failing suite is reported with its output, a
  skipped step is said to be skipped.
* Do not commit generated output from building inside the repo (`.gitignore`
  covers app build output); do commit re-emitted `examples/` after codegen
  changes.

## 9. Known traps (each has cost a session)

* Reading a working feature as a bug: check `LANGUAGE-OVERVIEW.md` section 0
  and grep `tests/suites` for a suite named after it.
* Stale runner: never invoke `tests/.runner-bin` directly; use `./tests/run`.
* Adding a stdlib module mid-run: the suite collects modules at start; re-run.
* Odin: a `match` binding named like a parameter shadows it (fixed: bindings now
  live in the `tuckˑm<depth>` namespace); union payloads cannot be assigned
  through a by-value parameter.
* A name used in both `console` and `stream` (e.g. `readLine`) is legal in
  separate modules; a module importing both must qualify.
* `tuck b` inside the repo litters the directory with generated files.
