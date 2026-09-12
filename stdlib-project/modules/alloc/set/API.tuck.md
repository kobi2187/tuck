**Status: pre-`group` design, superseded — see TASKS.md T-08.** The
Hashable-blocked note below predates `group`; `group Hashable` removes that
block. The `..` call-site shown is also wrong — see the fix inline.

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

`..` is rejected here — checked directly, same reason as `alloc.vec`: no
mutation to spell that way, `add` returns a new `Set`. Call-site spelling is
plain reassignment: `seen = {s: seen, value: word} add`.

## Notes
- **Hashing was blocked on `satisfies`, not anymore.** `satisfies` can't
  attach primitives to an interface (verified: *"names 'int', which is not
  a declared object in scope"*) — but `group Hashable` is structural, no
  attach statement, so `int`/`str` satisfy it the moment core.hash gives
  them a `hashOf` overload (TASKS.md T-08). `Set[str]` is
  `spellchecker`'s core type, so this is not a corner case.
- **`union`/`intersect`/`difference` keep their plain names.** Set algebra
  is one place the mathematical word *is* the everyday word — no Haskell
  smell, and Ruby uses the same three.
- **The `Seq[T]` representation is illustrative**, as with `Table` — a real
  implementation shares whatever `alloc.map` uses, since a set is a map
  with no values.
