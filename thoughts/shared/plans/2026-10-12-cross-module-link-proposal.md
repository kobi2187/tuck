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

## 2. The mechanism that works: a link symbol

Tested 2026-10-12 with a two-module program on each target. The referencing
module declares the callee WITHOUT a body under a fixed symbol; the defining
module exports it under the same symbol. Nothing imports anything and nothing
is looked up at run time.

| target | referencing side | defining side |
|---|---|---|
| Nim | `proc f(a: T): R {.importc: "sym".}` | `proc f(a: T): R {.exportc: "sym".}` |
| D | `pragma(mangle, "sym") R f(T a);` | `pragma(mangle, "sym") R f(T a) {...}` |
| Odin | a `foreign import x "system:c"` block, `@(default_calling_convention="odin")`, `@(link_name="sym") f :: proc(a: T) -> R ---` | `@(export, link_name="sym") f :: proc(a: T) -> R {...}` |

Odin refuses the plain body-less form with a duplicate-link-name error, hence the
foreign block; `system:c` names no library, it only lets the symbol resolve at
link time.

The symbol is a position in a program-wide list the compiler builds
(`Resolution.handlerSites` for A47), so both ends compute the same name from
the same table.

## 3. A34: a group provider in another module

Odin and D resolve a requirement where the generic is WRITTEN, so `big[T: Sized]`
in `lib` cannot name `size` from the importer. Nim resolves at instantiation and
already works.

Proposal: the provider is a parameter the call site supplies, not a name the
body looks up.

- Odin: `big :: proc(x: $T, $size: proc(self: T) -> int) -> bool`, called
  `big(b, size)`; a constant proc parameter, so it stays monomorphic and inlines.
- D: `bool big(T, alias size)(T x)`, called `big!(Blob, size)(b)`.
- The call site knows T from its argument and the provider from the group
  requirement (`requirementKey` already maps a requirement and a type to its
  provider).

Only a bounded fn whose provider is NOT visible from its own module needs this;
everything else keeps today's emission, so no example re-emits. A link symbol is
not enough here: the provider is chosen per instantiation, and a generic cannot
declare "the provider for whatever T is".

## 4. A27: an object in the importer satisfies an imported interface

An interface compiles to a closed tagged union of its satisfiers, by value, with
the call dispatch printed at each call site (`case a.tag of ... Sq_area(tmp)`).
The union is built from usage and the satisfiers it lists are the program's, as
ruled. Two things in it need the importer:

1. the VARIANT TYPE (`Sq`), because the union holds it by value;
2. the MEMBER PROC (`Sq.area`), called from the dispatch.

(2) is solved by §2: a dispatch arm calls a member whose module is not visible
through a link symbol, and the object's module exports its members.

(1) is the open question. Options:

a. **Hoist the data.** Move each satisfier's fields, and the types they
   reference, into a generated module the interface's module imports; the
   members stay behind as an extension in their own module. Keeps values by
   value and the by-value ownership and drop glue unchanged. Cost: splitting a
   `dkObject` into data and members in the AST, and the type closure (a field
   of a type that depends on a const, an alias, a generic) has to move too.
b. **Erase the payload for cross-module interfaces only.** The variant holds a
   tag and a pointer; the drop, copy and each member go through link symbols
   (`tuck_Sq_drop`, `tuck_Sq_copy`, `tuck_Sq_area`). Cost: an allocation per
   conversion, a second representation of an interface value in all three
   backends and in the ownership glue.
c. **Specialise.** Re-emit every fn that touches the interface in the module
   that can see the satisfiers. Keeps by-value and needs no link symbols for
   types, but a `Seq[Shape]` stored by the library and read by its own code does
   not survive it.

Recommendation: (a). It reuses all the existing interface machinery unchanged
and keeps the by-value model; (b) is the fallback if the type closure proves
unmanageable. Single-module interfaces are untouched in every option.

## 5. Order

1. A47 (done): link symbols for registry handlers.
2. A34: provider parameters for foreign providers (§3).
3. A27: member dispatch through link symbols, then the data split (§4a).
