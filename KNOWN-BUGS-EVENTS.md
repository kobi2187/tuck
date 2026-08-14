# Event registry: bugs found 2026-08-14

Found while reducing cyclomatic complexity in the checker. Both are real,
both reproduce on a clean build, neither is fixed — the pass they turned up in
was meant to be behaviour-preserving, so they are recorded here instead.

The registry system (spec Part 10) is preliminary. These are the failure modes
its current shape produces, not a criticism of the design.

---

## EV-1 — a raise inside a TASK body emits garbage

**Severity: high.** Produces Nim that does not compile, with an error message
naming generated code the user never wrote.

### Reproduce

```tuck
registry AppEvents:
  | Boom({n: int})

on AppEvents.Boom({n: int}):
  let x = n

task work() -> void:
  AppEvents.raise Boom {n: 1}
  return

fn main() -> int:
  {} work
  return 0
```

`tuck ch` says `OK`. `tuck build` fails:

```
taskraise.nim(7, 3) Error: invalid indentation
tuck: nim compilation failed
```

### What is actually emitted

The same raise, in a `fn` versus in a `task`:

```nim
# fn work()   — correct
proc tuck_work*(): void =
  raise_tuck_AppEvents_Boom(1)

# task work() — garbage
proc tuck_work*(): void =
  Boom(tuck_AppEvents.raise)(1)
```

The task version is the **pre-lowering parse shape printed verbatim**:
`AppEvents.raise Boom {n: 1}` parses as a call whose callee is a call whose
single argument is a `.raise` field access. `lowering.nim`'s
`flattenRegistryRaise` exists to collapse exactly that into
`raise_Registry_Event`. It never ran.

### Why

`lowerModule` (compiler/lowering.nim:150) walks fn bodies and nothing else:

```nim
for fn in m.allFns():
  lowerExpr(fn.fnBody, m)
for d in m.decls(dkExpr):
  lowerExpr(d.expr, m)
```

`allFns` (compiler/ast_query.nim:152) yields `dkFn` only. A task keeps its body
in `taskBody`, a different field on the same variant object, so `lowerExpr`
never reaches it.

**This is already known and worked around one file over.**
compiler/rewrite.nim:153-156 says:

> Tasks are walked SEPARATELY: allFns yields dkFn only, and a task keeps its
> body in taskBody. Seven examples declare tasks, so a rule that skipped them
> would be silently half-applied. (lowerModule has this same gap — it walks
> allFns and never reaches taskBody.)

The parenthesis is the bug, written down and left.

### Why nobody noticed

Lowering has two transforms, and the other one is done twice. Payload
explosion (`{a: 1, b: 2} f` -> `f(1, 2)`) is performed by `lowerExpr`, but
codegen ALSO performs it independently from the checker's recorded mapping
(compiler/codegen.nim:311-318). So inside a task body the payload transform
still happens — verified, including scrambled field order `{b: 9, a: 8}`
correctly emitting `(8, 9)` — and only the registry-raise transform, which has
no second implementation, is missing.

That is why this reads as "tasks are fine" until you put a raise in one.

### Fix

Widen the walk in `lowerModule`, matching what rewrite.nim already does:

```nim
for d in m.decls(dkTask): lowerExpr(d.taskBody, m)
```

The deeper fix is `allFns` itself, whose own comment warns that per-site kind
lists are how `dkActor` came to be silently skipped — this is the same shape,
one level up. Anything that walks "every body in the module" through `allFns`
has this hole; `mangle.nim:285` and both codegens handle `taskBody` explicitly
and are unaffected.

---

## EV-2 — a raise inside a task body is never CHECKED

**Severity: medium.** A typo'd event name in a task passes `tuck ch` clean.

### Reproduce

```tuck
registry AppEvents:
  | Boom({n: int})

on AppEvents.Boom({n: int}):
  let x = n

task watch({fd: int}) -> void:
  on select:
    | read fd -> {}: AppEvents.raise Typo {n: 1}
    | timeout 5 -> {}: return

fn main() -> int:
  return 0
```

`Typo` is not a declared event. `tuck ch` reports `OK (2.2 ms)`.

The same raise at statement level in a `fn` is correctly rejected:

```
Semantic Error [TK-RG01]: registry 'AppEvents' declares no event 'Typo'
  — `raise` may only name variants the registry declares
```

### Why

Same root cause as EV-1, on the checking side. `checkRaiseSites`
(compiler/typecheck.nim, the registry pass) iterates `m.allFns()` and calls
`raisedEventsIn` on each `fnBody`. A task's body is never handed to it, so
none of the four registry rules — event exists, payload matches, no
self-raise, every event handled — is applied to raises in tasks.

`raisedEventsIn` itself was separately widened today (commit `e42e7e1`): it
used to list ten node kinds and `else: discard`, missing raises nested in
kinds it did not name. That is fixed. It does not help here, because the task
body never reaches the walker at all.

### Fix

Same as EV-1 — the caller must feed task bodies in. Both fixes are the same
one-line widening in two places, or one fix to `allFns`.

### Note on scope

The four registry rules are enforced only over the bodies `allFns` yields.
Worth auditing whether actor handler bodies (`dkActor` members) reach it —
`members()` (ast_query.nim:102) does yield actor members, so those are
probably covered, but it was not tested.

---

---

## EV-3 — the duplicate-mechanism pattern behind EV-1

Not a separate bug; the shape that produced one. Recorded because it recurs.

Three roles in this compiler have TWO implementations, one feature-full and
one simplistic. In each case the simplistic copy is the one with the hole, and
the feature-full one hides it:

| Role | Feature-full | Simplistic |
|---|---|---|
| payload explosion | `codegen.nim:311-318`, from the checker's recorded mapping | `lowerExpr`'s `explodePayload` |
| decision-table combinatorics | `codegen_table.nim:37` `columnDomains` | `typecheck_decisions.nim:57`, same loop, var out-params |
| AST traversal | `ast.children`, exhaustive and compiler-checked | ~8 hand-rolled walks with `else: discard` |

EV-1 is what this costs. Payload explosion inside a task body works — because
codegen does it independently — so `lowerModule` never walking `taskBody`
looked harmless for years. The moment a transform with no second
implementation (registry-raise flattening) took that path, it emitted garbage.

The decision-table pair carries its own irony: `codegen_table.nim:21` says the
constant is "shared so the two cannot disagree", and there are two constants.

The traversal pair is being closed as encountered — `clearIds`, `lowerExpr`,
`raisedEventsIn`, `scanReturns` and `mentionsName` now use `ast.children`.
Each had a different silent gap before.

---

## Not bugs, checked and cleared

- **`raisedEventsIn` missing node kinds.** Was real; fixed 2026-08-14 in
  `e42e7e1` by walking `ast.children` instead of a hand-written list of ten.
- **Payload explosion inside tasks.** Looked broken by inspection
  (`lowerModule` never reaches `taskBody`) but works, because codegen does the
  same transform independently. See EV-1's "why nobody noticed".
