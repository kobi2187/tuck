# std.chrono — Tuck translation

## Shape decision
Freeform `pending:` over plain records, one per calendar concept.
**Compiler-verified**, `./tuck ch`: `OK`.

## The API

```tuck
type Weekday:
  | Mon
  | Tue
  | Wed
  | Thu
  | Fri
  | Sat
  | Sun

type Date = {year: i32, month: u8, day: u8}
type TimeOfDay = {hour: u8, minute: u8, second: u8, nano: u32}
type DateTime = {date: Date, time: TimeOfDay}
type Zone = {id: str}
type ZonedTime = {moment: DateTime, zone: Zone, offsetSec: i32}
type Period = {years: i32, months: i32, days: i32}

type ChronoError:
  | NoSuchZone
  | DstGap
  | OutOfRange

pending:
  fn today({z: Zone}) -> !Date [io, error: ChronoError]
  fn inZone({atMs: u64, z: Zone}) -> !ZonedTime [io, error: ChronoError]
  fn tryInZone({moment: DateTime, z: Zone}) -> ZonedTime?
  fn toUnixMs({zt: ZonedTime}) -> u64
  fn at({d: Date, t: TimeOfDay}) -> DateTime
  fn addPeriod({d: Date, p: Period}) -> Date
  fn weekdayOf({d: Date}) -> Weekday
  fn daysBetween({from: Date, to: Date}) -> i32
  fn parseDate({t: str}) -> Date?
  fn formatDate({d: Date, pattern: str}) -> str
```

## The design this module exists for, and it survives intact

The Nim design followed `java.time` — "the best-designed date/time API
surveyed, by consensus" — in keeping `Date`, `TimeOfDay`, `DateTime` and
`ZonedTime` as **genuinely distinct, non-interchangeable types**, because
"2026-08-19 14:30" is ambiguous until a zone is attached, and subtracting
two wall-clock readings across a DST boundary gives nonsense.

Tuck's records give that for free, and two of the Nim design's sharpest
calls translate unchanged:
- **No zone-less `today`** — "it isn't a real question."
- **`inZone` raises on a DST gap** (02:30 on a spring-forward morning does
  not exist), with `tryInZone` returning `?` for callers that expect it.
  That's exactly the raise-vs-`?` split the language already enforces.

## Notes
- **`when` could not be a field name** — reserved (`when TARGET == "..."`);
  renamed to `moment`. `FRICTIONS.md` #5c.
- **`Instant` is deliberately not redefined here.** It belongs to
  `sys.time`, which is real code; this module takes `atMs: u64` and hands
  back calendar values. Keeping one clock type in one place avoids the
  two-`Instant` problem the Nim design had to navigate between these
  modules.
- **`Recurrence` is not translated.** Round-3 restructured it from a flat
  pattern enum into a composite (rule + bound + timezone + exceptions) to
  handle RFC 5545 — signed ordinal weekdays, UNTIL/COUNT, EXDATE/RDATE.
  It's the largest single type in the corpus and needs the sum-type
  treatment done carefully rather than sketched; deferred deliberately, not
  forgotten. `ics-calendar-tool` and `todo-cli` both depend on it.
- **`Period` (calendar-relative) vs elapsed milliseconds stays split**,
  which is the other thing `java.time` gets right: "one month later" is not
  a fixed number of milliseconds.
