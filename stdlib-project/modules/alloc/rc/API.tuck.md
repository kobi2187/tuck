# alloc.rc — Tuck translation

## This module does not translate, and that is the finding.

`Shared[T]` is *"one value with several genuine owners, kept alive until
the last one lets go. `Watcher[T]` is a look-but-don't-hold handle that
breaks the cycles `Shared` would otherwise leak."*

"Several genuine owners of one value" is precisely the sentence Tuck's
Tier 1 is built so you cannot form:

> **No `ref` in Tier 1**, so no two names ever denote one record. A data
> race needs two references to one mutable location; the sentence cannot be
> formed.

So there is no shared ownership to reference-count, and no cycle to break
with a weak handle. The module's entire problem domain is absent.

## What replaces it
- **Sharing between concurrent contexts** — an `actor`. State lives in one
  place, messages are copied in, and no one else holds a reference.
- **Sharing within one context** — pass the value. Rule #4 makes that free
  (a pointer under the hood), and value semantics makes it safe.
- **A bounded set of live objects with explicit handoff** — a `pool`.
  `acquire`/`release` gives borrow-and-return semantics with a compile-time
  count, which is what many `Rc` uses actually want.

## Recommendation
Drop as a module, alongside `core.ptr`, `core.atomic`, `core.sync-cell` and
`alloc.box` — the fifth module to dissolve for the same underlying reason.
The `API.nim.md` stays as the record of the Rust/Nim design.
