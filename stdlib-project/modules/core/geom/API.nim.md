# core.geom — Nim API

## Purpose
Vectors, a matrix, and the handful of intersection tests every real-time
loop needs on every frame: distance, dot/cross product, ray-vs-box,
box-vs-box. Small, decades-settled math with no allocation and no OS
dependency — a game's physics step, a desktop app's hit-testing, and a
mobile app's touch-target math all want the same eight functions, not a
physics engine.

*New in this pass.* `DOMAINS.md`'s game-domain analysis checked `std.math`
directly and found `Decimal`, unit conversion, and statistics — no
`Vector2`/`Vector3`/AABB surface anywhere in the 65. Recommended rung **A**:
same character as `COMPARISON.md`'s priority-queue finding — small, settled,
belongs at `core` rather than `alloc`/`std` because none of it needs a heap,
the same reasoning that already separates `core.array`'s fixed-size `Grid2D`
question from `alloc.vec`'s growable `Grid[T]`.

## Protocols implemented
`Comparable` from `core.cmp` on nothing here — a vector has no total order,
and forcing one would answer a question nobody asked. Everything is domain
verbs; geometry has no structural analogue among the nine protocols, the
same conclusion `core.num`'s arithmetic half already reached.

## The API

```nim
{.push checks: off.}   ## core tier: no implicit bounds/overflow machinery

type
  Vec2* = object
    x*, y*: float32
  Vec3* = object
    x*, y*, z*: float32
  Mat3* = object
    ## Row-major 3x3 — 2D affine transforms (rotate, scale, translate) in
    ## one type, the same "don't build a second thing for a special case"
    ## reasoning `alloc.vec::Grid[T]` already applies to its own domain.
    rows*: array[3, Vec3]
  Aabb2* = object
    ## Axis-aligned bounding box. `min`/`max` rather than `origin`/`size` —
    ## every intersection test below reads directly off two corners with no
    ## conversion step.
    min*, max*: Vec2

func vec2*(x, y: float32): Vec2
func vec3*(x, y, z: float32): Vec3

func `+`*(a, b: Vec2): Vec2
func `-`*(a, b: Vec2): Vec2
func `*`*(a: Vec2, scalar: float32): Vec2
func `+`*(a, b: Vec3): Vec3
func `-`*(a, b: Vec3): Vec3
func `*`*(a: Vec3, scalar: float32): Vec3

func dot*(a, b: Vec2): float32
func dot*(a, b: Vec3): float32
func cross*(a, b: Vec3): Vec3
  ## No 2D `cross` overload returning a `Vec2` — the 2D cross product is a
  ## scalar (the z-component of the 3D one), not a vector, and giving it
  ## the same name as the 3D version would be the "same primitives, hides a
  ## real difference" mistake this module's own siblings avoid elsewhere.
func cross2*(a, b: Vec2): float32
  ## The scalar 2D case, named distinctly rather than overloaded onto `cross`.

func length*(v: Vec2): float32
func length*(v: Vec3): float32
func lengthSquared*(v: Vec2): float32
func lengthSquared*(v: Vec3): float32
  ## Distance comparisons only ever need the squared form — `a.lengthSquared
  ## < b.lengthSquared` avoids a square root on a path that runs every
  ## frame for every pair of entities, which is the entire reason this
  ## exists as a separate call rather than a hidden optimization inside
  ## `length`.
func normalized*(v: Vec2): Vec2
func normalized*(v: Vec3): Vec3
  ## Raises on a zero-length vector — there is no sensible direction to
  ## return, and returning a garbage unit vector would be a silent
  ## correctness bug in whatever reads it next. `tryNormalized` is the
  ## `Option`-returning sibling for a caller that expects zero vectors.
func tryNormalized*(v: Vec2): Option[Vec2]
func tryNormalized*(v: Vec3): Option[Vec3]

func identity*(_: typedesc[Mat3]): Mat3
func translation*(delta: Vec2): Mat3
func rotation*(radians: float32): Mat3
func scaling*(factor: Vec2): Mat3
func `*`*(m: Mat3, v: Vec2): Vec2      ## transform a point
func `*`*(a, b: Mat3): Mat3            ## compose two transforms

func aabb2*(min, max: Vec2): Aabb2
func has*(box: Aabb2, point: Vec2): bool
  ## The `Gettable`/`Collection` family's `has` verb, reused deliberately —
  ## "is this point inside this box" really is the same question `has`
  ## answers everywhere else in the library, unlike the vector arithmetic
  ## above, which has no structural equivalent to borrow.
func overlaps*(a, b: Aabb2): bool
func rayHits*(origin, direction: Vec2, box: Aabb2): Option[float32]
  ## The distance along the ray to the first intersection, or absent if the
  ## ray misses entirely — one call answers both "does it hit" and "how far",
  ## instead of a boolean plus a separate distance query most callers would
  ## need immediately after anyway.

{.pop.}
```

## Friendly-naming notes

| Common precedent (raylib/GLM) | Nim name | Why |
|---|---|---|
| `Vector2Length` / `Vector2LengthSqr` | `length` / `lengthSquared` | one word difference, sorts together, matches the project's own `core.num::countBits`-style naming discipline |
| `Vector2Normalize` (undefined on a zero vector) | `normalized` (raises) + `tryNormalized` (`Option`) | the library-wide raise/`try` rule applied here instead of an undefined-behavior footgun |
| `Vector2CrossProduct` returning a scalar | `cross2` | named distinctly from 3D `cross`, which returns a `Vec3` — same name, different return shape, is exactly the ambiguity `core.num::setBits` already refuses to create |
| `CheckCollisionBoxes` / `GetRayCollisionBox` (two separate calls) | `overlaps` / `rayHits` returning `Option[float32]` | one call for the ray case instead of a boolean plus a follow-up distance query |
| `MatrixTranslate` / `Rotate` / `Scale` as free functions | `translation` / `rotation` / `scaling` constructors, composed with `*` | matches the library's existing "constructor returns the value, operators combine them" shape rather than a mutating builder |

## In use

```nim
# a game's fixed-timestep step (per DOMAINS.md's game persona): broad-phase then narrow-phase
for a in entities:
  for b in entities:
    if a == b: continue
    if a.bounds.overlaps(b.bounds):        # broad phase, cheap
      resolveCollision(a, b)

# camera-ray picking, desktop or mobile touch-target math alike
let hit = rayHits(camera.pos, cursorDirection, target.bounds)
hit.ifSome(dist): selectEntity(target, at = camera.pos + cursorDirection * dist)

# a UI transform stack, matches `platform.hal`'s "compose, don't mutate in place" spirit
let toScreen = translation(vec2(400, 300)) * rotation(angle) * scaling(vec2(2, 2))
let screenPoint = toScreen * localPoint
```

## Vocabulary exceptions
- **`dot`, `cross`, `cross2`, `length`, `normalized` are domain verbs.**
  Vector arithmetic has no structural analogue among the nine protocols —
  the same conclusion `core.num`'s arithmetic half already states for
  `tryAdd`/`addClamped`, applied here to a different kind of number.
- **`has` on `Aabb2` is the one place this module borrows a structural
  verb**, because point-in-box containment really is the same question
  `Gettable`/`Collection`'s `has` answers everywhere else — reusing it
  costs nothing and teaches nothing wrong, unlike forcing `dot`/`cross`
  into the same vocabulary would.
- **Left unresolved, on purpose.** `core.array` deliberately did *not* gain
  a `Grid2D<T, R, C>` type despite the surface parallel to `alloc.vec::Grid`
  (recorded in `INDEX.md`'s extension-round-3 findings) — this module
  follows that same restraint and does not add a fixed-size tile-grid type
  here either, on the same reasoning: a compile-time-sized nested array
  already gives free `grid[r][c]` indexing, and `core.geom` has nothing to
  add to that. 3D transforms (`Mat4`, quaternions) are also out of scope —
  no domain persona or validated app in this project's set needs a 3D
  scene graph; `Mat3` covers every 2D case `DOMAINS.md` actually named.
