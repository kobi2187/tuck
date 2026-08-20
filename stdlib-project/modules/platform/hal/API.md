# platform.hal

## Purpose
A trait-based abstraction over microcontroller peripherals — GPIO, SPI, I2C, UART, ADC, PWM, timers, and DMA — so driver and application code compiles unmodified against any silicon vendor's implementation, provided that vendor's board-support crate implements the traits.

## Design lineage
Modeled directly on Rust's `embedded-hal` — the report (Part IV, Part V) names it explicitly as "the direct model for the proposal" and "the single most reusable idea for the platform tier." `embedded-hal` is not officially part of Rust's `std`; it lives as a community crate precisely because hardware trait sets evolve faster than language release cycles (Part V's core risk). This design keeps that lesson: `platform.hal` ships as a stable, versioned trait set with an explicit escape hatch, rather than pretending the traits can be frozen once and never touched again.

## Proposed API
```
trait OutputPin {
    fn set_high(&mut self) -> Result<(), Self::Error>;
    fn set_low(&mut self) -> Result<(), Self::Error>;
    type Error;
}

trait InputPin {
    fn is_high(&self) -> Result<bool, Self::Error>;
    type Error;
}

enum Edge { Rising, Falling, Both }

// Configures a pin's edge-detect hardware and binds it to a vector — this is the
// only place in `platform.hal` that talks to `platform.interrupt`'s IrqVector type,
// and deliberately stops there: `InterruptPin` configures the pin, it does not
// register a handler or decide wake-source policy (see platform.interrupt and
// platform.power for those, respectively).
trait InterruptPin: InputPin {
    fn enable_interrupt(&mut self, edge: Edge) -> Result<IrqVector, Self::Error>;
    fn disable_interrupt(&mut self) -> Result<(), Self::Error>;
}

trait I2c {
    type Error: I2cError;   // categorizes NoAck, BusError, ArbitrationLoss, Timeout
    fn write_read(&mut self, addr: u8, tx: &[u8], rx: &mut [u8], timeout: Duration)
        -> Result<(), Self::Error>;
    fn write(&mut self, addr: u8, tx: &[u8], timeout: Duration) -> Result<(), Self::Error>;
    fn read(&mut self, addr: u8, rx: &mut [u8], timeout: Duration) -> Result<(), Self::Error>;
}

trait SpiBus {
    type Error;
    fn transfer(&mut self, rx: &mut [u8], tx: &[u8]) -> Result<(), Self::Error>;
    fn transfer_in_place(&mut self, words: &mut [u8]) -> Result<(), Self::Error>;
    fn write(&mut self, tx: &[u8]) -> Result<(), Self::Error>;
    // Write-only, no rx buffer required. Most SPI displays are write-only devices;
    // forcing every framebuffer push through `transfer(rx, tx)` would require a
    // same-size scratch rx buffer (potentially several KB) whose only purpose is
    // satisfying a full-duplex signature the display never uses — RAM this tier
    // can't spare. Default impl may delegate to `transfer_in_place` on buses that
    // are physically full-duplex-only, but the caller never has to allocate for it.
}

// Extension trait: buses backed by a DMA channel implement this in addition to
// SpiBus. Not all SpiBus implementations can — a bit-banged or minimal-silicon
// bus has no DMA channel to offer — so this is opt-in, not folded into SpiBus itself.
trait SpiBusDma: SpiBus {
    fn write_dma(&mut self, tx: &'static [u8]) -> Result<DmaHandle, Self::Error>;
    // Non-blocking bulk write; caller polls completion via `Dma::poll` (above).
    // A blocking `write()` of a multi-KB framebuffer would hold the CPU busy-spinning
    // on the SPI peripheral for the whole transfer, which is directly at odds with a
    // device whose power budget is dominated by "how long can it stay asleep" — the
    // CPU can't even attempt WFI/enter_sleep until a blocking transfer completes.
}

trait Uart {
    type Error;
    fn write(&mut self, bytes: &[u8]) -> Result<usize, Self::Error>;
    fn read(&mut self, buf: &mut [u8], timeout: Duration) -> Result<usize, Self::Error>;
}

trait Adc<const BITS: u32> {
    type Error;
    fn read(&mut self, channel: u8) -> Result<u16, Self::Error>;
}

trait Pwm {
    type Error;
    fn set_duty(&mut self, channel: u8, duty_permille: u16) -> Result<(), Self::Error>;
    fn set_period(&mut self, ns: u64) -> Result<(), Self::Error>;
}

trait DelayNs {
    fn delay_ns(&mut self, ns: u32);
}

trait Dma {
    type Error;
    fn start_transfer(&mut self, src: &[u8], dst: &mut [u8]) -> Result<DmaHandle, Self::Error>;
    fn poll(&self, handle: DmaHandle) -> DmaStatus;   // InProgress | Done | Error
}
```

## Key design decisions
- **`timeout: Duration` is a mandatory parameter on every blocking bus operation** (`I2c::write_read`, `Uart::read`), not an optional or vendor-configured default. This is not in upstream `embedded-hal` 1.0 (which leaves timeout policy to the implementer) — it is added specifically because the validation app requires "I2C read with timeout, retry on bus error" as a first-class scenario, and a trait that can't express "give up after N ms" forces every application to reach past the trait into vendor registers, which is exactly the erosion Part V warns about.
- **`type Error: I2cError` uses an associated error trait with required categorization** (`NoAck`, `BusError`, `ArbitrationLoss`, `Timeout`) rather than a single opaque error type. `core.error` supplies the `Result` carrier (Principle 4), but a bare `Result<(), E>` with unconstrained `E` would let the retry-on-bus-error logic in the sensor-node app not know *which* errors are retryable versus fatal without vendor-specific matching — the categorization is the minimum needed to write portable retry logic.
- **No `init()` or configuration method is part of the trait set.** Chip-specific setup (clock source selection, pin muxing, multi-step sensor power-up sequences) is deliberately left to a vendor-provided constructor that *returns* a value implementing the trait — the trait only governs steady-state operation. This is the load-bearing decision for vendor neutrality: it concedes upfront that init is inherently vendor-specific rather than trying to force it into the trait and then leaking vendor quirks into every signature.
- **Revision (embedded-display-node): `SpiBus` gained `write` and an opt-in `SpiBusDma` extension trait; `InputPin` gained an `InterruptPin` extension.** The original `SpiBus` (validated only by `embedded-sensor-node`, which never used SPI at all) inherited `embedded-hal`'s full-duplex-only shape — `transfer`/`transfer_in_place` both require an rx buffer the same size as tx. That shape is fine for short, occasional command/status exchanges but is a real gap for a framebuffer-style bulk write: a write-only display pushing several KB per refresh would either waste RAM on a throwaway rx buffer or block the CPU for the whole transfer, which directly conflicts with a device whose power budget is "how long can it stay asleep." `write` (no rx buffer) and `SpiBusDma::write_dma` (non-blocking, pollable) are the concrete fix, not a workaround left to application code. Similarly, `InputPin` alone (validated by the sensor node's polled battery-voltage-adjacent GPIO use) has no way to express "wake me when this pin transitions" — `InterruptPin::enable_interrupt` closes that gap by returning an `IrqVector`, which is then registered through `platform.interrupt`'s existing `interrupt_handler!` macro and optionally passed to `platform.power`'s `WakeSource::Gpio`. `platform.hal`'s role is deliberately narrow here — configure the edge-detect hardware and hand back a vector — precisely so it doesn't have to take a position on masking (interrupt's job) or sleep-wake policy (power's job).
- **Escape hatch, stated explicitly rather than hidden:** every vendor HAL crate is permitted (and expected) to expose non-trait, vendor-specific methods alongside the trait implementation (e.g. `Stm32I2c::set_clock_stretch_timeout`). Application code that only uses trait methods stays portable; code that needs a quirky init path opts into a named, greppable vendor dependency instead of the trait silently growing chip-specific parameters. This is a direct, honest answer to Part V rather than a claim that no escape hatch is ever needed.

## Validated by applications
The embedded-sensor-node's core scenario — "read a temperature sensor over I2C with a timeout, retry on bus error, without hanging the device" — is the reason `I2c::write_read` takes an explicit `timeout` and returns a categorized error rather than a bare `Result<(), ()>`. A naive first design (mirroring upstream `embedded-hal` 1.0's `I2c` trait, which has no timeout parameter at all and assumes the implementation blocks indefinitely or the caller wraps it externally) would have been insufficient here: the app must not hang if the sensor's bus locks up, and "wrap it externally" would require a second, per-vendor timing primitive outside the trait, reintroducing exactly the portability loss the trait exists to prevent. The GPIO LED (fault-pattern blink on sensor error) and battery ADC read both fit the unmodified `OutputPin`/`Adc` traits with no changes required, which is a real (if smaller) point in favor of the trait set's stability. On the Part V risk directly: the trait set survives this one device for steady-state I2C operation, but only because init was deliberately excluded from the trait from the start — if init had been included, the sensor's specific power-up/warm-up sequence would have forced an escape hatch on day one. The design's honest position is that the escape hatch is not a failure mode to eliminate but a boundary to place correctly: at init/config, never at steady-state data transfer.

Where the embedded-sensor-node validated a *read*-dominated bus (I2C, short transactions, timeout/retry as the central concern), embedded-display-node validates the opposite shape: a write-dominated, bulk-transfer bus (SPI, a whole framebuffer at once) plus, for the first time in this project, GPIO used as more than a polled input — the encoder and button must be configured as edge-triggered sources, not read in a loop. Neither stress point existed in the original `SpiBus`/`InputPin` design: `SpiBus` had never been exercised by any app before this one (it shipped speculatively, modeled on `embedded-hal`'s shape but untested), and `InputPin`'s only prior validation was the sensor node's status LED, which is an *output* pin plus a battery-voltage ADC read — genuinely polled, never interrupt-driven. Both gaps are real, not hypothetical: a naive "just call `transfer` in a loop" or "just poll `is_high` on a timer" implementation would technically compile against the old trait set but would either burn RAM on a throwaway rx buffer and block the CPU during every screen refresh, or defeat the entire point of deep sleep by requiring the CPU to stay awake and poll a pin that only changes state a few times a minute. `SpiBusDma` and `InterruptPin` are the concrete, load-bearing fixes, not defensive additions.

## Open questions / risks
Whether `Dma` belongs in this trait set at all is unresolved — DMA controllers vary enough in channel/descriptor models across vendors that a single portable trait may be thinner than useful (a risk the report itself flags for `platform.hal` generally). A second open question: as more real devices are validated, will `timeout` alone be sufficient, or will retry/backoff policy also need to move into the trait (as this app's "retry on bus error" requirement already hints), pulling policy that arguably belongs in application code into the HAL layer.
