# sys.env

## Purpose
Exposes the process's inherited environment: command-line arguments, environment variables, and the current working directory — the raw inputs every CLI app's argument parser and every config-loading routine ultimately reads from.

## Design lineage
Modeled on Rust's `std::env` (separate `args()` and `vars()` iterators, explicit `Result`-returning `var()` rather than a panicking index) and Go's `os.Args`/`os.Getenv`. Deliberately not modeled on C's raw `argc`/`argv`/`environ` or Python's `sys.argv`/`os.environ` dict, both of which hide encoding assumptions (are these bytes guaranteed UTF-8?) that this design makes explicit instead.

## Proposed API
```
fn args() -> ArgsIter;               // core.iter-compatible; yields Result<String, EnvError> per arg (lossy or strict, see below)
fn args_os() -> ArgsOsIter;          // yields raw OsString — no UTF-8 assumption, for paths/args with unusual bytes

fn var(key: &str) -> Result<String, EnvError>;         // EnvError::NotPresent | EnvError::NotUnicode
fn var_os(key: &str) -> Option<OsString>;
fn vars() -> VarsIter;               // yields (String, String) pairs, lossy-skips non-Unicode entries
fn set_var(key: &str, value: &str) -> Result<(), EnvError>;   // process-local; documented as NOT thread-safe on POSIX
fn remove_var(key: &str) -> Result<(), EnvError>;

fn current_dir() -> Result<PathBuf, EnvError>;
fn set_current_dir(path: &Path) -> Result<(), EnvError>;
fn current_exe() -> Result<PathBuf, EnvError>;           // path to the running binary, best-effort
fn temp_dir() -> PathBuf;                                // platform temp directory, infallible
fn home_dir() -> Option<PathBuf>;                        // best-effort, no guaranteed source of truth on all OSes
```

## Key design decisions
- `args()`/`vars()` return `String`-yielding iterators that can fail per-item (`EnvError::NotUnicode`), with an `_os` sibling that never fails, rather than one API that silently lossy-converts — apps that need strict correctness (a script's arguments containing meaningful non-UTF-8 bytes) aren't forced into silent data loss, but the common case stays ergonomic.
- `set_var`/`remove_var` are explicitly documented as **not thread-safe** on POSIX (glibc's `setenv`/`getenv` are famously not safe to call concurrently with each other) rather than the API pretending otherwise — this is surfaced in the signature's error type and doc comment, not discovered at a debugger.
- `current_dir`/`set_current_dir` are process-global mutable state, which the API doesn't try to hide or thread-local-ize — a program using threads that both read and mutate the working directory should coordinate via `sys.sync`, the same as any other shared mutable state, rather than `sys.env` inventing a bespoke locking scheme.

## Validated by applications
- **todo-cli / cli-hangman / log-grep / archive-cli**: every one of these is a subcommand-style CLI whose entire input surface is `args()` feeding into `std.cli`'s parser — none of them appear in a "Modules exercised" table listing `sys.env` explicitly (it's treated as an invisible foundation under `std.cli`), which is itself a finding: `sys.env` should be judged by how *little* apps need to think about it, not by distinctive usage patterns. A naive design that made `args()` panic on non-UTF-8 input would have been invisible in testing on any of these apps' happy paths but would break the first user whose file path (used as an argument) contains unusual bytes — hence the `_os` escape hatch above.
- **secrets-vault**: `temp_dir()`/`home_dir()` matter for locating the default vault file location, and this app is why `home_dir()` is `Option`, not `Result` with a guaranteed-present contract — there is genuinely no single authoritative source across POSIX (`$HOME` vs. passwd entry) and Windows, and a vault app choosing a wrong default location is a security-relevant mistake, so the API refuses to paper over the ambiguity.

## Open questions / risks
Whether `sys.env` should offer a snapshot-once `EnvMap` (read all vars into an immutable map at startup) as the *recommended* pattern, given `set_var`'s thread-safety caveat — most apps read environment variables once at startup and never again, and steering them toward a snapshot would sidestep the thread-safety issue entirely rather than merely documenting it.
