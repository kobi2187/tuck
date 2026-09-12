# stdlib v2 — contracts, satisfiers, verbs

Three kinds of module, and the rule that keeps big implementations swappable.

## The layout

```
contracts only — `group` declarations, no code:
  value        Equatable Comparable Hashable Showable Cloneable        (+ Order)
  numeric      Addable Subtractable Multipliable Divisible Negatable
               Bitwise Shiftable Absolute
  math         Rounded Rooted Transcendental Checked
  collection   Countable Emptyable Clearable Indexable[E] Sliceable[E]
               Appendable[E] Removable[E] Keyed[K,V] SetLike[E]
               Iterator[E] Buildable[E]
  range        Stepped Measured[D] Spanned[E]
  io           Readable Writable Flushable Closeable Seekable           (+ Whence)
  convert      Parsable Encodable Decodable Defaultable
  serde        Sink EncodableTo[S] DecodableFrom[S]
  error        Describable Coded Recoverable Caused[E]
  format       Formattable Padded Radixed
  time         Duration Instant[D] Clock[I] Monotonic
  concurrency  Awaitable[E] Sendable[E] Receivable[E] Closable Cancellable
  random       RandomSource Distributed[E]
  memory       Sized Disposable Borrowable[V]

a concern — its satisfiers and its verbs:
  ordering / seqops / text

ONE algorithm each, interchangeable:
  hash_fnv1a_num / hash_fnv1a_str
```

63 groups. Implementations follow the contracts, not the other way round: a
contract is agreed first and satisfied later, and several here are deliberately
ahead of any code.

## What a contract cannot say yet

Written down rather than worked around, because each is a language question:

- **No-self requirements.** `fn zero() -> Self`, `fn default() -> Self`,
  `fn decodeFrom({source: S}) -> Option[Self]` — nothing in the arguments says
  which type to pick, and Tuck cannot infer a type param that appears only in
  the return. They are declared where they are genuinely the right shape
  (`convert.Defaultable`, `serde.DecodableFrom`) and unusable until that is
  settled. `numeric` avoids the problem instead: sum and product take a seed,
  the way Rust's `fold` and Ruby's `inject(0)` do, so no identity element is
  ever required.
- **No refinement.** `group Comparable: Equatable` is a parse error, so a verb
  needing both writes `[T: Equatable + Comparable]`. Pure ergonomics — `+`
  already says it.
- **No higher-kinded parameters.** `Mappable[F]` where `F` is itself generic —
  a `map` that returns "the same container, different element" — cannot be
  written. This is why the collection verbs are written against `Indexable[E]`
  and return `Seq`, rather than against an abstract container.
- **No visibility marker.** Every top-level name is exported, which is why the
  swap rule below is about names giving up their bare form rather than about
  keeping helpers private.

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

**`public:` states the contract surface.** Bare names, whitespace-separated,
across as many lines as it takes:

```tuck
public:
  hashOf combined bucketOf
```

No parameters, no arity, no return type — Tuck has no overloading, so a name
IS the signature, and a list repeating it would be a second copy to keep in
step. One list covers every kind of name (fn, type, object, group, fnsig),
because an importer resolves all of them the same way.

A module with no `public:` block exports everything, which is what every
module written before the block existed relies on.

This is what lets two implementations of one contract coexist: they share
their internal helper names by nature — `fnvStep` is in both hash modules —
and only the listed names ever reach an importer.

**One satisfier per group per program** still holds for the CONTRACT names.
A second `fn hashOf` in a module is "declared twice"; two imported modules
both exporting one gives the bare name up, and it stays reachable as
`mod::hashOf`. That makes "which hash is this program using" a question with
exactly one answer, visible at the call.

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
