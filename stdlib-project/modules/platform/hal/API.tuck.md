# platform.hal — Tuck translation

## Shape decision
Freeform `pending:` verbs over integer handles (`pin`, `bus`, `channel`),
sitting **above** Tuck's own `register` declarations. **Compiler-verified**,
`./tuck ch`: `OK`.

## Tuck already owns the bottom layer

The Nim design's "claiming a peripheral hands you a handle; the handle is
the only way to use it" exists to make MMIO type-safe. Tuck does that in
the language (spec §8.1):

```tuck
register RCC_CR at 0x40021000:
  HSION:   bit 0     [read, write]
  HSIRDY:  bit 1     [read]           # writing is a compile error
  HSITRIM: bits 3..7 [read, write]
```

`volatile` is implicit; writing a read-only field or reading a write-only
one is a **compile error**; and declarations can be generated from vendor
CMSIS-SVD files, so one importer covers the whole Cortex-M ecosystem.

That is stronger than a library handle type — it's per-*field* access
control, not per-peripheral. So this module's job shrinks to the
**portable vocabulary above the registers**: the words a driver written
once uses on any vendor's silicon.

## The API

```tuck
type PinLevel:
  | Low
  | High

type PinMode:
  | InputFloating
  | InputPullUp
  | InputPullDown
  | OutputPushPull
  | OutputOpenDrain

type Edge:
  | Rising
  | Falling
  | Both

type I2cError:
  | NoAck
  | BusError
  | ArbitrationLoss
  | I2cTimeout

type SpiError:
  | SpiTimeout
  | SpiBusError

pending:
  fn claimPin({id: int, mode: PinMode}) -> {pin: int}?
  fn readPin({pin: int}) -> PinLevel
  fn writePin({pin: int, level: PinLevel}) -> void
  fn enableInterrupt({pin: int, edge: Edge}) -> {vector: int}?

  fn i2cRead({bus: int, addr: u8, reg: u8, count: int, timeoutMs: u32}) -> !{data: Seq[u8]} [io, error: I2cError]
  fn i2cWrite({bus: int, addr: u8, reg: u8, data: Seq[u8], timeoutMs: u32}) -> !void [io, error: I2cError]

  fn spiTransfer({bus: int, tx: Seq[u8], timeoutMs: u32}) -> !{rx: Seq[u8]} [io, error: SpiError]
  fn spiWrite({bus: int, tx: Seq[u8], timeoutMs: u32}) -> !void [io, error: SpiError]

  fn adcRead({channel: int}) -> u16
  fn pwmSet({channel: int, dutyPermille: u16}) -> void
```

## Notes
- **The mandatory `timeoutMs` and categorized `I2cError` survive**, and
  they are round-0's finding #7 — the one place this design consciously
  diverged from upstream `embedded-hal`, because "read with timeout, retry
  on bus error, don't hang the device" is inexpressible against a trait
  that leaves timeout policy to the implementer. Tuck's declared
  `[error: I2cError]` makes the categories part of the signature.
- **`claimPin` returns `?`** — a pin already claimed elsewhere is absence,
  not failure, matching `pool.acquire`'s backpressure reasoning exactly.
- **`spiWrite` (write-only) plus `spiTransfer` (full duplex)** carries
  round-1's addition; the original trait set was full-duplex-only, which
  embedded-display-node's SPI display never needed.
- **`enableInterrupt` returning a vector** is round-1's `InterruptPin`
  extension, feeding `platform.interrupt`.
- **The vendor escape hatch stays an open tension**, as Part V of the
  report said: standardizing traits risks ossifying them, and hardware
  moves faster than a language. Tuck's `register` + SVD import actually
  *reduces* that risk — a vendor-specific register is reachable without
  reaching past this module's abstraction, so the portable layer doesn't
  have to cover everything to stay useful.
