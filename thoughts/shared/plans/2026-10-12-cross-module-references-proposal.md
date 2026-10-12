# Reaching a module that imports you: A47 (built), A34 and A27 (proposed)

Status: A47, A27 and A34 are built and pinned `bugFixed`.

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

## 3. A34: a group provider in another module (BUILT)

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

## 4. A27: an object in the importer satisfies an imported interface (BUILT)

An interface compiles to a closed union of its satisfiers, held BY VALUE (spec
§5.3: values copy, and every optimisation must give the same result as if they
were written that way). Ruled: keep it by value.

The union is emitted where the interface is declared, so every satisfier's data
type has to be nameable there; a satisfier in a module that imports the
interface's module closes an import cycle. The compiler sees the whole program,
so it moves DATA:

- `iface_hoist` (before `injectImportedTypes`) finds the satisfiers an interface's
  module cannot see and puts their fields, and the types those fields mention
  that live in an interface module or anything that imports one, into one
  generated module, `iface_variants`. It is a real module in the emitted program
  with one declaration per moved type and a header saying where each came from.
- The original declaration keeps its members and is marked `hoistedTo`: no
  backend emits its struct again, and a reference to it names the generated
  module.
- The interface's module gets a shape-only copy of each satisfier, so its union
  lists it.
- Every module that is not a dependency of the generated module imports it, so
  a type that moved is still visible where it was.

The interface's module cannot call the satisfier's members (§2): it keeps one
function reference per contract member and satisfier,
`tuckImpl_<Interface>_<member>_<Satisfier>`, which the satisfier's module assigns
in `tuckRegister`. A module that declares the satisfier itself dispatches
directly. Single-module interfaces are untouched.

```nim
# iface_variants.nim                    # lib.nim (declares Shape)
type Sq* = object                       var tuckImpl_Shape_area_Sq*: proc (self: Sq): int
  s*: int                               ...  tuckImpl_Shape_area_Sq(tmp)  # in dispatch

# m.nim (declares Sq and its members)
proc tuckRegister*() =
  tuckImpl_Shape_area_Sq = Sq_area
```

Refused with a message (not yet moved): an object that composes another
declaration, a type with member fns.

## 5. Order

1. A47 (done): lists of function references for registry handlers.
2. A27 (done): the satisfier's data moves to `iface_variants`, its members are
   reached through function references (§4).
3. A34 (done): provider parameters for a provider the bounded fn's module cannot name (§3).
