# todo-cli — dogfooding findings

## What was built

`todo.tuck`: tasks carrying a `Priority` sum type, a `Seq[Task]` built by
`push`, completing a task by assigning through an index, rendering with
`match` + string building, and counting urgent tasks through a `match` with a
wildcard arm. Runs on all three backends. Out of scope from `APP.md`: file
storage, the filter query language, recurrence, undo — this slice exists to
stress COMBINATIONS (sum types + match + Seq + records + in-place update),
which is where the previous seven apps found their bugs too.

## Frictions found

Four, three of them the same silent shape: `./tuck ch` reports `OK`, and the
failure lands in the backend, naming generated code the author never wrote.

### 1. `xs[i].field = v` assigned into a copy — FIXED

```tuck
tasks[0].done = true
```
Typechecked clean, then: `'tuckAt(tuck_tasks, 0).done' cannot be assigned to`.
The read path resolves a bracket to a `tuckAt()` call, which returns BY VALUE,
so an assignment target built on one addresses a temporary. All three backends
had it (`rt.tuckAt(...).done = true` on Odin and D).

Fix: an assignment TARGET whose chain bottoms out in an index emits direct
indexing (`tuck_tasks[0].done = true`). Only the bracket case diverges;
everything else still goes through the normal emitter, so field vars and
stamped calls are unaffected. Bounds are then checked by the host language
rather than `tuckSeqBounds` — still checked, just not by us.

### 2. An empty list literal had no element type — FIXED

```tuck
var acc = []
for i in 1 .. 3:
  acc = {items: acc, value: i} push
```
Typechecked clean, emitted `@[]`, and Nim said `cannot infer the type of the
sequence`. `--verify-stages` caught it as an `<unknown>` leak, so the checker
knew and simply did not say.

Fix, two halves: an empty list now takes its element type from the
expected-type channel when there is one (`{xs: []} take` against a
`Seq[int]` parameter genuinely types as `Seq[int]`), and is REJECTED with
`TK-TY20` when nothing supplies one, naming the two ways out — seed it with
its first element, or pass it straight into the `Seq[T]` position. There is no
local type annotation to suggest instead, because Tuck has none.

### 3. A reserved word as a variable name said nothing useful — FIXED

`var pending = ...` reported `Expected variable name` while pointing straight
at a perfectly good-looking name. `pending` opens the `pending:` block, so it
is reserved — but the message never said so. `expectMemberName` already
produces exactly the right diagnostic (`TK-PA08`, "`pending` is a reserved
word and cannot be used as a name here") and is used for FIELD names; the
variable-binding site used a bare `expect(tkIdent)`. Now it does not.

This one cost the most time in the session, because the message sent me
looking for a problem with `[]` — which was fine.

### 4. A wildcard `match` arm did not compile on Nim — FIXED

```tuck
match t.prio:
  Urgent: urgent = urgent + 1
  _: discard
```
Emitted `of _:`. `_` is Nim's ignore-identifier and illegal as a branch label:
`the special identifier '_' is ignored in declarations`. Odin and D already
emitted their `default:` — Nim was the odd one out. Now emits `else:`.

## Frictions NOT worth fixing

- **`{items: xs, value: v} push` is verbose.** It is the value-semantics
  convention (`push` returns the grown seq rather than mutating), consistent
  with `std/random`'s threaded state. Working as designed.
- **A continuation line must indent by exactly one 2-space level** (`TK-LX06`),
  not by visual alignment under the opening brace. The diagnostic explains
  itself clearly; it is a house rule, not a defect.
- **`{self: t} complete` with `..` on `self` in a plain fn is rejected**
  (`TK-TY15`). Correct — the self-mutation exemption is for object members and
  actor fields, not any parameter that happens to be NAMED self. The message
  says exactly that and how to fix it.

## Interface/mixin/actor design notes

None earned a place in this slice. `Priority` is a fieldless sum with three
variants and one `label` fn — an interface would be one implementation per
variant for a function that is three lines of `match`. No shared coordinator,
so no actor. The `render`/`label` pair would only want an interface if a
second output format appeared (`renderJson`), which is the point at which
`doc-convert-tester`'s `Codec` shape becomes the right answer.

## Joy-of-use verdict

Better than the earlier seven-app pass, and the difference is measurable: the
things those apps reported as missing (`push`, `splitLines`, `charAt`, a real
hash) are there now, so this app never hit a wall it could not write around.
What remains is the same class every time — the checker permits a shape the
emitter only partly handles, and the report lands in generated code. Three of
four findings here were exactly that, and all three were invisible until
something was BUILT. `./tuck ch` passing continues to mean less than it looks
like it means, which is the strongest argument for building more apps rather
than reading more of the compiler.
