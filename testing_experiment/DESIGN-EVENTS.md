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
  - Only the library's own author can mark it finished; an application can
    neither finish someone else's library nor un-finish one.
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

## 5. The reuse test, sketched

One UART driver, two applications, two boards. The driver names no line,
priority, instance or capacity.

```text
# SKETCH — shape only.

# uart.tuck — the driver library
interrupt events UartEvents:               # an INTERRUPT set the driver owns (§3a)
  | Rx({port: UartId, byte: u8})           # the instance travels in the payload
  | Overrun({port: UartId})
  acknowledged by: reading DR              # IRQ-3: checked on every path
  requires: queue >= 4, on_full in {drop}  # IRQ-5: the range it was written for

capture rxReady({port: Uart}) -> UartEvents:
  # immediate, interrupt context: the ONE capture (IRQ-1), never pending (IRQ-2)
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
  bind USART3.rx -> uart.rxReady [priority: 3, queue: 8,  on_full: drop]
  # queue: 2 here would be a compile error: "uart requires queue >= 4" (IRQ-5)
```

What the checker proves for each application, with the driver unchanged:

- every bound line has exactly one capture, from the driver; an unbound line
  stays disabled; a line bound twice is an error; no other module added an
  immediate handler (IRQ-1, IRQ-6);
- the capture is not pending and acknowledges its source on every path
  (IRQ-2, IRQ-3);
- every chosen knob lies inside the driver's declared range (IRQ-5);
- every event in the composed registry is handled (TK-RG03, as today);
- the capture reaches only ISR-safe operations (TK-EF05/07/11, as today);
- shared state touched by immediate handlers gets a ceiling from the bound
  priorities, and `critical:` lowers to that ceiling;
- every deferred queue fits the RAM budget; `on_full: wait` is refused for a
  hardware-raised event (an interrupt cannot wait);
- the same program built for a host replaces "line raises event" with
  "harness pends the line on the simulated controller" (IRQ-7), so the driver
  runs in `tuck sim --host` on all three backends under the same rules.

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
| E-Q7 | Is binding in the registry, the board package, or both? | (a) board default + application choice per knob, inside the driver's range; (b) application only | (a), with IRQ-5: the board may suggest, the driver bounds, the application chooses |
| E-Q8 | Are the strict rules a separate kind of set, or inferred from "a line is bound to it"? | (a) a declared **interrupt** kind; (b) inferred from binding | (a): a driver's author must know, while writing it, that IRQ-1..9 apply; inferring it at the application would make a library's rules depend on who imports it, which is the problem being solved |
| E-Q9 | How does a driver state "acknowledged by" and its required ranges? | a clause on the set; attributes on the capture; a register-field effect | open: needs w1c fields (D3) first, since most acknowledgements are a w1c write or a read with side effect |
| E-Q11 | Do POL-1, POL-3, POL-4 and POL-6 apply to every library, or only to components with interrupt sets? | (a) every library; (b) interrupt components only | **POL-4: every library (owner, 2026-11-22)**, in the finished/partial form above. POL-1, POL-3, POL-6: leaning (a) |
| E-Q13 | How does a library's author mark it finished? | (a) a module-level marker (a new word); (b) a library's own `errors [policy: strict]` means "finished"; (c) a manifest/package field | open, syntax. (b) needs no new word, but "strict" says nothing about `pending`; (a) states the intent exactly |
| E-Q14 | May a finished library import a partial one? | (a) no: finished requires finished dependencies; (b) yes | (a): otherwise the application's policy reaches the finished library through its dependency's continued-past error, which is what POL-1 forbids |
| E-Q15 | What does a partial library's own `errors` block mean when it is imported? | (a) inert, with a line in the report saying the application's policy applies; (b) refused; (c) it wins (today) | (a): it stays useful when the library is checked alone (its own self-check `main`), and visible when it is not |
| E-Q16 | Shortcut sites inside interrupt context | allowed only if the application's `on unhandled` is itself interrupt-safe (checked like any ISR callee); a `pending` capture may only trap | keeps the walking skeleton available for drivers without risking an interrupt storm |
| E-Q12 | How does a component mark a knob as a requirement rather than a default? | a range form on the knob; a separate `requires:` clause; a component-level declaration | open: syntax for the design round |
| E-Q10 | How is a latency requirement checked? | report the worst-case raise-to-capture time from higher-or-equal-priority captures' cycle bounds; gate only on opt-in | report first, as for timing (VISION §4.5) |

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
