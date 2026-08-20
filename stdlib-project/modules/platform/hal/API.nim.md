# platform.hal — Nim API

## Purpose
One set of words for the peripherals every microcontroller has — pins, buses, converters, timers — so a driver written once compiles against any vendor's silicon. Claiming a peripheral hands you a handle; the handle is the only way to use it.

## Protocols implemented
`GpioPin`: `Resource`, `Gettable`, `Settable`. `PwmChannel`: `Resource`, `Settable`, `Adjustable`. `Transfer` (a DMA job in flight): `Waitable`. Buses use `read`/`write` in their exact table sense.

## The API

```nim
{.push checks: off.}   ## platform tier: no implicit bounds/overflow machinery

type
  PinId* = distinct uint16          ## names a pin on the package; not a handle
  Level* = enum Low, High
  Edge*  = enum Rising, Falling, Both
  Permille* = distinct uint16       ## 0..1000, so `300.permille` needs no comment

  GpioPin* = object                 ## opaque: fields are private to this module
    id: PinId
    live: bool
proc `=copy`*(dst: var GpioPin, src: GpioPin) {.error: "a claimed pin cannot be duplicated — move it".}

proc claim*(_: typedesc[GpioPin], id: PinId): Option[GpioPin]
  ## The only door in. `none` if this pin is already claimed — an ordinary outcome,
  ## not a failure. There is no exported constructor.
proc close*(pin: var GpioPin)                 ## release it; claimable again. Idempotent.
proc open*(pin: var GpioPin): bool            ## re-claim after `close` — completes `Resource`,
proc isOpen*(pin: GpioPin): bool              ## so generic `retry(pin, 3, 10.ms)` just works.

proc get*(pin: GpioPin): Option[Level]        ## `none` if the pin is currently an output
proc set*(pin: var GpioPin, value: Level)
proc flip*(pin: var GpioPin)                  ## matches core.num's `flipBit`
proc watch*(pin: var GpioPin, edge: Edge): Irq
  ## Configure edge detection and hand back the vector. Registering a handler is
  ## platform.interrupt's job; wake-on-this-pin is platform.power's. Raises on silicon
  ## that cannot interrupt on this pin; `tryWatch` returns `none` instead.
proc unwatch*(pin: var GpioPin)

type
  BusProblem* = enum NoAck, BusError, LostArbitration, TimedOut
  BusFailure* = ref object of Failure          ## core.error's type, with a category
    problem*: BusProblem
    ## `retryable` is preset: NoAck/BusError/LostArbitration true, TimedOut false —
    ## so core.error's `worthRetrying(f)` answers correctly with no vendor matching.

proc writeThenRead*(bus: var I2cBus, address: uint8, tx: Bytes,
                    into: var openArray[byte], timeout: Duration): Count
proc write*(bus: var I2cBus, address: uint8, tx: Bytes, timeout: Duration): Count
proc read*(bus: var I2cBus, address: uint8, into: var openArray[byte],
           timeout: Duration): Count
  ## `timeout` has **no default**. You type the number, or you don't get a bus.

proc write*(spi: var SpiBus, tx: Bytes): Count            ## write-only: no rx buffer to spare
proc transfer*(spi: var SpiBus, tx: Bytes, into: var openArray[byte])
proc writeAsync*(spi: var SpiBusDma, tx: static openArray[byte]): Transfer
proc wait*(t: Transfer, timeout: Duration): bool          ## `Waitable`; poll-free sleep meanwhile

proc read*(adc: var Adc, channel: uint8): uint16          ## raw counts; `adc.bits` scales them
proc set*(ch: var PwmChannel, duty: Permille)             ## absolute
proc set*(ch: var PwmChannel, period: Duration)           ## same verb, different value type
proc adjust*(ch: var PwmChannel, delta: Permille)         ## relative — `Adjustable`
proc spinFor*(d: Duration)                                ## burns CPU. The name says so.
{.pop.}
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `set_high()` / `set_low()` | `set(pin, High)` / `set(pin, Low)` | Two procs became the vocabulary's one `set` verb with a value. `Level` also reads back out of `get`. |
| `is_high() -> bool` | `get(pin): Option[Level]` | A bare `bool` can't say "this pin is an output right now"; `Option` is the library's one word for that. |
| `enable_interrupt(edge)` | `watch(pin, edge)` | "Enable interrupt" is what the register does. `watch` is what you wanted. |
| `write_read(addr, tx, rx, t)` | `writeThenRead(...)` | The `Then` is the whole point — it's one transaction, not two. |
| `duty_permille: u16` | `Permille` distinct type | `set(ch, 300.permille)` can't be confused with a period, which is why one `set` covers both. |
| `delay_ns(ns)` | `spinFor(d)` | It is not a sleep — it holds the CPU awake, which on this tier costs battery. |
| `DmaHandle` + `poll(h)` | `Transfer` + `wait(t, timeout)` | Becomes `Waitable`, so it composes with everything else that waits. |
| `Error: I2cError` assoc. type | `BusFailure` with `problem` | One concrete raised type; `worthRetrying` already knows what to do with it. |

## In use — embedded-sensor-node

```nim
var led = GpioPin.claim(PinId(5)).orRaise("LED0 already claimed")   # or `device"led0"`
for go in 1 .. 3:
  let n = attempt[Count](bus.writeThenRead(sensorAddr, [0xFD'u8], raw, timeout = 10.ms))
  if n.isSome: break
  led.flip()                       # fault blink while we retry
```

## Vocabulary exceptions
`GpioPin` is `Gettable`/`Settable` **without a locator** — a pin has exactly one thing to read and one to write, so `get(pin)`/`set(pin, v)` drop the key argument. That is a deliberate stretch, recorded here rather than hidden; every other member of both protocols keeps its locator. `claim`, `watch`, `flip`, `transfer`, `spinFor` are domain verbs; they take the target first and options last like everything else.

## Honest limits
- **The claim pattern is a convention, not a proof.** `claim` is the only exported way to build a `GpioPin`, and `=copy` is a compile error so a handle can be moved but never duplicated — genuinely stronger than a comment. It is still *not* capability security: this module can construct another handle internally, `claim` is a plain `live` flag with no synchronization (two cores or an ISR racing on it need `platform.interrupt`'s critical section around the claim), and nothing stops a `cast`. Treat it as the same guarantee a careful Ruby library gives.
- **Init is deliberately absent.** Clock sources, pin muxing and multi-step sensor power-up stay in a vendor constructor that *returns* something matching these signatures. The escape hatch is real and is placed at init on purpose: vendor extras (`stm32.setClockStretch`) live on the concrete type, so portable code that only uses the names above stays portable and non-portable code names its dependency in the import line.
- `Dma` beyond `writeAsync` is unsettled — descriptor models vary enough between vendors that a fuller portable surface may be thinner than useful.
