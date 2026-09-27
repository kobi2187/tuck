# Rulings needed — 2026-09-27

What the auto-mode pass after the doc-pass audit
(`2026-09-27-doc-pass-audit.md`) fixed, and the decisions it stopped at. Each
ruling below has what was found, the options, and a recommendation. The code
behind most of them is small once the decision exists.

Everything listed under "Landed" is on `claude/actor-throughput-profiling-sbfhq8`
(PR #94). The full suite passes, and the emitted examples change only where a
commit says so.

---

## Landed

**Wrong answers fixed**

| Commit | What |
|---|---|
| `052d3ea` | F1: a decision table grouped rows by lossy printed text, so different answers could merge. Rows now compare structurally. |
| `cd5b9cc` | #6: `=` on a register field was checked as a READ. `[read]` fields were writable and `[write]` fields refused. |
| `3ef8de5` | A2/#5: `return value` in a fn with no `->` is now TK-TY32. It used to emit a Nim proc that nim refused. |
| `8561a8b` | F2: object, type and mixin members were never held to their effect bracket, and an `[io]` member looked pure to its caller. Both fixed. The budget error now carries TK-EF01. |
| `03af142` | `fn poke({self: Self})` could not be called, and neither could any mixin member (LANGUAGE-OVERVIEW's own `double` example). `rewrite.nim` now binds `Self` and composes same-module mixins before the checker runs. |
| `204532b` | `xor` had no keyword (and Odin spelled it `^`, which is not an operator there). A `?T` operand of `and`/`or` passed the checker but built on no backend; it now lowers to `.ok`. A one-line body (`if c: n = n + 1`) was emitted at column 0 on Nim. |
| `c14fd45` | The transition check traced a fn's returned variants without counting a tail `match`, so an illegal transition could check clean. Lowering and the tracer now share one tail-value rule. |
| `e16865c` | Odin and D chose whether to cast a record literal's field by the first letter of the emitted type name. They now use the Tuck type. |
| `8ba9c7a` (part) | D hex literals such as `0xfe` got no `L` suffix, so D inferred a 32-bit `int`. `rollRange` was biased, and overflowed on the full `i64` range. |

**Cleanups** (`e3a3a60`, `5b7dc3f`, `8ba9c7a`, `3a3dc5d`, `ca28999`, `ce2c6dd`,
`3473939`, `29a0353`, `7bab626`)
- Removed `uoPropagate`, the AST member for the dropped `expr?` operator.
- `8ba9c7a` also deleted four unused declarations. **They were restored the
  same day on the owner's instruction** (unused code here is kept for later
  use, in particular the SSA mechanism's):
  - `tuck_rt.AccessMode`;
  - `ssa_ir.FreeKind` and `Value.freedAt` / `Value.freedBy`;
  - the `TUCK_DEBUG_MOVE=diff` move differential (`oldStampsIn`,
    `moveDiffReport`);
  - `Lexer.linesLen`.
- Removed seven duplicated helpers, and replaced three type-substitution walkers with one exhaustive walker.
- Diagnostics:
  - they name their position once;
  - they no longer recommend the dropped `?` operator;
  - `typeName` spells tuples and fn types instead of `<type>`;
  - an arena no longer checks clean (TK-ME02).
- Stale docs fixed: the missing-type sentinel, the SSA mirror's status, Beef-era wording, the actor runtime.
- `benches/cg_emit` builds again.
- `complexity.walk` became a fork counter. The HEAVY ratchet dropped from 13 to 12.

**Tried and reverted:** #4 / A1 (attribute words as names). See R4: it is a
real design tension, not a bug.

---

## Rulings

### R1 — `a and b or c` means `a and (b or c)`
`and`, `or` and `xor` share one precedence level, and each parses its right
side as a whole expression. So `false and true or true` is **false** in Tuck
but true in C, Python and Nim. It is not listed in LANGUAGE-OVERVIEW §0, and no
file in the corpus mixes these operators without parentheses today.
- (a) `and` binds tighter than `or`/`xor`, as everywhere else.
- (b) Mixing them without parentheses is an error (Pony's rule).
- (c) Keep it, and add it to §0.

**Recommend (b).** It can't silently change what anyone's code means, and it
costs one diagnostic.

### R2 — is a `?T` in a boolean position a presence test?
Spec §7.2 and ROADMAP say yes: "a `?T` in a boolean position reads as *is
present*", and pool `acquire` is "handled with an ordinary `if`". The compiler
disagrees with itself. `if a and b:` is accepted (and since today builds, as
`.ok`). A bare `if a:` is refused: "unhandled ?int in condition".
- (a) Accept `if a:` / `not a` too, lowered to `.ok` and narrowing like
  `if a.ok:`.
- (b) Require `.ok` everywhere, which means refusing `?T` operands of
  `and`/`or`/`xor` as well.

**Recommend (a).** The spec already states it. The extra work is that `if a:`
must narrow `a.value` the way `if a.ok:` does.

### R3 — a one-line `if c: s1 else: s2` with statement branches
R2 makes any `if` with two non-block branches a value-if, by syntax alone. When
the branches are statements, `if n > 9: n = 0 else: n = n + 1` checks clean and
emits invalid code on all three backends (a bare expression on Nim, a ternary
of assignments on Odin and D). Separately, `if c: x` followed by `else: y` on
the next line does not parse.
- (a) A value-if needs expression branches. An assignment or `return` branch
  makes it the statement form.
- (b) Refuse statement branches in the one-line form.

**Recommend (a).** It extends R2's syntactic rule the natural way: an
assignment is syntactically a statement.

### R4 — #4 / A1: attribute words (`priority`, `error`, `stack`) as names
TK-PA08's text promises they are "reserved only inside brackets, so usable as
fields, parameters and function names". Fields work. I made fn names, `::`
members and expression positions accept them too. That works on all three
backends, but it exposes why the words are reserved: `xs[stack]` is then read
as an attribute bracket and **the index is dropped**. `return xs[stack]`
type-checked as `return xs`, and only a type mismatch caught it. I reverted
the change.
- (a) Keep global reservation. Fix TK-PA08's text, rewrite the A1 test as the
  rule that stands, and refuse attribute-named parameters, which are accepted
  today but can't be read in the body.
- (b) A tight `x[...]` is always an index and a spaced `[...]` is always an
  attribute. Then the words are free everywhere. The corpus needs checking
  for tight attribute brackets.
- (c) Allow the words as fn names only. A call site is never inside a bracket.

**Recommend (a) now, with (b) as the route if you want the words back.** Also
note: the A1 test program declares a field `priority` and a fn `priority`
side by side. The fields-and-fns namespace rule rejects that pair, so the test
could never pass as written.

### R5 — #5: what omitting `->` means
Returning a value from such a fn is now refused (TK-TY32), so the only
question left is the meaning of the omission.
- (a) It means `void`.
- (b) Reject it; a return type is mandatory (TUTORIAL.md claims this).

**Recommend (a).** Effect-only procedures (`fn log({s: str}) [io]:`) read
naturally, and all three backends allow it.

### R6 — #7: full-mailbox policy (today: silently drops)
- (a) Block the sender (backpressure). In single mode the sender yields.
- (b) Drop, and say so in a diagnostic or counter.
- (c) Raise, which makes every `send` fallible.

**Recommend (a).** Dropping loses work silently, and raising puts an error
path on every send.

### R7 — #84: no ordering between two senders into one mailbox
Thread mode happens to supply an ordering that batch mode doesn't. Per-sender
FIFO holds in every mode.
- (a) No cross-sender guarantee: document it, and add #84's two-sender repro
  as a `bugOpen` specimen (the committed app no longer reproduces it).
- (b) An initialisation barrier: an actor processes nothing else until a
  declared `on start` has run.

**Recommend (a) now, with (b) if the pattern keeps biting.** R8 turns the
crash into a compile error either way.

### R8 — #85: an actor field with no initialiser is silently zero
Now unblocked: #87 (initialisers discarded) was fixed on 2026-09-25.
- (a) Every actor field has an initialiser or is `T?`. This mirrors the
  `<uninit>` rule for constructions.
- (b) Only types with no meaningful zero need one (a record holding a `Seq`,
  and so on).

**Recommend (a)**, because it is simple and needs no classification of types.
Cost: both `benches/apps` programs (`st: BookState`, `sl: Slice`) become
`T?`. Initialisers must be constants, so a call can't initialise them.

### R9 — S3.1 / #43: how `tuck build` reaches the no-invariants switch on Odin and D
- (a) Pass through `--odin:` / `--dmd:` flags.
- (b) A Tuck-level `--no-invariants` that each backend translates.

**Recommend (b).** It keeps one flag per behaviour, consistent with the rule
that runtime behaviour does not depend on the backend.

### R10 — `on select` arms have no effect bracket
The effect checker skips actor-level `on select` arms deliberately, so an
`[io]` call in an arm goes unchecked.
- (a) The bracket goes on the header: `on select [io]:`, and every arm is held
  to it.
- (b) Each arm carries its own bracket.
- (c) Arms are implicitly `[io]`, since a select is waiting on I/O.

**Recommend (a).** It matches how handlers declare effects, and it is one
bracket.

### R11 — composing a mixin from another module
`+ Helpers` works only for a mixin declared in the same module, as it did
before today's change. An imported one silently becomes a sketch. Copying its
body across modules needs its free names qualified.
- (a) Refuse it with a diagnostic for now.
- (b) Support it.

**Recommend (a) now.**

### R12 — smaller calls
- **Unused code stays.** `ChainOp.coDot`, `MatchArm.guard` and `tuck_coro`'s
  libaco branches are kept: code that is not used yet is library code meant
  for later use, and is not a removal candidate. (Owner's instruction,
  2026-09-27.)
- **Arena.** TK-ME02 is a warning so that example 13 still compiles. Keep it a
  warning until arenas exist? (Recommend yes.)
- **`benches/bench_phases`** needs `benchy`. Its pooled lower/emit timings
  read one semantic layer that every pooled typecheck resets, so its numbers
  are meaningless as written. Rework or delete?
- **Uncoded diagnostics.** 134 `fail("... Error")` sites have no `TK-` code
  (97 Type, 10 Conformance, 7 Decision, 6 Const, …). One code per rule, or one
  per category? Per rule makes `tuck explain` useful. Per category is a day's
  work.

---

## Observations (no ruling needed)

- **An intermittent test.** `invariants`, "a violation reads the same on every
  backend", failed in 2 of 5 full runs today and never on its own. The emitted
  code for that snippet is byte-identical before and after today's changes. My
  suspicion is the harness's `timeout 10` under full-suite load; the failure
  detail wasn't captured.
- **GitHub issues.** #20 is linked to PR #94 and closes when it merges. #73
  still has its Odin/D half open (MISSING-FEATURES A18), and #43 has R9 open.
  No manual closing is needed.
- **The lexer's `delete(0)`** is not quadratic in practice. The queue only
  ever holds one scan step's tokens, so the audit overstated it.
- **Remaining audit refactors**, untouched and each a mechanical session:
  - four signature printers;
  - two attribute-bracket parsers;
  - two module-loading walks;
  - the string↔enum tables;
  - per-compile state in module globals;
  - `resetResolution`'s hand-copied tables;
  - the 750-line driver `when isMainModule`.
