# std.cli — Nim API

## Purpose
Everything between a user's terminal and your program: parsing arguments and subcommands, printing tables and progress, asking questions, and colouring output — including knowing when not to colour it.

## Protocols implemented
`Collection` on `Args` (enumerate what was passed) and `Gettable[string, T]` on parsed options. `Lifecycle` on `Progress` (`start`/`stop`). The rest are domain verbs — a terminal is not a container.

## The API

```nim
type
  Command* = object
  Args* = object

macro command*(name: static string; body: untyped): Command
  ## Declares a command and its flags in one block. The macro generates the
  ## parser, the `--help` text, and a typed accessor per flag — so a
  ## misspelled flag name is a compile error, not a runtime `nil`.

command "bsync":
  flag verbose, 'v', "print every file considered"
  option exclude, 'x', seq[string], "glob patterns to skip"
  option jobs, 'j', int, default = 4, "parallel workers"
  argument source, string, "folder to copy from"
  argument dest, string, "folder to copy into"
  subcommand "check", checkCmd
  run:
    if verbose: echo "syncing ", source, " → ", dest

proc get*[T](a: Args; name: string): Option[T]   ## for dynamic access; the macro is better
proc has*(a: Args; name: string): bool
iterator list*(a: Args): (string, string)
proc parse*(c: Command; argv: openArray[string]): Args   ## raises with a usage message
proc tryParse*(c: Command; argv: openArray[string]): Option[Args]

type Progress* = object
proc newProgress*(total: int; label = ""): Progress
proc start*(p: var Progress): bool
proc adjust*(p: var Progress; delta: int)    ## the verb table's relative change
proc set*(p: var Progress; done: int)        ## absolute
proc stop*(p: var Progress): bool            ## clears the line; safe if never started
proc newProgressGroup*(): ProgressGroup      ## many bars, one for each concurrent worker

type Table* = object   ## column-aligned output; distinct from alloc.Table, see below
proc newTable*(headers: openArray[string]): Table
proc add*(t: var Table; row: openArray[string]): bool {.discardable.}
proc show*(t: Table): Text                   ## widths computed once, at print time

proc ask*(question: string; default = ""): string
proc askSecret*(question: string): Secret[Text]
  ## Echo off. Returns alloc's Secret, so it cannot be printed by accident.
proc confirm*(question: string; default = false): bool

proc styled*(text: string; colour = Plain; bold = false): string
  ## Returns plain text when output is not a terminal, when NO_COLOR is set,
  ## or when piped — so `mytool | grep` never sees escape codes. No flag needed.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| clap's `Arg::new().long().short().help()` builder | the `command` macro block | a builder chain per flag is the single biggest source of CLI boilerplate; a declaration block reads like the `--help` output it generates |
| `ArgMatches::get_one::<T>("name")` | generated typed accessor, or `get(a, name)` | the macro path means you write `jobs`, not a string lookup that can be misspelled |
| `ProgressBar::inc(1)` / `set_position(n)` | `adjust(p, 1)` / `set(p, n)` | the verb table already distinguishes relative from absolute; two standard words instead of two invented ones |
| `MultiProgress` | `ProgressGroup` | says what it is, not how many |
| `term::Table` | `Table` (in `std.cli`) | kept, with the collision note below |
| `Password::new().interact()` | `askSecret(question)` | one call, and the return type is what stops it being logged |
| `colored::Colorize` trait | `styled(text, colour =)` | a free proc that already knows about pipes and `NO_COLOR`, so the correct behaviour is the default one |

## In use

```nim
# process-supervisor: a status snapshot, refreshed
var t = newTable(["process", "state", "uptime", "restarts"])
for p in supervisor.list(): t.add([p.name, $p.state, p.uptime.show(), $p.restarts])
echo t.show()

# image-thumbnailer: one bar per concurrent worker, from std.async tasks
let bars = newProgressGroup()
withScope: (scope) =>
  for file in folder.list(): scope.spawn thumbnail(file, bars.add(file.name))

# secrets-vault: the passphrase never becomes a printable string
let phrase = askSecret("master passphrase: ")
```

## Vocabulary exceptions
- **`Table` collides with `alloc.Table`**, deliberately and visibly. They are imported from different modules and mean different things (a hash map versus aligned terminal output), and any other name for the terminal one — `Grid`, `Report`, `Columns` — reads worse at the call site. Qualified imports (`cli.Table`) resolve it where both are needed, which is rare.
- `ask`, `confirm`, `styled`, `parse` and the `command` macro are domain verbs; the structural table has nothing to say about a conversation with a human.
- **`show` on `Table` returns `Text` rather than printing.** It follows `core.fmt`'s `Showable`, so the output can be tested, piped into a log, or written to a file — printing is the caller's `echo`.
