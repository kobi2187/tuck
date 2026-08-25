# core.sync-cell — Tuck translation

## This module does not translate, and that is the finding.

`core.sync-cell` is *"mutable state you can reach through a shared
reference, on one thread, without paying for a lock. `Slot[T]` for small
values you copy in and out; `Guarded[T]` for bigger ones, where the borrow
rules are checked as you go."*

Every noun in that sentence is something Tuck removes on purpose:

- **"through a shared reference"** — no `ref` in Tier 1; no two names ever
  denote one record (spec §1).
- **"borrow rules checked as you go"** — Tuck has no borrow checker,
  explicitly *"not because those problems were solved, but because they
  were never expressible."*
- **Rust's `Cell`/`RefCell`, which this module is modelled on**, exist to
  buy back interior mutability *inside* a borrow-checked language. With no
  borrow checker to work around, there is nothing to buy back.

## What replaces it
An ordinary `var` binding, or an object member mutating its own field via
`self ..field` — which is legal precisely because it's state the callee
*owns* rather than shares (rule #11: "legal for object members and actor
fields — state the callee OWNS"). Where the sharing is genuinely across
concurrent contexts, that's an `actor`'s fields, isolated by the mailbox
copy rather than by a cell.

## Recommendation
Drop as a Tuck module. Same treatment as `core.ptr`/`core.atomic`/
`core.slice` — flagged, `API.nim.md` kept as the design record.

This is the fourth `core` module to dissolve for the same underlying
reason, which is itself the finding: **Rust's and Nim's `core` tiers are
substantially about safely handling references, and Tuck's Tier 1 deletes
references.** See `TUCK-TRANSLATION.md`'s summary of what that does to the
tier as a whole.
