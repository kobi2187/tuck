# sys.signal — Nim API

## Purpose
Notice that someone pressed Ctrl-C, or that the system is asking your program to shut down, and deal with it in ordinary code. Signals arrive as messages you receive, never as a callback the OS runs on your behalf.

## Protocols implemented
`Signals` is `Resource` (`open`/`close`/`isOpen`) and borrows `receive` from `Messenger`. It is not a full `Messenger` — nothing in this module can send.

## The API

```nim
type
  Signal* = enum
    Interrupt      ## Ctrl-C
    Terminate      ## a polite "please stop"
    Hangup, Quit, User1, User2
    BrokenPipe     ## usually you want `ignore(BrokenPipe)` — see below
    WindowChanged
  Signals* = object   ## Resource. A queue of signals delivered to *this* process

proc watch*(wanted: varargs[Signal]): Signals
  ## Start collecting. Raises if the platform can't deliver one of them; see `tryWatch`.
  ## Registering a signal twice fans out to every live `Signals` — a library watching
  ## `Interrupt` never steals delivery from your own shutdown watcher.
proc tryWatch*(wanted: varargs[Signal]): Option[Signals]
proc onInterrupt*(): Signals
  ## `watch(Interrupt, Terminate)`. The one line a small CLI needs and nothing more.

proc receive*(s: var Signals; timeout = Forever): Option[Signal]
  ## Blocks in ordinary code, on an ordinary thread, with the whole language available.
  ## Absent on timeout. This is the only way signals leave this module.
proc close*(s: var Signals)      ## stop collecting; idempotent
proc isOpen*(s: Signals): bool
proc count*(s: Signals): int     ## how many are queued right now, unread

proc ignore*(sig: Signal)
  ## Discard it from now on. `ignore(BrokenPipe)` is what stops a client disconnecting
  ## mid-write from killing a whole server — the write returns an ordinary
  ## `IoFailure(problem: Reset)` instead, which the connection's own code already handles.
proc restore*(sig: Signal)       ## back to the OS default disposition
proc has*(sig: Signal): bool     ## does this platform deliver it at all? Windows answers `false` a lot
```

**There is no way to register a callback, and that is the design.** Everything real a program wants to do on Ctrl-C — truncate a partial file, rename it into place, tell connected clients, flush a log — is unsafe to call from actual signal-handler context on every OS there is. So this module's handler does exactly one async-signal-safe thing, a write to a self-pipe, and hands the decision to `receive` on a thread you control.

**Nim notes.** The internal handler is `{.noconv.}` and touches nothing but an `Atomic[int]` and a pipe write, so it is safe under `--mm:arc`, `--mm:orc` and `--mm:none` alike; no allocator and no GC are ever entered from handler context. On Windows there are no POSIX signals: `Interrupt` and `Terminate` are wired to `SetConsoleCtrlHandler`, and `has(Hangup)` honestly returns `false` rather than pretending.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `register(&[Signal])` → `SignalReceiver` | `watch(...)` → `Signals` | `watch` is the same word `sys.fs`'s file watcher uses for the same act; the plural type name says it holds several |
| `recv` / `try_recv` / `recv_timeout` | `receive(s, timeout =)` | three names become one, and absence is `Option`, per the rule |
| `SIGINT` / `SIGTERM` | `Interrupt` / `Terminate` | nobody has to know what the letters stood for |
| `SIGPIPE` | `BrokenPipe` | describes the situation, which is also the fix |
| `restore_default(sig)` | `restore(sig)` | "default" was the only thing you could restore it to |
| *(none)* | `has(sig)` | new. Windows genuinely lacks most of these, so "can this platform do it?" needs an answer that isn't a raise |
| `on_interrupt()` | `onInterrupt()` | kept — it earns its place as the one-liner for a small CLI |

## In use

```nim
# web-downloader: Ctrl-C must leave a resumable partial file, never a corrupt one
var signals = onInterrupt()
run(proc (s: Signals): int {.thread.} =
      discard s.receive()        # ordinary code, on an ordinary stack
      cancel.set(true), signals, name = "signals")

# ...on the download thread, at a frame boundary — where fs calls are actually safe:
if cancel.get():
  partial.persist(metadata = false)
  partial.close()
  rename(partialPath, partialPath.withSuffix(".resume"))
  quit(0)

# chat-server: stop accepting, tell everyone, drain
ignore(BrokenPipe)               # a vanishing client is an IoFailure, not a process death
onInterrupt().receive().ifSome(sig):
  server.close()
  rooms.read do (r: Rooms): r.announce("server restarting, back in a minute")
```

## Vocabulary exceptions
- **`watch` is a domain verb, shared deliberately with `sys.fs`.** `open` belongs to `Resource` and means "acquire this handle again"; starting to collect a *set* of signals is not that. Two modules, one word, same meaning — that is the vocabulary working.
- **`ignore` and `restore` are domain verbs with no target argument.** Signal disposition is process-global state the OS owns; inventing a `Process` object to be the target would be ceremony around a one-line call.
- **`Signals` uses `receive` without a matching `send`.** Sending a signal to another process lives on `sys.process`'s `Child`, where the PID actually is — `send(child, Terminate)`. Two halves of `Messenger` in two modules, each where it belongs, rather than a fake `send` here that could only ever signal yourself.
