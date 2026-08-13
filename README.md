# Tuck

A systems language for embedded and application work, transpiling to **Nim**
and **Odin**. Every piece of data flows through the system as a named struct;
the language restricts the shape of code so you can spend attention on the
shape of data.

```tuck
type ServerConfig:
  port: int
  timeout: u32

fn withDefaults({self: ServerConfig}) -> ServerConfig:
  var s = self
  s ..port {8080}
  return s

fn main() -> int:
  var server = {port: 0, timeout: 0} ServerConfig
  server ..withDefaults ..timeout {60}
  return server.port
```

## Start here

**New to Tuck — or auditing it? Read
[LANGUAGE-OVERVIEW.md](LANGUAGE-OVERVIEW.md) first,** especially §0 "What will
surprise you". It is the ground-truth document: every claim is backed by a
test or a run-gated example, cited by `file:line`, and it says plainly where a
feature is missing or half-built.

Several Tuck constructs behave differently from what a C/Go/Rust/Nim/Python
reader expects, and §0 lists them in one table. Skimming it costs a minute and
prevents the common failure: reading a working feature as a bug.

## The documents, and which to trust

The suite is the source of truth (`./run-all-tests.sh`). Prose drifts; these
are ordered by how much they have earned:

| Document | What it is | Trust |
|---|---|---|
| [LANGUAGE-OVERVIEW.md](LANGUAGE-OVERVIEW.md) | What the language DOES today, every claim cited to a test | **Highest** — written against the compiler, dated |
| [tuck-spec.md](tuck-spec.md) | The canonical spec: what the language IS, including designed-but-unbuilt parts | High, but describes intent — a section can be ahead of the code |
| [COMPILER-TOUR.md](COMPILER-TOUR.md) | How the compiler is put together, stage by stage | High |
| [MISSING-FEATURES.md](MISSING-FEATURES.md) | Open bugs and gaps, count checked against the suite by a test | Medium — a dated snapshot |
| [ROADMAP.md](ROADMAP.md), [TODO.txt](TODO.txt) | Planned work, rulings made | Medium — status lines go stale |
| [VISION.md](VISION.md), [ARTICLE.md](ARTICLE.md) | Why the language exists | Stable |

If a document and the compiler disagree, **the compiler is right** and the
document is a bug worth fixing.

## Build and test

```sh
nim c --hints:off -o:tuck tuck.nim          # build the compiler
nim c -o:tests/run tests/runner.nim         # build the test runner
./tests/run                                 # every suite
./tests/run typecheck value_semantics       # named suites
TUCK_REQUIRE_ODIN=1 ./tests/run             # insist the Odin backend is checked
```

`tests/run` builds `tuck` itself first, so the suite always runs against the
current tree. Without `TUCK_REQUIRE_ODIN=1` the Odin layer SKIPS when the
toolchain is absent, rather than failing — set it in CI, or an entire backend
can go unverified while the suite reports green.

```sh
./tuck check  file.tuck      # types + effects, no output
./tuck compile file.tuck     # emit .nim (add --odin for .odin)
./tuck build  file.tuck      # emit and link a binary
./tuck explain TK-TY15       # what a diagnostic code means, and how to fix it
```

Every diagnostic carries a permanent code (`TK-TY15`, `TK-RG03`). `tuck
explain` is the fastest way to learn a rule you just tripped.

## Layout

```
lexer.nim          text -> tokens
compiler/          parser -> rewrite -> typecheck -> semantics -> lowering -> codegen
  optimize.nim     OPTIONAL passes, off unless -O names them
  tuckrt/          the Odin runtime (the Nim one is compiler/tuck_*.nim)
std/               the standard library, in Tuck
examples/          44 programs, gated by the suite — the real corpus
tests/suites/      one .nim per suite; harness.nim holds the assertions
benches/           measurements, with SCORES.md as the ledger
```
