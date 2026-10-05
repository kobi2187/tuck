# Proposal: generic code over slabs

2026-10-04. This is the first gap left open after the slab's phase 5
(`2026-09-29-slab-proposal.md` §12.1). Owner, 2026-10-04: "since Slab is a
single shaped data type, it should be easy to pass a type as generic."

This document does three things:
- it turns that into a surface;
- it says what the compiler does today, probed against `7640082`;
- it lists what needs a ruling (§6).

Nothing here is built.

## 1. The gap

A reference type and its operations belong to one slab (`NodesRef`, `Nodes.free`). So:
- a `length` over a linked list is written once per slab;
- a `std` container cannot be written at all, because `std` cannot name a slab its user declares.

The obvious attempt is worse than a refusal. It checks clean and builds on no backend:

```tuck
fn length[R]({head: R?}) -> int:
  var n = 0
  var cur = head
  for cur.ok:
    n = n + 1
    cur = cur.value.next      # R is a type parameter: the read is Unknown
  n
```

`cur.value.next` is emitted as a field of the 8-byte reference itself, which
has none. Nim says `undeclared field: 'next' for type SlabRef`. A field read
through a reference has to go through its slab, and this body does not know
which slab.

## 2. Proposed: the slab is a type parameter

Every slab has one shape: a `Slab[T]` over chunked, fixed or contiguous
storage, with one 8-byte `SlabRef`. So a slab can be passed the way a type
is:

```tuck
fn length[S: slab]({head: Ref[S]?}) -> int:
  var n = 0
  var cur = head
  for cur.ok:
    n = n + 1
    cur = cur.value.next
  n

fn freeAll[S: slab]({refs: Seq[Ref[S]]}):
  for r in refs:
    S.free {r}

fn main() -> int:
  ...
  let a = {head: h} length         # S is Nodes, read from h: NodesRef?
  let b = {head: k} length         # k: TasksRef? — S is Tasks, a second copy
```

- **`S: slab`.** The bound word is the declaration's keyword. `[S: slab]` already parses.
- **`Ref[S]`.** A reference into S. `Ref[Nodes]` and `NodesRef` are one type:
  - generic code writes the long form;
  - other code keeps writing the short one.

  `S.Ref` would need a new type syntax, since a type is qualified with `::`. `Ref` names nothing today.
- **`S.new`, `S.free`, `S.live`, `S.get`, `S.set`, `S.reset`, `S.count`.** The slab's operations, written as on a named slab.
- **Inference.** A call infers S from an argument's reference type. Where there is no reference yet, only `none`, the binding states it: `let empty: IntsRef? = none`.

  A call naming its type arguments (`push[int, Ints]`) is missing for every
  generic today (`{} zero[int]` is "cannot infer"). That is a general
  generics gap, not this one's (Q6).

**How it is built.** The same way an interface bound is today (`iface_generics.nim`):
1. The checker records which slab S is at each call.
2. The fn is copied once per slab (`length_Nodes`), with S replaced by the slab.
3. The program is checked again, and the generic original is dropped.

Every copy is ordinary code that names one slab, so these see nothing new:
- P3's ownership check (TK-AC08: which owner touches which slab);
- Odin's drop procs;
- the three emitters.

What S holds is known only in a copy, so a field read through `Ref[S]` is
checked there. An error names the copy and points at the generic's line:
`length, copied for slab Nodes: no field 'next' on Item` (Q5).

## 3. A container: the cell names its own slab

This is the case that motivates the work: a `std` list. Its cell links to the slab
that holds it, and `std` cannot name that slab. The same parameter does it,
on a type:

```tuck-rejected
# std/list — a bound on a type's parameter does not parse yet (below)
type Cell[T, S: slab]:
  value: T
  next: Ref[S]?

fn push[T, S: slab]({head: Ref[S]?, value: T}) -> Ref[S]:
  let c = {value: value, next: head} Cell
  S.new {value: c}
```

```tuck
# the user's module
import list

slab Ints = list::Cell[int, Ints]   # names itself, as `next: NodesRef?` does today

fn main() -> int:
  let empty: IntsRef? = none
  let a = {head: empty, value: 1} list::push
  let b = {head: a, value: 2} list::push
  ...
```

At emit time S is erased. `Ref[S]` is `SlabRef` on every backend, so the host
type is `Cell[T]`.

A slab of a generic record works since 2026-10-04: `slab Ints = Link[int,
IntsRef]` with `new`, `set` and links through it, on all three backends
(`slabs`). That needed no ruling. Probing this proposal found it refused
(`Ints.new` read the element as having no fields), together with two
generic-record bugs beside it.

Two things here do not work today:
- **A bound on a type's parameter.** `type Cell[T, S: slab]` is "Expected generic parameter name".
- **Across modules.** The copy of `list::push` for `Ints` must live where both are visible: the user's module, naming list's own fns qualified. That is the placement problem A34 already has (a group bound whose provider is in another module). It is also why an interface bound is module-local today. Solve it once for both.

## 4. The alternative: the slab found from the reference

```tuck
fn length[T]({head: Ref[T]?}) -> int:    # T: the ELEMENT type
  ...

fn drop[T]({r: Ref[T]}):
  r.free                                 # the reference finds its slab
```

This is nicer to write: a generic fn names only the element. But two slabs of
one element type (`slab Free = Block`, `slab Busy = Block`) make `Ref[Block]`
ambiguous. That leaves two ways out, and neither is free:
- **The reference carries its slab at run time.** Either a slab number takes bits from the tenancy, or the reference grows to 12–16 bytes. With 24 tenancy bits, a cell's stale check wraps after 16M reuses instead of 4G. Every operation through a `Ref[T]` then dispatches on that number.
- **The fn is copied per reference type anyway.** That is §2 with the slab left unnamed.

P3 also loses precision. Which slab a `Ref[T]` fn touches is "any slab of T".
So an actor calling it on its own slab is refused (TK-AC08) whenever main
also has a slab of T. Not recommended.

## 5. Phases

1. **Module-local.**
   - `[S: slab]` on fns, `Ref[S]`, and `S.<op>`.
   - Inference from a reference argument; a copy per slab; the original dropped.
   - `[S: slab]` on a type, erased at emit.
   - The form in §1 is refused with a TK code naming `[S: slab]`, not left to fail in the host.

   Run-gated on all three backends: `length` and `freeAll` over two slabs, and a list whose cell names its slab.
2. **Across modules.** A generic from module L used with a slab from module U, placed in U, together with A34. Then `std/list` over slabs, and an example.
3. **Arenas** (`[A: arena]`), only if a use asks. An arena's references are already generic over their element (`FrameRef[T]`).

## 6. Decisions for the owner

| # | question | recommendation |
|---|---|---|
| Q1 | Generic code names the slab, `fn f[S: slab]`, and is copied once per slab (§2), rather than naming only the element with the slab found from the reference (§4) | yes |
| Q2 | `Ref[S]` is the reference type in generic code; `Ref[Nodes]` and `NodesRef` are one type | yes |
| Q3 | A type may take a slab parameter, so a container's cell names the slab it lives in: `type Cell[T, S: slab]`, `slab Ints = Cell[int, Ints]` (§3) | yes |
| Q4 | `r.free` / `r.live` as short forms of `S.free {r}` / `S.live {r}` | not now: `r.name` is the element's field space, and an element may have a `free` field |
| Q5 | A field read through `Ref[S]` is checked in each copy, not against a contract on the element | yes for now; a bound on the element only if a use asks |
| Q6 | A call may name its type arguments (`{...} push[int, Ints]`), for every generic, so that `none` can start a list | yes, as its own item after phase 1 |
