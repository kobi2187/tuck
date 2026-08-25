# core.ptr — Tuck translation

## This module does not translate, and that is the finding.

`core.ptr` is *"raw addresses, for the few places that genuinely need
them: allocators, FFI boundaries, and hardware registers."* Tuck's Tier 1
removes exactly that vocabulary on purpose.

The settled rule, read from `tests/suites/pointer_containment.nim` (the
authority — `LANGUAGE-OVERVIEW.md`'s one-line summary flattens it). It is
**three rules, not one**, and the distinction is about *memory*, not about
pointers:

1. **Legal as an extern parameter.** `cstring`, `Buf` (the builtin
   `uint8_t*`) and opaque handles may all be passed *into* C — Tuck is
   handing over something C already holds, and nothing raw lands in a Tuck
   variable.
2. **Illegal as an extern return, for `cstring`/`Buf`.** A returned
   `cstring` points at bytes whose lifetime is C's and unknowable here.
   Error: *"never returned out of it"*. The binding must return a safe type
   and copy in the impl module — `examples/34-ffi-cstring.tuck` does exactly
   this, and the suite build-and-runs it to prove the wrapping works.
3. **Legal as an extern return, for an *opaque handle*** (a fieldless
   extern type — `typedef struct Counter Counter;`). Explicitly exempt,
   with the reasoning stated in the suite: *"there is nothing to
   dereference and no memory Tuck can read. It is a token the library hands
   out and takes back — every real C API works this way (FILE\*, sqlite3\*).
   Barring it left `counterNew` unwritable in ANY form, since a handle has
   no by-value equivalent to copy out."*

**Storing is illegal in every case, including the exempt one.** A handle
may be returned but still cannot land in a record field, a `Seq` element, a
mixin member, or an actor field — so no pointer outlives the expression
that obtained it.

The spec's rationale is that this is the *point*, not a limitation: *"No
`ref` in Tier 1, so no two names ever denote one record… That is why Tuck
has no `Send`/`Sync`, no borrow checker, no lifetimes — not because those
problems were solved, but because they were never expressible."*

So a `core.ptr` module in Tuck would be a module for saying the one thing
the language is built to make unsayable.

## Where its three real use cases actually go

- **FFI boundaries** — `sys.ffi` already owns this, and Tuck's answer is
  better than a pointer type: `extern [c, header:, lib:]` blocks with
  opaque handles (`type Counter = {}`, emitted as `ptr`/`rawptr`) that can
  cross between externs but never be stored. The constraint is the feature.
- **Hardware registers** — `platform.hal`'s job, through the same extern
  mechanism plus `readDevice`/`writeDevice` (the Nim pass's own rename of
  `read_volatile`, kept for the same reason: "volatile" says nothing about
  *why*, "device" says exactly *when*).
- **Allocators** — `alloc.allocator`'s, and Tuck's `pool`/`arena`
  declarations (`pool RxBuffers = Array[512, u8] [count: 4]`, spec §8)
  are language-level, not a library of pointer arithmetic.

## Recommendation
Delete `core.ptr` from the Tuck-side module list, as with `core.slice`.
Flagged rather than done — deleting a module is worth confirming, and the
`API.nim.md` stays as the record of what the Rust/Nim design intended.
