# sys.process — Nim API

## Purpose
Run another program: configure it, start it, talk to its pipes, ask it to stop politely, and find out exactly how it ended — "exited with 3" and "the kernel killed it" never collapse into one number.

## Protocols implemented
`Child` is `Lifecycle` (`start`/`stop`/`isRunning`) + `Waitable` (`wait`), per PROTOCOLS' assignment table. Its pipes are `Streamable`, so they are `sys.io` streams like any other.

## The API

```nim
type
  Wiring* = enum
    Inherit                      ## share the parent's console (the default)
    Discard                      ## /dev/null
    Capture                      ## give the parent a Pipe
    ToFile                       ## dup2 straight onto a File — no userspace copying
  Command* = object              ## what to run; inert until started
  Child* = object                ## Lifecycle + Waitable. Remembers its Command, so it can restart
  Pipe* = object                 ## Streamable, nothing more
  Ending* = enum Finished, Killed
  Exit* = object
    case ended*: Ending
    of Finished: code*: int      ## ran to completion
    of Killed:   signal*: Signal ## never got to exit voluntarily
                                 ## Nim requires `case` over this to be exhaustive — the
                                 ## OOM-killed-child branch cannot be forgotten.

proc command*(program: string; args: openArray[string] = [];
              workDir = Path""; env = inheritEnv(); clearEnv = false;
              input = Inherit; output = Inherit; errors = Inherit): Command
  ## One constructor with named arguments instead of a nine-method builder chain.
  ## `clearEnv = true` starts from an empty environment — one word, so leaking a parent's
  ## secrets into a child is a decision rather than an oversight.

proc start*(c: Command): Child          ## raises if the binary is missing or not executable
proc tryStart*(c: Command): Option[Child]
proc start*(ch: var Child): bool        ## Lifecycle: run the same Command again — this *is* restart
proc stop*(ch: var Child; grace = 5.seconds): bool
  ## Terminate, wait up to `grace`, then Kill. The escalation a supervisor actually wants,
  ## in one call, so nobody hand-rolls it and gets the timeout wrong.
proc isRunning*(ch: Child): bool        ## reaps if it can; never leaves a zombie behind
proc wait*(ch: var Child; timeout = Forever): bool   ## Waitable: true if it ended in time
proc exit*(ch: Child): Option[Exit]     ## absent while it is still running
proc send*(ch: var Child; sig: Signal)  ## the vocabulary's hand-off verb, aimed at a PID
proc pid*(ch: Child): int

proc input*(ch: var Child): Option[Pipe]     ## present only where you asked for `Capture`
proc output*(ch: var Child): Option[Pipe]
proc errors*(ch: var Child): Option[Pipe]

proc succeeded*(e: Exit): bool               ## true only for `Finished(0)`
proc run*(c: Command; timeout = Forever): (Exit, seq[byte], seq[byte])
  ## start + wait + collect. A convenience over the above, not a second code path.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Command::new().arg().env().current_dir()` | `command(program, args, env =, workDir =)` | nine chained setters become one call; the argument-order rule already covers it |
| `Stdio` | `Wiring` | it configures three streams, not one, and "stdio" is jargon |
| `Stdio::Piped` / `Null` / `FromFile` | `Capture` / `Discard` / `ToFile` | each says what happens to the bytes |
| `spawn()` | `start()` | `Lifecycle`'s verb — and it makes `stop` then `start` obviously a restart |
| `kill()` + `signal(sig)` | `send(ch, Kill)` / `send(ch, Terminate)` | one verb. `kill()` was a second name for one message |
| `wait()` / `try_wait()` | `wait(timeout =)` / `isRunning` / `exit` | absence is `Option[Exit]`, not a nested `Result<Option<_>>` |
| `ExitStatus::Exited/Signaled` | `Exit` with `Finished` / `Killed` | kept as a closed variant; "Finished" and "Killed" need no glossary |
| `ChildStdin/Stdout/Stderr` (3 types) | one `Pipe` | direction is decided by which field you took it from |
| `output()` / `status()` | `run(c, timeout =)` | one convenience, with the timeout Rust's version can't express |

## In use

```nim
# process-supervisor: the whole restart policy, exhaustively handled
var child = command(cfg.exe, cfg.args, workDir = cfg.dir,
                    output = Capture, errors = Capture).start()
run(drainInto, (child.output.get(), rotatingLog))     # sys.io.copy, zero glue

while not stopping:
  discard child.wait()
  case child.exit().get().ended
  of Finished:
    if child.exit().get().code == 0: break             # clean exit, done
    backoff.next().sleep(); discard child.start()      # crashed
  of Killed:
    log.warn "killed by ", child.exit().get().signal   # OOM-killed reads differently in the log
    backoff.next().sleep(); discard child.start()

discard child.stop(grace = 10.seconds)                 # Terminate, wait, then Kill
```

## Vocabulary exceptions
- **`send(child, signal)` uses `Messenger`'s verb without `Child` being a `Messenger`.** A signal genuinely is a message handed to a process, and `receive` has no meaning here — `sys.signal` owns the receiving side, for *this* process only. Borrowing the right verb beat inventing `signal()`.
- **`Lifecycle.start` on an already-finished `Child` re-runs it.** This is the one place the protocol pays for itself outright: a supervisor's restart loop is `stop` then `start` on one value, with no second "Command" object to keep alive alongside it.
- **`exit()` returns `Option`, `start()` raises.** "Not finished yet" is ordinary absence; "that binary does not exist" is a failure. A caller can never see a spawn failure and an exit status through the same value.
