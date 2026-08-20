# platform.interrupt

## Purpose
Critical-section (interrupt-mask) primitives and interrupt vector registration, providing the one mechanism every other `platform.*` module uses to protect shared state from concurrent access by an ISR and application code.

## Design lineage
Modeled on the Rust `cortex-m` crate's `critical-section` abstraction — a single `CriticalSection` token type that proves interrupts are masked for the lifetime of a closure, decoupled from any specific core's interrupt-disable instruction — with Zephyr's `irq_lock()`/`irq_unlock()` pair as the second precedent for the lower-level, non-RAII masking primitive that some contexts (ISR entry/exit, RTOS internals) need directly rather than through a closure.

## Proposed API
```
// Token proving interrupts are masked; cannot be constructed outside this module.
struct CriticalSection<'cs> { _private: PhantomData<&'cs ()> }

fn critical_section<R>(f: impl FnOnce(CriticalSection) -> R) -> R;
// Nests safely: re-entering while already inside a critical section is a no-op,
// not a re-mask/re-unmask that could race on restore.

// Lower-level, non-RAII pair for contexts that can't take a closure (ISR prologues,
// RTOS scheduler internals):
fn irq_lock() -> LockState;
fn irq_unlock(state: LockState);   // must restore prior state, not force-enable

trait InterruptController {
    fn enable(&mut self, vector: IrqVector);
    fn disable(&mut self, vector: IrqVector);
    fn set_priority(&mut self, vector: IrqVector, prio: IrqPriority);
    fn pending(&self, vector: IrqVector) -> bool;
    fn clear_pending(&mut self, vector: IrqVector);
}

// Vector registration is static (compile-time), not a runtime handler-pointer table:
macro_rules! interrupt_handler {
    ($vector:ident => $handler:ident);
}

// A Mutex<T> that can only be accessed from inside a CriticalSection, statically
// preventing "forgot to lock" bugs at compile time rather than at runtime:
struct IrqMutex<T> { /* ... */ }
impl<T> IrqMutex<T> {
    fn borrow<'cs>(&'cs self, cs: CriticalSection<'cs>) -> &'cs T;
}
```

## Key design decisions
- **`CriticalSection` is an unforgeable token, not a boolean or a guard object you might forget to check** — code that needs to touch shared state must be handed a `CriticalSection` value, which only `critical_section()` or an ISR prologue can produce. This mirrors Rust `critical-section`'s core trick: the type system, not caller discipline, prevents "read shared state outside a critical section," which is directly the failure mode the sensor-node app's ring buffer is exposed to (I2C/timer ISR writes concurrently with the sampling task).
- **Nesting is defined to be safe and cheap (a no-op on re-entry) rather than left undefined**, because the app's I2C driver (itself calling into a critical section around DMA/status-register access) is invoked from *within* the periodic task's own critical section around the ring-buffer write in some code paths — a naive mask/unmask-every-time implementation would incorrectly re-enable interrupts on the inner exit, unmasking before the outer critical section intended.
- **Vector registration is static (a compile-time macro binding a symbol to a vector), not a runtime-mutable function-pointer table.** This trades a small amount of flexibility (no runtime handler swapping) for eliminating an entire bug class (a NULL or wild vector-table entry from an uninitialized runtime table) — consistent with the tier's "nothing hidden, nothing assumed" principle, and matching how `cortex-m-rt` actually does it.
- **`IrqMutex<T>::borrow` requires a `CriticalSection` value as a parameter**, not an internal lock/unlock pair, so that holding the token *is* holding the lock — this directly composes with `platform.rtos`'s `Mutex<T>` (which is for task-vs-task contention) to cover the ISR-vs-task case that `rtos::Mutex` alone cannot, since blocking inside an ISR is not a valid operation on any of the three reference kernels.

- **Revision (embedded-display-node): confirmed, rather than changed, that `platform.interrupt` has no concept of "this interrupt is a wake source" — and that it should not gain one.** embedded-display-node needs the encoder and button interrupts to wake the device from deep sleep, not merely to protect a shared data structure while the CPU is already awake, which is a genuinely different use of "interrupt" than the sensor node's ring-buffer critical section. The boundary is resolved explicitly rather than left implicit: wake-source designation belongs entirely to `platform.power`'s `WakeSource`/`WakeReason` types (see that module's revision), for two concrete reasons this app surfaces that the sensor node never did. First, in `SleepDepth::Standby`, the encoder/button pin's interrupt vector *does* still fire an ordinary ISR when it wakes the core (execution resumes where `enter_sleep` was called) — so `platform.interrupt`'s vector-registration and critical-section machinery is still exactly what runs, just triggered by a source `platform.power` also happens to be watching for wake purposes. `platform.interrupt` doesn't need to know "this vector is also a wake source" to handle that correctly; it just handles the vector, as always. Second, in `SleepDepth::Shutdown`, the same GPIO edge does *not* fire an ordinary ISR at all — RAM isn't retained, so waking is architecturally a reset, and nothing in `platform.interrupt`'s model (vector table, critical sections, `IrqMutex`) is even live at the moment the wake occurs; the "why did I just restart" question is answered by `platform.power::last_wake_reason()`, read back from `platform.boot`'s reset path, not by anything in this module. Giving `platform.interrupt` its own "wake source" concept would therefore either duplicate `platform.power::WakeSource` (for the Standby case) or be actively wrong (for the Shutdown case, where no interrupt vector fires at all) — so the resolution is to add nothing here and keep the module's scope exactly where it already was: masking and vector dispatch for interrupts that are live and firing, full stop.

## Validated by applications
The embedded-sensor-node names "I2C/timer interrupt handling" and "critical sections around the ring-buffer write" directly as the feature this module exists for, and it is the clearest case in this tier where a naive design would have failed outright: if critical sections were expressed as an ordinary function pair (`lock()`/`unlock()`) instead of an unforgeable token, nothing would stop the ring-buffer write path from being reached without ever calling `lock()` — a bug that is easy to introduce and, on a device with no debugger attached in the field, effectively unfindable. The requirement that both the I2C ISR (writing a completed sample) and the periodic sampling task (reading/rotating the ring buffer) touch the same fixed-size buffer is exactly what `IrqMutex<T>` is for, and it only works because `borrow()` demands a live `CriticalSection`, forcing every touch point through the same guarded path at compile time. This module survives contact with the app without needing a vendor escape hatch — critical-section masking is one of the few operations in this tier that genuinely is uniform across Cortex-M silicon (a single core register, PRIMASK/BASEPRI), which is precisely why `cortex-m`'s `critical-section` crate itself has stayed stable in practice; the escape-hatch risk from Part V is much more acute in `hal` and `devicetree` than here.

embedded-display-node validates a different axis of this module than the sensor node did. The sensor node validated the *ISR-vs-task race* use of critical sections — protecting a fixed-size ring buffer written from an I2C/timer ISR and read from a periodic task, where `IrqMutex<T>::borrow` demanding a live `CriticalSection` is what makes the bug (forgetting to lock) unrepresentable. embedded-display-node touches almost none of that: there's no shared ring buffer here, and its ISRs (encoder edge, button edge) are simple, low-rate, and don't race with a task over mutable state in the same way. What it validates instead is the *boundary* question above — that "interrupt" and "wake source" are related but not identical concepts, and that this module's job stops at "the vector fires and is dispatched" without reaching into sleep-depth or reset semantics. That distinction was invisible with only one embedded app in evidence, because the sensor node's only sleep behavior was a single timer wake that never routed through an interrupt vector at all (`WakeKind::Timer`, handled entirely inside `platform.power`) — this module's relationship to sleep/wake was simply never exercised before this second device.

## Open questions / risks
Nested-masking correctness on cores with priority-based masking (BASEPRI-style partial masking, not just PRIMASK all-or-nothing) is not fully specified above — `set_priority`-aware critical sections that only mask interrupts below a given priority (needed if a future device wants a truly non-maskable, always-live interrupt) would require a second, priority-aware critical-section variant that this design has not yet worked out. A second, newer open question from embedded-display-node: whether an interrupt vector that is also configured as a `Standby`-depth wake source needs any special re-entry handling on resume (e.g., is `CriticalSection` state guaranteed sane immediately after WFI returns, before the ISR's normal prologue runs?) is asserted here by analogy to ordinary interrupt entry, but not independently verified against a specific vendor's wake-latency behavior — a genuine gap this project's analysis-only scope cannot close.
