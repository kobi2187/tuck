# Rulings needed — 2026-11-24

Every open decision that blocks work, in one place: the audit's "Waiting on a
ruling" list (`docs/audit/LEDGER.md`) and the open GitHub issues that need a
ruling rather than code. Each item gives what happens today, the options, and a
recommendation. Answer with the item's ID and a letter: "Y1: b".

Ordered by the standing rule: memory first, then correctness (programs that
give different answers per backend, or hang), then syntax.

The recommendations lean on the principle restated on 2026-11-24: **fewer
forms, a simple language.** Where an option adds a form, the page says so.

Already decided today, recorded in `AGENTS.md` §3:
- a value `if`/`match` has no branch that returns;
- value branches and arms are inline, and an indented block is the statement form;
- a value `if` needs an `else`.

---

## 1. Memory

### M1 (#104.1): is an ordinary record's layout specified?
**Today:** unspecified. Each backend lays a record out as its host does.
- (a) **Unspecified**, except under `extern [c]`, where it follows C's layout
  of the declared fields in order. Hardware layout stays explicit (`register`).
- (b) Specified everywhere (declaration order, C alignment).

**Recommend (a).** (b) forbids each host's own reordering and buys nothing a
program can observe; FFI is the one place layout is visible, and (a) covers it.

### M2 (#104.2): does D pass a large record by reference?
**Today:** D emits plain by-value parameters, so a large record is copied at
every call; Nim and Odin pass it by hidden reference. Parameters are immutable
bindings, so by-reference passing is already safe.
- (a) D emits `in`/`ref const` for records above a size, chosen after measuring.
- (b) Leave it; D copies.

**Recommend (a), measure first.** `benches/bench_value_vs_ref.nim` is Nim only;
a D column comes before the change.

### M3 (#104.3): does D free promptly?
**Today:** D leaves frees to its GC. Results are identical; peak memory is
higher and frees are not at scope end. Spec §7.5 calls it a backend difference.
- (a) Keep the GC, documented.
- (b) D emits the same drops as Odin (ownership rule G), the GC as a backstop.

**Recommend (b) for embedded and long-running servers**, scheduled after the
Odin per-type drop work (#206), which it would reuse. This is the one item here
that is a project direction, not a rule.

---

## 2. Programs that give different answers, or hang

### Y1: `int`/`i64` overflow
**Today:** overflow traps on Nim, wraps on Odin and D; the docs say unchecked.
- (a) **Trap everywhere** (a program error with a message, like `/0` after Y2).
- (b) Wrap everywhere (two's complement).
- (c) Unspecified (keep the difference, document it).

**Recommend (a)**, kept in `--release` like the bounds check. It matches how
Y2/Y3 settled division and indexing; `[saturating]` and a wrapping type (if one
is wanted) are the explicit ways to get other behaviour. Cost: a check per
`+ - *` on Odin and D; measure on the Benchmarks Game before deciding.

### Y6: an out-of-range or NaN float `~int`
**Today:** Odin gives 0, Nim and D the minimum; a constant one Nim and Odin
refuse to build.
- (a) **Trap** (program error), and a constant one is a Const Error.
- (b) Saturate (NaN to 0, out of range to min/max), as Rust does.

**Recommend (b).** It is total, cheap, and one answer everywhere; a trap on a
conversion surprises more than it helps. (a) if Y1 goes to "trap" and you want
one story for arithmetic edges.

### Y18: `int` and `i64` in one expression
**Today:** the 2026-08-25 ruling says they never need a cast; open bug A116 says
the checker should refuse the mismatch; on `types/mix1` Odin returns 12 where
Nim and D return 0.
- (a) **`int` is `i64`**: one type, two spellings. No cast, one answer.
- (b) Distinct types; mixing needs a cast (A116's reading).

**Recommend (a).** Fewer forms: two names for one 64-bit integer cost nothing
to read, and the disagreement goes away by construction.

### C18 / #221: a `waitUntil` predicate over another actor's state
**Today:** a predicate is re-tested only when the actor it is registered with
handles a message. Reading a second actor's fields hangs under `--actors:batch`
on every backend and passes by timing under `thread` (`mixed_actors.tuck`).
- (a) **Register the wait with every actor the predicate reads**; any of them
  handling a message re-tests it.
- (b) Refuse: a predicate may read only the actor it is called on (a new TK).

**Recommend (a)** (the issue's own recommendation). The checker already walks
what a predicate reads; (b) breaks a reasonable program shape.

### C2, C4, C5: shared state across actor threads
**Today:** the documented "safe" read of another actor's public field can be torn
(`c_torn`, `c_seqrace`); a top-level pool and the resource registry are unlocked
across threads (`c_poolrace`, `r_res/race`).
- (a) **Another actor's field is read through a snapshot taken at its drain
  boundary** (a copy made by its own thread); pools and the registry take a lock.
- (b) Refuse cross-actor field reads; values move only by message.

**Recommend (b) for fields, (a) for pools and the registry.** Fewer forms:
"actors share by sending" is already the model; the read is the exception that
races. Pools and the registry are runtime structures and just need the lock.
Check how many programs read another actor's field before ruling; if many, (a).

### T9: transition checks across a loop
**Today:** spec §4.4b rules out a loop fixed point for variant sets, so a
transition legal on iteration 1 and illegal on iteration 2 passes.
- (a) **Compute the fixed point** (re-run the body until the variant sets stop
  growing; they are finite).
- (b) Keep the spec; document that loops are checked once.

**Recommend (a).** The sets are small and finite, so it terminates fast. It
removes a hole without adding a form.

---

## 3. Generics and types

### Y11: generic bodies
**Today:** a value of type `T` fits any slot inside a generic body; each
instantiation is checked only by the host compiler.
- (a) **Rigid type parameters**: in the body, `T` supports only what its bound
  says (an interface), checked once.
- (b) Re-check the body per instantiation.

**Recommend (a).** Errors land in the generic's own source rather than in a host
compiler's output, and interface bounds already exist.

### T13: may a type parameter bind a wrapper (`T?`, `!T`)?
**Today:** it may, so `len` takes a `Seq[int]?` without a guard.
- (a) **No**: a type parameter binds a plain type; wrappers are unwrapped first.
- (b) Yes, and the operand checks follow the wrapper through.

**Recommend (a).** The guard is the point of `T?`.

### Y8, second half: a `[saturating]` chain that is not stored
**Today:** a chain stored into a saturating type clamps (A177, spec §4.1). One
that is compared, passed or returned still wraps.
- (a) **Clamp wherever the expression's type is saturating**, not only at stores.
- (b) Keep spec §4.1 (stores only), document it.

**Recommend (a).** "Saturating" should not depend on where the value goes next.

### `-128 Temp`
**Today:** parses as `-(128 Temp)`, so on a saturating `i8` it is -127.
- (a) **A minus sign directly before a literal is part of the literal**
  (`-128 Temp` is the minimum).
- (b) Keep unary minus as an operator.

**Recommend (a)**, as Y4 already did for a bare `-128`.

### TK-TY16 holes: a partial record in a sum payload, a slab `new` missing a field
**Today:** the checker cannot follow either (`un/c11`, `sl2`).
- (a) **Refuse the store**: a payload or a slab cell takes a complete record.
- (b) Track holes through payloads and slab cells.

**Recommend (a).** Smaller and simpler; (b) is a new analysis for a rare shape.

---

## 4. Effects

### E4: does awaiting a task need `[io]` in the caller?
**Today:** an unmarked fn may await an `[io]` task (a hidden yield point);
`[pure]` is refused.
- (a) **Yes**: binding a task's result is a pause, which is an effect.
- (b) No: only the task's own body needs `[io]`.

**Recommend (a).** A yield point is exactly what effect brackets exist to show.

### E16: `on select` arm budgets
**Today:** arms are not checked against the actor's effect budget (pending F2).
- (a) **Each arm is held to the handler's budget**, like any body.

**Recommend (a).** No alternative seems worth keeping; listed for the record.

---

## 5. Syntax (issues)

### #196: several patterns in one `match` arm
**Today:** not writable; the AST and every backend already support or-patterns.
- (a) Comma: `"GET", "DEL": ...` (Nim's spelling).
- (b) Bar: `"GET" | "DEL": ...`.
- (c) Not added (one arm per pattern).

**Recommend (a).** A bar already opens an arm (`| Pat ->`), so (b) reads two
ways. (c) is the "fewer forms" answer if you prefer it.

### #198: a backend keyword as a field name (`map`)
**Today:** refused (TK-PA12) because Odin reserves `map`.
- (a) **The backends escape a colliding field name** internally; Tuck allows it.
- (b) Keep the refusal.

**Recommend (a).** It removes a rule rather than adding one: a Tuck author
should not need Odin's, Nim's and D's keyword lists.

### #201: `--release` enforces the 8-line budget
**Today:** `--release` fails a build over the size budget (TK-CX01/02).
- (a) `--release` optimises only; a separate `--strict` (or CI) enforces.
- (b) Data-only lines (record literals, a list of constructions) do not count.
- (c) **Keep it**: the budget is the principle, and `--release` is where it
  binds.

**Recommend (c), with (b).** Your stated principle is bounded, readable fns;
(b) only stops a table of initial conditions from counting as logic.

### #202: a call inside a payload (TK-PA13)
**Today:** refused by design (protects in-place append); the most frequent edit
in real programs.
- (a) Keep the rule; `tuck fix` inserts the `let` (exact, mechanical).
- (b) Allow nesting except where it would defeat in-place append.

**Recommend (a).** No language change, and the cost goes to zero.

### #57: blocks in single-expression positions
Today's rulings answer most of it: value positions are inline, and setup goes in
a `let` before the statement or in a fn. What remains: `decision` cells,
`const`, `static_assert` and list elements take one expression.
- (a) **Close #57**: one expression in those positions, by the same rule.
- (b) Pick one of the issue's options (A to F) for a block-as-value form.

**Recommend (a)**, consistent with today.

### #17: spelling of variant sets in fn signatures
Semantics ruled; `[T]` and `[...]` are taken.
- (a) `ProtocolStage<Login|Active>` (the issue's own sketch).
- (b) `ProtocolStage in {Login, Active}`.

**Recommend (a)** only if `<...>` is free in the grammar; otherwise (b).

### #15: a task's `on select` over a result in flight (`resp.ok`)
Needs a call that is started without being awaited, which spec §9.2 (binding
awaits) does not allow.
- (a) A `start` form returns a handle without awaiting.
- (b) Drop the task form; tasks select through an actor.

**Recommend (b)**, fewer forms, unless example 16 is a program you want.

### #203: rename a type at the import
**Today:** `import a {Box -> B}` is refused with "write `a::Box`".
- (a) Allow renaming types too.
- (b) **Keep qualification** as the one way.

**Recommend (b)**, fewer forms. The bare-nullary half of #203 is a bug fix, not a
ruling, and can be built as is.
