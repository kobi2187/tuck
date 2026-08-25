# alloc.list — Tuck translation

## Already rejected in the Nim design, and Tuck seals it.

`Chain[T]` was the one module `INDEX.md` recorded as validated *negatively*:
three apps (`mp3-player`, `todo-cli`, `chat-server`) each looked like
plausible customers and **all three resolved to `Seq`/`Ring`/`Table`
instead** on inspection. The Nim design kept it only for two narrow wins:
O(1) splice of two big sequences, and insert/remove at a position already
held.

**In Tuck it cannot be written at all.** A doubly-linked list is nodes
holding references to other nodes; Tier 1 has no `ref`, and a stored
pointer is rejected in a record field by the containment rule. Both of its
narrow wins depend on holding a position *by reference*, which is the same
thing.

## Trees are fine — sum types handle them

An earlier draft of this file claimed Tuck couldn't express recursive data
structures at all. **Wrong**, and the correction matters for
`std.encoding` and `std.reflect`: a **sum type recursing through a `Seq`
works today**, verified:

```tuck
type Json:
  | JNull
  | JBool({b: bool})
  | JNum({n: float})
  | JStr({s: str})
  | JArr({items: Seq[Json]})
  | JObj({keys: Seq[str], vals: Seq[Json]})
```

`./tuck ch`: `OK`. That covers JSON documents, schema trees, filesystem
hierarchies — every tree the corpus actually needs. Sum types (object
variants) are the right way to describe a tree in Tuck, not pointers.

**The one real boundary** is *direct* self-reference with no collection in
between:

```tuck
type Expr:
  | Add({left: Expr, right: Expr})   # typechecks, then fails to build
```

Tuck accepts this and emits a Nim `case` object containing itself by value;
Nim then rejects it — `Error: illegal recursion in type 'tuck_Expr'`. So a
binary-tree-shaped node needs its children in a `Seq` (or an index into
one), which costs nothing in practice.

Worth noting as a diagnostics gap rather than a language gap: the failure
surfaces from the *backend* compiler, not from `tuck ch`, so the author
sees a Nim error about generated code instead of a Tuck error about their
own type. Small, self-contained fix.

## Recommendation
Drop as a module — it was already the design's own "removing it is the
finding" case, and `Chain[T]` specifically needs by-reference node handles,
which is a different thing from recursive *data*, and genuinely absent.
