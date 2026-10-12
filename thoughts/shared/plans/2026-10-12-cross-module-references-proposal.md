# Reaching a module that imports you: A47 (built), A34 and A27 (proposed)

Status: A47 is built and pinned `bugFixed`. A34 and A27 are proposals; the
representation question for A27 (§4) wants a ruling.

## 1. The shape of the problem

A program is closed-world: the compiler sees every module, every call site and
every satisfier, and there are no plugins or run-time loading. Yet three
constructs need a module to reach something defined in a module that IMPORTS it,
which no import graph can express in Nim, Odin or D (an import cycle):

| bug | the library module needs | which lives in |
|---|---|---|
| A47 | the handlers of its registry | the importer |
| A34 | the group provider (`size`) its bounded fn calls | the importer |
| A27 | the satisfier of its interface (`Sq` for `Shape`) | the importer |

## 2. The mechanism: function references, handed over explicitly

The library cannot name the importer's function, but the importer can name the
library's, and a function is a value. So the importer hands the library a
reference and the library calls it. Everything is ordinary emitted code a
developer can read:

```nim
# lib: the registry keeps a list of references per event
var tuckHandlers_AppEvents_Low*: seq[proc (left: int) {.nimcall.}]
proc raise_AppEvents_Low*(left: int) =
  latestAppEvents = AppEvents(tuckTag: Low, left: left)
  for h in tuckHandlers_AppEvents_Low: h(left)

# importer: hands its handlers over; the entry point calls this once, before main
proc tuckRegisterHandlers*() =
  tuckPush(tuckHandlers_AppEvents_Low, tuckfn_AppEvents_Low)
```

This is A47 as built. Odin appends to a `[dynamic]proc(...)`, D to a
`void function(...)[]`. The compiler does the bookkeeping (which events have
outside handlers, which modules register, the order of the entry point's calls)
and the emitted program shows all of it.

A first version of A47 used link-time symbols (`importc`/`exportc`,
`pragma(mangle)`, an Odin `foreign` block). It worked on all three targets and
was dropped: a naming convention resolved by the linker is something a developer
has to take on faith, where a list of function references is something they can
read.

## 3. A34: a group provider in another module

Odin and D resolve a requirement where the generic is WRITTEN, so `big[T: Sized]`
in `lib` cannot name `size` from the importer. Nim resolves at instantiation and
already works.

The provider is a function reference passed by the call site:

- Odin: `big :: proc(x: $T, $size: proc(self: T) -> int) -> bool`, called
  `big(b, size)`; a constant proc parameter, so it stays monomorphic and inlines.
- D: `bool big(T, alias size)(T x)`, called `big!(Blob, size)(b)`.
- The call site knows T from its argument and the provider from the group
  requirement (`requirementKey` already maps a requirement and a type to its
  provider).

Only a bounded fn whose provider is NOT visible from its own module needs this;
everything else keeps today's emission, so no example re-emits. No table, no
start-up call: the reference travels with the call.

## 4. A27: an object in the importer satisfies an imported interface

An interface compiles to a closed tagged union of its satisfiers, by value, with
the call dispatch printed at each call site. The union is built from usage, as
ruled. For an interface with a satisfier in a module the interface's module
cannot see, the union cannot hold that satisfier's type, nor call its members.

Proposal: such an interface value is **a pointer and a table of function
references**, the classic shape and the same idea as §2.

```
Shape = { data: pointer, vt: ^ShapeVTable }
ShapeVTable = { area: proc(data: pointer) -> int, drop: proc(data: pointer),
                copy: proc(data: pointer) -> pointer, typeId: int }
```

- Each satisfier's module defines its table and registers nothing at run time:
  the conversion `x: Shape = {s: 4} Sq` is in the importer, which knows `Sq`, so
  it builds the box and names `Sq`'s table directly.
- The library calls `s.vt.area(s.data)`. No import, no lookup.
- `match v: Sq q` compares `typeId`, which the closed world assigns.
- Ownership: the box is owned by the `Shape`; drop and copy go through the table,
  so the existing glue (`tuckDrop`/`tuckCopy` for a sum) gains one more case.

Cost: an allocation per conversion and a second representation of an interface
value in all three backends and in the ownership glue. It applies only to an
interface that has a satisfier outside the interface's module; every
single-module interface is unchanged.

Alternative: move the satisfier's data fields, and the types they reference,
into a generated module the interface's module imports, keeping values by value.
Cheaper at run time, but it splits an object declaration into data and members
and has to carry the whole type closure (consts, aliases, generics) with it.

Recommendation: the table. It is the simplest to explain and to read in the
emitted code, and it needs nothing moved between modules.

## 5. Order

1. A47 (done): lists of function references for registry handlers.
2. A34: provider parameters for a foreign provider (§3).
3. A27: the pointer-and-table representation for cross-module interfaces (§4).
