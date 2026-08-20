# sys.env — Nim API

## Purpose
What the process was handed on the way in: command-line arguments, environment variables, the working directory, and the handful of well-known locations (temp, home, the running binary) every CLI eventually asks for.

## Protocols implemented
`env`, the process environment, is `Gettable[string, Text]` + `Settable` + `Collection[(Text, Text)]` — it really is a table, so it gets the table's words. `arguments()` is a plain `Collection[Text]`.

## The API

```nim
type Environment* = object   ## the process environment. There is exactly one
let env*: Environment

proc get*(e: Environment; key: string): Option[Text]
  ## Absent if unset. Raises `Failure` if the value is set but isn't valid UTF-8 —
  ## absence and corruption are different things and get different answers.
proc tryGet*(e: Environment; key: string): Option[Text]      ## absent for either reason
proc getBytes*(e: Environment; key: string): Option[seq[byte]]  ## never fails on encoding
proc has*(e: Environment; key: string): bool
proc set*(e: var Environment; key: string; value: string)
proc remove*(e: var Environment; key: string): Option[Text]
iterator list*(e: Environment): (Text, Text)                 ## the Collection primitive
proc count*(e: Environment): int
proc snapshot*(e: Environment; memory = defaultMemory()): Table[Text, Text]
  ## Read the whole environment once, into an ordinary `alloc.map`. This is the recommended
  ## shape for anything threaded: POSIX's `setenv`/`getenv` are not safe to call concurrently
  ## with each other, so a snapshot at startup sidesteps the problem instead of documenting it.

iterator arguments*(): Text
  ## Everything after the program name. Raises on a non-UTF-8 argument.
iterator rawArguments*(): seq[byte]     ## never raises — for paths with unusual bytes
proc programName*(): Text

proc workingDir*(e: Environment): Path
proc `workingDir=`*(e: var Environment; p: Path)
  ## Process-global mutable state, and this module doesn't pretend otherwise: if two threads
  ## both touch it, guard it with a `sys.sync.Guarded` like any other shared value.
proc exePath*(e: Environment): Path             ## best effort; raises where the OS won't say
proc tempDir*(e: Environment): Path             ## always answers
proc homeDir*(e: Environment): Option[Path]     ## genuinely absent on some systems — see below
```

**Why `set` is not thread-safe, stated once.** `setenv` on glibc can reallocate `environ` while another thread is walking it. Nim cannot fix that, so this module says so in the signature's doc comment and offers `snapshot` as the way out, rather than inventing a lock that only protects callers who happen to use this module.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `env::var(key) -> Result` | `env.get(key): Option[Text]` | it's a lookup in a table. `Gettable`'s exact signature, so it needs no learning |
| `env::var_os` | `env.getBytes` | says what you get back, not which OS concept it came from |
| `env::set_var` / `remove_var` | `env.set` / `env.remove` | the structural verbs. `remove` even hands back what was there, as the table promises |
| `env::vars()` | `env.list()` | the `Collection` primitive, so `count`, `each` and `toSeq` all arrive free |
| `env::args()` | `arguments()` | spelled out; `args` is the abbreviation everyone expands mentally anyway |
| `current_dir()` / `set_current_dir()` | `env.workingDir` / `env.workingDir = p` | Nim's assignment sugar; one name instead of a get/set pair |
| `current_exe()` | `env.exePath()` | "exe" plus "path" says it; "current" was never in question |
| `home_dir() -> Option` | unchanged | kept `Option` deliberately — see below |
| *(none)* | `snapshot()` | new. Resolves this module's own open question in favour of the safe pattern |

## In use

```nim
# secrets-vault: find the vault, refusing to guess
let vault = env.get("VAULT_FILE").map(toPath)
              .orElse(env.homeDir().map(h => h / ".vault"))
              .orRaise("no VAULT_FILE set and no home directory — say where the vault is")

# log-grep: arguments straight into the parser, with the odd-bytes door left open
var patterns = newList[Text]()
for a in arguments():
  if a.startsWith("-"): flags.add(a) else: patterns.add(a)

# process-supervisor: snapshot once, hand a clean environment to each child
let base = env.snapshot()
command(cfg.exe, cfg.args, env = base.only(cfg.passThrough), clearEnv = true).start()
```

## Vocabulary exceptions
- **`env` is a module-level value, not a type you construct.** There is one process environment; making callers write `getEnvironment().get(...)` would be ceremony around a global that is genuinely global. `Environment` exists only so the structural verbs have a target to attach to.
- **`arguments()` and `programName()` take no target.** Same reason. They are the one place in the tier where a structural verb (`list`) would have had nothing to list *from*, so they are plainly-named iterators instead.
- **`homeDir` returns `Option`, not a `Path` with a fallback.** There is no authoritative answer across POSIX (`$HOME` versus the passwd entry) and Windows, and a vault that silently picks the wrong directory is a security bug. Absence is the honest report.
