# sys.process

## Purpose
Spawns and manages child OS processes: builder-style command construction, stdin/stdout/stderr pipe wiring, exit-status inspection, and process-group control for cases the current app set doesn't directly exercise but any general-purpose systems stdlib must cover.

## Design lineage
Modeled on Rust's `std::process::Command` builder pattern (chainable configuration, then a single `.spawn()`/`.output()` call) over Go's `os/exec` (similar shape, slightly more implicit) and Python's `subprocess` (rejected as a primary model because its API surface — `run`/`call`/`check_call`/`Popen`, each with overlapping options — is exactly the "archaeological accretion" Principle 4 warns against; one builder, one execution path).

## Proposed API
```
struct Command { .. }
impl Command {
    fn new(program: &str) -> Command;
    fn arg(self, a: &str) -> Command;
    fn args<I: IntoIterator<Item = &str>>(self, a: I) -> Command;
    fn env(self, key: &str, val: &str) -> Command;
    fn env_clear(self) -> Command;               // start from an empty environment, not inherited-by-default
    fn current_dir(self, path: &Path) -> Command;
    fn stdin(self, cfg: Stdio) -> Command;
    fn stdout(self, cfg: Stdio) -> Command;
    fn stderr(self, cfg: Stdio) -> Command;
    fn spawn(self) -> Result<Child, ProcessError>;
    fn output(self) -> Result<Output, ProcessError>;      // spawn + wait + collect stdout/stderr, convenience
    fn status(self) -> Result<ExitStatus, ProcessError>;  // spawn + wait, no capture
}
enum Stdio { Inherit, Null, Piped, FromFile(File) }

struct Child { .. }
impl Child {
    fn id(&self) -> u32;
    fn stdin(&mut self) -> Option<&mut ChildStdin>;    // implements sys.io::Writer
    fn stdout(&mut self) -> Option<&mut ChildStdout>;  // implements sys.io::Reader
    fn stderr(&mut self) -> Option<&mut ChildStderr>;  // implements sys.io::Reader
    fn wait(&mut self) -> Result<ExitStatus, ProcessError>;
    fn try_wait(&mut self) -> Result<Option<ExitStatus>, ProcessError>;  // non-blocking poll
    fn kill(&mut self) -> Result<(), ProcessError>;                     // unconditional forceful termination (SIGKILL-equivalent)
    fn signal(&self, sig: sys::signal::Signal) -> Result<(), ProcessError>;  // send an arbitrary signal (e.g. Terminate) to this child by PID — graceful-stop request
}
struct Output { status: ExitStatus, stdout: Vec<u8>, stderr: Vec<u8> }

// ExitStatus is a closed, exhaustively-matchable enum, not an opaque struct with
// independently-nullable code()/signal() accessors — see "Revision (process-supervisor)" below.
enum ExitStatus {
    Exited(i32),                    // ran to completion; the exit code (0 == success)
    Signaled(sys::signal::Signal),  // terminated by a signal — never reached voluntary exit
}
impl ExitStatus {
    fn success(&self) -> bool;                        // true iff Exited(0)
    fn code(&self) -> Option<i32>;                     // Some(n) iff Exited(n); None iff Signaled
    fn signal(&self) -> Option<sys::signal::Signal>;   // Some(s) iff Signaled(s); None iff Exited
}
// Note what ExitStatus deliberately does NOT represent: spawn failure (binary not found,
// exec permission denied, etc.) is not a variant here at all — it surfaces as
// Err(ProcessError) from Command::spawn() itself, at an earlier, structurally distinct
// call site. A caller can never observe "spawn failed" and "exited/signaled" through the
// same value, which is the point.
```

## Key design decisions
- `env_clear()` exists because the default is inherited environment, which is convenient but a latent security issue (accidentally leaking a parent's secrets into a child) — making "start clean" one explicit call rather than the default matches Principle 2's spirit of "nothing hidden" even though this is above the no-alloc boundary.
- `ChildStdin`/`ChildStdout`/`ChildStderr` implement `sys.io`'s `Writer`/`Reader` directly, so piping a child process's output through `sys.io::copy` into a file or compressor needs zero glue code — this is a direct consequence of Principle 3 rather than a process-module-specific design.
- `Stdio` offers two genuinely different redirection paths, and process-supervisor's log-rotation requirement is what confirms both are needed rather than one being redundant: `Stdio::FromFile(File)` is a direct OS-level `dup2`-equivalent redirect — zero userspace copying, but fixed to one file descriptor for the child's whole lifetime, so it cannot express "start writing to a new file once the current one hits 10MB." `Stdio::Piped` gives the parent a `ChildStdout`/`ChildStderr` that is an ordinary `sys.io::Reader`, which the supervisor drains with `sys.io::copy` into its own small `RotatingWriter` (an app/std-level `Writer` that swaps its inner `File` when a size/time threshold crosses) — no special-cased "redirect with rotation" API exists anywhere in `sys.process`, because none is needed: rotation is just a `Writer` implementation, and any `Writer` composes with `copy` for free, per Principle 3. This is the concrete resolution to the "redirection must compose through `sys.io`, not need a special-cased API" requirement.
- `output()`/`status()` are documented convenience wrappers over `spawn()` + `wait()`, not separate code paths — avoiding Python subprocess's proliferation of near-duplicate entry points (Principle 4: one idiom).
- `kill()` sends the platform's unconditional forceful-termination signal; graceful termination (ask a child to shut down cleanly, e.g. `SIGTERM`, and give it a chance to exit before escalating) goes through the new `Child::signal(sig)` method instead — see "Revision (process-supervisor)" below for why this lives on `Child` rather than in `sys.signal` itself.

**Revision (process-supervisor):** two changes, both forced by the supervisor's graceful-shutdown requirement ("forward SIGTERM to all children, wait with a timeout, then SIGKILL stragglers") and its restart-policy logic ("crashed" vs. "exited cleanly" vs. "never started").
1. **`ExitStatus` changed from an opaque struct with `code()`/`signal()` returning independently-nullable `Option`s to a closed two-variant enum (`Exited(i32)` / `Signaled(Signal)`).** The original shape technically let a caller distinguish the cases by checking which accessor returned `Some`, but nothing in the type system *required* handling both — a supervisor could write `if let Some(code) = status.code() { restart_if_nonzero(code) }` and silently never restart a process that was killed by a signal (a real, security-relevant bug class: a supervised process OOM-killed by the kernel is indistinguishable from one that exited 0 unless the signaled case is exhaustively handled). The enum form makes `match status { Exited(0) => .., Exited(_) => restart(), Signaled(_) => restart() }` the natural way to write it, and an exhaustive match is a compile error if a variant is missed. `code()`/`signal()` are kept as convenience accessors over the enum, not the source of truth.
2. **`Child::signal(sig)` was added.** The original doc's plan — "graceful termination is `sys.signal`'s job, send `SIGTERM` to the child's PID" — turned out not to be implementable against `sys.signal`'s actual API: that module (see `modules/sys/signal/API.md`) is deliberately receive-only (register/`recv`, modeled on `signal-hook`), with no facility to *send* a signal to an arbitrary PID. Sending a signal to a specific child is a process-management operation tied to the PID a `Child` handle already owns, so it belongs on `Child`, reusing `sys.signal::Signal` as the vocabulary (so "which signals exist" stays defined in one place). This is exactly the SIGTERM-then-timeout-then-SIGKILL escalation a supervisor needs, and it was simply missing before this app exercised the module.

## Validated by applications
- **process-supervisor** (Round 2): this app was built specifically to close the gap noted below — it is now the module's primary validator. Its restart-vs-don't-restart policy is the direct forcing function for the `ExitStatus` enum revision (above): a supervisor that cannot reliably tell "exited 0," "exited nonzero," "killed by SIGKILL/OOM," and "never started at all" apart cannot implement correct backoff or its "flapping" circuit breaker (a process nonzero-exiting in a fast loop and one being repeatedly OOM-killed are both "crashing" for backoff purposes, but must be reported differently in supervisor logs — `std.log` needs the distinction even where the restart *policy* treats both the same). Its graceful-then-forceful shutdown sequence (SIGTERM to all children, wait with timeout, SIGKILL stragglers) is the forcing function for `Child::signal()`. Its stdout/stderr log-capture-with-rotation requirement is the concrete confirmation that `Stdio::Piped` + `sys.io::copy` (not a bespoke redirect API) is the right composition, exercising `Child::stdout()`/`stderr()`'s `Reader` implementations directly rather than incidentally.
- Prior to this app, none of the original 11 reference apps listed `sys.process` in their "Modules exercised" table (`mp3-player` delegates decoding via `sys.dynload`/`sys.ffi` in-process rather than subprocess; `doc-convert-tester`'s conversions are pure in-process transforms). That gap, recorded in `INDEX.md`'s "Honest gaps" section, is what process-supervisor was commissioned to close.
- `image-thumbnailer` (Round 2) lists `sys.process` as a secondary option alongside `sys.ffi` for invoking an external image codec (shell out to a CLI tool vs. FFI-bind a library) but its "Validation note" treats `sys.ffi` as the more direct answer for that app's case; see `modules/sys/dynload/API.md` and `modules/sys/ffi/API.md` for how that app's requirements were resolved. It does not add further pressure to `sys.process` itself beyond confirming `Command`/`Output` (the simple "run a tool, capture output" convenience path) is adequate for a fire-and-forget codec invocation, which the existing `output()` method already covers without change.

## Open questions / risks
Process groups and job control (mentioned in the module's one-line role) are not yet reflected in the API sketch above beyond `kill()`/`signal()` — POSIX process groups (`setpgid`, sending a signal to a whole group) and Windows Job Objects are different enough mechanisms that a portable abstraction needs real design work. process-supervisor's own design sidesteps this by tracking each child's PID individually and signaling each one in turn rather than relying on group semantics, which works for its scale (a small, statically-configured set of children) but would not scale to a supervisor managing children that themselves fork further descendants — deferred pending a validating app with that shape.
