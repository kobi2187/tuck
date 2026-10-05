# Proposal: the ownership rules, written down once

2026-10-05. Owner, after the A39 report: "we need a more generalized mechanism
to consolidate all the bug fixes. I thought SSA was the solution but the
rules may need more formalization."

This document does four things:
- states the rules (§2);
- shows that every ownership bug on record is one of them broken (§3);
- says what each existing pass becomes (§4) and how to get there safely (§5);
- lists what needs a ruling (§6).

Nothing here is built.

## 1. Why the SSA mirror was not enough on its own

`thoughts/ssa-mirror-design.md` (2026-09-21) planned four stages:
- **A.** Build the value graph. Done.
- **B.** Read moves off it. Partly done.
- **C.** Turn each lowering into an explicit rewrite, so the emitters stop deciding. Not done.
- **D.** Let frees fall out of the graph. Not done.

The mirror answers *when* a value is last used, and it answers that well. It
never became the place where *what happens to the value* is decided. That
decision is still spread over the passes that predate the mirror. Each one
holds a private rule, and the rules disagree at the edges:

| decides | where | lines |
|---|---|---|
| copy at a binding | `lowering_seqcopy`, via `analysis_provenance`'s fresh/aliased lattice | 1 123 |
| free at scope exit | `analysis_ownership`, `ownership_escape`, `ownership_str` | 1 077 |
| move into a callee | `twin_shape`, `twin_calls` (the `f` / `f_moved` pair) | 371 |
| Nim `sink` | `codegen_common.keptAt` / `paramIsMovable` | ~125 |
| alias inside one call | `lowering_alias` | 142 |
| evaluation order | `lowering_field_order` | 94 |
| after the fact | `buffer_check` | 181 |

That is about 3 100 lines. They see heap through name lists
(`seqFieldNames`, `recordDupFields`, `exclusiveSites`, slot strings), so a
type the list does not describe is simply invisible to them. Every bug this
week was one of those edges:
- a generic record's slot list was empty (`1e79b46`);
- `sink` read a root stamp the mirror no longer makes (`11d1a40`);
- a provenance join forgot its parameter (`76bc292`);
- "escaped" was decided per name, so a take in one branch leaked on the other (the shelved take);
- a sum type has no slots at all (A39).

## 2. The rules

**Terms.**
- A type **owns** heap iff it is `Seq[E]` or `str`, or contains one: a record or object field, a sum variant's payload, an Array element, or a `?`/`!` payload. Recursive types are included.
- A **place** is a local, a path through one (`r.nodes`), a parameter, an actor field, a slab cell, or a mailbox slot.
- A **value** is one version of a place, as the mirror numbers it.

**U — every read of an owning value is a borrow or a sink.** A closed list,
one entry per node kind, with no `else`:
- **Borrow** (the read only looks): an operand, an index base, `.len`, an iterable, a condition, a match subject, an argument to a borrowing parameter, a reading member's receiver.
- **Sink** (the read is stored where it outlives the expression): a binding, an assignment, a construction field, a container element (`push`'s value, a list literal), a `return` or tail value, a `send` payload, an actor field write, a slab `new`/`set`, an argument to a consuming parameter.
- **A mutable borrow** is a third kind, an in-place write: `x[i] = v`, a self-writing member's receiver, the in-place append. It needs the place to be owned, which value semantics guarantees for a local.

**S — a sink moves at a final use of an owned place, and copies otherwise.**
- "Final" is the mirror's answer, read in written order (rule E).
- "Owned" means a local this body bound, or a consuming parameter. It never means a borrowing parameter, an actor field read by a handler, or a literal; those are copied into a sink.
- A temporary (a call's result, a construction, a literal list) is owned and used once, so it always moves. **There is no provenance question.** A call's result is the caller's: if the callee returned a borrowed parameter, rule S already copied it inside the callee.

**P — a parameter is consuming iff some final read of it (or of a path
through it) is a sink.** Otherwise it borrows. This is the least fixed point
over recursion, as `keptAt` computes it today, and there is one signature
per fn:
- the callee consumes;
- the caller applies S at the argument, moving a dead value and copying a live one.

Nim spells this `sink`. The `f` / `f_moved` pair is the same rule encoded as two procs.

**D — every owned place is dropped exactly once, at the end of its scope, on
every path, unconditionally.**
- Borrowing parameters, an actor's fields inside a handler, and literals are never dropped by the body.
- An assignment to an owned place evaluates the new value, then drops the old one, then stores. ("An overwritten value is freed after its replacement is built.")

**M — a move out of a place that is still to be dropped resets it to empty.**
- Dropping an empty value does nothing, so D needs no path reasoning. A value moved on one branch and kept on the other is dropped correctly on both.
- The reset may be left out where the place is provably dead on every path to its drop; that is an optimisation, not a rule.
- On Odin, D is a `defer` at the declaration, which already runs on every exit path, and M is `x = {}`.

**G — copy, drop and reset are derived from the type, once per type.**
- `Seq[E]`: a new buffer plus E's copy per element (a `memcpy` when E owns nothing); drop is E's drop per element, then free; reset is an empty header.
- `str`: clone; free unless static.
- Records, sums, Arrays and `?`: field by field, variant by variant, element by element.
- A recursive type gets recursive glue.
- **Backends:**
  - Nim already has `=copy`/`=destroy` for all of these, so it gets nothing new;
  - Odin gets emitted glue procs;
  - D gets the copy glue (deep `.dup`) and no drops, since its collector handles them.

**E — operands are evaluated left to right, as written, and "final" is
decided in that order.** Reordering is an optimisation. It may move a sink
later only past operands that cannot change the moved place: no chain, no
assignment, no call that might write that place's `self`.

**A — inside one call, a place given as a mutable borrow cannot also be read
by value.** The by-value read is copied to a temporary first (A23).

**T — a send is a sink into the mailbox.** The handler's payload parameter
consumes it; a field write in a handler is a sink into the actor. (The 2026-09-28 ruling: "actors send data, never pointers".)

**V — checked, not trusted.** After elaboration, a checker walks the mirror:
- every owned value is moved or dropped, exactly once on every path;
- nothing is used after a move;
- nothing borrowed is dropped.

This replaces `buffer_check`'s per-name approximation with a total check. The `TUCK_TRACK` gate (`odin_backend`) and the peak-RSS pins check the same thing at run time.

## 3. Every ownership bug on record, by the rule it broke

| bug | what happened | rule |
|---|---|---|
| EV-12 / #77 | Odin never freed a copy; 13.6 GB OOM | D |
| EV-13 | a `Seq` sent to an actor stayed shared (nim 42, odin 99) | T, S |
| EV-14 / #82 | a threading chain's dead intermediates were never freed | D (temporaries) |
| EV-15 | a dead container handed to a threading fn was still copied | S, P |
| EV-20 / #86 | every heap `str` leaked on Odin | G (`str`), D |
| PR #75 | twin predicate and analysis drifted apart: a use-after-free (14 then 48) | P: one predicate |
| `pick` | a twin's result skipped its copy and aliased another argument (65, not 17) | S: no copy elision on results exists |
| method receiver | `a.total` read no `a`; a moved `a` was then read (203, not 105) | U |
| `var t = xs` | a twin skipped the copy, and `t[0] = 99` reached `xs` | S: `xs` was not final |
| A23 | `k.absorb {other: k}` saw its own change (101, not 1) | A |
| #96 | a Seq moved into a record, or returned as a tail value, was freed too | M, D |
| A38 | a field handed to a twin was freed by the caller too | M, at path granularity |
| `1e79b46` | a generic record's Seq was invisible, so the return freed it (segfault) | G |
| `11d1a40` | Nim lost `sink` for any parameter read through a field | P over paths |
| `b04b116` | `{nodes: out, slot: out.len - 1}` copied on every return | E |
| `76bc292` | a wrapper's private copy was copied again and dropped (483 MB) | S: results are owned |
| `1531b60` | the runtime's task slots and waiters were never freed | D, for the runtime too |
| A39 | a recursive sum's boxes were never freed (111 MB) | G (recursive), D, S |
| shelved take | a take on one branch leaked on the other | M |
| 12 latent sites | in-place lowerings the copy decision never saw ("item 4") | E, U: in-place is a mutable borrow |

Twenty bugs, eight rules. More to the point, each rule sits in **one** place, so
the next bug of each kind has nowhere to come from.

## 4. What each pass becomes

One new pass, **`ownership_elaborate`**. It runs after lowering, on each
backend's private copy, before ownership is printed. It reads the mirror at
`ssLowered` and rewrites the tree with explicit nodes, which is the
`ssa-mirror-design.md` Stage C ruling: "the code they'll see passed to them
is simple".
- `exkCopy {src}` and `exkMove {src}` at sinks;
- `exkDrop {place}` at scope ends;
- `exkReset {place}` after a move.

Each emitter only prints:

| node | Nim | Odin | D |
|---|---|---|---|
| copy | `x` (Nim copies) | `tuckˑcopyˑT(x)` | `tuckˑcopyˑT(x)` (deep `.dup`) |
| move | `x` | `x` | `x` |
| drop | nothing | `defer tuckˑdropˑT(&x)` | nothing |
| reset | nothing | `x = {}` | nothing |
| consuming param | `sink T` | `T` | `T` |

| today | becomes |
|---|---|
| `lowering_seqcopy` + `analysis_provenance` | rule S in the elaborator; the lattice retires |
| `analysis_ownership` + `ownership_escape` + `ownership_str` | rules D and M: no escape analysis |
| `twin_shape` + `twin_calls` (`f` / `f_moved`) | rule P: one proc per fn |
| `keptAt` / `paramIsMovable` | rule P, shared by every backend |
| `lowering_alias` | rule A, inside the elaborator |
| `buffer_check` | rule V, the total checker |
| `lowering_field_order` | stays, as rule E's optimisation, now on every backend |
| the mirror, `analysis_liveness` (oracle) | unchanged: the elaborator's input and its check |

The elaborator, the glue and the checker are estimated at 1 000 to 1 200
lines, against about 3 100 replaced.

**What it costs at run time.**
- Twins go, and the number of copies stays the same: the wrapper's copy now happens at the caller, and only when the argument is still live.
- Resets are one store per move.
- Nested owning values (`Seq[Bag]`, `Seq[Seq[int]]`, recursive sums) get DEEP copies where today's are shallow. Today's are an aliasing bug kept latent only because nested values are rarely written in place, so this is the semantics, not overhead. It still gets measured (benches/containers, trees, apps) before switching.
- Nim changes nothing it already does, except that `sink` and field order come from the shared rules.

## 5. Getting there without a red day

Each phase ends green:
- on the full suite;
- on the tracked `odin_backend` gate;
- on every peak-RSS pin;
- on the benches against `benches/SCORES.md`.

This is the discipline Stages A and B used: compute the new answer beside the
old one, explain every difference, then switch.

0. **The rules in the code.** This document's §2 becomes the header of
   `compiler/ownership_rules.nim`, along with rule U's classifier. That is a
   `case` over every node kind with no `else`, so a new kind does not build
   until its use is classified. A suite asserts the classification of each
   kind.
1. **Glue (G)** for Odin and D, generated but not yet called. Tested under
   `TUCK_TRACK` on nested, generic and recursive types.
2. **Shadow mode.** The elaborator computes copy, move, drop and reset for
   the corpus, both applications, the Savina ports and the stdlib. It is
   diffed against today's decisions, and each difference is explained or
   fixed.
3. **Odin frees switch to D and M.** `analysis_ownership`,
   `ownership_escape`, `ownership_str` and `buffer_check` retire. Rule V
   runs under `--verify-stages`.
4. **Odin and D copies switch to S.** `lowering_seqcopy` and
   `analysis_provenance` retire.
5. **Rule P replaces twins.** `twin_shape` and `twin_calls` retire, and
   Nim's `sink` reads the same predicate.
6. **What falls out:**
   - A39 flips to `bugFixed` (recursive glue);
   - the shelved take lands (rule M), so `slab_thread` turns linear on Odin and D;
   - `odin_backend`'s tracked list loses its one exception.

## 6. Decisions for the owner

| # | question | recommendation |
|---|---|---|
| Q1 | Rules U, S, P, D, M, G, E, A, T and V (§2) are THE ownership semantics for every backend, decided in one pass | yes |
| Q2 | The decisions are explicit node kinds in the lowered tree (`exkCopy`, `exkMove`, `exkDrop`, `exkReset`) that emitters only print, not marks in side tables | yes: one construct, one node kind |
| Q3 | Twins retire for consuming parameters: one proc per fn; the caller copies only a live argument | yes |
| Q4 | A nested owning value copies deeply (today shallowly), which is value semantics, measured before the switch | yes |
| Q5 | `str` follows `Seq`: owned, cloned into a sink from a literal; a literal is static and never dropped | yes; refcounted sharing only if a measurement asks |
| Q6 | Migration through shadow mode and a corpus differential (§5) before anything switches | yes |
| Q7 | A39 waits for phase 6, not a separate fix first | yes: a fix outside the model would be a twenty-first rule |
