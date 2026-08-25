# core.error — Tuck translation

## Shape decision
Mostly **dissolved into the language**, like `core.types::Option` before
it. What survives is a small error enum plus helpers.

**Compiler-verified**, `./tuck ch`: `OK`.

## What the language already supplies

The Nim design built an exception hierarchy (`Failure` as a
`CatchableError` root, `Bug` as a `Defect`, `failBecause` for chaining,
`attempt` as the template every `tryX` was written with). Tuck's error
model is different in kind, not degree, and supplies most of it directly:

| Nim design | Tuck |
|---|---|
| `Failure` root exception | `!T` fallible return + `err` to raise (`LANGUAGE-OVERVIEW.md` §4) |
| `attempt` template behind every `tryX` | the `try`-prefix convention itself, plus `?T` |
| error *kinds* | `[error: FsError \| NetError]` — a declared enum set per fn, checked at `match r.err` |
| `retryable` field | belongs on the enum variant, not a shared base |
| `cause` chaining / `list(f)` | **no counterpart** — see below |
| `Bug`/`Defect` split | no counterpart; Tuck has no uncatchable-defect tier |
| `needs` (precondition) | no counterpart verified; `std/seq.tuck` treats preconditions as call-site program errors instead |

Notably: **fallible functions must be `[io]`** — a pure fn cannot return
`!T` at all (confirmed by the compiler while translating `core.geom`). So
`core`, whose whole point is pure freestanding code, mostly *cannot raise*.
That's not a limitation to work around; it means precondition-style failure
in this tier is either `?T` or a documented call-site program error, exactly
as `std/seq.tuck::at[T]` already does it.

## The API

```tuck
type Where = {line: u32, column: u32, offset: int}

type CoreError:
  | Invalid
  | OutOfRange
  | Unsupported

pending:
  fn worthRetrying({e: CoreError}) -> bool
  fn describe({e: CoreError}) -> str
  fn spotOf({e: CoreError}) -> Where?
```

## Open question — error chaining has no Tuck answer
`failBecause(why, cause)` / `cause(f)` / `list(f)` let a high-level failure
carry the low-level one that caused it ("couldn't load config" *caused by*
"file not found"), which `INDEX.md`'s round-2 notes record as a real gap
that `doc-convert-tester` and `kv-store-server` both hit. Tuck's `err`
raises a *variant of a declared enum* — there is no field to hang a cause
on, and `err r.err` re-raises the original rather than wrapping it. Options:
give each error enum an explicit `cause` payload field (verbose, per-module),
or accept that Tuck reports one error and the context lives in the message.
Worth a decision; not made here.
