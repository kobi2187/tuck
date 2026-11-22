# Design note — interrupts as events

Status: design-round input for roadmap item 1.0 (question D13), 2026-11-22.
Nothing here is ruled. Code in `text` fences is a **sketch of shape**, every
keyword a placeholder; only `tuck` fences are working Tuck.

The owner's direction: *if we can use events with bare metal that would be
super — different worlds but similar semantics.* And the owner's caution that
followed it: *an irq is actually somewhat different from hosted events; the
event policy part where a user can ignore and implement later is problematic
if it can change a finished bare-metal component.* This note works out what
both mean, what the compiler already does, and what has to be decided. §3a is
the answer to the caution: **the exact rules**.

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

## 3a. An interrupt is a stricter kind of event: the rules

Hosted events are loosely coupled on purpose: a raiser need not know who
listens, handlers are added by whoever imports the registry, a handler can be
`pending:` (trap, return zero, or log and continue, chosen by a build flag),
and a later deployment site overrides an earlier one. Each of those freedoms
is a defect for an interrupt:

| Freedom that is fine for a hosted event | What it does to an interrupt |
|---|---|
| "nobody handles it yet" / a `pending:` handler that returns zero or logs | the source is never acknowledged, so the interrupt re-fires forever: an interrupt storm, the board hangs |
| another module adds a handler | new code runs in interrupt context: a finished driver's latency, stack and ceilings change without its source changing |
| a later site overrides a knob (the resource-registry rule) | an application shrinks a queue or slows a priority below what the driver was verified at, and the driver drops bytes |
| raise calls the handler directly | the "interrupt" runs without preemption, so a test proves nothing about the real interleaving |
| a full queue waits (`on_full: wait`) | an interrupt cannot wait; it would deadlock the core |

So the strictness attaches to the **kind of event**, not to the target. An
event set is either an **ordinary** set (today's semantics, unchanged, on every
target) or an **interrupt** set. The rules below hold for an interrupt set
**on every target, the host sim included**, so a component behaves the same
in simulation as on silicon. That is how "different worlds, similar
semantics" survives the caution: the worlds differ in who raises, never in
what is allowed.

The rules (numbered so they can be cited by diagnostics and tests):

- **IRQ-1 One capture, owned by the driver.** Each interrupt event has exactly
  one immediate handler, the *capture*, declared in the module that declares
  the set. No other module may add an immediate handler to it. Importers add
  *deferred* handlers only. **Nothing an application or another library writes
  can change what runs in interrupt context.**
- **IRQ-2 No holes in interrupt context.** A capture can never be `pending:`
  or `...`, in any build mode, on any target; the PENDING-report flags (trap /
  zero / log) do not apply to it. A *deferred* handler may be pending: the
  capture still runs, the event is still queued and counted, and the PENDING
  report lists the handler. Implementing it later changes task-level
  behaviour only, never the driver.
- **IRQ-3 Acknowledged on every path.** The set states how its source is
  cleared (which register read or write); the checker proves every path
  through the capture performs it. Forgetting to clear a flag is the classic
  cause of interrupt storms, and in C it is caught only by review.
- **IRQ-4 A capture is small and closed.** It may read and write registers,
  compute, and post deferred deliveries or `latest`. It may not wait,
  allocate, `send`, loop without a constant bound, or raise an *ordinary*
  event (that would run someone else's immediate handlers in interrupt
  context). Its worst-case cycles and stack are part of its contract and are
  reported. (TK-EF05/07/11 already cover part of this.)
- **IRQ-5 Requirements, not overrides.** For interrupt bindings the
  resource-registry rule (a later site overrides an earlier one) is replaced
  by a constraint: the driver declares the range it was written for (queue
  depth at least N, the overflow policies it tolerates, the latency it needs
  between a raise and its capture). The application chooses values inside
  that range; a value outside it is a compile error naming the driver's
  requirement. Defaults come from the driver, not from the board.
- **IRQ-6 Bound or off, enabled after init.** A line the application does not
  bind stays disabled. A bound line is enabled by generated code after its
  driver's initialisation has run, never at reset. A vector that fires
  unbound reaches the default handler, whose FAULT line names it.
- **IRQ-7 A software raise takes the hardware path.** Raising an interrupt
  event from code (a test, the host harness, a self-test on the board) *pends*
  the line through the interrupt controller (the NVIC's set-pending register
  on Cortex-M, `platform.interrupt`'s controller on the host). It never calls
  the capture directly, so the capture always runs in interrupt context, with
  real masking and preemption.
- **IRQ-8 Deferred delivery is fixed.** Raise order is kept per source; each
  deferred handler sees each delivered event once; drops are counted per
  binding and readable at run time; `wait` is never an overflow policy.
- **IRQ-9 A component's interrupt contract is visible.** The set's variants,
  capture, acknowledgement, cost bounds and declared ranges form the driver's
  interrupt contract. `tuck audit` prints it per binding, so a change to a
  finished driver shows up in review as a contract change, not as a timing
  surprise on the bench.

**What stays the application's choice, deliberately:** which instance and
line, the priority, the queue depth and overflow policy (inside the driver's
range), and every deferred handler. **What is sealed:** everything that runs
in interrupt context. A priority chosen by the application does change when
the driver's *deferred* work runs and what the ceilings are; that is fine,
because the checker recomputes both for each application and the driver's
declared latency requirement is checked against the result.

**Ordinary events on a bare-metal target** keep their hosted rules, with one
addition from IRQ-4: they are raised from task context, never from a capture.

## 3b. Every policy, and what it may do to a finished component

`pending:` is only one of several places where Tuck lets a decision be made
later or somewhere else. The owner's caution applies to all of them. Here is
every policy the compiler and spec have today (checked 2026-11-22), who sets
it, and whether it can change a component its setter did not write:

| Policy | Set by | Can change a finished component today? |
|---|---|---|
| `errors [policy: strict \| continue \| exit]` + `on unhandled` (spec §4.9) | spec: the application, once. Built: each module, its own (measured 2026-11-22) | under POL-4, **only partial modules**: a finished library is strict whatever the application declares. In a capture the handler would run in interrupt context (POL-2) |
| `resources:` `cap`, `policy: strict \| lazy \| exit`, `on_full`, `on_finish`, `sweep_batch` (§7.4) | library and application, the importer overriding the imported | **yes**: an application can shrink a library's cap, change its `on_full`, or switch it to `lazy`, whose sweep runs inline at a finish |
| actor `queue`, `on_full: wait \| drop \| assert` (§9.1) | the actor's author | no (not overridable), but `wait` is impossible from an interrupt |
| `pending` stub behaviour: trap / zero value / log and continue (§5.4) | a build flag (spec; today a stub only names itself when called) | **yes**, and "zero" or "log and continue" in a capture is an interrupt storm |
| `--isr-check:warn \| error` | the build | **yes**: the race gate a driver was verified under can be turned into a warning |
| `--no-invariants` | the build | only on a path where an invariant would fail, which is a bug path |
| `--actors`, `--concurrency`, `--frames` | the build | **yes**: the runtime model; on metal the profile fixes them |
| overflow `[saturating \| wrapping \| trapping]` (§7) | the author of the type | no |
| the event registry itself | — | no policy of its own today (the parser takes a name and variants); the knobs this note adds (priority, queue, overflow) are new policies and fall under the rule below |

**The rule that covers all of them** (POL, citable like IRQ):

- **POL-1 A policy may decide what happens when something goes wrong,
  only within what the component declared it tolerates. It may never change
  what a correct component does on its normal path.** `--no-invariants`
  passes (it only affects a path that is already a bug). An application
  shrinking a library's cap below the library's stated need does not.
- **POL-2 Interrupt context is policy-free.** No application-wide or build
  policy reaches a capture. A capture is checked as `errors: strict` whatever
  the application chose, so the `unhandled` handler can never run in
  interrupt context. It holds no resource operations and no stubs. The ISR
  gate is always `error` for interrupt sets: `--isr-check:warn` applies to
  ordinary code only.
- **POL-3 A component's knob is a default or a requirement, and says which.**
  A *default* may be overridden, which is today's resource rule and stays as it
  is for hosted code. A *requirement* is a range (cap at least N, `on_full` one
  of a set, queue at least N). An override outside it is a compile error
  naming the component's requirement. Interrupt bindings are always
  requirement-style (IRQ-5). The coherence check that already runs on a
  merged resource kind (TK-RS11) is where this check belongs.
- **POL-4 One development stage per application; finished libraries opt
  out** (owner's model, 2026-11-22; replaces "shortcuts stay in the
  application", which misread the policy's purpose). The errors policy is the
  walking skeleton's switch: the stage of development stated in one place
  instead of TODOs and "not implemented" exceptions scattered through the
  code. Logging and never crashing is a legitimate development choice. So:
  - The **application's** `errors` policy governs every *partial* module:
    the application's own code and every library not marked finished. A
    partial library's unhandled sites go to the application's
    `on unhandled` and are listed in the application's SHORTCUTS report,
    under the library's name. **Nothing is hidden.**
  - A library its **author** marks **finished** is error-complete: checked
    as `strict` (every error handled at its site), with no `pending` or
    `...` stubs, whatever the application chose. The application's policy
    does not reach it, so its behaviour cannot change with the importer
    (POL-1).
  - **A library that declares `errors [policy: strict]` is finished
    automatically** (owner, 2026-11-22). An explicit marker may come later;
    strict already counts.
  - Only the library's own author can mark it finished; an application can
    neither finish someone else's library nor un-finish one.
  - Finished forbids stubs; a finished library imports only finished ones;
    a partial library's own `continue` / `exit` block is inert when imported
    (all ruled 2026-11-22). **The rule for any site: in a finished module,
    strict; anywhere else, the entry module's policy.**
  - **Release needs no separate rule.** Shipping firmware builds with
    `[policy: strict]` (spec §4.9), which now covers every partial library
    too: a shortcut left anywhere becomes a compile error naming its site.

  Today (measured): the policy is per module, not per application; a
  library's own `continue` block runs its *own* handler; the application's
  policy never reaches a library (a library checks `strict` without its own
  block); and a library's shortcut sites never appear in any report, since
  SHORTCUTS lists the entry module's only. The model above fixes the last one
  and restores the spec's "one declaration per application".
- **POL-5 The profile fixes the runtime model.** On a metal board,
  `--actors`, `--concurrency` and `--frames` are set by the board profile. A
  component may state what it requires (`--frames:static`), and a build that
  contradicts it is refused.
- **POL-6 Every effective value is visible.** `tuck audit` prints, per
  component, each knob's merged value and who set it (component default,
  board, application). A change to a finished component's effective
  policies then shows up in review, not on the bench.

POL-1 is the criterion; POL-2 to POL-6 apply it to each policy above. These
rules are not specific to bare metal. POL-1, POL-3, POL-4 and POL-6 are
worth having for any reusable library, hosted or not. Bare metal is where
breaking them costs a hung board instead of a log line.

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

**Where interrupts depart from the precedent (§3a, IRQ-5):** for a resource
knob the importer overrides the imported. For an interrupt binding it may
only choose inside the range the driver declares, and it can never add or
replace the capture (IRQ-1). The split of *who declares what* is the same;
the rule for combining them is stricter.

## 5. The ruled shape (owner, 2026-11-22)

Built up in a design conversation from one question: what must an embedded
engineer decide for every interrupt, and how does the language make each
decision required and visible? Every classic interrupt bug is a decision that
was *skipped* (a cause nobody handled, a flag never cleared, a buffer with no
overflow plan, an `if` order that hides an error, a priority nobody thought
about). The shape below reuses existing constructs for almost all of it and
adds one keyword (`bind`) and a few attributes. Code is a sketch of shape;
the spellings marked *new* are the only new words.

**Who writes what:**

| Piece | Written by | Spelling |
|---|---|---|
| how each status flag clears (read SR then DR, write-1-to-clear, ...) | nobody: generated from SVD into the chip package | a fact on the `register` field (spelling open, with D3) |
| what can happen | the driver | its own `registry`, each event marked `[stream]`, `[signal]` or `[latest]` (*new*) |
| which cause fired | the driver | a `decision` table over the status bits: no gaps, row order explicit |
| what runs inside the interrupt | the driver | one `fn ... [irq]`, optionally `[budget: N, rate: N]` (*new*) |
| which line, priority, queue size | the application | `bind LINE -> module.fn [priority: N, queue: N]` (*new*) |
| reacting afterwards | anyone | ordinary `on Events.X(...)` handlers |

```text
# --- driver: uart.tuck -------------------------------------------------
registry UartEvents:
  | Rx({data: u8})  [stream, overflow: drop_newest]   # every byte; the driver fixes overflow
  | Overrun         [signal]                          # repeats merge into a count
  | FrameError      [signal]

decision uartCause({ore: bool, fe: bool, rxne: bool}) -> UartCause:
  | true  _     _     -> Overrun     # row order is the fix: errors before data
  | false true  _     -> Framing
  | false false true  -> Byte
  | false false false -> Spurious    # stated, never silent; no gaps allowed

fn onUart({u: Uart}) [irq, budget: 30, rate: 11_520]:
  match {ore: u.SR.ORE, fe: u.SR.FE, rxne: u.SR.RXNE} uartCause:
    | Overrun  -> UartEvents.raise Overrun
    | Framing  -> UartEvents.raise FrameError
    | Byte     -> UartEvents.raise Rx {data: u.DR.DATA}
    | Spurious -> return
  u.DR.DATA discard               # the compiler checks every path clears what is set

# --- application A, board 1 ---------------------------------------------
bind USART1 -> uart.onUart [priority: 2, queue: 16]

# --- application B, board 2: the same driver, untouched ------------------
bind USART2 -> uart.onUart [priority: 1, queue: 64]

# --- anywhere: the reactions --------------------------------------------
on UartEvents.Rx({data: u8}):            # any module importing the driver
  ...
actor Console:
  on UartEvents.Rx({data: u8}):          # or in an actor, in its own context
    ...
```

**Where code runs, exactly:**

- **Inside the interrupt (top half):** only the body of the one `[irq]` fn the
  application bound to that line. It is a top-level fn of the driver's module
  (a vector needs a fixed target); its actions are ordinary statements (read
  registers, compute, `raise`); it is strict, bounded and stub-free
  (IRQ-1..9, TK-PO04), and no other module can add code to it.
- **After the interrupt (bottom half):** every `on Events.X` handler wherever
  it is declared. `on` is simply how an event handler is written: usually at
  the top level of any module that imports the events (sub-modules
  included). No task or actor is needed to handle an event; an actor or a
  task's `on select` is just one more place the same `on` may appear. The
  runtime calls the handlers after the interrupt returns, outside interrupt
  context, in raise order, under the normal rules (I/O, the error policy).
  The compiler collects them program-wide, as it collects registry handlers
  today.
- **In between:** the event's kind. `stream`: a queue of the bound `queue: N`
  with the driver's overflow policy; `signal`: a counter; `latest`: one slot,
  overwritten, read without tearing. `raise` is the same verb on a host: only
  the world differs.

**What the compiler can promise from it:** no interrupt storm (every path
clears what it handles, from the register facts); no forgotten cause (the
decision table has no gaps); bounded time in the interrupt (`budget` against
the static score); statically sized RAM (every queue is an explicit number);
no silent overflow (the driver's policy, counted); priorities and ceilings
from `bind`; an event nobody handles is a compile error (TK-RG03); an `[irq]`
fn nobody binds is reported. Each decision-table row is also a test vector:
the host simulation can raise every flag combination, so a driver is exercised
before any hardware exists.

**Ruled:** a registry per module (a driver owns its events; TK-RG05 becomes
one registry per module, and the whole surface is a *report*,
`tuck audit --events`, not one declaration); the driver fixes the overflow
policy on the event; the application gives an explicit queue size in `bind`
(the compiler may warn when `rate` says it is too small).

**Ruled the same day:**

- **E-Q3: each `bind` names its own channel.** Two lines bound to one
  driver fn get separate events, queues and overflow counts; the handler
  reads like the wiring, and the driver is unchanged:

  ```text
  bind USART1 -> uart.onUart as Console [priority: 2, queue: 16]
  bind USART2 -> uart.onUart as Modem   [priority: 1, queue: 64]

  on Console.Rx({data: u8}):
    ...
  ```

- **D3: how a flag clears is written on the register field**, generated
  from SVD (`modifiedWriteValues`, `readAction`):
  `UIF: bit 0 [w1c]` (write 1 to clear; codegen never read-modify-writes
  such a register) and `ORE: bit 3 [clear: read SR then DR]` (cleared by a
  read sequence). The compiler checks every path of an `[irq]` fn clears
  what it handled.

- **D12: a register layout is a type; a peripheral is an instance of it.**
  A `register` block with no address is a layout; `register NAME: Layout at
  ADDR [facts]` is one instance. A driver takes the type (`{u: Uart}`) and
  never names an instance; the hardware passes no instance to a handler,
  so `bind` supplies it, and the compiler generates one specialised copy
  per binding with the address built in (no run-time cost against a
  hand-written single-port handler). Where instances differ (clock enable,
  DMA channel), the chip package states it as a fact on the instance and
  the driver reads `u.clock`. A port that needs its own handler is bound to
  a different fn by the application; the reusable driver never holds an
  instance-specific one. svd2tuck maps `derivedFrom` onto one layout with
  several instances; `register NAME at ADDR` keeps working.

  ```text
  # chip package, generated from SVD
  register Uart:                      # no address: a layout (a type)
    SR at +0x00:
      RXNE: bit 5 [clear: read SR then DR]
      ORE:  bit 3 [clear: read SR then DR]
    DR at +0x04:
      DATA: bits 0..8
  register USART1: Uart at 0x40013800 [clock: RCC.APB2ENR.USART1EN]
  register USART2: Uart at 0x40004400 [clock: RCC.APB1ENR.USART2EN]

  # application: one port gets the driver, another its own handler
  bind USART1 -> uart.onUart      as Console [priority: 2, queue: 16]
  bind USART2 -> myapp.onModemUart as Modem  [priority: 1, queue: 64]
  ```

**Still open in this note:** nothing; D2 (frame homes) and D8 (deadlines)
are separate design rounds (`ROADMAP.md` 1.3, 5.3).

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
| E-Q1 | How does a library contribute events? | (a) an event **set** the application's registry includes; (b) independent registries | **ruled 2026-11-22: (b), a registry per module**; the whole surface is a report (§5) |
| E-Q2 | What makes a handler deferred? | (a) placement; (b) an explicit marker | **ruled 2026-11-22 (§5):** the immediate code is the body of the bound `[irq]` fn; every `on Events.X` handler is deferred, wherever it is declared |
| E-Q3 | Two instances of one driver | (a) the **instance in the payload**, one set; (b) a set instantiated per binding | **ruled 2026-11-22: (b)**, `bind ... as Name`: each binding is its own channel (§5) |
| E-Q4 | Where does the capture live? | (a) a driver-provided ISR-safe fn; (b) generated by the chip package | **ruled (§5): (a)**, an `[irq]` fn in the driver; the chip package supplies lines and how flags clear |
| E-Q5 | Overflow of a hardware-raised deferred event | `drop` (counted, visible), `assert`; never `wait` | **ruled 2026-11-22: fixed by the driver on the event** (`[stream, overflow: ...]`), not by the application |
| E-Q6 | Order of several handlers across modules | declaration order within a module; across modules, dependency order (imported first), as resource knobs | same rule as resources |
| E-Q7 | Is binding in the registry, the board package, or both? | (a) board defaults + application; (b) application only | **ruled (§5): `bind` in the application**, with an explicit `queue: N` and `priority: N` |
| E-Q8 | Are the strict rules a separate kind of set, or inferred from "a line is bound to it"? | (a) a declared interrupt kind; (b) inferred | **settled by §5:** the driver declares `[irq]` on the fn and a delivery kind on each event it raises from there, so the strict rules are known where the driver is written |
| E-Q9 | How does a driver state "acknowledged by" and its required ranges? | a clause on the set; attributes on the capture; a register-field effect | open: needs w1c fields (D3) first, since most acknowledgements are a w1c write or a read with side effect |
| E-Q11 | Do POL-1, POL-3, POL-4 and POL-6 apply to every library, or only to components with interrupt sets? | (a) every library; (b) interrupt components only | **POL-4: every library (owner, 2026-11-22)**, in the finished/partial form above. POL-1, POL-3, POL-6: leaning (a) |
| E-Q13 | How does a library's author mark it finished? | (a) a module-level marker (a new word); (b) a library's own `errors [policy: strict]` means "finished"; (c) a manifest/package field | **ruled 2026-11-22: (b), strict is finished automatically**; an explicit marker may follow |
| E-Q13a | Does finished (strict) also forbid `pending` / `...` stubs? | (a) yes, a stub in a strict library is refused; (b) no, stubs stay a separate PENDING concern | **ruled 2026-11-22: (a)** |
| E-Q14 | May a finished library import a partial one? | (a) no: finished requires finished dependencies; (b) yes | **ruled 2026-11-22: (a) no** |
| E-Q15 | What does a partial library's own `errors` block mean when it is imported? | (a) inert, with a line in the report saying the application's policy applies; (b) refused; (c) it wins (today) | **ruled 2026-11-22: (a) inert** |
| E-Q16 | Shortcut sites inside interrupt context | allowed only if the application's `on unhandled` is itself interrupt-safe; or never | **ruled 2026-11-22: never.** Interrupt code is strict and stub-free under any policy ("the embedded part is rigid"); built as TK-PO04 |
| E-Q12 | How does a component mark a knob as a requirement rather than a default? | a range form on the knob; a separate `requires:` clause; a component-level declaration | open: syntax for the design round |
| E-Q10 | How is a latency requirement checked? | report the worst-case raise-to-capture time from higher-or-equal-priority captures' cycle bounds; gate only on opt-in | report first, as for timing (VISION §4.5) |

## 8. Build order

**No ruling needed (finish the spec'd registry first; owner's rule: finish
partial features):**

- E1. More than one handler per event, in declaration order. **DONE
  2026-11-22**, across modules too.
- E2. `latest`. **DONE 2026-11-22**: `Reg.latest is V`, its own node
  (exkLatestIs), false before the first raise.
- E3. Handlers inside an actor, delivered as messages. **DONE 2026-11-22**:
  rewrite lifts a top-level forwarder that sends to the actor's mailbox.
- E4. Behavioural tests on all three backends for each: **DONE**,
  `tests/suites/event_registry.nim`.

**After the ruling (ruled 2026-11-22, §5):**

- E5. A registry per module and `tuck audit --events`, the program-wide
  event report. **DONE 2026-11-22**: TK-RG05 retired, TK-RG06 (one per
  module), TK-RG07 (names unique). Raises in task bodies and select arms
  are now checked, and so is a payload-less raise (it was matched by
  neither the checker nor any report).
- E5a. Delivery kinds on an event (`[stream]`, `[signal]`, `[latest]`) and
  the driver's `overflow:`. **DONE 2026-11-22 as declarations and checks**:
  TK-RG08 (a signal has no payload), TK-RG09 (overflow only on a stream,
  `drop_newest` or `drop_oldest`), TK-RG10 (interrupt code raises only an
  event with a delivery kind). The deferred delivery itself (queue, count,
  slot, drained after the interrupt) needs `bind`'s `queue: N` and is E5b.
- E5b. `bind LINE -> module.fn [priority: N, queue: N]`: an unbound `[irq]`
  fn is reported, an unbound or doubly-bound line is an error.
- E6. Hardware raisers on metal: SysTick raising a `Tick` event under QEMU,
  then a UART line (roadmap 2.2, 2.3).
- E6a. Register clear facts from SVD (with D3) and the "every path clears"
  check; `[budget, rate]` against the static score.
- E7. The host harness raising the same events (`tuck sim --host`), one
  vector per decision-table row.
- E8. The reuse test (roadmap 2.7) on two QEMU boards.
