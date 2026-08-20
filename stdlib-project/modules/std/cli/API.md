# std.cli

## Purpose
Subcommand-capable argument parsing plus terminal color, progress-bar, and prompt helpers — the full toolkit for building a polished command-line tool without an external crate/package.

## Design lineage
Modeled on Rust's `clap` for ergonomics (declarative argument definitions that generate help text, subcommands, and validation together, rather than manual flag-by-flag branching), explicitly positioned as an improvement on Go's `flag` package ("too minimal" — no subcommands, no generated help formatting, positional args require manual handling) and Python's `argparse` ("too verbose" — a `parser.add_argument(...)` call per flag with string-keyed everything, no compile-time-checked destination type).

## Proposed API
```
// Declarative builder — one Command tree covers top-level flags, subcommands, and positional args.
struct Command;
impl Command {
    fn new(name: &str) -> Command;
    fn about(self, text: &str) -> Command;
    fn arg(self, a: Arg) -> Command;
    fn subcommand(self, cmd: Command) -> Command;
    fn parse(&self, argv: &[&str]) -> core::types::Result<Matches, ParseError>;   // returns Err with formatted usage text
}
struct Arg;
impl Arg {
    fn new(name: &str) -> Arg;
    fn short(self, c: char) -> Arg;               // -v
    fn long(self, s: &str) -> Arg;                 // --verbose
    fn takes_value(self) -> Arg;
    fn required(self) -> Arg;
    fn default_value(self, v: &str) -> Arg;
    fn help(self, text: &str) -> Arg;
    fn value_parser<T: core::convert::TryFrom<&str>>(self) -> Arg;   // typed parsing + typed error at parse() time
}
struct Matches;
impl Matches {
    fn get<T: core::convert::TryFrom<&str>>(&self, name: &str) -> Option<T>;
    fn is_present(&self, name: &str) -> bool;
    fn subcommand(&self) -> Option<(&str, &Matches)>;   // which subcommand ran, and its own Matches
}
enum ParseError { MissingRequired(alloc::string::String), InvalidValue { arg: alloc::string::String, msg: alloc::string::String },
                    UnknownFlag(alloc::string::String) }

// Terminal output
mod term {
    enum Color { Red, Green, Yellow, Blue, Cyan, Default }
    fn colored(text: &str, c: Color) -> alloc::string::String;   // no-op (plain text) when stdout isn't a tty — auto-detected
    fn is_tty(w: &dyn sys::io::Writer) -> bool;

    struct ProgressBar;
    impl ProgressBar {
        fn new(total: u64) -> ProgressBar;
        fn set(&mut self, current: u64);
        fn set_message(&mut self, msg: &str);
        fn finish(self);
    }
    struct MultiProgress;      // for N-way concurrent operations (downloads, archive entries) — one line per item
    impl MultiProgress {
        fn add(&mut self, total: u64) -> ProgressBar;
    }

    fn prompt(question: &str) -> alloc::string::String;                 // reads a line, echoed
    fn prompt_hidden(question: &str) -> alloc::string::String;           // password-style, no echo
    fn confirm(question: &str, default: bool) -> bool;                   // y/n prompt

    // Added for process-supervisor: `supervisorctl status` is a column-aligned snapshot of
    // several always-running processes (name/pid/uptime/restart-count/state) refreshed on
    // demand, not a 0..total operation moving toward completion — ProgressBar's "total" concept
    // doesn't fit it, and hand-aligning columns with padded format strings is exactly the kind
    // of ceremony this module exists to remove elsewhere. `Table` is a static column-aligned
    // renderer (one snapshot in, one formatted block out); it does not redraw in place the way
    // `ProgressBar` does, since a status table's rows can change in count and content between
    // refreshes, unlike a bar's monotonic single value.
    struct Table { headers: alloc::vec::Vec<alloc::string::String> }
    impl Table {
        fn new(headers: &[&str]) -> Table;
        fn row(&mut self, cells: &[&str]) -> &mut Table;
        fn render(&self) -> alloc::string::String;   // column widths sized to content; colored via `colored()` per-cell if desired
    }
}
```

## Key design decisions
- **`Arg::value_parser<T>` ties a flag to a typed destination via `core.convert::TryFrom`, the same conversion mechanism every other `std` module uses (Principle 4)**, rather than `std.cli` inventing its own per-type parsing convention — a malformed `--retries=abc` for a `u32`-typed arg produces a `ParseError::InvalidValue` at `parse()` time with no separate manual `.parse()` call needed in application code, closing the gap the report identifies in `argparse`'s type-blind, string-everywhere design.
- **Color output auto-detects TTY-ness and degrades to plain text when piped**, rather than requiring the caller to check `term::is_tty` before every colored call — `term::colored` is always safe to call unconditionally, which keeps CLI code free of `if is_tty { ... } else { ... }` branches scattered through it.
- **`MultiProgress` exists as a distinct type from `ProgressBar`, not a `Vec<ProgressBar>` the caller manages manually**, because concurrent progress bars need shared terminal-line coordination (redrawing N lines in place without interleaving corrupted output from concurrent writers) that a bare collection of independent bars can't provide safely under `std.async`'s concurrent tasks.
- **Subcommand `Matches` are returned as a nested `(&str, &Matches)` pair rather than an enum the caller must exhaustively match** — this keeps `Command`'s subcommand tree fully data-driven (subcommands can be added without touching a central enum definition), at the cost of the caller needing a runtime `match` on the string name rather than a compiler-checked exhaustiveness check; judged an acceptable tradeoff since CLI dispatch is inherently a runtime, string-keyed operation (`argv[1]`) either way.
- **Revision (process-supervisor):** `ProgressBar`/`MultiProgress` (validated by `archive-cli`, `web-downloader`) both model an operation moving from `0` toward a known `total` — that shape does not fit `supervisorctl status`, which is a repeated snapshot of several independently-running, indefinitely-lived processes with no "done" state at all. Rather than stretching `ProgressBar` to cover it (e.g. abusing `set_message` for a whole table, which every prior app already showed is meant for a single short status string next to a bar), `term::Table` was added as its own type for the column-aligned-snapshot case. `math-toolkit-cli`'s `mtk stats` tabular output (mean/median/stddev/percentiles as a row each) is the same shape and uses the same type — a second, independent app landing on the identical need is a real signal this was a gap, not just a one-app preference.

## Validated by applications
- **todo-cli**: the primary subcommand-tree exercise — `todo add`/`list`/`done`/`undo` each are a `Command::subcommand`, with `add`'s free-text tag/project/due-date arguments validated by this design's ability to mix required positional text with typed optional flags in one declaration; also the app that most exercises `Matches::get::<T>` for a typed due-date argument parsed straight through `std.chrono`'s conversion.
- **archive-cli**: exercises `MultiProgress` directly — `archive create` over many files reports one progress line per large file while an aggregate bar tracks the whole operation, which is the concrete case that forced `MultiProgress` to exist as more than "just construct several `ProgressBar`s."
- **secrets-vault**: the defining exercise for `term::prompt_hidden` — the master-passphrase prompt must never echo input to the terminal or leave it in shell history, and `confirm` gates destructive operations (`vault delete`); this app is also why `prompt_hidden`'s returned `String` is explicitly called out in `std.crypto`'s doc as material the caller should feed directly into `kdf::derive_key` and drop promptly, rather than treating `std.cli`'s prompt helpers as responsible for secret hygiene themselves.
- **cli-hangman**: exercises the plain, non-subcommand path (`Command::new("hangman").arg(...)`, no `.subcommand()` calls at all) plus `term::colored` for win/lose banners — validates that the simplest possible CLI doesn't require touching any of the subcommand machinery to get typed flag parsing and colored output.
- **process-supervisor**: forces the `term::Table` addition above — `supervisorctl status` is a refreshable snapshot table, a genuinely different shape from every prior app's progress display. Also exercises the plain-subcommand path (`status`/`restart`/`stop`/`tail` as `Command::subcommand`s) alongside `web-downloader`/`todo-cli`/`archive-cli`, with nothing new there.
- **image-thumbnailer**: confirms `MultiProgress` (established by `archive-cli`) generalizes past sequential per-file progress to genuinely concurrent progress updates arriving from `std.async`-spawned worker tasks rather than a single-threaded loop advancing one bar at a time — `MultiProgress::add` handing back an independent `ProgressBar` per in-flight file is exactly what lets each worker task own and update its own bar without a shared-mutable-state coordination problem the caller has to solve by hand; no API change needed, this is the concrete case that shows the "shared terminal-line coordination" design decision above wasn't just archive-cli-shaped.

## Open questions / risks
Whether `std.cli` should generate shell-completion scripts (bash/zsh/fish) from the same `Command` declaration, as `clap` does via a separate crate, is left open; none of the eleven apps required it, so it's deferred rather than designed here.
