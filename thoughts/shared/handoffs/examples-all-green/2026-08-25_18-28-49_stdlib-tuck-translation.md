---
date: 2026-08-25T18:28:49+03:00
session_name: examples-all-green
researcher: Kobi
git_commit: 172c68044339552b636ce20261ae0cc30328e917
branch: claude/spec-code-audit-34xh4q
repository: tuck_lexer
topic: "stdlib-project: translate the 72-module design corpus into real Tuck"
tags: [stdlib, translation, tuck, frictions, rulings, roadmap]
status: complete
last_updated: 2026-08-25
last_updated_by: Kobi
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: stdlib design corpus translated to Tuck; 11 frictions + 3 rulings recorded

## Task(s)

1. **Merge PR 3 conflicts** — COMPLETE. Merge commit `172c680`.
2. **Extend `stdlib-project/` with missing modules** — COMPLETE. 7 new modules
   (`sys.window`, `sys.audio`, `std.db`+`sqlite`, `core.geom`,
   `platform.watchdog`, `std.perf`, `std.queue`) plus 2 glue additions
   (`sys.fs::Lock`, `std.net-http::Cookie`). Module count 65 → 72.
3. **Domain/persona analysis** — COMPLETE (`DOMAINS.md`), incl. a corrected
   reading of "offline" (developer's registry access, not app runtime).
4. **Translate all 72 modules into real Tuck** — COMPLETE. Every module has an
   `API.tuck.md` beside its `API.nim.md`.
5. **Record compiler frictions** — COMPLETE (`FRICTIONS.md`, 11 items).
6. **Record user rulings in ROADMAP** — COMPLETE (3 rulings + 3 experiments).

## Critical References

- `stdlib-project/TUCK-TRANSLATION.md` — the shared findings. **Read first**;
  every module file assumes it.
- `stdlib-project/FRICTIONS.md` — compiler-facing findings with verbatim errors.
- `ROADMAP.md` — three new "User ruling (2026-08-24)" sections + "Experimental".

## Recent changes

- `ROADMAP.md` — appended: Experimental (D backend, slab allocator, SoA);
  ruling on no function overloading; ruling on explicit numeric conversion;
  ruling on optional variant sets in fn signatures.
- `LANGUAGE-OVERVIEW.md:780` — pointer rule expanded to the real three-way
  table (param/return/stored × cstring-Buf/opaque-handle).
- `LANGUAGE-OVERVIEW.md` §10, §13 — two new `⚠️ OPEN` callouts (generic actor,
  generic fnsig) and one on unchecked fnsig-slot stores.
- `stdlib-project/` — 72 `API.tuck.md` files, plus `COMPARISON.md`,
  `GOVERNANCE.md`, `DOMAINS.md`, `TUCK-TRANSLATION.md`, `FRICTIONS.md`.

## Learnings

**Tuck absorbs most of a Rust/Nim `core`+`alloc` tier.** ~1/3 of `core` and
7/10 of `alloc` don't translate — not for many reasons, for one: those tiers
are largely about handling *references* safely, and Tier 1 deletes references.
`Option[T]`→`?T`, `Unfilled[T]`→the `<uninit>` checker marker,
`addClamped`→`[saturating]` attribute, `sys.ffi`→`extern` blocks.

**Verified compiler facts (each reproduced, not inferred):**
- `compiler/typecheck.nim:263` `compatible()` ends `a.kind == e.kind`; all
  numeric primitives are `tkPrim`, so `u32` satisfies `u16`. A `strictKind`
  define already exists to measure tightening it.
- Only `[saturating]` has codegen. `[wrapping]`/`[trapping]` appear once
  (`compiler/codegen_common.nim:99`) in a list that merely implies `distinct`
  — behaviour is whatever the backend does.
- `bake` matches the signature declared on the record's slot — but **storing a
  mismatched fn into a fnsig slot is not checked** (call-through arity is:
  `tests/suites/typecheck.nim:1805`).
- Recursive sum types work through `Seq` (JSON tree builds); *direct*
  self-containment passes `tuck ch` then fails in Nim with
  `illegal recursion in type`.
- `Seq` emits as a plain Nim value param/return — no `sink` — so `..push` in a
  loop is O(n²) today.
- Top-level `satisfies Obj: Iface` works (`tests/suites/interfaces.nim:247`),
  but not on primitives (correct refusal, misleading message).

**Reserved words bite in identifier positions:** `pending`, `error`, `when` all
fail as field/fn names with "expected a field name", never naming the collision.

## Post-Mortem

### What Worked
- **Probing every construct against `./tuck ch` before writing it down.** Caught
  several things the docs implied but didn't hold (generic `fnsig`, generic
  `actor`, `satisfies` on primitives). Never trust a doc summary over the suite.
- **Reading `tests/suites/*.nim` as the authority.** `pointer_containment.nim`
  gave the real three-rule pointer story where `LANGUAGE-OVERVIEW.md` had a
  flattened one-liner.
- **One `TUCK-TRANSLATION.md` for shared findings**, per-module files reference
  it. Kept 72 files from re-deriving the same four rules.
- **Building and *running* one probe** (`TokenIssuer`) to confirm `self`
  mutation persists — typecheck alone would not have shown it.

### What Failed
- Tried: `fnsig Mapper = {x: T} -> U` as a workaround for generic fnsig →
  typechecks but `T`/`U` read as `Unknown`; a silent no-op. Recorded as a trap,
  not used.
- Tried: `bake` onto a bare record literal → no declared slot type to match.
  Corrected by user; the record needs a declared type.
- Error: assumed rule #4 ("passed without copying") covered `Seq` → it covers
  *records*. Corrected by reading emitted Nim.
- Several `sys`-tier conclusions were flagged by the user as wrong but not yet
  itemized — see Action Items.

### Key Decisions
- Decision: `map`/`filter`/`reject`, not `keep`/`drop`.
  - Alternatives: the Nim pass's `keep`.
  - Reason: user ruling — Ruby-ish, not Haskell-ish; `map`/`filter` are too
    widely understood to rename. Factor supplies the short-word half
    (`concat`, `append`, `take`, `any`, `all`).
- Decision: modules that can't translate get an `API.tuck.md` explaining *why*,
  flagged for deletion rather than deleted.
  - Reason: deleting a module is the user's call; the `API.nim.md` stays as the
    design record.
- Decision: write against the *intended* language where a gap is known
  (generic `fnsig`), marking it clearly.
  - Reason: explicit user instruction ("assume it'll be fixed").

## Artifacts

- `stdlib-project/TUCK-TRANSLATION.md`
- `stdlib-project/FRICTIONS.md`
- `stdlib-project/DOMAINS.md`, `COMPARISON.md`, `GOVERNANCE.md`
- `stdlib-project/INDEX.md` (updated: 72 modules, Extension round 4)
- `stdlib-project/modules/*/*/API.tuck.md` (72 files)
- `ROADMAP.md` (3 rulings + Experimental section)
- `LANGUAGE-OVERVIEW.md` (pointer table + 3 OPEN callouts)

## Action Items & Next Steps

1. **Corrections pass.** User said "you got it wrong with some of your
   conclusions" re: the `sys` tier — not yet itemized. Most likely suspects:
   the "no CPU parallelism" claim in `sys/thread/API.tuck.md` and
   `std/async/API.tuck.md` (inferred from the scheduler description, flagged
   provisional in one file but stated flatly in the other), and the
   dissolved-module verdicts that recommend deleting modules.
2. **Numeric conversion work, in this order** (per the ruling):
   a. Enforce no-implicit-conversion at binding sites — the `compatible()`
      line above. b. Implement `~`/`^` (and decide whether `to` exists).
   c. Implement `[wrapping]`/`[trapping]` for real, *then* decide the
      bare-primitive default — a default naming `[trapping]` is theatre until
      trapping traps.
3. **Two stdlib decisions that block implementation:** map/set key hashing
   (primitives can't satisfy `Hashable`; a `fnsig` hash slot looks most
   Tuck-idiomatic and needs no language change), and whether stateful values
   (`Dice`, `TDigest`, `Biquad`, `alloc.vec`) become `object`s with
   `self ..field` mutation instead of returning `{state, value}` pairs. The
   second affects ~12 modules and has one answer.
4. **Cheapest high-value compiler fix:** reserved-word diagnostics
   (`FRICTIONS.md` #5/#5b/#5c) — one message change, three papercuts.
5. **Variant-sets-in-signatures ruling** needs a syntax decision before
   implementation (angle brackets collide with nothing today but `[T]`/`[...]`
   are the existing bracket idioms).

## Other Notes

- **Four independent modules want a macro facility**: `std.serde-derive`
  (its whole content), `std.reflect`'s compile-time half, `std.testing::check`
  (needs the unevaluated expression tree to print both sides), and
  `platform.devicetree` (compile-time file reading). That convergence is the
  strongest evidence this exercise produced for anything.
- **Three capability regressions vs the Rust/Nim design**, all traceable to
  no-borrowed-views / no-threads: no zero-copy file scanning (`sys.mmap` —
  `log-grep`/`mp3-player` lose what they chose mmap for), no runtime symbol
  loading (`sys.dynload` — `dlsym` can't produce a callable), and CPU
  parallelism (see Action Item 1 — possibly overstated).
- **`secrets-vault`'s threat model currently survives in none of its three
  parts** — `Scrubbed[T]`, `SecureAllocator`, and `askSecret` returning
  `Secret[Text]` all lack Tuck counterparts. Largest security regression;
  belongs in one conversation, not three module footnotes.
- Scratchpad probes are in
  `/tmp/claude-1000/-home-kl-prog-tuck-lexer/f23c73ff-*/scratchpad/` — ephemeral,
  but the useful ones are quoted verbatim in `FRICTIONS.md`.
