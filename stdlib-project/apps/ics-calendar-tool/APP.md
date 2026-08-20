# App: ics-calendar-tool

A CLI calendar utility: `icstool list calendar.ics --from 2026-09-01 --to 2026-09-30` expands recurring events (`RRULE`) into their concrete occurrences within a date range, respecting per-event timezones (`VTIMEZONE`), and `icstool conflicts calendar.ics` reports overlapping events. `icstool add calendar.ics "Team sync" --every week:mon --time 10:00 --tz America/New_York` generates a new recurring event.

## Why this is a good validation target
This is the deepest test yet of `std.chrono`'s recurrence math (`Recurrence::next_after`, added in the original design specifically for `todo-cli`'s "remind me every Monday" case) against the real iCalendar `RRULE` grammar, which is considerably richer than simple weekly repetition (monthly-by-weekday-ordinal like "third Thursday," yearly-with-exceptions via `EXDATE`, and per-occurrence timezone conversion). It's also the second app (after `git-lite`, `diff-patch`, `config-schema-validator`) to propose a new `std.encoding` format, forcing the inclusion-policy test defined in Extension round 2 to actually be applied by someone other than the app that motivated it.

## Features
- Parse `.ics` files (VEVENT/VTIMEZONE/VALARM components, `RRULE`/`EXDATE`/`RDATE` recurrence rules).
- Expand recurring events into concrete occurrences within a queried date range, timezone-correct (an event created in `America/New_York` displayed to a viewer in `Asia/Tokyo` must land on the right wall-clock moment).
- Conflict detection: find overlapping occurrences across all events in a calendar, including recurring ones expanded within a window.
- Generate new `.ics` files/events from CLI flags, round-tripping through the same parser.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| std | `std.chrono` | the module under direct stress — `Recurrence` needs to express `RRULE`'s actual grammar (BYDAY with ordinals, BYMONTHDAY, UNTIL/COUNT bounds, EXDATE exceptions), and timezone-correct occurrence expansion across DST transitions |
| std | `std.encoding` | parsing/generating the `.ics` text format — **apply the Extension-round-2 inclusion policy explicitly: does iCalendar pass?** See validation note |
| std | `std.testing` | recurrence expansion is exactly the kind of logic that needs property/table-driven tests against real-world `RRULE` edge cases (DST spring-forward skipping an hour, February 29th yearly events, "last weekday of the month") |
| sys | `sys.fs` | reading/writing `.ics` files |
| std | `std.cli` | date-range query flags, tabular event listing |
| core | `core.error` | malformed `RRULE` strings, unresolvable timezone identifiers |

## Validation note: applying the format-inclusion policy to iCalendar
Extension round 2's `std.encoding` inclusion policy requires a format to be (1) general-purpose for arbitrary data, not one tool's fixed output, and (2) small, unambiguous, and securely separable. iCalendar passes both, differently from the two formats that failed: unlike unified-diff (which is one specific tool's output format, not a general serialization target), `.ics` is a widely-used, multi-vendor interchange format (calendar apps, scheduling systems, `RRULE` is even reused outside calendaring for generic recurrence description) — it passes criterion 1. Unlike YAML (whose ambiguity is load-bearing to the format itself), iCalendar's grammar is verbose but unambiguous, and it has no equivalent of YAML's type-coercion footguns or unsafe-tag history — it passes criterion 2. The proposed resolution: `std.encoding.ics` is a legitimate addition, structured the same way `std.encoding.xml`'s `FeedReader` sits on top of the general `XmlReader` — a focused `.ics` component/property parser, with `Recurrence`'s `RRULE` support living in `std.chrono` (since recurrence expansion is fundamentally date/time logic, not a text-parsing concern) and consumed by the encoding layer rather than duplicated inside it.
