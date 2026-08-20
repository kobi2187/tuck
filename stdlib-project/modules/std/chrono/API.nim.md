# std.chrono — Nim API

## Purpose
Dates and times that refuse to be confused with each other — a calendar date is not an instant, and "in one month" is not "in 30 days" — plus recurrence rules rich enough for a real calendar file, not just "every Monday".

## Protocols implemented
`Recurrence` is a `Collection[ZonedTime]`: implement `list` and "every occurrence in September" is a `for` loop that can `break`. `Instant` and `ZonedTime` are `Adjustable[Duration]`. Nothing here is a `Resource` or a `Messenger`; the rest is domain arithmetic.

## The API

```nim
type
  Instant* = object      ## a point on the timeline, UTC, nanoseconds. No calendar.
  Date* = object         ## a calendar day. No time, no zone.
  TimeOfDay* = object    ## a wall-clock time. No day, no zone.
  DateTime* = object     ## day + time, still no zone — "2026-08-19 14:30" is ambiguous
  ZonedTime* = object    ## day + time + zone. The only one that can answer "how long until".
  Zone* = object         ## an IANA id, e.g. "America/New_York"
  Weekday* = enum Mon, Tue, Wed, Thu, Fri, Sat, Sun
  Period* = object       ## calendar-relative: years, months, days
  Recurrence* = object

proc now*(): Instant
proc today*(z: Zone): Date            ## no zone-less `today` exists — it isn't a real question
proc inZone*(i: Instant; z: Zone): ZonedTime
proc inZone*(d: DateTime; z: Zone): ZonedTime
  ## The only path from a wall-clock reading to a real moment. Raises on a DST gap
  ## (02:30 on a spring-forward morning doesn't exist); `tryInZone` returns none.
proc toInstant*(z: ZonedTime): Instant
proc at*(d: Date; t: TimeOfDay): DateTime

proc adjust*(i: var Instant; delta: Duration)     ## exact elapsed time. Adjustable.
proc adjust*(z: var ZonedTime; delta: Duration)
proc shift*(d: Date; years = 0; months = 0; days = 0): Date
  ## Calendar arithmetic, by named argument. Jan 31 `.shift(months = 1)` lands on
  ## the last valid day of February, which is what a person means.
proc until*(a, b: ZonedTime): Duration
proc compare*(a, b: ZonedTime): Ordering          ## core.cmp — the one comparison mechanism
proc weekday*(d: Date): Weekday

# Recurrence — built by naming what repeats, then narrowing it.
proc every*(days = 0; weeks = 0; months = 0; years = 0;
            on: openArray[Weekday] = []; onDays: openArray[MonthDay] = [];
            startingAt: DateTime; zone: Zone): Recurrence
proc until*(r: Recurrence; at: ZonedTime): Recurrence   ## RRULE UNTIL
proc times*(r: Recurrence; n: Count): Recurrence        ## RRULE COUNT — mutually exclusive with `until`
proc skipping*(r: Recurrence; dates: openArray[Date]): Recurrence     ## EXDATE
proc alsoOn*(r: Recurrence; moments: openArray[DateTime]): Recurrence ## RDATE

proc next*(r: Recurrence; after: Date): Option[ZonedTime]
  ## none once the bound runs out — a tightly bounded, heavily excepted rule
  ## genuinely can have no next occurrence.
iterator list*(r: Recurrence; fromDate, toDate: Date): ZonedTime
  ## Lazy, and each occurrence's UTC offset is recomputed from its own date, so a
  ## 10:00 meeting stays at 10:00 local across a DST transition instead of drifting.

proc toRecurrence*(rrule: TextView; startingAt: ZonedTime): Recurrence  ## RFC 5545 grammar
proc toRrule*(r: Recurrence): Text                                     ## the exact inverse
proc parseRepeat*(spec: TextView): Recurrence                          ## "every monday"
```

`MonthDay` is `day(15)`, `lastDay()`, or `nth(3, Thu)` — with a **negative** ordinal counting from the end, so `nth(-1, Fri)` is RRULE's `BYDAY=-1FR`, "the last Friday".

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `LocalDate` / `LocalDateTime` / `ZonedDateTime` | `Date` / `DateTime` / `ZonedTime` | Three long names where the word doing the work was buried in the middle. The distinction survives; the typing doesn't. |
| `LocalTime` | `TimeOfDay` | Says what it is. "Local time" sounds like a zone-aware concept, and it isn't one. |
| `TimeZone` | `Zone` | One word, and it never appears without a date beside it. |
| `date.plus(Period{months:1})` | `date.shift(months = 1)` | **The headline rename.** No struct to construct, and `shift` (calendar) versus `adjust` (exact `Duration`) puts two different words on the two different arithmetics — which is the bug class this module exists to prevent. |
| `duration_until(other)` | `until(a, b)` | Reads at the call site: `cert.goodUntil().until(now)`. |
| `is_before -> Ordering` | `compare -> Ordering` | The old name promised a `bool` and returned a three-way answer. |
| `Recurrence::new(rule, start, tz)` + `RecurrenceRule` enum | `every(weeks = 1, on = [Mon], ...)` | A four-variant enum plus a constructor collapse into one call whose arguments read as English. |
| `with_bound(Until(d))` / `Count(n)` | `.until(d)` / `.times(n)` | Two builder words instead of a wrapper enum; being separate procs is also what enforces RRULE's "never both" rule. |
| `with_exceptions` / `with_additions` | `skipping` / `alsoOn` | EXDATE and RDATE in one word each, from the reader's point of view rather than the spec's. |
| `next_after(d)` | `next(r, after = d)` | Shorter, and the `Option` says the bound can run out. |
| `occurrences_between` | `iterator list(r, from, to)` | The Collection primitive, with two locators — the same widening `alloc.vec`'s `Grid.get(row, col)` already takes. |
| `from_rrule` / `to_rrule` | `toRecurrence` / `toRrule` | The `to<Format>` family in both directions. |

## In use

```nim
# ics-calendar-tool: expand every recurring event into a September window
for part in newIcsReader(calFile).list():
  if part.kind == VEvent:
    let repeat = part.rrule.map(r => r.toRecurrence(startingAt = part.dtstart))
    for at in repeat.get().list(fromDate = from, toDate = to):
      occurrences.add((part.summary, at))       # ZonedTime, so cross-zone overlap is real

# ics-calendar-tool: `icstool add ... --every week:mon --time 10:00 --tz America/New_York`
let r = every(weeks = 1, on = [Mon],
              startingAt = today(tz).at(hour(10)), zone = tz)
writer.write(newEvent(summary), repeats = some(r))

# todo-cli: the same type, built the small way
task.due = parseRepeat("every monday").next(after = today(tz))
```

## Vocabulary exceptions
`shift`, `until`, `every`, `times`, `skipping`, `alsoOn`, `next` and `inZone` are domain verbs — calendar arithmetic has no structural analogue, and each is one word taking its subject first.

`until` is deliberately overloaded across two shapes: `until(a: ZonedTime, b: ZonedTime): Duration` and `until(r: Recurrence, at: ZonedTime): Recurrence`. The word means the same thing both times ("up to this moment"); Nim resolves by type, and giving the second one a different name would have been a synonym.

**Still missing, named rather than papered over:** RRULE's `BYSETPOS` (pick the Nth result after combining several BY* filters) and sub-daily `FREQ=HOURLY/MINUTELY/SECONDLY` are not expressible with `every`'s arguments. No app in the corpus needs either, so neither is guessed at.
