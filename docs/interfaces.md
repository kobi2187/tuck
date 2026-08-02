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

An interface has no size, so an interface-typed value is never the object
itself. It is **two words: a reference to the data, and a reference to that
concrete type's function table.**

```nim
type AnimalVT* = object
  noise*: proc(data: pointer): int {.nimcall.}

type Animal* = object
  data*: pointer
  vt*: ptr AnimalVT
```

Both halves are filled where a concrete object enters an interface slot — the
last point at which the compiler knows the type:

```nim
tuck_hear(Animal(data: addr d, vt: addr Animal_for_tuck_Dog))
```

and the call simply reads what the value carries:

```nim
proc tuck_hear*(a: Animal): int =
  return a.vt.noise(a.data)
```

The table is a static global, one per (object, interface) pair, shared by every
value of that type. A thunk adapts the object's member fn to the table's
signature:

```nim
proc Animal_tuck_Dog_noise(data: pointer): int {.nimcall.} =
  noise(cast[ptr tuck_Dog](data)[])

let Animal_for_tuck_Dog = AnimalVT(noise: Animal_tuck_Dog_noise)
```

So a wrap costs two stores and no allocation.

### What this is not

**There is no runtime type.** No header on the object, no hierarchy to walk, no
name lookup, no type comparison. The table pointer is not "find out what this
is" — it is the answer, computed at compile time and carried along. Dispatch is
dynamic only in the sense that a function pointer is.

That forecloses, deliberately: type assertions, type switches, reflection,
inheritance, and interface default methods. All are listed in the spec's
Appendix B as omissions.

**The data half borrows.** It points at the object, not a copy — so mutation
through an interface value is visible to the original, and nothing is allocated
at the boundary.

(Compare Go, whose interface values *are* freely storable and which therefore
copies to the heap on every conversion.)

Borrowing is only sound while the object outlives the interface value, and
**that is not yet enforced** — see Current limits.

### Emission is demand-driven

Tables and thunks are generated only for the (object, interface) pairs some call
site actually asked for. An object that satisfies an interface it is never
passed as costs the conformance check and nothing else.

### Both backends

Nim and Odin emit the same structure from one source; only the spelling differs:

| | Nim | Odin |
|---|---|---|
| table | `AnimalVT = object` | `AnimalVT :: struct` |
| pointer | `data*: pointer` | `data: rawptr` |
| cast | `cast[ptr T](data)[]` | `cast(^T)data` (no deref — the receiver is already a pointer) |
| address-of | `addr d` | `&d` |
| construction | `Animal(data: …, vt: …)` | `Animal{data = …, vt = …}` |

Both produce 42 for the example above.

---

## Current limits

**The borrow is not contained yet.** The design is that an interface value may
appear as a function parameter and a local, but not as a record/object/actor
field nor as a return type — so the object it points at is always in an
enclosing scope. Today none of that is checked: returning an interface value or
storing one in a field both compile, and either can dangle. The pointer
containment rule already implemented for `cstring`/`Buf`
(`tests/pointer_containment.sh`) is the shape this needs.

**A list literal does not wrap its elements.** `[d, c]` synthesizes as
`Seq[Dog]` from its first element, so a `Seq[Animal]` parameter rejects it. The
wrap fires at a call argument today; a collection element needs the expected
element type pushed into the literal, which is a change to how list literals are
checked. Until then, heterogeneous *collections* are not available — passing
different objects to the same interface *parameter* is.

**Only objects may satisfy an interface.** Actors are plausible later — their
handlers dispatch through a mailbox, so the thunk shape genuinely differs — and
nothing in the design precludes it.

**Two objects satisfying one interface share a member-name namespace.** Member
fns are registered under their bare name in a flat table, so `Dog.noise` and
`Cat.noise` collide there. Emission qualifies them (`tuck_Dog_noise`), and
dispatch resolves through the contract, so this does not affect interfaces — but
a member fn still shadows a top-level fn of the same name.

## Tests

- `tests/interfaces.sh` — declaration and conformance, including every failure
  mode with its message
- `tests/interface_wrap.sh` — which objects may enter an interface slot
- `tests/interface_call.sh` — resolving a call against the contract
- `tests/interface_dispatch.sh` — emitted shape on both backends, demand-driven
  generation, and an exit code (42) reachable only if each object dispatched to
  its own implementation
