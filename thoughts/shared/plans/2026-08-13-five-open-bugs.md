# The five pinned bugs: what each one is, and how to fix it

> **Status 2026-08-13.** Three fixed and committed (bugs 5, 7, 4 in the
> numbering below — `alias` collision, Odin imported type, `select` silence).
> One item was withdrawn after being measured (bug 6's checker half). Two
> remain, both in the undecided group: bug 3 (missing required fields) and
> bug 6 (the parser). Open-bug count is now 4; §A of MISSING-FEATURES tracks
> it and `end_to_end` machine-checks the number.

All five were reproduced from a clean build on 2026-08-13. Every claim below
was observed, not inferred from the existing bug comments — two of those
comments turned out to name the wrong file.

The five are pinned as `t.bugOpen` in `tests/suites/known_bugs.nim`
(numbered 14-18 there, 3-7 in `MISSING-FEATURES.md` §A). Fixing one means
flipping its marker to `t.bugFixed`, which locks the behaviour in.

---

## The shape they share

Four of the five are the **same kind of mistake**: a code path that cannot
handle its input answers *silently* instead of refusing. Nothing is reported
at check time; the damage shows up later as broken generated code, or never.

| # | What the user writes | What they are told | What actually happens |
|---|---|---|---|
| 3 | `{} Config` (two required fields) | `OK` | fields become whatever the backend zero-inits |
| 4 | `on select` with a `timeout.5s` arm | `OK` | the whole handler body is deleted |
| 5 | `alias(a: title, b: title)` | `OK` | Nim rejects the emitted code |
| 6 | `cfg ..mod::fn ..f1 {60}` | `OK` | receiver is discarded; garbage emitted |
| 7 | imported type on Odin | `OK` | Odin cannot find the type |

The checker exists so the user never sees an error about code they did not
write. In all five, that promise is broken.

---

## Bug 3 — missing required fields are accepted

**Intent.** Ruling of 2026-07-09 (`ROADMAP.md:29`): "`Foo {}`: legal only when
the type has no fields. Types with fields require every field at
construction; absence must be explicit `?T`."

So `{port: 80, timeout: 5} Config` is fine, `{} Config` against a fieldless
type is fine, and `{} Config` against `Config` with two `int` fields must be
an error.

**How it strays.** `compiler/typecheck.nim:1634-1642`, in `synthCall`:

```nim
if calleeName != "" and not tc.fnSigs.hasKey(calleeName) and
   (tc.typeDecls.hasKey(calleeName) or tc.objDecls.hasKey(calleeName)):
  for a in e.args: discard tc.synthesize(a)   # types of supplied fields, checked
  return Type(span: e.span, kind: tkNamed, name: calleeName)
```

`synthCall` is an ordered chain of "is it this? is it this?" branches.
Construction is recognised *before* the function-call branch, and returns the
right answer — the declared type — while never comparing the supplied field
set against the declared one. The supplied fields get their types checked;
the *absent* ones are never looked for.

The comparison already exists twice for calls
(`typecheck.nim:300` and `:1408`, "missing required field '...'"), and the
generic-construction branch immediately above already reads the declared
fields via `getFieldsForType(tc.module, tc.typeDecls[calleeName])`
(`inferConstructionArgs`, `:1548`). Construction is the one path that reads
neither.

Verified: `tuck ch` on `{} Config` with `port: int, timeout: int` prints
`OK (1.8 ms)`, exit 0, no diagnostic.

**Fix.** In that branch, before returning: fetch the declared fields, and for
each one not supplied and not optional, fail with the existing message
wording. A field is optional exactly when its type is `?T` — `isWrapper` with
base name `"?"` (`typecheck_util.nim:69`). `FieldDef` has no default-value
slot, so required-vs-optional has no third case.

Zero fields declared and zero supplied stays legal — that is the ruling's
explicit carve-out, and it is the case a naive "reject empty `{}`" fix would
break.

**Risk.** This turns previously-accepted programs into errors. The corpus
must be run before the change is trusted: any example relying on zero-init is
either a real bug caught, or a place needing `?T`. Run the whole corpus first
and read every new failure before adjusting anything.

---

## Bug 4 — an unrecognised `select` arm deletes the body

The worst of the five: a program that looks correct, compiles clean, and does
nothing.

**Intent.** `on select:` waits on several sources and runs the arm that fires
first. Spec §9.3's own worked example uses this shape.

**How it strays.** `compiler/codegen.nim:1089-1112`:

```nim
var readArm, timeoutArm: ptr SelectArm = nil
for arm in e.selArms.mitems:
  if arm.source == "read": readArm = addr arm
  elif arm.source == "timeout": timeoutArm = addr arm
...
if readArm != nil and timeoutArm != nil:
  ...                       # the one supported shape
else:
  ind & "discard  # select: only read+timeout arms supported (first cut)"
```

Anything that is not exactly one `read` plus one `timeout` falls to a bare
`discard`. The arm bodies are never visited. The only trace is a code comment
in generated output the user never opens.

Verified: the §9.3-shaped program above emits exactly
`discard  # select: only read+timeout arms supported (first cut)` and `tuck ch`
reports `OK`.

Two separate defects sit here, and they need separating:

- **The gap** — `timeout.5s` (a dotted source) is an unbuilt feature, tracked
  as G3. Being unbuilt is acceptable.
- **The silence** — falling back to `discard` instead of refusing. That is a
  bug regardless of which arm shapes are eventually supported.

**Fix — the silence, now.** Replace the `else` branch with a hard compile
error naming the arm shape that was not understood, with its span. A new
diagnostic code is needed; `compiler/diagnostics.nim` has no
"construct not supported by this backend" code today.

**Design defect to fix at the same time.** `SelectArm.source` is a
`string` whose legal values live in a *comment*:

```nim
SelectArm* = object
  source*: string      # actor: message handler name. task: "read"/"timeout".
```

That is exactly why the bug is possible: `arm.source == "read"` is an
unchecked string compare with no compiler help, and every new source shape is
one more silent non-match. `source` is doing two unrelated jobs — an actor's
handler *name* and a task's source *kind*.

Better shape: make the kind an enum (`skRead`, `skTimeout`, `skHandler`, and
one explicit arm for anything parsed-but-unsupported), and keep the handler
name in its own field. Then the `case` over it is exhaustive, and a shape the
emitter cannot lower becomes a branch the compiler *forces* someone to write,
rather than a string that quietly matches nothing. This follows the
`exhaustive-case-no-else` rule already used elsewhere in the codebase.

Fixing the silence without fixing the string is possible, but leaves the trap
armed for the next source kind.

**Fix — the gap, separately.** Lowering `timeout.5s` is its own piece of work
and should not be bundled into the same change.

---

## Bug 5 — `alias()` never checks for collisions

**Intent.** `expr alias(old: new, ...)` restructures a record: the same values
under renamed fields. Two sources renamed onto the *same* target name is
incoherent — one value would have to win.

**How it strays.** `compiler/typecheck.nim:1473-1489`, `asAliasCall` builds
its result field list in a loop with no duplicate check:

```nim
for (oldName, newExpr) in e.args[1].fields.items:
  ...
  fields.add(FieldDef(name: newExpr.name, ...))   # no guard
Type(span: e.span, kind: tkRecord, fields: fields)
```

Twenty lines below, `asMergeCall` (`:1499-1514`) accumulates fields the same
way and *does* guard, calling `failIfDuplicateField` on every add.

The helper already exists (`:1491`) and does exactly the right thing. Note it
is defined **after** `asAliasCall` — in Nim that means alias literally cannot
see it without a forward declaration or a move. That ordering accident is the
most likely reason the check was never applied there.

Verified end to end: `tuck ch` says `OK`, the emitted Nim is
`var normalized = (title: ext.trackId, title: ext.category)`, and `nim check`
answers `Error: field initialized twice: 'title'`.

**Fix.** Move `failIfDuplicateField` above `asAliasCall` and call it before
each `fields.add`. Its message ("merge field ... collides between members")
must be reworded to serve both callers.

**Design defect.** Tuck has three paths that combine field sets — `+`
composition (guarded by `failIfComposedCollision`), `merge` (guarded by
`failIfDuplicateField`), and `alias` (unguarded). Three paths, two guards, two
different messages. The guard belongs at the single point where any path
appends to a field set, so a fourth combiner cannot be added without it.
Consolidating the two existing guards into one is the durable fix; wiring
alias into the existing helper is the minimum.

---

## Bug 6 — a qualified mutator in a chain destroys the receiver

**Both the bug comment and `MISSING-FEATURES.md` place this in codegen. That
is wrong — it is a parser bug, and codegen is faithfully emitting a broken
tree.**

**Intent.** `cfg ..bigmod::withDefaults ..f1 {60}` should behave like the
unqualified spelling, which works:

```
cfg ..withDefaults ..f1 {60}   ->   cfg = tuck_withDefaults(cfg)
                                    cfg.f1 = 60
```

**How it strays.** From `tuck p --ast`, the qualified version parses to a
chain whose **base is `exkQualified{modulePath: [""], qualName: "withDefaults"}`**,
with **one** step (`..f1`). `cfg` is gone. `bigmod` became an empty string.
The unqualified version parses to **two** steps with base `cfg` — confirmed by
dumping both.

The mechanism, in `compiler/parser_expr.nim`:

1. `cfg ..bigmod` → `chainMutation` (`:269`) builds
   `exkChain{base: cfg, steps: [..bigmod]}`
2. next token is `::` → `chainStep` (`:362`) dispatches to `chainQualified`,
   passing the chain node as `expr`
3. `chainQualified` (`:284`):
   ```nim
   let moduleName = if expr.kind == exkVar: expr.name else: ""
   Expr(span: sp, kind: exkQualified, modulePath: @[moduleName], qualName: name)
   ```
   The chain is not `exkVar`, so `moduleName` becomes `""` — and the function
   **returns a fresh node, discarding `expr` entirely.** Base and first step
   are dropped on the floor.
4. `..f1 {60}` then attaches to that orphan as a new chain

Downstream, the checker cannot save it either. `checkChainStep`
(`typecheck.nim:1122-1133`) asks `tc.fnSigs.hasKey(step.target.name)`; for a
name that never resolved there is no match, the receiver is `tkNamed` not
`tkRecord`, so the `elif` guard does not fire and **it falls off the end
without an error**. Codegen then finds no recorded step call and takes the
field-set branch (`codegen.nim:1031`), emitting
`<base>.f1 = 60` — which renders as `tuck_withDefaults.f1 = 60`.

**Fix.** Two independent holes; both should close.

1. `chainQualified`'s `else: ""` is a silent fallback that swallows a
   malformed parse. `module::name` is only meaningful when the left side is a
   plain module name. Either handle the chain-step case properly — build a
   qualified *step target* and leave the chain intact — or reject it with a
   real parse error. Silently rebuilding the tree around a discarded receiver
   is the one option that must go.
2. `checkChainStep`'s fall-through: a step matching neither a field nor a
   known fn must always fail, not only when the receiver is `tkRecord`. That
   guard is the reason a parser bug reached codegen unannounced.

Which behaviour to support — lower it like the unqualified form, or reject
qualified names in chain-step position — is a design decision the pinned test
leaves open. Fix (2) is correct either way and is worth doing first: it
converts this from silent garbage into a clear error.

**Design defect.** `chainStep` returns a replacement expression, so any branch
can discard its input without the type system objecting. A postfix
continuation should *extend* what it was given. Making the contract explicit —
each step takes the accumulated expression and must incorporate it — would
have made this unwriteable.

---

## Bug 7 — Odin: an imported type is emitted unqualified

**Intent.** Nim's `import` brings names in unqualified, so `tuck_Big` works
there. Odin never merges package scopes: a package member is always
`pkg.name`. The emitter already knows this and does it correctly for
*functions*.

**How it strays.** Verified emission for a program whose type comes from
`bigmod`:

```odin
package main
import "core:os"

tuck_main :: proc () -> int {
  cfg := tuck_Big{f0 = 1}     // Undeclared name: tuck_Big
  return cfg.f0
}
```

while the module emitted beside it is a separate package:

```odin
package tuck_bigmod
tuck_Big :: struct { f0: int, }
```

**Three faults, not one** (the bug note records only the first):

1. `tuck_Big` is written bare.
2. **There is no `import` for the module at all** — only `core:os`.
3. These are the same fault. Import emission
   (`codegen_odin.nim:2391-2394`) is gated on
   `if (pkg & ".") in body` — a **string search over the generated text**.
   Nothing emitted `bigmod.`, so no import was added. Fixing the
   qualification makes the import appear on its own.

The machinery to qualify already exists: `importedTypeQualifier`
(`codegen_odin.nim:124-136`), reached through `odinNamedFallback` (`:138`)
from `odinType` (`:184`). The emitted package is `tuck_bigmod` but the import
is aliased back to the Tuck name (`import bigmod "./mod_bigmod"`, `:2394`), so
`bigmod.tuck_Big` — what the pinned test asserts — is the correct target.

**Fix.** Find the construction path that emits the type name without going
through `odinType`/`odinNamedFallback`, and route it through. Then confirm the
import appears and `odin build` succeeds — assertion `emitsOdin` alone will
not catch a missing import.

**Design defect, and it is the serious one.** Two mechanisms here are
guesswork dressed as logic:

- **Provenance smuggled through `span.file`.** `importedTypeQualifier` decides
  whether a type is imported by string-matching a sentinel prefix in the
  *source-position* field: `d.span.file.startsWith(ImportedTypeMarker & ":")`,
  set in `modules.nim:319`. Any pass that rebuilds a decl or drops spans
  silently loses the origin, and the function fails **open** — returning the
  bare name, producing broken Odin rather than an error. Origin is a real
  property of a declaration and deserves a real field on `Decl`
  (`originModule: string`), not a tunnel through a diagnostic field.
- **Imports decided by substring search on generated code.**
  `(pkg & ".") in body` will add an import because the string appears inside a
  comment or a string literal, and omit one whenever qualification is missed —
  which is exactly what happened here. The emitter should *record* each
  package it qualifies against as it emits, then write imports from that set.
  That makes fault 2 impossible independently of fault 1.

Both are worth fixing while this area is open; the substring gate in
particular will keep producing this class of bug.

---

## Order of work

The five are independent — no shared code — so the order is by **how settled
the fix is**. One question decides it: does anyone still have to make a
choice? Everything requiring a decision goes last, however easy the typing.

### Decided — the correct behaviour is not in question

1. **Bug 5 — `alias()` collision.** The guard is already written
   (`failIfDuplicateField`), already used by the sibling path, and merely out
   of scope. Move it above `asAliasCall`, call it, reword the message to serve
   both callers. Nothing to decide: two fields named `title` is incoherent
   under any reading, and `nim check` already rejects the output.

2. ~~**Bug 6, fix (2) — the checker fall-through.**~~ **WITHDRAWN
   2026-08-13 — the premise was wrong.** Attempted, measured, reverted.

   The claim was that `checkChainStep`'s `elif recvT.kind == tkRecord` guard
   was too narrow, letting a step on a `tkNamed` receiver fall through
   silently. Two things disproved it:

   - The receiver in the failing program is never `Big`. The parser has
     already replaced it with the orphan `exkQualified`, and `synthQualified`
     (`typecheck.nim:2165`) returns `unknownType` for anything with a
     non-empty `modulePath` — our orphan carries `[""]`, length 1. So the
     base types as **Unknown**, `fieldsOf` returns empty, and gradual typing
     correctly declines to reject it. Widening the guard changes nothing.
   - Widening it is a no-op anyway: `synthChain` calls `tc.resolve(result)`
     first, which unwraps a named type to its structural record, so
     `recvT.kind == tkRecord` is *already* true for a declared type. Built a
     pre-change compiler to confirm — both versions reject
     `cfg ..nosuch {60}` identically.

   The real lesson is why this cannot be fixed in the checker at all:
   **gradual typing means the checker cannot distinguish "the user is
   sketching" from "the parser destroyed this tree."** Both arrive as
   Unknown. A malformed parse must therefore be rejected at parse time,
   because afterwards it is indistinguishable from legitimate incompleteness.
   That moves the whole of bug 6 into the undecided group below.

3. **Bug 7 — Odin imported type.** The target output is known exactly
   (`bigmod.tuck_Big`), the qualifier already exists
   (`importedTypeQualifier`), and the fn side already does it right. Route
   construction through `odinNamedFallback`. Verify with a real `odin build`
   — the text assertion alone will not catch the missing import.

4. **Bug 4, the silence only.** Refusing to compile a shape the emitter
   cannot lower is not a judgment call — a deleted handler body is wrong under
   every reading. Replace the `discard` fallback with a real error and a new
   diagnostic code. The `SelectArm.source` enum belongs in the same change:
   it is what makes the next silent non-match impossible.

### Undecided — needs a choice before it can be written

5. **Bug 3 — missing required fields.** The *ruling* is settled
   (`ROADMAP.md:29`) but the blast radius is not: this is the only fix that
   rejects programs compiling today. What is unknown is how much of the corpus
   leans on zero-init. Run the whole corpus first, read every new failure
   individually, and decide per case whether it is a real bug caught or a
   place needing `?T`. That reading is the work; the checker change is small.

6. **Bug 6, fix (1) — the parser.** Blocked on a genuine design decision:
   lower `mod::fn` in chain-step position like the unqualified form, or reject
   it outright. Both are defensible, the pinned test deliberately leaves it
   open, and fix (2) removes the urgency by making the failure loud.

7. **`timeout.5s` lowering (G3).** An unbuilt feature, not a bug. Out of scope
   here; item 4 only stops it failing silently.

Each fix flips its `t.bugOpen` to `t.bugFixed` and commits on its own; the
count in `MISSING-FEATURES.md` §A is machine-checked against the suite by
`end_to_end`, so the doc must be updated in the same commit.

## Reproductions

Kept in the session scratchpad: `b3.tuck`, `b4.tuck`, `b5.tuck`, `b6.tuck`
(plus `b6ok.tuck`, the working unqualified form for comparison), and
`b7/`. Each is the minimal program from the pinned test.
