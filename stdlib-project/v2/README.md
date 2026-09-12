# stdlib v2 — contracts, satisfiers, verbs

Three kinds of module, and the rule that keeps big implementations swappable.

## The layout

```
value / collection / numeric / io / convert   contracts only — `group` declarations
ordering / seqops / text                      a concern: its satisfiers and its verbs
hash_fnv1a_num / hash_fnv1a_str               ONE algorithm each, interchangeable
```

A contract module imports nothing. Everything else imports the contracts it is
written against. Nobody imports downward.

`v2` is a directory, not a filename suffix: `import value.v2` is a parse error,
`import value` resolves to `value.tuck`, and imports resolve only within the
importing file's own directory (or `std/`). So every module that composes with
another sits here, flat.

## Swapping an implementation

A `group` names an operation; a module supplies it. Which module you import is
the choice of implementation, and it is the whole mechanism:

```tuck
import value
import hash_fnv1a_str     # or hash_xxh64_str, or a binding to an external lib
```

Nothing else in the program changes. A verb bounded by `[T: Hashable]` is
written once and works against whichever `hashOf` is in scope.

**One satisfier per group per program.** Tuck has no overloading: a second
`fn hashOf` in a module is "declared twice", and two imported modules both
exporting one is reported as a collision rather than silently resolved. That
is the guardrail, not a limitation — it makes "which hash is this program
using" a question with exactly one answer, visible in the import list.

The practical consequence: a hash module is per algorithm *and* per key kind,
because one `hashOf` cannot cover both `str` and numbers. `hash_fnv1a_num` and
`hash_fnv1a_str` are different modules for that reason, and a program picks the
key kind its maps use.

## What belongs in its own module

Anything big enough to have alternatives, or to come from outside:

- **hashing algorithms** — FNV-1a is here because it is small and adequate;
  xxHash, SipHash or a C binding replace it by changing one import
- **unicode tables** — case folding, normalisation and character categories are
  megabytes of data with real alternatives (ICU, a trimmed table, no table at
  all). `text` deliberately holds only the *codec*: UTF-8 and UTF-16 transforms,
  which are pure logic with no data behind them and no meaningful alternative.

A module that binds an external library is an `extern:` block exporting the
same names — the importer cannot tell the difference, which is the point.

## Encodings

`str` is UTF-8 and stays UTF-8: that is what all three backends' own string
type already is (Nim's `string` is bytes, Odin's is UTF-8, D's `string` is
`immutable(char)[]`). UTF-16 is a *conversion* at the boundary that needs it —
Windows wide APIs, Java/JS/C# interop, a UTF-16 file — not a second string
type, which would mean two of every verb. Rust, Go and Swift all make the same
call.
