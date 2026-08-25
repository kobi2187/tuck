# alloc.set — Tuck translation

## Shape decision
A real new type, like `alloc.map` — Tuck has no set. **Compiler-verified**,
`./tuck ch`: `OK`.

## The API

```tuck
type Set[T] = {items: Seq[T]}

pending:
  fn newSet[T]() -> Set[T]
  fn add[T]({s: Set[T], value: T}) -> Set[T]
  fn remove[T]({s: Set[T], value: T}) -> Set[T]
  fn has[T]({s: Set[T], value: T}) -> bool
  fn count[T]({s: Set[T]}) -> int
  fn union[T]({a: Set[T], b: Set[T]}) -> Set[T]
  fn intersect[T]({a: Set[T], b: Set[T]}) -> Set[T]
  fn difference[T]({a: Set[T], b: Set[T]}) -> Set[T]
  fn toSeq[T]({s: Set[T]}) -> Seq[T]
```

Call sites use `..` (`seen ..add {value: word}`), per
`TUCK-TRANSLATION.md`.

## Notes
- **Blocked on the same hashing question as `alloc.map`** — primitives
  cannot be attached to a `Hashable` interface via top-level `satisfies`
  (verified: *"names 'int', which is not a declared object in scope"*).
  `Set[str]` is `spellchecker`'s core type, so this is not a corner case.
- **`union`/`intersect`/`difference` keep their plain names.** Set algebra
  is one place the mathematical word *is* the everyday word — no Haskell
  smell, and Ruby uses the same three.
- **The `Seq[T]` representation is illustrative**, as with `Table` — a real
  implementation shares whatever `alloc.map` uses, since a set is a map
  with no values.
