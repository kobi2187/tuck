# kv-store-server — findings (2026-10-27)

The first program in the tree split over four modules of its own (`kvmap`,
`kvproto`, `kvwal`, `kv`; about 510 lines), written for #107. It runs the same
session on Nim, Odin and D, and its crash recovery is tested by replaying a
committed snapshot and log (`tests/suites/apps.nim`).

## Compiler bugs it found, fixed

- **A99 (#189):** a `match` on a `str` with string arms did not compile on any
  backend; the pattern lost its quotes.
- **A100 (#190):** a qualified call (`kvmap::put`) skipped the ownership rules,
  so an argument the callee consumes was freed twice: a crash on start-up on
  Nim. Qualifying is what the next finding forces, so the two met at once.
- On Odin, `run`'s `match c:` was emitted as `switch &v in c` on a parameter
  ("cannot be made addressable"). It went away with the A100 fix and did not
  reproduce in isolation, so it is recorded here rather than pinned.

## Friction, in the order it cost time

1. **Name collisions across imports, with no way to import less.** No
   overloading (a ruling), so every shared name must be qualified or renamed:
   `files` exports a member `put`, `iter` (imported for `sort` alone) exports
   `find`. A selective import, `import iter (sort)`, would remove both. This
   is the one that will grow with program size.
2. **No multi-pattern match arm.** `"GET", "DEL": ...` is not syntax, so the
   dispatch repeats one arm per word. The AST has an or-pattern (`pkOr`, used
   by decision tables) and every backend prints it; only a spelling is
   missing, which is a ruling.
3. **A call inside a payload is refused (TK-PA13, by design).** Written about
   fifteen times out of habit and fixed by a `let` each time. The message is
   clear; the cost is real for anyone arriving from another language.
4. **The two standard libraries disagree on spelling.** `std/hash` has
   `hash({data})`, `stdlib-project`'s `core.hash` has `hashStr({data})`, so a
   module cannot move between them unchanged.
5. **`map` cannot be a field name**: it is an Odin keyword, and the error says
   so. A backend's vocabulary leaking into the language.
6. `alloc/map`'s `Table` finds a key by scanning every entry, so the app has
   its own hash map (`kvmap`, separate chaining over FNV-1a).

Not friction: the lone-`.ok`-guard rule (TK-TY46) caught a real misuse, and
`discard` covers ignoring an error on purpose.
