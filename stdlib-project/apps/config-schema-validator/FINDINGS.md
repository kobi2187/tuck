# config-schema-validator — findings

## What was built

A hardcoded `Config` record (name/environment/maxConnections/debug) checked
against three validation rules — required-field, int-range, enum-membership —
dispatched through one `interface Rule`, with every violation collected (not
just the first) and printed. No TOML/YAML parsing, no file/line/column
tracking, no rule registry file format — those are APP.md's full ambition;
this is the slice needed to exercise `interface` for real against the current
compiler. `stdlib-project/apps/config-schema-validator/validate.tuck`
typechecks (`./tuck ch`) and builds and runs correctly for both an invalid
sample config (3 violations reported) and a valid one (`config is valid`).

## Missing stdlib functions needed

None. Everything used (`str.toStr`, `console.printLine`) already exists in
`std/`. No `pending:` stubs were needed — the whole app is real code against a
hardcoded record, which is the intended scope reduction from APP.md's real
TOML/JSON parsing.

## Compiler bugs / friction hit

Four real, reproduced bugs. All four are why the final `validate.tuck` looks
the way it does — each is called out in a comment at its workaround site.

**1. A sum-type variant constructed with a `?T`-wrapped target type silently
drops its payload fields.** Minimal repro (`tuck c`, single variant, no
sharing):

```tuck
type V:
  | MissingField({field: str})

fn check({x: int}) -> ?V [io]:
  if x < 0:
    return V.MissingField {field: "name"}
  return

fn main() -> int [io]:
  let r = {x: -1} check
  if r.ok:
    {text: r.value.field} printLine
  return 0
```

Emitted Nim: `return tok(tuck_V(kind: MissingField))` — no `field: "name"` set
anywhere, even though the exact same construction (`V.B {field: "hello-B"}`)
returned directly from a *non-optional* fn emits the field correctly
(`tuck_V(kind: B, b: (field: "hello-B"))`). The bug is specific to the target
type being `?T`-wrapped at construction time. Binding the construction to a
`let` first and returning that doesn't help — the loss happens at
construction, not at the `tok()` wrap.

**2. `match`-narrowed field access on a sum type reads the FIRST declared
variant's storage, not the matched arm's — a runtime `FieldDefect` the moment
two variants share a field name.** Minimal repro (`tuck b`):

```tuck
type V:
  | A({field: str})
  | B({field: str})

fn describe({v: V}) -> str:
  match v:
    A: return v.field
    B: return v.field

fn main() -> int:
  let v = {field: "hello-B"} V.B
  let s = {v: v} describe
  return s.len
```

Both arms emit `v.a.field` (the codegen for `.field` inside a match arm
resolves to whichever variant declares it *first* in the type, not the arm's
own tag). Typechecks fine; crashes at runtime:
`Error: unhandled exception: field 'a' is not accessible for type 'tuck_V'
using 'kind = B' [FieldDefect]`.

**3. Interface dispatch codegen wraps an extra payload field into a Nim named
tuple instead of passing it positionally, when the interface method takes a
param besides `self`.** Minimal repro (`tuck b`):

```tuck-rejected
type Config:
  n: int

interface Rule:
  fn check({self: Self, config: Config}) -> int

object A:
  satisfies Rule
  fn check({self: A, config: Config}) -> int:
    return config.n

object B:
  satisfies Rule
  fn check({self: B, config: Config}) -> int:
    return config.n + 1

fn total({rules: Seq[Rule], config: Config}) -> int:
  var s = 0
  for r in rules:
    s = s + r.check {config: config}
  return s

fn main() -> int:
  return {rules: [{} A, {} B], config: {n: 10} Config} total
```

Emitted Nim, every branch of the dispatch: `check(tmp, (config: config))`
against `proc check(self: var tuck_A; config: tuck_Config)` — a straight type
mismatch (`tuple[config: tuck_Config]` where `tuck_Config` is expected). A
bare (unbraced) `r.check config` is worse — it drops the argument entirely
(`check(tmp)`, missing required param). Only `self`-only interface methods
dispatch correctly through a `Seq[Interface]` loop today.

**4. A bare `return` in a `?T`-returning fn does not produce "absent" — it
reads back as present, with zero-valued fields.** Minimal repro (`tuck b`):

```tuck
type V:
  field: str

fn check({x: int}) -> ?V [io]:
  if x < 0:
    return {field: "bad"} V
  return

fn main() -> void [io]:
  let r = {x: 5} check
  if r.ok:
    {text: "present: " + r.value.field} printLine
  else:
    {text: "absent"} printLine
```

Called with `x: 5` (the non-triggering path, a bare `return`), this prints
`present: ` — `r.ok` is `true` with an empty `field`, never `absent`. Root
cause found in `compiler/tuck_rt.nim:54-59,123`: `TuckStatus`'s first variant
is `tsOk`, so a Nim proc falling through a bare `return` returns its
zero-valued `TuckResult` — whose `status` defaults to the enum's first member,
`tsOk`. `tuck_rt.tnone[T]()` exists for exactly this ("absent" status) but
`grep -rn tnone compiler/*.nim` shows it is defined and never emitted by any
codegen path — a bare `return` in an optional-returning fn needs to lower to
`return tnone[T]()`, not fall through to Nim's own bare `return`. This is the
most consequential of the four: it silently inverts the meaning of the
success path for every `?T` fn whose "nothing to report" case is a bare
`return`, which is the natural way to write one.

Given bugs 1+2, `Violation` was reduced from a sum type to a plain record.
Given bug 3, `interface Rule.check` takes only `self`, with each rule's
target value baked into the rule object at construction instead of passed
alongside. Given bug 4, "no violation" is an explicit `found: bool` field on
`Violation` rather than a `?Violation` return — confirmed correct for both the
invalid- and valid-config paths by actually running the built binary.

One additional (non-blocking) friction point: `Seq[Interface]` list literals
only pick up the interface type when each element is first bound to its own
`var`/`let` — `[{} A, {} B]` inline inside the list literal keeps its
concrete-type unification and fails against a `Seq[Rule]` parameter, while
`var a = {} A; var b = {} B; [a, b]` works. `tests/suites/interface_seq.nim`
already exercises the working (pre-bound) form, so this isn't a regression,
but it's a real ergonomic trap for the first thing someone tries to write.

## Interface/mixin/actor design notes

Interface dispatch itself — `interface Rule: fn check({self: Self}) -> ...`,
three objects `satisfies Rule`, a `Seq[Rule]` loop calling `rule.check` — is
genuinely pleasant once shaped around bug 3's constraint (self-only methods).
The tagged-variant-that-copies design (LANGUAGE-OVERVIEW.md section 5) is
exactly the right model for "several unrelated validation strategies, one
dispatch point" — no vtable ceremony, and a `Seq[Rule]` reads as a real
heterogeneous list.

No mixin was reached for — the three rules share no behavior, only a
contract; a mixin would have meant giving them fields, and mixins are
fns-only by design.

No actor was reached for, and I flag it explicitly per instructions: a
project-wide **rule REGISTRY** (something every app's rules register into,
rather than being assembled into a `Seq` by hand at the call site) is a
plausible cross-app shared shape — `spellchecker`, `sudoku-solver`, and
anything else running "N independent checks over one value" would want the
same registration + run-all pattern. I did not build it; it would need to be
a genuine singleton coordinator (`actor`-shaped) rather than a per-call `Seq`,
and that's a bigger design decision than this app's scope.

## Joy-of-use verdict

The core call syntax (payload structs, postfix chaining, `..` mutators) is
pleasant and reads naturally once you stop reaching for a leading verb. But
this app hit four independent, silent-or-crashing bugs in the *combination*
of `interface` + optional/sum-type returns + payload dispatch — every one of
which would be very hard for someone without the compiler's own source open
to diagnose (bug 4 especially: it doesn't error, it just returns the wrong
answer). Each individual feature (`interface`, `?T`, sum types, `match`) has
a suite entry proving *some* shape of it works; the specific combinations a
"several validators, one report" app naturally reaches for are exactly the
untested seams. Once routed around all four, the resulting program is small,
honest, and does real work — but this is not a stdlib gap, it's the compiler
declining to do the thing the language's own vocabulary suggests you should
write.
