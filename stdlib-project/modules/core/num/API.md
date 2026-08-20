# core.num

## Purpose
Explicit-overflow-behavior arithmetic for the fixed-width integer types — checked (returns `Option`/`Result`), wrapping (defined modular behavior), and saturating (clamps to the type's min/max) variants of every arithmetic operation — plus explicit endianness conversion for reading/writing binary data.

## Design lineage
Modeled on Rust's integer methods (`checked_add`, `wrapping_add`, `saturating_add`, `to_be_bytes`/`from_le_bytes` as the standard vocabulary for making overflow behavior an explicit choice rather than either silent UB or a silent wraparound) and Zig's `std.math` (which shares the same philosophy that a plain `+` should be a deliberate, audited choice — Zig even makes unchecked overflow a safety-checked panic in debug builds). The report's Part II ties silent integer overflow (C/C++'s UB on signed overflow, silent wraparound elsewhere) to a well-documented real-world defect category (integer-overflow-triggered buffer overruns); this module's entire purpose is closing that gap by making every arithmetic operation's overflow behavior a name in the API, not an assumption.

## Proposed API
```
impl u32 {   // representative; the same method set exists on every fixed-width int type
    fn checked_add(self, rhs: u32) -> Option<u32>;
    fn checked_sub(self, rhs: u32) -> Option<u32>;
    fn checked_mul(self, rhs: u32) -> Option<u32>;
    fn checked_div(self, rhs: u32) -> Option<u32>;       // None on divide-by-zero too

    fn wrapping_add(self, rhs: u32) -> u32;
    fn wrapping_sub(self, rhs: u32) -> u32;
    fn wrapping_mul(self, rhs: u32) -> u32;

    fn saturating_add(self, rhs: u32) -> u32;
    fn saturating_sub(self, rhs: u32) -> u32;
    fn saturating_mul(self, rhs: u32) -> u32;

    fn overflowing_add(self, rhs: u32) -> (u32, bool);   // value + did-it-overflow flag

    fn to_be_bytes(self) -> array::Array<u8, 4>;
    fn to_le_bytes(self) -> array::Array<u8, 4>;
    fn from_be_bytes(bytes: array::Array<u8, 4>) -> u32;
    fn from_le_bytes(bytes: array::Array<u8, 4>) -> u32;

    fn leading_zeros(self) -> u32;
    fn count_ones(self) -> u32;

    // Added (sudoku-solver): bit manipulation was present only as the two
    // methods above (count_ones, leading_zeros) — everything else needed to
    // treat an integer as a bitset (test/set/clear a specific bit position,
    // find the lowest set bit, iterate all set positions) was missing and
    // would otherwise force manual shift-and-mask code at every call site.
    fn trailing_zeros(self) -> u32;                     // position of the lowest set bit; 32 if self == 0
    fn is_bit_set(self, index: u32) -> bool;             // index must be < bit width; panics like array indexing does
    fn set_bit(self, index: u32) -> u32;                 // returns a new value with bit `index` set to 1
    fn clear_bit(self, index: u32) -> u32;                // returns a new value with bit `index` set to 0
    fn toggle_bit(self, index: u32) -> u32;

    // Iterate the positions of set bits, ascending, without materializing
    // a Vec — built from trailing_zeros + the "clear lowest set bit" idiom
    // (self & (self - 1)), so cost is O(popcount), not O(bit width):
    fn ones(self) -> impl iter::Iterator<Item = u32>;
}
```

## Key design decisions
- Plain `+`/`-`/`*` operators are left defined with debug-mode overflow trapping and release-mode wrapping (matching the report's endorsement of Zig's approach) rather than either always trapping (a runtime-cost tax on every hot loop) or always silently wrapping (reintroducing the exact defect category this module exists to close) — the four explicit families (`checked_`/`wrapping_`/`saturating_`/`overflowing_`) exist precisely so code that *needs* a specific behavior never has to depend on the operator's build-mode-dependent default.
- Endianness conversion methods (`to_be_bytes`/`from_le_bytes`) return/accept `core.array`'s fixed-size `Array<u8, N>`, not `core.slice`'s `Slice<u8>`, so a call site handling a 4-byte value cannot accidentally pass or receive a mis-sized buffer — reusing `core.array`'s type-level size guarantee rather than a runtime length check.
- `checked_div` folding divide-by-zero into the same `Option`-returning family as overflow (rather than treating it as a separate panic-only case, C's convention) keeps exactly one error-handling shape for "this arithmetic operation might not produce a valid result," consistent with Principle 4.
- **Revision (sudoku-solver): bit manipulation was under-specified, not absent by design.** The original method set had `count_ones` and `leading_zeros` (inherited from the endianness/overflow survey, where they show up mostly as byte-swapping helpers) but nothing to test, set, or clear an individual bit, find the lowest set one, or walk the set ones in order — a real gap, not a deliberate scoping decision, since "use an integer as a small bitset" is a distinct, common use of an integer that has nothing to do with the checked/wrapping/saturating arithmetic families the module was otherwise built around. `set_bit`/`clear_bit`/`toggle_bit` return a new value rather than mutating in place, consistent with every other method on this primitive, Copy-typed integer (`wrapping_add` etc. already return rather than mutate) — there is no special-cased mutable-bitset wrapper type; a plain `u16` (9 candidate bits fit in one) *is* the bitset, which keeps this addition inside `core.num` rather than motivating a new type or module. `ones()` is the one genuinely new *shape* here (an iterator, not a value-returning method) — it's included because "iterate set bit positions" is a distinct enough operation from "test/set one bit" that hand-rolling it at every call site (a `while x != 0 { ... x &= x - 1 }` loop) is exactly the kind of ceremony `core.iter`'s existence argues against reintroducing one level down.
- **Cross-tier consistency note:** this same bit-manipulation gap would have resurfaced verbatim in `platform.hal`-style register manipulation (reading a status register and asking "which interrupt flags are set," or building a peripheral config word bit-by-bit) — sudoku-solver's 9-bit candidate set and a microcontroller's 32-bit register are the same underlying need (test/set/clear/iterate bits on a fixed-width integer) wearing different application domains. Resolving it once, generically, in `core.num` (rather than, say, ad hoc inside `platform.hal` for registers and again inside whatever a future bitset-heavy app needed) is the tier-by-weakest-dependency argument (Principle 1) applied to a method set, not just a type: any tier above `core` gets this for free rather than re-deriving it.

## Validated by applications
- **embedded-sensor-node**: raw I2C sensor bytes must be reassembled with an explicit, hardware-datasheet-specified endianness, and battery-voltage/ADC scaling on a target with no floating-point unit needs fixed-point arithmetic built from checked/saturating integer operations rather than floats — this app is the direct validation that `to_be_bytes`/`from_be_bytes` and saturating arithmetic need to be zero-cost and allocation-free (already guaranteed by Tier 0 placement), and that they compose cleanly with `core.convert::TryFrom` at the register-to-typed-reading boundary described in that module's doc.
- **mp3-player**: sample format conversion (e.g., 16-bit PCM ↔ float, volume scaling) must not overflow into audible clipping artifacts or wrap into loud noise — `saturating_add`/`saturating_mul` are the direct fit, and this app's real-time constraint confirmed these need to be genuinely branch-cheap (ideally compiling to a native saturating instruction where the target has one) rather than an `Option`-based checked path that would need unwrapping on every sample in a hot loop — this is what motivated keeping `saturating_*` and `checked_*` as separate families rather than deriving saturating behavior from checked behavior at every call site.
- **archive-cli**: reading untrusted archive headers (entry sizes, offsets, compressed/uncompressed length fields) is a well-known source of integer-overflow-triggered decompression-bomb and buffer-overrun bugs in real archive tools; this app is the direct validation that `checked_add`/`checked_mul` (not saturating or wrapping) must be the default posture for any arithmetic on values sourced from an untrusted file, and that `core.error`'s `Result` propagation composes cleanly with `Option`-returning checked arithmetic via `core.types::Option::ok_or`.
- **math-toolkit-cli**: `std.math`'s `Decimal` type (exact money arithmetic) is implemented as a scaled integer underneath, and this app's `mtk money "19.99" + "5.005"` requirement — a cent must never silently vanish — is a direct validation that `checked_add`/`checked_mul` on the underlying fixed-width representation, not the debug-trap/release-wrap default of plain operators, must be what `Decimal` calls internally; the statistics subcommand's running-sum accumulation over a CSV column is the same story one layer up, confirming this module's existing generic method set (already specified as present on every fixed-width int type, no new type needed) is sufficient without `core.num` itself knowing anything about decimals or statistics.
- **sudoku-solver**: each cell's candidate set (digits 1-9 still possible) is naturally a 9-bit integer bitset, and constraint propagation (naked singles: "exactly one bit set", hidden singles: "this digit's bit is set in exactly one cell of a group", pointing pairs) is fundamentally repeated bit testing, clearing, and popcount over these sets — this app is the direct validation that the bit-manipulation gap above was real: without `is_bit_set`/`clear_bit`/`ones()`/`count_ones`, the solver's core loop would be forced into manual `(mask >> i) & 1` shift-and-mask code at every step, which is exactly the ceremony a stdlib bitset method set exists to remove. `ones()` specifically is what makes "for each remaining candidate digit in this cell" a one-line `for d in cell.candidates.ones()` loop rather than a 9-iteration scan-and-skip.
- **kv-store-server**: `INCR`/`DECR` on a stored integer value must report an error rather than silently wrapping past `i64::MAX`/`MIN` (the classic Redis-observed footgun this command family is named after) — a direct, unmodified use of `checked_add`'s `Option`-returning shape, and a useful confirmation that a *server* command handler (not just a CLI or firmware routine) is a natural, ordinary caller of this module's existing API with zero extension needed.

## Open questions / risks
Whether `core.num` should also standardize a fixed-point (`Q-format`) numeric type for float-less embedded targets like `embedded-sensor-node`'s battery/ADC scaling, or leave that to `platform.dsp`, is unresolved — currently the app is served by saturating integer arithmetic alone, which may prove insufficient for more demanding fixed-point math.
