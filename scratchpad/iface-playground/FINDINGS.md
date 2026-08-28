# Interface semantics — reference behaviour before writing the D backend

Probe: `iface3.tuck` (and `iface2.tuck`, which additionally prints).

## What was verified, by running

| Backend | Exit | Meaning |
|---|---|---|
| Nim  | 12 | reference |
| Odin | 12 | agrees |

`iface2` on the Nim backend printed `n1=3 n2=9 n3=500`, which pins each claim
separately:

1. **The wrap COPIES.** `n1` is 3: the value was copied into the variant, and
   mutating the original to 9 afterwards did not change it.
2. **A later wrap sees the new value.** `n2` is 9 — each wrap site copies
   afresh, so nothing is cached.
3. **Dispatch picks the arm for the stored tag.** `n3` is 500, i.e. Cat's own
   `noise` (volume * 100), not Dog's.

## The representation, as emitted

Nim (case object):

    type AnimalTag* = enum Animal_is_tuck_Cat, Animal_is_tuck_Dog
    type Animal* = object
      case tag*: AnimalTag
      of Animal_is_tuck_Cat: tuck_CatVal*: tuck_Cat
      of Animal_is_tuck_Dog: tuck_DogVal*: tuck_Dog

Odin (plain struct, every field present):

    Animal :: struct {
        tag: AnimalTag,
        tuck_CatVal: tuck_Cat,
        tuck_DogVal: tuck_Dog,
    }

A wrap site emits `Animal(tag: Animal_is_tuck_Dog, tuck_DogVal: d)` — tag plus
the concrete value BY VALUE. No pointer, no vtable, no thunk.

## Consequences for the D backend

- **Follow ODIN's shape**, not Nim's: D has no case-object, and the union form
  is already proven there by the payload-sum work.
- A call site is a `switch` on the tag with one arm per satisfier, each arm a
  DIRECT call to that type's own member. Not `final switch`: the satisfier set
  can be empty, and an unreachable default is cheap insurance.
- `satisfiersOf` is a WHOLE-PROGRAM query (it takes realModules) — a type in
  another module can satisfy an interface it never heard of, which is the
  retroactive `satisfies` the stdlib work relies on.
- No `.dup` concern: the value is copied in, so it owns its data.

## Pre-existing bug found while probing (NOT interface-related)

The Odin backend cannot emit `n1.toStr` on an int — "'n1' of type 'int' has no
field 'toStr'". `iface2.tuck` reproduces it; `iface3.tuck` is the same probe
with the print removed so the interface semantics could be measured. The Nim
backend handles it fine.
