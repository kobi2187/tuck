# core.mem — Tuck translation

## Shape decision
Mostly **absorbed by the language**. What's left is small enough that this
module may not be worth keeping as its own unit — flagged at the end.

## `Unfilled[T]` is a compiler rule in Tuck, not a library type

The Nim design's centrepiece was `Unfilled[T]` — *"memory that is the right
size and alignment for a `T` but has no valid `T` in it yet. The only
sanctioned way to say that."* It wrapped `array[sizeOf(T), byte]` plus a
`filled` flag, and the Nim pass renamed Rust's `MaybeUninit<T>` to it
specifically so *"the 'prove you initialized it' ceremony becomes the
library's ordinary absence idiom."*

**Tuck tracks this in the checker instead.** A field the construction
skipped carries a compile-time `<uninit>[T]` marker on the field's type
inside the variable's own type; *reading* it is the error, assigning to it
clears the marker (`tests/suites/uninit.nim`, a suite of its own). So the
"prove you initialized it" guarantee holds with **no wrapper type, no
runtime flag, and no `get` returning an optional** — the compiler refuses
the read outright.

That is strictly better than the library version it replaces: `Unfilled[T]`
could be forgotten (just declare an ordinary `T` full of garbage instead),
whereas the marker applies to every partially-constructed record whether
the author thought about it or not.

## What's left, and where it goes

| Nim design | Tuck |
|---|---|
| `Unfilled[T]`, `blank`, `zeroed`, `fill`, `get` | the `<uninit>` checker rule — gone from the library |
| `addressOf` (hand the buffer to DMA) | `sys.ffi`'s extern boundary; a pointer may cross but never be stored (see `core.ptr`) |
| `sizeOf`/`alignOf`/`sizeOfValue` | no verified compile-time-reflection equivalent in this pass — open |
| `swap`/`swapIn`/`takeOut` | value semantics forbids the `var T` parameters these need; the `swapIn`/`takeOut` idiom is "return the new value" instead |
| `Scrubbed[T]` (zero-on-drop for secrets) | **genuinely missing** — see below |

## The one real gap: secret scrubbing

`Scrubbed[T]` wraps a value and overwrites its memory on scope exit *"using
a write the optimizer is forbidden to remove."* That's a real requirement
(`secrets-vault` drove it, and `INDEX.md` records it as a finding that
changed the design), and Tuck has no counterpart: no destructor hook, no
scope-exit action, and the optimizer-barrier property needs backend
cooperation in both Nim and Odin.

Worth its own decision rather than being buried here. Note it interacts
with `alloc.allocator`'s `SecureAllocator`/`Secret[T]` — which was
`INDEX.md`'s round-0 answer to the same problem at a different level — so
resolving one should resolve both.

## Recommendation
With `Unfilled` absorbed and `addressOf` belonging to `sys.ffi`, this
module reduces to `sizeOf`-style reflection (unresolved) plus secret
scrubbing (a real gap needing a language answer). **Consider folding it
away** and tracking the scrubbing question with `alloc.allocator`'s
`Secret[T]` instead. Flagged, not done.
