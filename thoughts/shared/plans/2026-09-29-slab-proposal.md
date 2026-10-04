# Proposal: `slab` — references by index, and the arena over it

2026-09-29. ROADMAP item 9 asks for one proposal covering the slab and the
arena before any code. The owner has ruled the direction (2026-09-28/29): a
`slab` keyword on Tuck's surface, general reference semantics by index, the
arena built on it, chunked storage, "any indexable type" underneath. This
document turns that into a design and lists what still needs a ruling (§10).
Every performance claim cites `benches/SCORES.md` ("Trees", "Slab storage").

## 1. What it is

A slab is a named, owned table of cells of one type. `new` puts a value in a
cell and returns a **reference**: a small value naming the cell. Holding a
reference is how one thing points at another — a parent, a next node, a
shared child — without a pointer and without leaving value semantics for
anything else.

```tuck
type Node:
  data: int
  prev: NodesRef?
  next: NodesRef?

slab Nodes = Node                     # grows; cells never move

fn main() -> int:
  let a = Nodes.new {data: 1, prev: none, next: none}   # none: no link yet (Q4)
  let b = Nodes.new {data: 2, prev: a, next: none}
  a.next = b                          # writes a's cell: b and a now link
  let back = b.prev
  if not back.ok:
    return 0
  back.value.data += 10               # through the link: a.data is 11
  Nodes.free {r: a}
  return back.value.data              # stops: TUCK SLAB [Nodes]: stale reference
```

(Runs on all three backends since phase 2, and stops at the last line with
exit 1.)

What it buys that value semantics cannot say: **identity** (a cursor, a
parent pointer, a doubly linked list), **sharing** (a DAG; two parents, one
child) and **cycles** (a graph).

## 2. What it builds on

- **`pool` (§7.2)** is already a fixed slab: N cells, a tenancy counter per
  cell, a handle of (index, tenancy), a per-pool handle type, and a stale
  handle stops the program. The runtime (`ObjectPool` in all three), the
  handle-type plumbing (`<Pool>Handle`, `isPoolHandleType`), and the
  `exkPoolOp` lowering are the pattern this follows.
- **The resource registry (§7.4)** repeats the same slot-plus-generation
  table for OS handles.
- **`alloc.list`** (stdlib) is the pattern by hand: nodes in one `Seq`,
  `next`/`prev` as `int`. Since 49ff9c7 it is linear on Nim (a read-only
  `Seq` parameter no longer copies); a slab gives it types and stale checks.
- **`lowering_recursive`** stays as it is (§8).

## 3. Surface

```tuck
slab Nodes = Node                          # chunked, grows (the default)
slab Nodes = Node [count: 1024]            # fixed Array: static, embedded
slab Nodes = Node [storage: contiguous]    # one Seq: opt-in (§5)
```

| form | gives |
|---|---|
| `Nodes.new {data: 1, ...}` | `NodesRef` — the fields ARE the construction, built in the cell. With `[count]`: `NodesRef?`, absent when full (as `acquire`) |
| `r.data`, `r.next` | read a field of the cell, checked |
| `r.data = v`, `r.data += 1` | write a field of the cell |
| `Nodes.get {r}` / `Nodes.set {r, value}` | the whole value, copied out / in |
| `Nodes.free {r}` | the cell is reusable; every reference to it is now stale |
| `Nodes.live {r}` | `bool` — is `r` still current? |
| `Nodes.reset` | every cell free, every outstanding reference stale, O(1) |
| `Nodes.count` | live cells |
| `r == s` | identity: same cell, same tenancy |

- **Each slab has its own reference type** (`NodesRef`), so a reference into
  the wrong slab is a type error — the ROADMAP's open "index into the wrong
  slab" question, answered the way `<Pool>Handle` already answers it.
- **A link is `NodesRef?`.** Absent is "no node", through the existing
  optional machinery (`.ok`, `.value`, `lowering_optional`).
- **A reference is a value.** It copies, compares, sits in a field, a `Seq`,
  a record — 8 bytes: a 32-bit index and a 32-bit tenancy.

## 4. Semantics

- **Only a reference aliases.** `let n = Nodes.get {r}` is a copy, as every
  other value in Tuck is. Nothing about records, `Seq` or parameters changes.
- **`let r` may still write `r.data`.** The reference is immutable; the cell
  is not — it belongs to the slab. This is the one place a `let` name reaches
  a write, and it is the point of the feature. (TK-TY13's "a `let` cannot
  change" stays true of the reference itself: `r = s` on a `let` is refused.)
- **A stale reference stops the program** — any read, write, `get`, `set` or
  `free` through a reference whose cell was freed or reset:
  `TUCK SLAB [Nodes]: stale reference to cell 17` and exit 1 on every
  backend, as a stale pool handle does. `live` is how code asks first.
- **Tenancy per cell.** `free` bumps the cell's tenancy and puts it on the
  free list; `new` takes from the free list first. `reset` bumps a
  slab-wide epoch instead of touching every cell (§6).

## 5. Storage: any indexable type

The slab layer — free list, tenancy, typed references, reset — is written
once, over a storage with four operations: length, borrowed read, write,
grow-by-one. Three storages cover every case:

| storage | grows | cells move | measured (8.4M nodes) |
|---|---|---|---|
| **chunks** of 4096 cells (default) | one chunk at a time, no copy | never | build ~120 ms, no pause, lowest peak |
| **fixed** `Array[N]` (`[count: N]`) | never | never | static; embedded; what a pool is |
| **contiguous** `Seq` (opt-in) | doubling | on growth | 370 ms (glibc remap) to 2870 ms with a 1.2 s stall (Nim's allocator) |

Chunks by default because they behave the same on every target and
allocator: growth never copies, never pauses, and a cell's ADDRESS is stable
— which an extern (DMA, `Pool.addr`) needs and contiguous growth cannot give.
Their cost is one extra dependent load: a tree walk is within noise, a read
with no locality 20–40% slower. `contiguous` is for workloads dominated by
scattered reads, or that need one block (SIMD, handing it to C, copying it in
one `memcpy`). The chunk size is a power of two so a reference splits into
chunk and cell with a shift and a mask.

A cell is `{tenancy: u32, value: T}` — the stale check and the read touch one
cache line.

**Two levels (Q8, measured — SCORES.md "Slab storage").** The growable
storage is a fixed top of directory pages, each a fixed array of chunk
pointers, each chunk a fixed array of cells: 64 x 1024 x 4096 = 256M cells
before anything is copied, and then only the 64-entry top. Every allocation
is one of two fixed sizes, made when first needed — which a fixed-block
allocator on a target without a heap can serve. It costs nothing measurable
once the accessor skips the bounds checks its own shift-and-mask makes
redundant (the slab checks the index against its length once, with the
tenancy). A chunk is sized in BYTES (64 KiB, rounded down to a power-of-two
cell count, at least one), so a large element does not make a 4096-cell
chunk of megabytes.

## 6. Freeing

Per-cell `free` with tenancy, plus a whole-slab `reset`:

- `reset` is O(1): a slab-wide epoch is bumped, and a reference carries the
  epoch it was made in (folded into the tenancy's top bits, keeping it 8
  bytes). Cells are then reused in order with their tenancy bumped.
- No reference counting — a cost on every copy of a reference, and cycles
  (the case slabs exist for) would still leak. No tracing collector.
- **At exit, a slab reports cells never freed**, as the registry reports
  resources left open — unless it is declared `[leaks: ok]` (a slab meant to
  live for the whole program says so). §10, Q3.

## 7. Ownership: who may touch a slab

A slab is shared mutable state, and under `--actors:thread` an actor runs on
its own thread. So:

- **A slab belongs to where it is declared.** Inside an actor: that actor's
  handlers, members and `on select` arms only. At top level: main's thread —
  `main`, the fns it calls, and tasks.
- **The checker refuses a top-level slab reached from an actor**, through any
  chain of calls — the same whole-program walk resource kinds already make
  (`semantics.nim`, §7.4's `Demands`). A new TK code.
- **A reference cannot cross an actor boundary**: not in a message payload,
  not in another owner's field. Only values cross (§9.1). A new TK code.

`pool` has the same gap today — nothing stops an actor handler touching a
global pool from another thread. Out of scope here; the same rule fits it.

## 8. What this does NOT change: recursive sum types

`lowering_recursive` keeps boxing each recursive edge. Measured (SCORES.md
"Trees"): after 49ff9c7 it is linear and level across backends, and a node
array per tree value builds 4–10x slower (every construction merges two
arrays) while copying 9x faster. What would win everywhere is one slab per
recursive type, shared by every tree, with nodes never changed in place — a
copy is then the root reference. But a value tree has no `free`, so that
needs reference counts on its nodes, which is its own measurement. Deferred,
and independent of this feature.

## 9. The arena (§7.3) over slabs

An arena is **a lifetime shared by several slabs**:

```tuck-rejected
arena Frame                              # a lifetime, not a block

fn handle({pkt: Packet}) [io]:
  let hdr = Frame.new Header {len: pkt.len}   # FrameRef[Header]
  let body = Frame.new Body {bytes: pkt.bytes}
  ...
  Frame.reset                            # every Frame reference now stale
```

- The compiler gives the arena one slab per element type its `new` sites
  name; `reset` resets them all (their epochs). There is no per-cell `free`
  — that is what makes it an arena.
- **"Cannot outlive the arena" is checked at run time first:** a reference
  made before a `reset` is stale after it, and stops the program if used.
  The static scope analysis §7.3 describes can come later, as a check that
  proves the runtime one never fires.
- `[size: N]` becomes a byte budget over all its slabs; `new` past it is
  `?` absent (as a counted slab's).

The spec's form — `arena X [size: N]:` followed by a block of statements —
is replaced: an arena is a declaration, used anywhere, reset explicitly.
§10, Q5.

## 10. Decisions for the owner

| # | question | recommendation |
|---|---|---|
| Q1 | Freeing: per-cell `free` + tenancy, `reset` by epoch; no RC, no GC | yes |
| Q2 | Implicit `r.field` through a reference (not the pool's explicit `read`) | yes — it is what makes it a reference |
| Q3 | Report unfreed cells at exit, opt out with `[leaks: ok]` | yes |
| Q4 | A `T?` field may be LEFT OUT of a construction and starts absent (today TK-TY16 refuses it, so a node cannot say "no `next` yet") | yes — the same rule R8 gave actor fields |
| Q5 | The arena is a declaration and a lifetime (§9), replacing §7.3's block form | yes |
| Q6 | Top-level slabs belong to main's thread; an actor reaching one, or a reference crossing an actor boundary, is a compile error (§7) | yes |
| Q7 | `pool` stays as it is for now; converging it into a counted slab (plus `addr`) is later | yes |
| Q8 | Chunk size 4096 cells, fixed; a `[chunk: N]` knob only if a workload asks | yes |

**RULED 2026-09-29 (owner): yes to all, with two changes.**

- **Q4 → `none`.** Absent gets a spelling of its own: `none`, a literal whose
  `?T` comes from where it is written — a field in a construction
  (`{data: 1, next: none} Node`), a `return`, an assignment, an argument. A
  field left OUT of a construction is still refused (TK-TY16); `none` is how
  a construction says "no `next` yet".
- **Q8 → no resize may make a program wait.** "With embedded or systems we
  prefer another indirection, 3 ops instead of 2, over unpredictable waiting
  when resizing. Even an array of chunks of chunks — then copying once if
  really reached even that huge amount. Arrays created at run time as needed
  keep memory low." So the chunk DIRECTORY must not grow by copying either:
  a fixed top level of directory pages, each a fixed array of chunk
  pointers, each chunk a fixed array of cells — every allocation one of two
  fixed sizes, made when first needed, and nothing copied until the top level
  itself is full. Measured before it is built (§5, "Two levels").

## 11. Building it

Each phase ends green on all three backends, with the full suite.

1. **Runtime.** `Slab[T]` over chunks / fixed / contiguous in `tuck_rt.nim`,
   `tuck_rt.odin`, `tuck_rt.d`: `new`, `free`, `live`, `reset`, checked
   borrowed read, write, count, the stale-reference stop. Exercised through
   the phase-2 surface, and by a bench against `alloc.list`'s hand-written
   index form and the boxed tree.
2. **The declaration.** `dkSlab` (its own node kind, per CLAUDE.md), the
   parser, the checker (element type, `count`/`storage` attributes, the
   `NodesRef` type, `new`/`free`/`live`/`reset`/`get`/`set`/`count`, field
   access and assignment through a reference, `NodesRef?` links), mangling,
   and the three emitters. Q4 lands here if ruled.
3. **Ownership** (§7): the actor-reach and boundary checks, with their TK
   codes and `tuck explain` texts.
4. **The arena** (§9) over phase 1's slabs.
5. **Docs and specimens:** spec §7.3/§7.x, LANGUAGE-OVERVIEW §15, an example
   program per shape — doubly linked list, tree with parent links, graph
   with a cycle — each run-gated with an expected exit code.

## 12. Open after phase 5 — the gaps P2 showed

Recorded 2026-10-04, after the declaration ran on all three backends. A slab
reference covers identity, sharing and cycles; these are the reference uses it
does not yet cover. Owner: "when the feature is done, it's time for bug fixes
and handling discovered gaps."

1. **Generic code over slabs** — first. A reference type and its operations
   are per slab (`NodesRef`, `Nodes.free`), so `fn length` over a linked list
   is written once per slab; a `std` container cannot be written at all.
   Owner, 2026-10-04: "since Slab is a single shaped data type, it should be
   easy to pass a type as generic." Every slab IS one shape — the runtime's
   `SlabChunked[T]` / `SlabFixed[T, N]` / `SlabSeq[T]` over one `SlabRef` —
   so the question is only the surface. Two candidates, to be put to the
   owner with a sketch each:
   - **the slab as a type parameter**: `fn length[S: slab]({head: S.Ref?})`,
     its operations reached as `S.free {r}`, instantiated per slab the way a
     generic fn is per type today;
   - **the operations through the reference**: `r.free`, `r.live`, with
     `fn length[T]({head: Ref[T]?})` — the slab found from the reference's
     type, so a generic fn names only the element.
2. **Interior references.** A reference names a whole cell — not one of its
   fields, not an element of a `Seq` inside it. Today: a cell reference plus
   the field or index.
3. **References to locals.** No `&x` for an out-parameter or a swap; Tuck
   returns values instead, as everywhere else. Probably stays so — listed
   so that it is a decision, not an omission.
4. **Automatic lifetime.** No reference counting and no collector: freeing
   is `free`, a forgotten one is in the exit report, and P4's arena gives a
   group of cells one lifetime ended by one `reset`.
5. **Across actors.** P3 makes it a compile error (Q6) — closed by design,
   not open.

