# core.types

## Purpose
Defines the primitive value vocabulary shared by every other tier: fixed-width numeric types, `bool`/`char`, the `Option<T>`/`Result<T, E>` sum types, tuples, and fixed-size array *types* (as distinct from `core.array`'s operations on them). Everything above this module — including `core.error` — is built on `Option`/`Result`, so this module has zero dependencies of its own.

## Design lineage
Modeled on Rust's `core::option`/`core::result` (sum types as the universal "maybe absent" / "maybe failed" vocabulary, checked exhaustively by the compiler) and Zig's error-union types (`!T`, which fuse a success value and an error set at the type level). The report's Part II survey flags null-pointer/exception-based absence-handling (Java pre-`Optional`, C null pointers) as a recurring defect category; `Option`/`Result` as *the* representation, used with no alternative, is the direct fix, and it is what makes Principle 4 ("one coherent idiom per cross-cutting concern") possible for error handling in `core.error`.

## Proposed API
```
enum Option<T> { Some(T), None }
enum Result<T, E> { Ok(T), Err(E) }

impl<T> Option<T> {
    fn is_some(&self) -> bool;
    fn map<U>(self, f: impl FnOnce(T) -> U) -> Option<U>;
    fn unwrap_or(self, default: T) -> T;
    fn unwrap_or_else(self, f: impl FnOnce() -> T) -> T;
    fn ok_or<E>(self, err: E) -> Result<T, E>;
    fn as_ref(&self) -> Option<&T>;
}

impl<T, E> Result<T, E> {
    fn is_ok(&self) -> bool;
    fn map<U>(self, f: impl FnOnce(T) -> U) -> Result<U, E>;
    fn map_err<F>(self, f: impl FnOnce(E) -> F) -> Result<T, F>;
    fn unwrap_or(self, default: T) -> T;
    fn ok(self) -> Option<T>;
}

// Fixed-size array TYPE (operations live in core.array):
type FixedArray<T, const N: usize> = [T; N];

// Tuple types are structural, up to some fixed arity (e.g. 12), with
// positional field access: t.0, t.1, ...

// Primitive aliases with explicit width, no platform-dependent "int":
type i8; type i16; type i32; type i64; type i128;
type u8; type u16; type u32; type u64; type u128;
type f32; type f64;
type usize; type isize;   // pointer-width, used only for sizes/indices
type bool; type char;     // char is a Unicode scalar value, not a byte
```

## Key design decisions
- `usize`/`isize` exist only for sizes and indices, never as a general-purpose integer default — this avoids the C convention of `int` silently standing in for "index," "count," and "arbitrary number," which the report's survey ties to a class of overflow and truncation bugs.
- `char` is defined as a Unicode scalar value (not a byte, not a UTF-16 code unit), so `core.str`'s iteration has a well-defined element type from day one instead of retrofitting one, as several surveyed languages (C, early Java) had to.
- `Option`/`None` deliberately has no implicit conversion to/from a "zero" or "null" sentinel of any primitive type — absence is only ever representable as `Option::None`, closing the null-pointer-equivalent hole by construction.
- No exceptions and no separate panic-value type: `Result<T, E>` is the only carrier for recoverable failure, and `E` is left fully generic rather than fixed to one exception hierarchy, so every tier can define its own error enum without inheriting an unrelated base type.

## Validated by applications
- **embedded-sensor-node**: the app profile lists `core.types` as directly exercised because nothing above `core` exists on this target — sensor reads, filter state, and ring-buffer entries are all built from primitives, `Option` (no reading yet), and fixed arrays with no heap. This confirmed that `Option<T>` must be representable with zero runtime overhead over a raw value for common cases (e.g. `Option<u16>` for a not-yet-sampled ADC reading) — the design leans on niche-filling (using an otherwise-invalid bit pattern for `None`) rather than a separate discriminant tag, matching Rust's `NonZeroU16`-style optimization, since a discriminant byte per sample would double the size of the flash ring buffer.
- **secrets-vault**: wrong-passphrase and corrupt-vault outcomes are naturally `Result<Vault, VaultError>` rather than a thrown exception, which matters because the app's "fail closed" requirement means the *type system*, not caller discipline, should force every call site to handle the failure path before touching decrypted data.
- **todo-cli**: `Option<Task>` for "task with this UUID may not exist" and `Result` for corrupt-storage parsing were both needed from the same primitive; originally considered a single "nullable result" type to reduce vocabulary, but todo-cli's undo log showed that "absent" (no such task) and "failed" (storage unreadable) are semantically different call-site responses, confirming two distinct sum types are worth the small extra surface.

## Open questions / risks
Whether tuple arity should be capped (and where) is unresolved; capping too low pushes users toward ad hoc structs (arguably fine), capping too high adds compiler/tooling burden for a rarely-used tail.
