# platform.rtos

## Purpose
An RTOS-agnostic API for tasks, queues, semaphores, mutexes, and timers, so application code that needs periodic scheduling and inter-task communication compiles unmodified against FreeRTOS, Zephyr's kernel, or a bare-metal cooperative executor.

## Design lineage
Modeled primarily on CMSIS-RTOS2, ARM's standardized, kernel-agnostic API that FreeRTOS, Zephyr, and other kernels already implement so application code doesn't have to pick a kernel to be portable (Part I, §1.4). Zephyr's own kernel API (`k_thread_create`, `k_sem`, `k_msgq`, `k_timer`) is used as a second precedent, chiefly for its explicit, no-hidden-state timer and work-queue conventions, since CMSIS-RTOS2 alone under-specifies periodic timer semantics.

## Proposed API
```
struct TaskConfig {
    stack_size: usize,       // bytes, compile-time-sized — no dynamic stack growth
    priority: Priority,      // fixed enum, not an arbitrary integer (avoids priority inversion by convention)
    name: &'static str,
}

trait Rtos {
    type TaskHandle;
    type Error;

    fn spawn_task(&self, cfg: TaskConfig, entry: fn(&mut TaskContext))
        -> Result<Self::TaskHandle, Self::Error>;
    fn task_sleep(&self, ctx: &mut TaskContext, dur: Duration);
    fn task_yield(&self, ctx: &mut TaskContext);
    fn run_on_idle(&self, hook: fn() -> WakeReason);
    // Registers the function the kernel's idle task calls in place of busy-waiting
    // when no task is runnable. The hook is expected to call
    // platform.power::enter_sleep(depth, wake_sources) itself and return the
    // WakeReason it got back — this trait deliberately does not wrap SleepDepth or
    // WakeSource selection (that policy stays in platform.power, per the existing
    // rtos/power boundary below). What the hook does with the WakeReason after
    // getting it back — typically Queue::send it to whichever task is blocked in
    // Queue::receive waiting to react — is application/BSP wiring, not a new
    // primitive this module needs to invent: Queue<T, N> already covers hook-to-task
    // and task-to-task delivery.
}

struct Queue<T, const N: usize> { /* fixed-capacity, no allocator */ }
impl<T, const N: usize> Queue<T, N> {
    fn send(&self, item: T, timeout: Duration) -> Result<(), QueueError>;
    fn receive(&self, timeout: Duration) -> Result<T, QueueError>;   // QueueError::Timeout | Full
}

struct Semaphore { /* counting semaphore */ }
impl Semaphore {
    fn new(initial: u32, max: u32) -> Self;
    fn acquire(&self, timeout: Duration) -> Result<(), TimeoutError>;
    fn release(&self);
}

struct Mutex<T> { /* priority-inheriting by default */ }
impl<T> Mutex<T> {
    fn lock(&self, timeout: Duration) -> Result<MutexGuard<T>, TimeoutError>;
}

trait PeriodicTimer {
    fn every(period: Duration, callback: fn(&mut TaskContext)) -> Self;
    fn cancel(&mut self);
}
```

## Key design decisions
- **Revision (embedded-display-node): `Rtos` gains `run_on_idle`, a named idle-task hook, so heterogeneous wake sources can be dispatched to whichever task should react — the existing task/queue primitives already cover the event-driven scheduling itself, so this is a small, targeted addition, not a redesign.** `Queue<T, N>::receive(timeout)` (already present) is exactly CMSIS-RTOS2/Zephyr's own idiom for a task that blocks until an event arrives rather than on a fixed interval — a task doing `queue.receive(Duration::MAX)` and reacting to whatever `WakeReason` value shows up *is* event-driven scheduling, and needs no new task-level primitive. The actual gap is upstream of that: something has to notice the whole MCU just woke from deep sleep and turn `platform.power::enter_sleep`'s `WakeReason` into a value posted onto that queue, and no existing method on `Rtos` names where that happens. `PeriodicTimer`'s validated design already established the pattern informally — "an RTOS-backed implementation lets the kernel's own idle-task power hook do it" — but that hook was never explicit or reusable because `PeriodicTimer::every`'s own trait method was the only consumer, and it only ever had one wake source (its own period) to hand back to itself. embedded-display-node's three heterogeneous sources feeding into a single UI task's queue is what makes the hook need a name and a signature of its own: `run_on_idle` is that name, kept as thin as possible (it returns the `WakeReason` and nothing more — routing it to a specific queue is left to the hook body, not baked into the trait) so it composes with `PeriodicTimer` rather than replacing it, and so a bare-metal (no-RTOS) build — which has no idle task to register a hook on in the first place — simply never calls `run_on_idle` at all and instead calls `enter_sleep` directly from its main loop, exactly as `PeriodicTimer`'s bare-metal implementation already does.
- **`Queue<T, N>` and `TaskConfig::stack_size` are fixed-capacity/compile-time-sized, never allocator-backed by default** — consistent with Principle 2 ("this tier typically uses only compile-time-sized arenas... never a general-purpose heap"). An `Rtos` implementation *may* back a task's stack with `alloc.allocator` on a hosted target, but the trait itself never requires it, so the identical `Queue<Sample, 8>` declaration works whether the backing kernel is FreeRTOS's `heap_4` or a bare-metal target with no heap at all.
- **`PeriodicTimer` is a distinct trait from `task_sleep`, not a convenience wrapper over it**, because "wake every N seconds, sample, sleep again" has two legitimate implementations that must both satisfy the same application code: a real RTOS runs the periodic work as a task blocked in `task_sleep` inside a loop, while a bare-metal executor with no task concept at all can implement `PeriodicTimer` directly on a hardware timer interrupt with no task, no stack, and no scheduler. Collapsing this into "just call sleep in a loop" would have made the bare-metal (no-RTOS) case impossible to express under the same trait, defeating the module's stated purpose.
- **Priority is a fixed, small enum (not an arbitrary integer)** deliberately narrowing what CMSIS-RTOS2 allows (which exposes a wide numeric priority range) — this is a portability bet: a numeric priority meaningful on an RTOS with 56 priority levels is not portably meaningful on a 3-level bare-metal scheduler, and the report's Principle 3 favors small composable interfaces over exposing every backend's full configuration surface.
- **Mutex is priority-inheriting by default with no opt-out in the trait**, because priority inversion is a well-known, hard-to-debug embedded failure class; an implementation without inheritance support (rare, but possible on a minimal bare-metal executor) must document the deviation rather than silently changing semantics — an intentional case where correctness is prioritized over covering every possible backend uniformly.

## Validated by applications
The embedded-sensor-node's periodic sampling requirement — sample, filter, log, sleep, repeat — is the reason `PeriodicTimer` exists as its own trait rather than folding into task/sleep primitives: the app's stated design intent is explicitly that "even if the final build is a bare-metal loop, the same task API should work if a real RTOS is later dropped in," which only holds if the periodic-wakeup abstraction doesn't presuppose a task/stack/scheduler in the first place. This is exactly the `rtos`/`power` boundary tension named in the assignment: the naive design (a single `Rtos::spawn_task` plus `task_sleep(duration)` in a loop) implicitly assumes a scheduler exists to resume the task after sleeping, but the app's real behavior is "sleep" meaning "enter a low-power mode and let a hardware timer wake the CPU," which is `platform.power`'s responsibility, not `platform.rtos`'s. The fix reflected in `PeriodicTimer` above is that `rtos` owns *scheduling intent* (what runs, how often, in what order) while `power` owns *how the wait is physically realized* (WFI/STOP mode vs. RTOS tick), and the two compose rather than one subsuming the other — a bare-metal `PeriodicTimer` implementation calls into `platform.power`'s sleep-mode selection directly, while an RTOS-backed implementation lets the kernel's own idle-task power hook do it. Whether this trait set actually survives contact with the device: yes for the sampling loop itself, but the ring-buffer critical section (shared between the I2C ISR and the periodic task) is only expressible by combining `rtos`'s `Mutex` with `platform.interrupt`'s critical-section primitive, which this module does not provide alone — a real gap, not papered over here.

Where the sensor node validated the *periodic* half of this module — one task, one interval, sleep-and-resume forever, which is exactly what `PeriodicTimer` as a trait distinct from `task_sleep` exists to serve — embedded-display-node validates the *event-driven* half, which the original design left almost entirely implicit. Its scheduling requirement is qualitatively different: react to whichever of {encoder, button, RTC alarm} occurred, not "do the same fixed thing every fixed interval." `Queue<T, N>::receive(timeout)` turns out to already be the right task-level primitive for this — a genuine point in the original design's favor, since it was included for general inter-task communication, not designed with this scenario in mind, and still fits — but the app exposes that nothing in the module said *who* is responsible for noticing a multi-source hardware wake-up and translating it into a queued event a task can `receive()`. That responsibility is invisible with only a single wake source in evidence (the sensor node's sample timer), because a single source has nowhere else to be routed to — there being only one task interested, and one plausible reason. This app's requirement of one wake, disambiguated three ways, feeding into scheduling decisions for a single UI task is what forces that responsibility to get a name (`run_on_idle`).

## Open questions / risks
Whether `PeriodicTimer` should be part of `platform.rtos` at all, versus living entirely in `platform.power` or `platform.interrupt`, is genuinely unsettled — it sits at the seam between all three modules and this design's placement (in `rtos`, delegating the "how" to `power`) is a judgment call, not a settled fact. CMSIS-RTOS2 itself does not have a directly equivalent timer-vs-sleep split, so this is a deviation from the primary lineage that has not been validated against a second real application.

`run_on_idle` inherits the same unsettled-seam problem, and arguably sharpens it: it is now unclear whether *this* hook belongs in `rtos` at all, versus being a `platform.power`-owned callback that `rtos`'s idle task merely calls into, since the hook's entire body is "call `platform.power::enter_sleep` and hand the result somewhere" — very little of what it does is actually `rtos`-specific. This design keeps it in `rtos` because the "hand the result somewhere" half (posting to a `Queue<T, N>`) is an `rtos` concept `power` has no reason to know about, but that is a placement judgment, not a proof, and it has not been tested against a third application with a different scheduling shape (e.g. multiple tasks each caring about a different subset of wake sources) that might break the "one hook, one WakeReason" assumption `run_on_idle` makes.
