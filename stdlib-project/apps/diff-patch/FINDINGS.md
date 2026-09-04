# diff-patch — findings

## What was built

A small, real line-level diff of two text files: read `a.txt`/`b.txt` via
`std/fs`, split each into lines, run an actual O(n·m) LCS dynamic program over
the lines, backtrack it, and print unified-style `+`/`-`/unchanged lines. This
is a thin slice of the full `APP.md` ambition — no unified-diff hunk headers
(`@@ ... @@`), no patch-file parsing/application, no `--check` mode, no
fuzzy-offset matching. It exists to stress the language on a genuinely
non-trivial algorithm (LCS + backtracking), not to be feature-complete.

## Missing stdlib functions needed

Both gaps below were **hand-implemented as a workaround inside diffpatch.tuck**,
not stubbed with `pending:` — the algorithm itself is the point of this app,
so sketching it away would have defeated the exercise.

- **`seq`: growable append.** Proposed: `fn push[T]({items: Seq[T], value: T}) -> void`
  (mutates in place, same convention as `setAt`). Why: `std/seq.tuck` only has
  `at`/`setAt` — both require an already-sized `Seq`. There is no way to build
  a `Seq[T]` whose length isn't known as a literal at the call site. Worked
  around by preallocating fixed-size `Seq[str]`/`Seq[int]` literals (a
  `maxLines`-slot line list, a flat `(maxLines+1)^2` DP table addressed by
  `i*stride+j`) and tracking real length in a separate `count: int` — real
  code, but a hard ceiling: this app cannot diff a file with more than
  `maxLines` (8) lines without hand-editing the literal size.

- **`str`: line splitting.** Proposed: `fn splitLines({s: str}) -> Seq[str]`.
  Why: there is no way to split text on `\n` at all today — no `split`, no
  string-search primitive beyond `charAt`/`containsChar`. Worked around with a
  manual `charAt`-in-a-loop scan building each line by repeated `+`
  concatenation (see `splitLines` in `diffpatch.tuck`). This is exactly the
  kind of thing that should be a one-line stdlib call; writing it by hand
  works but is O(n^2)-ish (string concat in a loop) and it's logic every
  text-processing app will reimplement slightly differently.

## Compiler bugs / friction hit

1. **Unqualified `readFile` collides with Nim's own `syncio.readFile` in the
   emitted Nim, breaking the build — reproduced, exact error:**
   ```
   /tmp/tuck-diff-patch-out/diffpatch/diffpatch.nim(115, 20) Error: ambiguous call; both syncio.readFile(filename: string) [proc declared in /home/kl/apps/Nim/lib/std/syncio.nim(863, 6)] and tuck_rt.readFile(path: string) [proc declared in /home/kl/prog/tuck_lexer/compiler/tuck_rt.nim(366, 6)] match for: (string)
   ```
   Happens with `import fs` + unqualified `{path: ...} readFile` (the pattern
   most of this codebase's docs treat as the idiomatic unqualified-call
   style). `./tuck ch` accepts it cleanly — the ambiguity only surfaces at the
   Nim compilation stage, so `tuck ch` gives a false green light for this
   particular name. Root cause: the Nim backend emits the call as a bare
   `readFile(...)`, and Nim's `system`/`std/syncio` module auto-exports its
   own `readFile`, so any std module choosing that name collides.
   `writeFile` is equally exposed (Nim's `syncio.writeFile` exists too) but
   wasn't hit here since `diffpatch.tuck` never writes.
   **Workaround used:** call qualified as `fs::readFile` instead (matches
   `examples/24-stdlib.tuck`'s style). Fix candidates: mangle/prefix stdlib
   extern names in the Nim backend so they can't collide with Nim's own
   auto-imported names, or qualify all stdlib extern calls at emission time
   regardless of how the Tuck source spelled the call.

2. **A `const` cannot reference another `const` in its initializer, even
   through pure arithmetic.** Reproduced minimally:
   ```tuck
   const a = 8
   const b = a + 1
   ```
   ```
   Const Error: 'const b' must be a pure compile-time expression at line 2:1
   ```
   `LANGUAGE-OVERVIEW.md` section 1 states a `const` initializer just needs to
   be a *pure* expression (rejects `[io]` calls and `record` construction) —
   it doesn't mention this as a further restriction, and referencing an
   already-defined, purely-numeric `const` reads as unambiguously pure.
   Worked around in `diffpatch.tuck` by writing `const stride = 9` as its own
   literal instead of `const stride = maxLines + 1`, which duplicates the
   relationship as an unenforced comment instead of code.

## Interface/mixin/actor design notes

None of the three fit naturally here. There's exactly one algorithm and one
output shape in this slice — no polymorphism point for `interface` (a real
`APP.md` build with multiple *output formats* — unified diff vs. a
side-by-side view — would be a legitimate `interface DiffFormat` with one
`fn render({hunks: ...}) -> str` per implementer, but that's out of this
slice's scope). No shared behavior across types worth a `mixin`. No singleton
coordinator — nothing here wants to be one `actor`; every function is a pure
transform over its arguments. Confirms the task's own suspicion that
diff-patch doesn't need one.

## Joy-of-use verdict

The call-payload convention (`{...} fn`) and the postfix/dot sugar stayed
pleasant even inside a real nested-loop DP algorithm — no syntactic friction
writing `{items: dp, index: i * stride + j} at`. The actual pain was entirely
stdlib-shaped, not language-shaped: no line-splitting primitive and no
growable sequence turned what should have been a 40-line diff implementation
into ~90 lines of index arithmetic and manual char scanning. The `readFile`
name collision cost real debugging time because `tuck ch` reported clean and
the failure only appeared as a raw Nim compiler error two stages later — that
gap between "the tool that should catch this" and "the tool that actually
catches it" is the sharpest edge in the whole session.
