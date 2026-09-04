# doc-convert-tester — findings

## What was built

`docconv.tuck` builds exactly one thing out of the full APP.md ambition: the
"one `Codec` interface, many formats" claim. An `interface Codec` declares
`encode`/`decode`; two toy formats (`KvCodec` for `key=val`, `CsvCodec` for
`key,val`) each `satisfies Codec` with real hand-written encode/decode logic
(no real Markdown/HTML/CSV/JSON/TOML parsing — that needs `std.encoding`,
`std.i18n`, `std.testing`, none of which exist in the real compiler). A third,
harder format (quoted CSV) is stubbed as a `pending:` typed hole rather than
implemented. `checkRoundTrip` takes a `codec: Codec` (the interface type, not
a concrete type) and round-trips `decode(encode(x)) == x` through it — this
is the actual polymorphic-dispatch exercise, not a cosmetic detail.

## Missing stdlib functions needed

None needed beyond what `std/str.tuck` already has (`charAt`, `containsChar`,
`toStr`). `splitOnce`/`findSep`/`sliceStr` (manual string splitting on a
separator, built from `charAt` in a loop) are local to `docconv.tuck`, not
proposed as stdlib additions — they're toy-format plumbing, not a general
primitive; a real `std.encoding` would not implement CSV this way.

## Compiler bugs / friction hit

**Real bug, reproduced and isolated to a 17-line file.** Calling an interface
method that takes payload fields beyond `self` (e.g. `codec.encode {key, val}`)
through a value typed as the *interface* (not a concrete implementing type)
generates broken Nim.

Repro (`/tmp/tuck-doc-convert-out/repro.tuck`, kept out of the repo):
```tuck
interface Codec:
  fn encode({key: str, val: str}) -> str
object KvCodec:
  satisfies Codec
  fn encode({key: str, val: str}) -> str: return key + "=" + val
object CsvCodec:
  satisfies Codec
  fn encode({key: str, val: str}) -> str: return key + "," + val
fn run({codec: Codec, key: str, val: str}) -> str:
  return codec.encode {key: key, val: val}
```
`./tuck b` fails at the Nim stage:
```
repro.nim(30, 13) Error: type mismatch
Expression: encode(tmp, (key: key, val: val))
  [1] tmp: tuck_CsvCodec
  [2] (key: key, val: val): tuple[key: string, val: string]
Expected one of (first mismatch at [position]):
[1] proc encode(self: var tuck_KvCodec; key: string; val: string): string
[2] proc encode(self: var tuck_CsvCodec; key: string; val: string): string
```

**Root cause** (read, not edited): `compiler/codegen.nim`'s `genIfaceDispatch`
(around line 453-472) builds each dispatch-case arm as
`ic.member & "(tmp" & extra & ")"`, where `extra` (line 465) is
`", " & ctx.genExpr(e.dotArg)` — the whole payload record literal lowered as
ONE Nim tuple expression, e.g. `(key: key, val: val)`. But the concrete
implementing procs are emitted elsewhere (object member codegen) with payload
fields SPLATTED into separate positional Nim params:
`proc encode*(self: var tuck_KvCodec, key: string, val: string)`. The two
shapes don't match once a payload has fields beyond `self` — call site passes
one 2-field tuple where the callee wants two separate string args. This never
surfaced in `tests/suites/interface_dispatch.nim` /
`tests/suites/interfaces.nim` because every tested interface method there is
either self-only (`fn noise({self: Self}) -> int`, called as `a.noise` — no
`dotArg` at all, so `extra` stays `""`) or never actually dispatched through
an interface-typed value at a call site with extra payload fields. So: **the
one case this app exists to test — a real format-agnostic interface used
polymorphically with non-trivial method arguments — is the one case the
current interface-dispatch codegen doesn't handle.** `docconv.tuck` typechecks
clean (`./tuck ch` reports `OK`) but `./tuck b` fails with the error above at
`docconv.nim:69` in this app's own build.

Separately (already known, not new): a local variable named `out` in
`sliceStr` silently broke the Nim backend (`out` is a Nim keyword; the mangler
only renames global declarations, per the note in `hangman.tuck`/TODO.md).
Hit it once while writing the string-slicing helper, renamed to `acc`, moved
on — logging it here only to confirm the existing TODO.md entry is still live
and easy to re-trigger.

## Interface/mixin/actor design notes

- Writing the interface itself was pleasant: `interface Codec: fn encode(...)
  fn decode(...)` reads exactly like a Rust trait or Go interface, and
  `satisfies Codec` on each object is an explicit, readable conformance
  declaration (the "conformance is explicit, never structural" rule paid off
  immediately — a typo in a method's payload field name gets rejected at the
  `satisfies` site, not silently later).
- Adding a third implementer would be trivial *for the declaration side* —
  copy an `object` block, change the two method bodies. The blocker is
  entirely the dispatch bug above: any function that wants to treat codecs
  uniformly (the entire point of the interface) is currently unusable once a
  method takes more than a bare `self`.
- A **format registry** (name/extension -> `Codec` instance, so callers do
  `registry.get("csv").encode {...}`) is exactly the kind of object this app,
  `config-schema-validator`, and `git-lite` would likely all want — a
  singleton lookup table keyed by string, dispatching to one of several
  `satisfies`-based implementers. That smells like a good candidate for a
  shared `actor`-based registry pattern (one compile-time instance, globally
  addressable) if those apps converge on the same shape — flagging it rather
  than building it, since it's speculative until a second app actually wants
  the same lookup-by-name behavior. Given the dispatch bug above, though, any
  such registry would hit the identical wall the moment its methods take
  payload arguments.

## Joy-of-use verdict

Declaring the interface and its two implementers was genuinely pleasant — the
syntax is minimal and the conformance checking caught a mistyped field name
immediately, before I even tried to build. The friction was entirely on the
runtime side: the one thing this app exists to prove (dispatch a
non-trivial-arity method through an interface value) doesn't work yet, so the
"joy" here is really "confirmed the compiler's own thesis about itself" —
`./tuck ch` says the design is sound, `./tuck b` says the codegen for it isn't
finished. That's a useful, honest result for a dogfooding pass, not a
pleasant one.
