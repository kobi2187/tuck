# Interfaces in Tuck

An interface is a **contract**: the set of functions a type promises to provide.
Objects declare conformance explicitly, the compiler checks it, and a value of
an interface type dispatches to the right implementation with no runtime type
information of any kind.

Spec: §5.2 (interfaces) and §5.3 (dispatch).

---

## Declaring

The body of an interface is its requirement list — there is nothing else an
interface can hold, so there is no nesting:

```tuck
interface Animal:
  fn noise({self: Self}) -> int
```

An object declares conformance with a `satisfies` line in its body, beside the
`+` composition lines. One object may satisfy several interfaces:

```tuck
object Dog:
  name: str
  satisfies Animal

  fn noise({self: Dog}) -> int:
    return 1
```

`satisfies` is what admits an object to the contract. Having the right members
by coincidence is **not** enough — conformance is explicit, so adding a member
can never silently enrol a type in a contract its author never agreed to.

## Conformance

Checked at compile time, when the object is declared:

- **Parameters and return type match exactly**, names included. Payload fields
  bind by name in Tuck, so a parameter's name is part of the contract, not
  decoration.
- **Effects may be a subset.** An implementation may do *less* than the contract
  permits — a pure `save` satisfies an `[io] save` — never more. Same direction
  as the caller/callee effect budget.
- **`Self` means the implementing type.** In a required signature, `-> !Self`
  reads as `-> !Dog` for `Dog`.
- **A body-less member implements nothing.** It is a signature; there would be
  no code to run.

A mismatch names both signatures and the exact problem:

```
t.tuck:8:3: Conformance Error: object 'Dog' does not satisfy 'Speaker'
  contract   fn speak({volume: int}) -> str [io]
  implements fn speak({loudness: int}) -> str [io]
  parameter 1 is named 'loudness', the contract calls it 'volume' (payload
  fields bind by name, so the name is part of the contract)
```

## Using

A function takes the interface; any satisfying object may be passed:

```tuck
fn hear({a: Animal}) -> int:
  return a.noise

fn main() -> int:
  var d = {name: "rex"} Dog
  var c = {lives: 9} Cat
  return ({a: d} hear) + ({a: c} hear)     # 1 + 41 = 42
```

`Dog` and `Cat` are ordinary objects, constructed as themselves. Nothing is
declared "as an Animal" — the conversion happens where one is passed.

Inside `hear`, only the contract is reachable. A member the concrete object
happens to have but `Animal` does not declare is not callable there, because
nothing at that point knows which object it was handed. That is an error naming
what the contract does require.

---

## How it works

An interface value is a **variant over the types that satisfy it**: a tag, plus
the object itself, copied in.

```nim
type AnimalTag* = enum Animal_is_tuck_Cat, Animal_is_tuck_Dog

type Animal* = object
  case tag*: AnimalTag
  of Animal_is_tuck_Cat: tuck_CatVal*: tuck_Cat
  of Animal_is_tuck_Dog: tuck_DogVal*: tuck_Dog
```

Wrapping copies:

```nim
tuck_hear(Animal(tag: Animal_is_tuck_Dog, tuck_DogVal: d))
```

and dispatch is a `case` on the tag calling the concrete member fn directly:

```nim
proc tuck_hear*(a: Animal): int =
  case a.tag
  of Animal_is_tuck_Dog:
    var tmp = a.tuck_DogVal
    noise(tmp)
  ...
```

No function table, no thunks, no pointers — and the optimizer can see through
the whole thing.

### It copies, like everything else

The value **owns** its data. That is the same rule records and actor messages
already follow, so there is one thing to learn about values in Tuck: they copy.

Consequences, all of them good:

- an interface value can be **returned**, stored in a **field**, and held in a
  **collection**, with no lifetime question to reason about
- mutation through an interface hits the copy, not the original — write it back
  if you want it kept, exactly as with any other value
- no escape analysis, no borrow rules, no annotations

### Why a variant and not a byte buffer

`array[max(sizeof), byte]` plus a memcpy is the obvious cheap version, and it is
**wrong**: Tuck objects hold `str` and `Seq`, which the backend manages, and a
byte blit never adjusts the refcount — the source's destructor frees the payload
out from under the copy.

That version passed three hand probes before AddressSanitizer and a look at the
mechanism showed it had survived only because ARC happened to *move* rather than
copy in those particular shapes. A variant lets each backend generate the
correct copy and destroy per branch.

### Every satisfier is a branch

The variant must be able to hold any satisfying type, so each one is a branch
whether or not a given program ever wraps it. That needs the whole-program set,
which `satisfies` declares and codegen collects across the module closure.

### Both backends

Nim and Odin emit the same structure from one source; only the spelling differs:

| | Nim | Odin |
|---|---|---|
| variant | `case tag*: AnimalTag` | `tag: AnimalTag` + payload fields |
| construction | `Animal(tag: …, tuck_DogVal: d)` | `Animal{tag = …, tuck_DogVal = d}` |
| dispatch | `case a.tag` (an expression) | `switch v.tag` inside a closure, since Odin has no switch expression |

Both produce 42 for the example above.

---

## Current limits

**Odin cannot take a list literal for a `Seq` parameter.** Pre-existing and not
about interfaces — a plain `Seq[Record]` fails the same way, because
`[dynamic]T` has no literal form in Odin ("Compound literals of dynamic types
are disabled by default"); it is built with `append`. Emitting that needs
statement hoisting in the Odin backend. Mixed collections therefore work on the
Nim backend today and not yet on Odin.

**Only objects may satisfy an interface.** Actors are plausible later — their
handlers dispatch through a mailbox, so the dispatch shape genuinely differs —
and nothing in the design precludes it.

**Every satisfying type is a branch, so the value is as large as the largest.**
A `Seq[Animal]` element is `max(sizeof)` over the satisfying types, plus the
tag. Predictable and known at compile time, which suits the embedded story, but
it wastes space when the types differ wildly. A borrow-when-provably-safe
optimization could avoid the copy where nothing observes the difference; it is
not worth building until a profiler asks for it.

**Two objects satisfying one interface share a member-name namespace.** Member
fns are registered under their bare name in a flat table, so `Dog.noise` and
`Cat.noise` collide there. Emission qualifies them (`tuck_Dog_noise`), and
dispatch resolves through the contract, so this does not affect interfaces — but
a member fn still shadows a top-level fn of the same name.
