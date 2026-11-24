# AGENTS.md

How to work on bugs, audit findings and correctness fixes in this repository.
These are the owner's standing instructions, kept from the audit work in
`docs/audit/LEDGER.md` (classes A–I). They apply to any agent, in any session.
`CLAUDE.md` and `ONBOARDING.md` still hold the build, test and architecture
rules; this file is about HOW to fix things.

## 1. Fix at the root, by class

- Investigate until you find the root cause, and fix it there. A fix at the
  symptom (one more special case at the site that crashed) is not a fix.
- Fix by CLASS, not by instance. When a finding is one case of a pattern
  (names used as identity, a call kind with no edge, a flag that is global
  where it should be per node), fix the pattern, then check every listed
  instance against the one fix.
- Add invariant assertions for the expected state — the information that must
  be valid and present on an object before and/or after each operation — at
  the stage where it must hold (`--verify-stages`, `assertCallEdges`,
  `tree_invariants`, `assert` on a pass's input). An invariant that would have
  caught the bug is part of the fix.

## 2. Never decide the language implicitly

- Do ONLY the items that need no language decision. A fix that changes what
  the language means, overrides something the spec states, or picks between
  reasonable semantics is a DECISION, and the owner makes it.
- When an item needs a decision: stop on that item, record it (task list and
  the ledger's "Waiting on a ruling"), and carry on with the rest. Do not
  adopt your own recommendation.
- Asking is fine; an answer of "no preference", silence, or an interrupted
  question is NOT approval. The owner will think these through separately.
- Signs that an item is a decision: the spec says otherwise (e.g. §4.4b rules
  out a loop fixed point), a new refusal of code that was legal by a stated
  rule, a runtime policy (overflow, trap codes, cross-thread access), or two
  fixes that would give programs different meanings.
- A fix that makes the checker enforce a rule the spec or a diagnostic
  already states ("the error is the READ, not the omission") is not a
  decision. Say which stated rule it enforces in the commit and the comment.

## 3. Standing rulings

- Name collisions are explicit errors. The user qualifies (`a::Size`,
  `a::Shape.Dot`); the compiler never renames a user's declaration to make a
  collision go away.
- A name with arguments in front of it (`{x: 1} f`) is a fn call. Fields are
  values. A fn reference is called/invoked differently (`:f`, `.invoke`).
- A program is Tuck on every backend or on none: something that builds on Odin
  and D but not on Nim (or any other split) is refused by the checker, not
  left to a host compiler.
- A value `if`/`match` gives a value on every branch. A branch that leaves the
  fn (`let x = if c: 5 else: return 0`) is refused, not an early exit
  (owner, 2026-11-24).
- A value `match` arm or value `if` branch may be an indented block; its last
  line is the value (owner, 2026-11-24: one rule for both, within the usual
  complexity and line limits). A value `if` needs an `else`. Lowered to the
  statement form by `lowering_block_arms`.

## 4. Organise the work

- Use the task list: one parent per class, one subtask per finding (or tight
  group of findings). Mark a subtask in progress when you start it and
  completed only when it is fixed, pinned and its suites pass. Deferred
  decisions get their own task.
- Keep `docs/audit/LEDGER.md` current: each fix gets a row (what, pin,
  invariant), each open decision a line under "Waiting on a ruling".

## 5. Prove each fix

- Reproduce first, on every backend it concerns (`tuck b`, plus `--odin` and
  `--dlang`); the three must agree with the right answer afterwards.
- Pin it in `tests/suites/known_bugs.nim` with the repro as the assertion and
  `bugFixed` (next free `A<n>`, a comment saying what was wrong and why).
  Include the VALID neighbours of a new refusal as passing assertions, so the
  fix cannot over-reach unnoticed.
- After a checker change, run `tools/corpus_check.sh OLD NEW` (OLD built from
  the commit you compare against): `tuck ch` over `examples/`, `std/`,
  `stdlib-project/` and `benches/` with each file's own flags. A new refusal
  there is either a real bug in that file or a sign the fix is too broad.
  Checking `stdlib-project/` or `benches/` WITHOUT `--stdlib:stdlib-project
  --root:` makes every file fail identically before and after, and hides
  exactly the regressions the check exists to find (it hid three once).
- After a codegen or ownership change, run `tools/emit_examples.sh` and read
  `git diff examples/`.
- Run the affected suites, then the full `./tests/run`. Never edit compiler
  sources or rebuild `./tuck` while a suite is running (the complexity gate
  and the stage-1 build read them); experiment with a separate binary.
- The complexity ratchet only moves down: when a change pushes a proc to
  `cc >= 15` or past the ceiling, split it into named helpers in the same
  change.

## 6. Report faithfully

- Commit messages and summaries say what changed and what was verified. A
  commit made before its suites finished says so. A failure is reported with
  its output, not rounded away.
- A finding that turns out not to be a bug is recorded as such, with the
  reason (e.g. "c16: Tuck has no string interpolation").
