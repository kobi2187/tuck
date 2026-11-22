# Design note — interrupts as events

Status: design-round input for roadmap item 1.0 (question D13), 2026-11-22.
Nothing here is ruled. Code in `text` fences is a **sketch of shape**, every
keyword a placeholder; only `tuck` fences are working Tuck.

The owner's direction: *if we can use events with bare metal that would be
super — different worlds but similar semantics.* This note works out what that
means, what the compiler already does, and what has to be decided.

---

## 1. The idea in one paragraph

Tuck already has an application-wide event surface: `registry` declares the
events, `X.raise V {...}` signals one, `on X.V(...)` handles it, and the
checker proves every event is handled (TK-RG03) and no handler raises its own
event (TK-RG04). A hardware interrupt is an event whose raiser is the
silicon. If interrupts enter the program as registry events, a driver is
written against **events it declares**, never against a vector, and the same
driver runs on a host (where a test, a timer or the OS raises the event) and
on a Cortex-M (where an interrupt line raises it). **The semantics are the
language's; only the raiser and the execution context differ by world.**

## 2. What the registry does today (checked 2026-11-22)

| Behaviour | Today | Spec Part 10 |
|---|---|---|
| `registry`, `raise`, top-level `on`, all three backends | **runs** (Nim, Odin, D: `tick`, `byte`, exit 3) | yes |
| A handler's effects are checked | **yes**: a handler calling `printLine` must declare `[io: console]` | — |
| Handler in another module that imports the registry | **works** | — |
| Two handlers for one event, in declaration order | refused (duplicate top-level name) | permitted |
| `latest` query | not implemented | yes |
| Handler inside an actor | not counted (TK-RG03) | "in a manager or actor" |
| A library declaring the events it raises | refused (TK-RG05: one registry per program) | one global per application |

The first row is now pinned `featureDone` in `tests/suites/roadmap.nim`; the
three missing rows are pinned `featureMissing`. Before that the registry had
no behavioural assertion at all.

## 3. One semantics, two worlds

What an event *means* does not depend on the target:

- An event is a **typed fact**: a variant and its payload, declared once.
- **Raising** delivers it to every handler of that variant.
- A handler is either **immediate** (runs in the raiser's context, before
  `raise` returns: today's semantics) or **deferred** (runs later, in its
  owner's context, in raise order, through a bounded queue).
- **`latest`** is the last payload per variant, readable from anywhere.

What differs by world:

| | Hosted | Bare metal |
|---|---|---|
| Who raises | code, an OS signal, a timer, a test harness, `platform.interrupt`'s simulated controller | code, or an **interrupt line** |
| Immediate handler runs in | the raiser's thread | the raiser's context; for a hardware raise, **interrupt context** (the "top half") |
| Deferred handler runs in | its actor's thread (mailbox), or `main`'s task loop | its actor (a coroutine under `--actors:single`), or a task woken by the metal reactor (the "bottom half") |
| Queue for deferred delivery | the actor's mailbox | a static, lock-free single-producer queue the compiler sizes |
| `latest` | a static slot | a static slot (seqlock when the raiser is an interrupt) |
| What the checker must also prove | effects | effects, **ISR-safe reachability** of immediate handlers, **priority ceilings**, queue RAM in the budget |

The split between immediate and deferred is the embedded world's
top-half/bottom-half rule, the FreeRTOS `FromISR` rule and Embassy's
signal/channel split, expressed in Tuck's existing vocabulary rather than a
new one.

**One reading that needs ruling:** the spec says `raise` "calls all
registered handlers … synchronously". For a top-level handler that stays
true. For a handler that lives in an actor it cannot be: running an actor's
handler on the raiser's thread breaks the actor's ownership of its fields. So
an actor-hosted handler is naturally *deferred*, delivered like a message,
on a host and on metal alike. That is also exactly what an interrupt needs.

## 4. Reuse: the ruled precedent

The owner already ruled this split once, for the **resource registry**
(2026-09-14, main ROADMAP "Partial — Resource registry"):

> a `resources:` block is a deployment decision, the protocol of an OS service
> is the library's … A kind may be declared by MORE THAN ONE site, one knob
> each: the library declares the protocol and on_finish, the app declares
> cap/policy/sweep_batch. Per knob, with a later site OVERRIDING an earlier
> one … the importer overrides the imported.

Applied to events:

| Knob | Declared by |
|---|---|
| the variants and payloads (the protocol) | the driver library |
| its immediate handler (the capture: read the data register, clear the flag) and its deferred handlers | the driver library |
| which interrupt lines exist and which peripheral raises each | the chip package (from SVD) |
| which line raises which event, for which instance | the board package (a default) or the application (overrides) |
| priority, queue capacity, overflow policy | the application (a library may ship a default) |

So the application's registry is still the one place the whole event surface
reads from (the property TK-RG05 protects), but it is *composed*: it includes
the event sets its libraries declare, and adds its own.

## 5. The reuse test, sketched

One UART driver, two applications, two boards. The driver names no line,
priority, instance or capacity.

```text
# SKETCH — shape only.

# uart.tuck — the driver library
events UartEvents:                         # an event set the driver owns
  | Rx({port: UartId, byte: u8})           # the instance travels in the payload
  | Overrun({port: UartId})

on interrupt rxReady({port: Uart}) -> UartEvents [irq_safe]:
  # immediate, interrupt context: the capture, nothing else
  if port.SR.ORE: return {port: port.id} Overrun
  return {port: port.id, byte: port.DR.DATA} Rx

# console.tuck — another library, uses the driver
actor Console:                             # deferred: runs in the actor
  line: Array[80, u8] = ...
  on UartEvents.Rx({port, byte}):
    ...

# app_a.tuck — board A: console on USART1
registry AppEvents:
  include UartEvents
  bind USART1.rx -> uart.rxReady [priority: 2, queue: 16, on_full: drop]

# app_b.tuck — board B: console on USART2, a GPS on USART3
registry AppEvents:
  include UartEvents
  bind USART2.rx -> uart.rxReady [priority: 1, queue: 64, on_full: drop]
  bind USART3.rx -> uart.rxReady [priority: 3, queue: 8,  on_full: assert]
```

What the checker proves for each application, with the driver unchanged:

- every bound line has exactly one capture; an unbound line goes to the
  default handler; a line bound twice is an error;
- every event in the composed registry is handled (TK-RG03, as today);
- the capture reaches only ISR-safe operations (TK-EF05/07/11, as today);
- shared state touched by immediate handlers gets a ceiling from the bound
  priorities, and `critical:` lowers to that ceiling;
- every deferred queue fits the RAM budget; `on_full: wait` is refused for a
  hardware-raised event (an interrupt cannot wait);
- the same program built for a host replaces "line raises event" with
  "harness raises event", so the driver's logic runs in `tuck sim --host`
  on all three backends.

## 6. What each world costs at run time

| Path | Metal cost |
|---|---|
| immediate handler | a vector stub that calls the capture; no allocation |
| deferred delivery | one write into a static queue + readying a frame |
| `latest` | one slot write (seqlock: two counter writes) |
| a task waiting on an event (`on select`) | the frame parks on the queue; the post readies it; `WFI` meanwhile |

No heap, no locks, no dynamic subscription: what the registry already
promises ("a small static array of slots … no queues, no dynamic
allocation") stays true, plus one static queue per deferred binding.

## 7. Questions to rule

| # | Question | Options | Leaning, and why |
|---|---|---|---|
| E-Q1 | How does a library contribute events? | (a) an event **set** the application's registry includes; (b) independent registries | (a): keeps "the whole surface in one place", mirrors resource kinds |
| E-Q2 | What makes a handler deferred? | (a) **placement**: top-level `on` immediate, an actor's or task's `on` deferred; (b) an explicit marker | (a): no new word, and it is the only sound reading of an actor handler anyway (§3); the checker reports which kind each handler is |
| E-Q3 | Two instances of one driver | (a) the **instance in the payload**, one set; (b) a set instantiated per binding | (a): simplest, one handler serves both; (b) only if per-instance types are needed |
| E-Q4 | Where does the capture live? | (a) a driver-provided ISR-safe fn; (b) generated by the chip package | (a): the driver knows its peripheral kind; the chip package only lists lines |
| E-Q5 | Overflow of a hardware-raised deferred event | `drop` (counted, visible), `assert`; never `wait` | `drop` + count as default |
| E-Q6 | Order of several handlers across modules | declaration order within a module; across modules, dependency order (imported first), as resource knobs | same rule as resources |
| E-Q7 | Is binding in the registry, the board package, or both? | (a) board default + application override per knob; (b) application only | (a): a board ships a working default; an application overrides one knob without restating the rest |

## 8. Build order

**No ruling needed (finish the spec'd registry first; owner's rule: finish
partial features):**

- E1. More than one handler per event, in declaration order.
- E2. `latest`.
- E3. Handlers inside an actor, delivered as messages (needs E-Q2's reading
  confirmed, since the spec says "synchronously").
- E4. Behavioural tests on all three backends for each (started: roadmap
  suite).

**After the ruling:**

- E5. Event sets in libraries, composed by the application's registry.
- E6. Hardware raisers on metal: SysTick raising a `Tick` event under QEMU, then a
  UART line (roadmap 2.2, 2.3).
- E7. The host harness raising the same events (`tuck sim --host`).
- E8. The reuse test (roadmap 2.7) on two QEMU boards.
