# App: process-supervisor (systemd-lite)

A CLI daemon that supervises a small set of child processes defined in a config file: starts them, restarts them on crash with exponential backoff, captures and rotates their stdout/stderr to log files, and exposes `supervisorctl status|restart|stop <name>` over a local Unix socket.

## Why this is a good validation target
`sys.process` was flagged in Round 1's INDEX.md as having zero validating apps. This app exists specifically to close that gap under real pressure: correct child reaping (no zombies), signal forwarding on supervisor shutdown, and distinguishing "child exited 0" from "child crashed" from "child was intentionally stopped" are all things a thin `Command`/`spawn` API can get subtly wrong.

## Features
- Config file (TOML, via `std.encoding`) listing processes: command, args, working dir, restart policy.
- Spawn, monitor exit status, restart with exponential backoff (capped), and a "flapping" circuit breaker (give up after N crashes in M minutes).
- Redirect child stdout/stderr to rotating log files (size- or time-based rotation).
- Local control socket (Unix domain) for `status`/`restart`/`stop`/`tail` commands from a companion CLI.
- Graceful supervisor shutdown: forward SIGTERM to all children, wait with a timeout, then SIGKILL stragglers.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| sys | `sys.process` | the module under direct test — spawn, wait/reap, exit-status classification, stdout/stderr redirection |
| sys | `sys.signal` | forwarding SIGTERM/SIGINT to children; handling the supervisor's own signal receipt |
| sys | `sys.fs` | log file rotation, reading the config file |
| sys | `sys.net` | the Unix domain control socket |
| std | `std.log` | supervisor's own structured logging, separate from captured child output |
| std | `std.chrono` | backoff timing, "N crashes in M minutes" windowing |
| std | `std.encoding` | TOML config parsing |
| alloc | `alloc.map` | process-name → handle/state registry |
| core | `core.error` | classifying child failure modes (exited nonzero, killed by signal, spawn failed entirely) |

## Anticipated API stress points
`sys.process`'s exit-status type needs to distinguish "exited with code N" from "terminated by signal S" as different cases, not collapse both into one integer (the classic POSIX `wait()` footgun) — a supervisor cannot implement correct backoff-vs-don't-restart policy without that distinction. Redirecting a child's stdout to a `sys.fs` file handle needs to compose through `sys.io`'s Reader/Writer the same way every other stream in the stdlib does, not require a special-cased "redirect" API distinct from what `web-downloader` or `archive-cli` use for ordinary files.
