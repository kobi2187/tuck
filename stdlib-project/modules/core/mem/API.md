# core.mem

## Purpose
Explicit control over memory layout and (de)initialization: `size_of`/`align_of` for any type, `swap`/`replace`/`take` for moving values without aliasing, and `MaybeUninit<T>` for representing memory that exists but has no valid value yet — the toolkit every allocator, buffer, and FFI boundary in higher tiers is built from.

## Design lineage
Modeled on Rust's `core::mem` (`size_of`/`align_of` as compile-time-resolvable functions, `MaybeUninit<T>` as the sanctioned way to hold uninitialized memory instead of UB-inducing zero-initialization-by-convention) and Zig's `@sizeOf`/`@alignOf` builtins plus its culture of explicit, visible (de)initialization at every allocation site. The report names Zig's explicitness as a direct model (Part II, "ideas worth stealing") for making memory behavior auditable rather than assumed.

## Proposed API
```
fn size_of<T>() -> usize;              // compile-time constant
fn align_of<T>() -> usize;
fn size_of_val<T>(val: &T) -> usize;   // for dynamically-sized types

fn swap<T>(a: &mut T, b: &mut T);
fn replace<T>(dest: &mut T, src: T) -> T;   // returns old value, no double-drop
fn take<T: Default>(dest: &mut T) -> T;     // replace with T::default()

struct MaybeUninit<T> { /* opaque: T-sized/aligned storage, no drop, no read guarantee */ }

impl<T> MaybeUninit<T> {
    fn uninit() -> Self;
    fn zeroed() -> Self;                         // only where all-zero is a valid bit pattern
    fn write(&mut self, value: T) -> &mut T;
    unsafe fn assume_init(self) -> T;             // caller proves it was written
    fn as_ptr(&self) -> ptr::Ptr<T>;
}

fn drop<T>(value: T);                             // explicit early destruction
fn forget<T>(value: T);                           // suppress destructor, e.g. ownership handed to FFI

// Zero-on-drop wrapper for sensitive memory (secrets, key material):
struct Zeroizing<T> { /* wraps T; on drop, overwrites the backing memory with zero
                          via a call the optimizer is forbidden to elide */ }
impl<T> Zeroizing<T> {
    fn new(value: T) -> Self;
}
```

## Key design decisions
- `MaybeUninit<T>` is the *only* sanctioned representation of "allocated but not yet valid" memory; there is no implicit zero-initialization anywhere in `core` or `alloc`, forcing every buffer-then-fill pattern (I/O reads, hardware register capture, decoder scratch space) through a type the compiler tracks the init-state of, rather than the C convention of an ordinary `T` that happens to hold garbage.
- `Zeroizing<T>` is included in `core.mem` rather than left entirely to `std.crypto`, specifically because the report's `secrets-vault` app profile poses this as an open question the Part IV design left implicit — the resolution taken here is that "guaranteed, non-elidable zero-on-drop" is a memory-layout concern belonging at this tier, with `std.crypto`/`alloc.string` building secret-holding types on top of it rather than each reinventing zeroing.
- `forget` exists as an explicit, named escape hatch (never an implicit leak) for FFI ownership transfer — consistent with Principle 2's "nothing hidden," a leaked destructor must be visible in the source, not an accidental consequence of a dropped `Result`.

## Validated by applications
- **secrets-vault**: this is the primary forcing function named directly in the app's "Anticipated API stress points" — whether `alloc.string`/`alloc.vec` (built on `core.mem`) offer any way to request zero-on-drop, non-swappable memory for secret material. The naive first design had no `Zeroizing<T>` at all and pushed zeroing entirely into `std.crypto` as a bespoke `SecretBytes` type; this app's "no plaintext ever touches disk or logs" requirement, combined with "atomic vault updates" needing decrypted buffers to exist transiently in memory, showed zeroing needs to be a `core.mem` primitive so *any* type (not just a crypto-specific one) can opt in, including the app's own in-memory plaintext staging buffers.
- **mp3-player**: the audio callback thread's double-buffering / lock-free handoff between UI and audio threads relies on `swap`/`replace` semantics to hand off a filled sample buffer without a copy and without ever leaving a buffer in a half-initialized state visible to the other thread — `MaybeUninit` is how the pool-allocated buffers are represented before the decoder has filled them, avoiding a wasted zero-fill on a real-time path where every microsecond is budgeted.
- **embedded-sensor-node**: the I2C read buffer and register-capture sequence are the textbook `MaybeUninit` use case — memory exists (statically allocated, no heap) but has no valid sensor value until the bus transaction completes; this confirmed `MaybeUninit` needs to work with zero runtime cost and no heap dependency, validating it belongs in `core`, not `alloc`.

## Open questions / risks
Whether `Zeroizing<T>`'s "non-elidable" guarantee is something `core` can promise portably across every target's optimizer, or whether it needs a platform-specific `platform`-tier hook for the hardest embedded cases, is flagged as unresolved.
