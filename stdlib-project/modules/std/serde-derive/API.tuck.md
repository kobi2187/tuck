# std.serde-derive — Tuck translation

## Blocked: this module *is* a macro.

Its entire content is a derive facility — read a type's fields at compile
time, generate encode/decode functions for them. The Nim pass called it
"the one place the Nim version is plainly better than the Rust original"
precisely *because* Nim macros read the typed AST in the same file: no
build script, no separate derive crate, no procedural-macro compilation
step.

Tuck has no user-facing macro or compile-time reflection facility verified
in this pass, so there is nothing to translate — not a shape to adapt, an
absent capability.

## What a Tuck author does instead, today

Write the codec by hand, against `std.encoding`'s `Json` tree:

```tuck
fn toJson({t: Task}) -> Json:
  return {keys: ["id", "title", "done"],
          vals: [{n: t.id} Json.JNum, {s: t.title} Json.JStr, {b: t.done} Json.JBool]} Json.JObj
```

Mechanical, and exactly the boilerplate the module exists to remove — for
one type it's fine, for forty it's the reason derive facilities exist.

## What this blocks, concretely
- `doc-convert-tester` (round-trip any type through any format) — its whole
  premise.
- `config-schema-validator`'s typed half (the dynamic half works, see
  `std.reflect`).
- Any app persisting more than a handful of record types.

## The decision this forces
Whether Tuck wants a macro system is a language question well outside a
stdlib translation, and it has real costs — macros complicate the two-
backend story, tooling, and error messages. But it is worth noting that
**three separate modules in this corpus want it**: this one,
`std.reflect`'s compile-time half, and `std.testing`'s `check` (which
needs the unevaluated expression tree to report both sides of a failed
comparison).

Three independent demands is the strongest evidence available from this
exercise that the facility earns its cost — recorded as a finding, not a
recommendation.
