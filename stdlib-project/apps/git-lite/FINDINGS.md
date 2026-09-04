# FINDINGS — git-lite

## What was built
A content-addressed blob store (`gitlite.tuck`, ~124 lines): a `GitObject`
interface, `Blob`/`Commit` implementers, a toy deterministic `weakHash`, and
dedup via `fs::fileExists`. `./tuck ch` and `./tuck b` both succeed; the
binary was run and confirmed: a dedup hit, byte-exact round trip, and a
commit record (message + parent hash + blob hash) hashed and stored the
same way as a blob. No `init`/`add`/`checkout` CLI, no compression, no real
cryptographic hash, no commit-graph traversal — all descoped per the task
brief.

## Missing stdlib functions needed
- `std/crypto` or `core/hash`: a real hash fn, e.g. `fn hash({data: str}) -> str`.
  The biggest gap — there is no way to turn a `str` into bytes or a number at
  all today. Not stubbed via `pending:` (a toy hash was explicitly in scope
  for this slice); `weakHash` is a real, working, deterministic toy built
  only from `charAt`/`containsChar`/`==` (maps each character to its index
  in a fixed alphabet — there is no `ord()`).
- `std/str`: a char→int accessor (`ord`), needed for any real byte-oriented
  hash or checksum. Worked around with a linear-scan `charIndex`, which is
  wrong for any character outside the fixed alphabet.
- `std/fs`: a directory-creation primitive (`makeDir`, ideally idempotent /
  mkdir-p). `writeFile` does not create parent directories, so a store
  cannot bootstrap its own `objects/` directory from Tuck alone — had to
  `mkdir -p` from the shell before running the binary. This is the one
  truly load-bearing gap for any app with an init step.

## Compiler bugs / friction hit
1. **`mod`/`div` as infix word-operators don't parse as binary ops** —
   swallowed by bare-call postfix sugar. Parenthesized form fails with
   `Expected 'RParen' here, found '1000000007'`. The unparenthesized form
   compiles but silently drops the right operand, emitting
   `mod(((acc*131)+v))`, which then fails at the Nim stage with
   `missing parameter: y`. `nimBinOp` in `codegen.nim:562-571` has real
   `boDivInt`/`boMod` cases that are simply unreachable from the parser.
   Worked around with a manual subtraction loop (`clampMod`).
2. **Same-named methods on different objects resolve to the wrong one
   outside interface dispatch.** `Blob.hash`/`Commit.hash`, called via
   `receiver.method` or `{self: x} method` (not through an interface-typed
   value), always resolve to whichever was declared LAST regardless of the
   receiver's actual type — contradicting LANGUAGE-OVERVIEW.md's claim that
   this overloads on `self`. Exact error: `argument to 'hash' expects
   Commit but got Blob`, even when the receiver genuinely was a `Blob`.
   Works correctly ONLY when called through an interface-typed value.
   Worked around by adding a `hashOf({obj: GitObject})` wrapper and always
   calling through it.
3. **A fallible call used as an implicit tail-return double-wraps** when the
   enclosing fn's return type is already that same `!T`: `got
   'TuckResult[TuckResult[tuple[]]]' but expected 'TuckResult[tuple[]]'`.
   Worked around with the explicit `let w = ...; if not w.ok: err w.err`
   guard shape (matches `examples/24-stdlib.tuck`).
4. **Minor doc bug, not a compiler bug**: `satisfies` must come immediately
   after `object Name:`, before any field — LANGUAGE-OVERVIEW.md's own `Dog`
   example puts a field first. The doc is stale.

## Interface/mixin/actor design notes
`GitObject` (hash/serialize) was clearly the right call and is a strong
candidate for a CROSS-APP shared interface — `diff-patch`,
`config-schema-validator`, and `doc-convert-tester` likely want the same
hash+store contract. Considered but did NOT build an actor-backed singleton
store for this slice — one caller, no concurrency, would be pure ceremony.
Worth reconsidering once a real multi-invocation `gl` CLI exists (a
genuine, not-yet-earned Manager candidate).

## Joy-of-use verdict
The call-chaining/payload-binding style fit this domain well and read
naturally. All friction was concentrated in three sharp, silent edges (no
usable `div`/`mod`, wrong-overload dispatch outside interfaces, double-wrap
on fallible tail-returns) — each cost a full stop-and-diagnose cycle, but
each had a small workaround once found.
