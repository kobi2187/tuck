# std.reflect — Tuck translation

## Shape decision
The **runtime** half translates; the **compile-time** half does not.

## What translates: `DynValue`

Round-2 added a fully dynamic value tree, decoupled from any
compile-time-known type, because `config-schema-validator` loads both the
config *and* the schema at runtime — so "walk a value against a schema
neither side knew about at compile time" had no answer in the
derive-oriented design.

That is a recursive sum type, which Tuck does well — and it is **the same
shape as `std.encoding`'s `Json`**:

```tuck
type DynValue:
  | DNull
  | DBool({b: bool})
  | DNum({n: float})
  | DText({s: str})
  | DList({items: Seq[DynValue]})
  | DRecord({keys: Seq[str], vals: Seq[DynValue]})
```

**Worth asking whether these should be one type.** Round-2 kept
`std.encoding` and `std.reflect` separate because one is about *formats*
and the other about *values*, but in Tuck they are structurally identical,
and having two near-identical trees invites conversion functions nobody
wants to write. Flagged as a real consolidation question.

Schema validation is then a generic recursive walk over two `DynValue`
trees — ordinary Tuck code, no reflection facility needed.

## What does not translate: compile-time reflection

The Nim design's `T: Reflect` half — enumerate a type's fields, read their
names and types, drive a codec from them — needs compile-time type
introspection. Tuck has none verified in this pass.

Its consumers were `doc-convert-tester` (round-trip any type through any
format) and `std.serde-derive` (see that module). Both are blocked on the
same missing facility.

## The one thing worth keeping from the Nim design's negative result
`secrets-vault` validated reflection **negatively** — it deliberately did
*not* use it, because a type that can enumerate its own fields is a type
whose secrets can be walked out of it. That argument holds regardless of
whether Tuck gains the facility, and is a reason to make any future
reflection opt-in per type rather than universal.
