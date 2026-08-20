# platform.interrupt — Nim API

## Purpose
Turning interrupts off for a moment, and saying which proc runs when one fires. Every other `platform` module borrows this to protect state an interrupt handler and ordinary code both touch.

## Protocols implemented
**None of the nine.** Masking and vector dispatch are control flow, not a shape a value has. `Guarded[T]` deliberately does *not* implement `Gettable` — see the exceptions below.

## The API

```nim
{.push checks: off, stackTrace: off.}

type
  Irq* = distinct uint8            ## which interrupt; the vector table slot is an
                                   ## implementation detail you never spell
  IrqPriority* = enum Highest, High, Normal, Low
  Masked* = object                 ## proof that interrupts are off *right now*.
                                   ## No exported constructor. Cannot be stored:
  proc `=copy`*(dst: var Masked, src: Masked) {.error: "proof of masking cannot outlive its block".}

template uninterrupted*(name, body: untyped)
  ## `uninterrupted(off): ...` runs `body` with interrupts masked and binds `off: Masked`.
  ## Nests safely: re-entering while already masked is a no-op, so the inner block
  ## exiting never unmasks early on the outer block.

type IrqState* = distinct uint32
proc maskInterrupts*(): IrqState        ## the non-nesting pair, for places that cannot
proc restoreInterrupts*(s: IrqState)    ## take a block: ISR prologues, kernel internals.
                                        ## Restores the previous state — never force-enables.

type Guarded*[T] = object               ## state an ISR and a task both touch
proc guarded*[T](initial: T): Guarded[T]
proc borrow*[T](g: var Guarded[T], proof: Masked): var T
  ## The only way to reach the value, and it costs a `Masked`. "Forgot to lock"
  ## is therefore not something you can write down.

template onInterrupt*(irq: static Irq, name, body: untyped)
  ## Defines the handler and links it into the vector table at compile time —
  ## expands to `proc <vectorName>() {.exportc, cdecl, raises: [].}` and binds
  ## `name: Masked`, because an ISR prologue already masks. No runtime table.

proc enable*(irq: Irq)
proc disable*(irq: Irq)
proc set*(irq: Irq, priority: IrqPriority)   ## target, then value — the `set` verb
proc isPending*(irq: Irq): bool
proc clearPending*(irq: Irq)
{.pop.}
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `CriticalSection<'cs>` | `Masked` | Names what is true (interrupts are masked) instead of naming the region. `borrow(g, off)` then reads as "reach in, here's the proof." |
| `critical_section(\|cs\| ...)` | `uninterrupted(off): ...` | One ordinary English word, and Nim's block syntax removes the closure — so it also works where a closure would allocate. |
| `irq_lock()` / `irq_unlock(s)` | `maskInterrupts()` / `restoreInterrupts(s)` | "Lock" suggested a mutex, which this is not. The pair now says what it touches, and `restore` says it puts back rather than turns on. |
| `IrqMutex<T>` | `Guarded[T]` | Also not a mutex — nothing blocks, nothing sleeps. It is state with an entry fee. |
| `interrupt_handler!(V => f)` | `onInterrupt(V, off): ...` | The handler body is written where it is registered, so there is no second place to keep in sync. |
| `IrqVector` | `Irq` | Everyone says "the timer IRQ"; nobody says "the timer vector". |
| `set_priority(v, p)` | `set(irq, priority)` | Falls straight into the structural `set` verb with no special case. |
| `pending` / `clear_pending` | `isPending` / `clearPending` | `is` prefix marks the question, matching `isOpen`/`isRunning` everywhere else. |

## In use — embedded-sensor-node

```nim
var samples = guarded(Ring[int16].fixed(64))     # written by the ISR, read by the task

onInterrupt(i2cIrq, off):                        # `off: Masked` is already in scope
  samples.borrow(off).addLast(i2c.lastWord())    # no raising calls allowed in here

uninterrupted(off):                              # the task side, same guarded value
  let batch = samples.borrow(off).drain()
  flashLog.append(batch)
```

## Vocabulary exceptions
`uninterrupted`, `maskInterrupts`, `restoreInterrupts`, `borrow`, `onInterrupt` and `guarded` are domain verbs. `Guarded[T]` is pointedly **not** `Gettable`: a `get(g, key): Option[T]` would let someone read shared state without holding a `Masked`, which is the exact bug this type exists to make unwritable — the same reasoning that keeps `alloc.allocator`'s `Secret[T]` out of `Gettable`. `set(irq, priority)` is the one structural verb here and keeps its ordinary shape.

## Honest limits
- **Wake-source semantics are not here and should not be.** In `Deep` sleep the encoder pin's ISR really does run on wake, so this module's machinery is exactly what handles it — without needing to know the pin was also a wake source. In `Coldest` sleep no vector fires at all, because waking is a reset; the "why did I restart" question is answered by `platform.power`'s `lastWakeReason()`. A `WakeSource` concept here would duplicate `power` in the first case and be simply wrong in the second.
- **`Masked` is unforgeable-ish, not unforgeable.** `uninterrupted` and `onInterrupt` are the only exported producers and `=copy` is a compile error, so it cannot be stashed in a global and reused later. It is still an ordinary object: this module can build one, and a `cast` defeats it. Convention, backed by the compiler in the common case.
- Priority-based masking (BASEPRI-style, where some interrupts stay live) needs a second, priority-aware variant of `uninterrupted` that this design has not worked out.

**Nim-specific:** an ISR must be `{.exportc, cdecl, raises: [].}` and compiled under `{.push checks: off, stackTrace: off.}` — which means **no raising verb may be called inside `onInterrupt` at all**. This is where PROTOCOLS' `try`-prefix rule stops being a convenience: in ISR bodies the `try` siblings are the only callable half of the library, and the compiler enforces it through `raises: []` rather than leaving it to review.
