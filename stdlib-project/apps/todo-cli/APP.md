# App: todo-cli (taskwarrior-like)

A local task manager: `todo add "buy milk" +errand due:tomorrow`, `todo list project:home +urgent`, `todo done 3`, `todo undo`. Tasks have tags, projects, priorities, due dates, optional recurrence, and a UUID. Storage is a local file (or small set of files); a query mini-language filters and sorts the list view.

## Why this is a good validation target
It is the best app in the set for `std.chrono` (due dates, recurrence, "overdue" calculations across timezones) and for `std.encoding` used as durable local storage rather than wire format, plus it forces a real answer for "undo" — i.e., whether the storage module makes small, safe, atomic updates easy or whether the app has to hand-roll write-ahead logging.

## Features
- Add/list/done/delete/modify tasks; tags (`+tag`), projects, priority, due date, recurrence rule (e.g. "every Monday").
- Filter query language: `project:home +urgent due:today`, sort by priority/due date.
- Undo/redo via an append-only change log.
- Import/export to JSON for interop/backup.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| sys | `sys.fs` | reading/writing the task database file(s), atomic rename for safe writes |
| std | `std.encoding` | JSON (interop/export) and/or a compact binary format for the local DB, through the *same* Codec interface |
| std | `std.chrono` | due dates, recurrence rules, "is this task overdue" logic, timezone-correct "today" |
| std | `std.regex` | parsing/matching parts of the filter query language |
| std | `std.cli` | argument parsing for the subcommand style (`todo add ...`), colored/tabular list output |
| std | `std.testing` | testing the filter-query parser and recurrence-rule math exhaustively |
| alloc | `alloc.map` | indexing tasks by UUID/tag for fast filtering |
| alloc | `alloc.vec` | the append-only undo log |
| core | `core.cmp` | sort ordering (priority, due date, custom user-defined orders) |
| core | `core.error` | malformed query strings, corrupt storage file |

## Anticipated API stress points
`std.chrono`'s recurrence math needs first-class support for "next occurrence after date D," not just duration arithmetic — a common gap in real date/time libraries this app would immediately expose. The undo log wants `sys.fs` to make append-then-fsync trivial and safe, without the app manually managing file offsets.
