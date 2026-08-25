# core.geom — Tuck translation

## Shape decision
Freeform functions over plain records, matching `pending:`'s "declared, not
yet implemented" purpose exactly — no allocator, no OS resource, no
long-lived state, so no manager object and no actor. Per direct guidance:
freeform now, may later get proxied into a manager object if a real need
surfaces — nothing here forecloses that.

**Compiler-verified**, `./tuck ch` on the block below: `OK`, 27/27 signatures
reported `PENDING` and none rejected. No custom operator overloading exists
in Tuck (checked: no `fn \`+\`` anywhere in spec, tests, or examples) — so
`Vec2`/`Vec3` arithmetic are named verbs (`vAdd`, `dot`, `cross`) called
through the ordinary postfix/dot convention (`a.dot {b: b}`), not operators.
Same-name overloading across `Vec2`/`Vec3` (`dot` for both) was not risked
without confirming Tuck resolves free-function overloads by parameter type
the way Nim does — `dot`/`dot3` stay distinct names until that's checked.

**A real constraint this surfaced:** the Nim design's `normalized(v): Vec2`
"raises on zero-length" cannot be expressed as `!Vec2` here — a fallible
return requires `[io]` (spec §4; the compiler rejects a pure `!T` outright).
Resolved the way `std/seq.tuck`'s `at[T]` already resolves an analogous
precondition: `normalized` stays a plain `Vec2` return (a zero-length input
is a program error at the call site, not a value the caller matches on);
`tryNormalized` is the real `Vec2?` alternative for a caller that expects
zero vectors.

## The API

```tuck
type Vec2 = {x: float, y: float}
type Vec3 = {x: float, y: float, z: float}
type Mat3 = {r0: Vec3, r1: Vec3, r2: Vec3}
type Aabb2 = {min: Vec2, max: Vec2}

pending:
  fn vAdd({a: Vec2, b: Vec2}) -> Vec2
  fn vSub({a: Vec2, b: Vec2}) -> Vec2
  fn vScale({a: Vec2, scalar: float}) -> Vec2
  fn v3Add({a: Vec3, b: Vec3}) -> Vec3
  fn v3Sub({a: Vec3, b: Vec3}) -> Vec3
  fn v3Scale({a: Vec3, scalar: float}) -> Vec3

  fn dot({a: Vec2, b: Vec2}) -> float
  fn dot3({a: Vec3, b: Vec3}) -> float
  fn cross({a: Vec3, b: Vec3}) -> Vec3
  fn cross2({a: Vec2, b: Vec2}) -> float

  fn length({v: Vec2}) -> float
  fn length3({v: Vec3}) -> float
  fn lengthSquared({v: Vec2}) -> float
  fn lengthSquared3({v: Vec3}) -> float
  fn normalized({v: Vec2}) -> Vec2
  fn normalized3({v: Vec3}) -> Vec3
  fn tryNormalized({v: Vec2}) -> Vec2?
  fn tryNormalized3({v: Vec3}) -> Vec3?

  fn identity() -> Mat3
  fn translation({delta: Vec2}) -> Mat3
  fn rotation({radians: float}) -> Mat3
  fn scaling({factor: Vec2}) -> Mat3
  fn transformPoint({m: Mat3, v: Vec2}) -> Vec2
  fn compose({a: Mat3, b: Mat3}) -> Mat3

  fn hasPoint({box: Aabb2, point: Vec2}) -> bool
  fn overlaps({a: Aabb2, b: Aabb2}) -> bool
  fn rayHits({origin: Vec2, direction: Vec2, box: Aabb2}) -> float?
```

## In use

```tuck
let a = {x: 1.0, y: 2.0} Vec2
let b = {x: 3.0, y: 4.0} Vec2
let box1 = {min: {x: 0.0, y: 0.0} Vec2, max: {x: 5.0, y: 5.0} Vec2} Aabb2
let box2 = {min: {x: 1.0, y: 1.0} Vec2, max: {x: 6.0, y: 6.0} Vec2} Aabb2
if {a: box1, b: box2} overlaps:
  resolveCollision(a, b)
```

## Open questions carried from the Nim design, unresolved here too
- **`dot`/`dot3` and `length`/`length3` stay distinct names — settled, by
  ruling.** Free functions do not overload in Tuck
  (`[TK-TY02] duplicate declaration`), and per the 2026-08-24 ruling in
  `ROADMAP.md` that is deliberate, not a gap: a call site should say which
  function it calls without the reader reconstructing parameter types,
  which matters especially in a language where arguments bind by name *and*
  by type across a payload with subset matching. So the `3` suffix is the
  intended spelling, not a workaround.
- Operator sugar (`a + b` reading as `vAdd`) does not exist in Tuck today;
  the named-verb calling convention above is not a stopgap, it's the
  language's actual idiom (spec: no unit/operator magic, `5.ms` is a plain
  postfix call).
