# std.chrono

## Purpose
Genuinely distinct, non-interchangeable date/time types — `Instant`, `LocalDate`, `LocalDateTime`, `ZonedDateTime` — plus first-class recurrence-rule support for computing "next occurrence after date D," which ordinary date/time libraries typically bolt on poorly or omit.

## Design lineage
Modeled directly on Java's `java.time` (JSR-310), which the report calls "explicitly the best-designed date/time API in the whole survey" — specifically its refusal to let a timezone-naive local date and a timezone-aware instant be the same type, which is the root cause of most real-world date bugs in other languages' single-`Date`-type designs. Recurrence-rule support (absent from `java.time` itself, which stops at `Period`/`Duration` arithmetic) is added as a first-class extension because `todo-cli`'s app profile identifies it as a real, common gap.

## Proposed API
```
// Types are deliberately NOT interconvertible without an explicit, named conversion.
struct Instant;                          // monotonic-free wall-clock instant, UTC, nanosecond precision (re-exports sys.time::SystemTime's instant)
struct LocalDate { year: i32, month: u8, day: u8 };                 // no time-of-day, no zone — a calendar date only
struct LocalTime { hour: u8, minute: u8, second: u8, nanos: u32 };  // no date, no zone
struct LocalDateTime { date: LocalDate, time: LocalTime };           // no zone — "2026-08-19 14:30", ambiguous in isolation
struct ZonedDateTime { local: LocalDateTime, zone: TimeZone, offset: UtcOffset };  // the only type that can answer "how long until"

struct TimeZone(alloc::string::String);   // IANA tz database ID, e.g. "America/New_York"
struct Duration { secs: i64, nanos: u32 };   // exact elapsed time — for Instant/ZonedDateTime arithmetic
struct Period { years: i32, months: i32, days: i32 };  // calendar-based — for LocalDate arithmetic (respects month lengths, leap years)

impl Instant { fn now() -> Instant; fn to_zoned(&self, tz: &TimeZone) -> ZonedDateTime; }
impl LocalDate {
    fn today(tz: &TimeZone) -> LocalDate;         // explicit: "today" is meaningless without a zone
    fn plus(&self, p: Period) -> LocalDate;
    fn day_of_week(&self) -> Weekday;
    fn at(&self, time: LocalTime) -> LocalDateTime;
}
impl LocalDateTime { fn at_zone(&self, tz: &TimeZone) -> ZonedDateTime; }  // the only path to a "real" instant
impl ZonedDateTime {
    fn to_instant(&self) -> Instant;
    fn duration_until(&self, other: &ZonedDateTime) -> Duration;
    fn is_before(&self, other: &ZonedDateTime) -> core::cmp::Ordering;   // core.cmp — the one comparison mechanism
}

enum Weekday { Mon, Tue, Wed, Thu, Fri, Sat, Sun }

// Recurrence: the gap todo-cli exposed, EXTENDED (ics-calendar-tool) to cover RRULE's actual
// grammar. See "Revision (ics-calendar-tool)" below for why this became a richer composite type
// — rule + bounds + exceptions — rather than staying a single flat pattern enum.
//
// RecurrenceRule is the "how often" pattern (todo-cli's original Daily/Weekly/Monthly/Yearly
// shape, extended with BYDAY-with-ordinal and BYMONTHDAY to cover RRULE's FREQ/BYxxx grammar).
enum RecurrenceRule {
    Daily { every_n_days: u32 },
    Weekly { on: alloc::vec::Vec<Weekday>, every_n_weeks: u32 },
    Monthly { on: alloc::vec::Vec<MonthDay>, every_n_months: u32 },   // "on" plural: RRULE allows multiple BYDAY/BYMONTHDAY entries per rule
    Yearly { on: (u8, u8) },        // (month, day)
}
// "3rd Thursday" is NthWeekday(3, Thu); "last weekday of the month" is NthWeekday(-1, ...) — a
// negative ordinal is RRULE's own convention for counting from the end (BYDAY=-1FR = "last Friday").
enum MonthDay { Fixed(u8), Last, NthWeekday(i8, Weekday) }

// Bound: RRULE's UNTIL/COUNT — a recurrence rule alone is unbounded (repeats forever) unless
// paired with one of these. Exactly one or neither (Never = unbounded), never both, matching
// RRULE's own "UNTIL and COUNT are mutually exclusive" grammar rule.
enum RecurrenceBound {
    Never,                          // unbounded — todo-cli's original "every monday, forever" case
    Until(ZonedDateTime),           // RRULE UNTIL — always evaluated in the recurrence's own zone (see decisions)
    Count(u32),                     // RRULE COUNT — stop after N occurrences, counted from the first
}

// Recurrence: the composite value RRULE actually is — a rule, a bound, and per-instance
// exceptions/additions — rather than the bare pattern enum todo-cli's simpler case needed.
struct Recurrence {
    rule: RecurrenceRule,
    bound: RecurrenceBound,
    tz: TimeZone,                              // the recurrence's own zone — see DST decision below
    start: LocalDateTime,                      // the first occurrence's local wall-clock time, e.g. 10:00
    exceptions: alloc::vec::Vec<LocalDate>,    // RRULE EXDATE — dates that would otherwise recur, but don't
    additions: alloc::vec::Vec<LocalDateTime>, // RRULE RDATE — one-off extra occurrences outside the rule
}

impl Recurrence {
    fn new(rule: RecurrenceRule, start: LocalDateTime, tz: TimeZone) -> Recurrence;  // bound: Never, no exceptions, by default
    fn with_bound(self, bound: RecurrenceBound) -> Recurrence;
    fn with_exceptions(self, dates: alloc::vec::Vec<LocalDate>) -> Recurrence;
    fn with_additions(self, dates: alloc::vec::Vec<LocalDateTime>) -> Recurrence;

    fn next_after(&self, d: LocalDate) -> Option<LocalDate>;    // now Option: None once the bound is exhausted
    // Occurrences are yielded as ZonedDateTime, not LocalDate — DST-correctness (see decisions) is
    // only expressible once the zone is in the return type; a bare LocalDate answer would silently
    // discard the "does this instant's UTC offset differ from the rule's start offset" question.
    fn occurrences_between(&self, start: LocalDate, end: LocalDate) -> impl core::iter::Iterator<Item = ZonedDateTime>;
    fn parse(spec: &str) -> core::types::Result<Recurrence, core::error::Error>;  // "every monday" — the todo-cli mini-language, unchanged
    fn from_rrule(rrule: &str, dtstart: ZonedDateTime) -> core::types::Result<Recurrence, core::error::Error>;  // RFC 5545 RRULE grammar
}
```

## Key design decisions
- **The four types have no implicit conversions between each other** — going from `LocalDateTime` to `ZonedDateTime` requires naming a `TimeZone` explicitly (`at_zone`), and going from `LocalDate` to "now" requires naming a zone too (`LocalDate::today(tz)` — there is no zone-less `today()`), because "what day is it" is genuinely a different question in Tokyo and Los Angeles and a single ambient-timezone default is exactly the kind of hidden global state Principle 4 argues against everywhere else in this design.
- **`Duration` (exact elapsed time) and `Period` (calendar-relative time) are distinct types with distinct arithmetic** — `date.plus(Period{months:1,..})` on Jan 31 lands on the last valid day of February, while `instant.plus(Duration{secs: 30*86400})` is exactly 30×86400 seconds later; conflating these two is the single most common date-arithmetic bug class `java.time` itself was designed to eliminate, and this design keeps that split explicit rather than offering one generic `add()`.
- **`Recurrence::next_after` is the primitive; `parse` is a convenience layer on top of it**, not the other way around — a caller building a recurring-task UI can construct `Recurrence` values programmatically without ever going through the string mini-language, and `parse`'s job is narrowly to turn `todo-cli`'s `due:tomorrow`/"every monday" syntax into a `Recurrence` value, keeping the string-parsing surface separate from (and testable independently of) the date-math surface, per `std.testing`'s isolation goal.
- **`occurrences_between` is a lazy `core.iter` iterator**, not a materialized list, so "list every occurrence this year" for a yearly-bounded UI view doesn't force computing occurrences the caller will never look at — the same "don't force materialization" pattern used by `std.regex`'s `find_all`.
- **Revision (ics-calendar-tool), RESOLVED as a real type change, not a note: `Recurrence` becomes a composite type — rule + bound + timezone + exceptions/additions — because RRULE genuinely is that shape, not a single pattern with optional extra fields bolted on.** `todo-cli`'s validating requirement was narrow by construction ("every Monday," unbounded, no exceptions, no ordinal weekdays), and the original `Recurrence` enum was sized exactly to that requirement — which is precisely why it under-shoots iCalendar's actual `RRULE` grammar rather than merely lacking a feature or two. Working through `ics-calendar-tool`'s stated needs term by term against RFC 5545's `RRULE` forces four independent extensions, and each is resolved concretely rather than left as a caveat:
  - **BYDAY with ordinals ("third Thursday").** `MonthDay::NthWeekday` already existed for `todo-cli`'s "last day of the month," but its ordinal was unsigned and its home (`MonthDay`) only appeared inside `Monthly`. It is now `NthWeekday(i8, Weekday)` — signed, since RRULE's own BYDAY grammar uses negative ordinals to count from the end of the period (`-1FR` = "last Friday"), which "last day" was really a degenerate case of all along (`NthWeekday(-1, ...)` restricted to the day-of-month axis, not a separately-modeled `Last` variant needing its own logic — `Last` is kept only for the bare "last calendar day regardless of weekday" case, which has no weekday component at all).
  - **BYMONTHDAY and UNTIL/COUNT bounds.** `Monthly.on` moved from a single `MonthDay` to `Vec<MonthDay>` because RRULE permits multiple `BYMONTHDAY`/`BYDAY` entries in one rule (e.g. "the 1st and 15th"), which the original one-`MonthDay`-per-rule shape had no way to express at all — not a missing convenience, a missing case. `UNTIL`/`UUCOUNT` did not exist anywhere in the prior design (the only stop condition was "the caller stops asking," i.e. unbounded, matching `todo-cli`'s actual usage) — `RecurrenceBound` makes "unbounded," "stops on a date," and "stops after N" three explicit, mutually exclusive states rather than trying to encode a stop condition as an optional field on the rule itself, matching RFC 5545's own "UNTIL and COUNT are mutually exclusive" grammar constraint directly in the type rather than as a runtime-checked invariant.
  - **EXDATE exceptions.** This is the item this module's own prior Open Questions section named as unresolved since the original `todo-cli` design ("Whether `Recurrence` needs an `Exceptions` list... is left open"). It is resolved here: `exceptions: Vec<LocalDate>` (RRULE `EXDATE`) and, since `ics-calendar-tool` also needs one-off additions (RRULE `RDATE` — an extra occurrence outside the rule's own pattern, e.g. a makeup session), `additions: Vec<LocalDateTime>` alongside it. Both are plain fields on `Recurrence`, checked by `next_after`/`occurrences_between` after the rule generates a candidate date — an excluded date is skipped, an added date is merged in — which is why `next_after`'s return type became `Option<LocalDate>` (a rule with a tight `Until` bound plus enough `EXDATE`s can genuinely run out of occurrences, which the prior infallible-return signature had no way to represent).
  - **DST-correct expansion.** The subtlest of the four, and the reason `Recurrence` needed to carry its own `tz: TimeZone` rather than staying zone-naive: a recurring 10:00 local meeting must land on 10:00 *local* time at every occurrence, even for an occurrence that falls on the other side of a DST transition from the rule's `start`, which means the *UTC offset* for that occurrence's `ZonedDateTime` is computed fresh from `(local wall-clock time, tz, that occurrence's date)` — never carried forward as a fixed offset from `start`. This is exactly the same "local vs. zoned are different types with different arithmetic" discipline `ZonedDateTime`/`LocalDateTime`'s separation already establishes elsewhere in this module (see Key design decisions above); a design that computed occurrences as `start.to_instant() + n * Period` (treating recurrence as instant arithmetic) would silently drift the wall-clock time by exactly the DST offset difference on every occurrence past a transition, which is a real, well-known class of calendaring bug, not a hypothetical edge case. `occurrences_between`'s return type changing from `LocalDate` to `ZonedDateTime` is the concrete, forced consequence: a bare `LocalDate` return has nowhere to put the "what UTC offset applies to *this* occurrence" answer, and silently dropping it is exactly the bug this decision exists to prevent.
  - **`from_rrule`/RFC 5545 grammar parsing is a separate entry point from `parse`, not a change to it** — `parse` stays `todo-cli`'s small English-like mini-language ("every monday"), and `from_rrule` is the literal `RRULE:FREQ=MONTHLY;BYDAY=3TH;COUNT=12`-style text iCalendar actually uses, kept as two named functions rather than one that tries to sniff which grammar it's looking at, matching this module's existing "the typed value is the primitive, string parsing is a convenience layer on top, keep multiple textual dialects as separate named entry points rather than one guessing function" pattern already established for `Recurrence::parse` itself.

## Validated by applications
- **todo-cli**: the module's primary and most demanding consumer — `Recurrence::next_after` is exactly the "next occurrence after date D" capability the app's profile flags as commonly missing from date/time libraries, used both for computing a recurring task's next due date after `todo done` and for the "overdue" query filter; the string mini-language (`due:tomorrow`, recurrence specs) round-trips through `Recurrence::parse`, and `std.testing::table` exhaustively covers weekday/interval/month-end edge cases (Jan 31 + monthly, Feb 29 handling) that a naive first design (recurrence as a bare cron-string with no typed structure) would have made much harder to test in isolation.
- **podcast-subscriber**: exercises parsing real-world, inconsistently-formatted feed dates (RFC 822 `pubDate` vs. ISO 8601 in Atom feeds) into `ZonedDateTime`, plus `duration_until` for scheduling the next poll — this app is why date *parsing* had to tolerate multiple wire formats even though the internal type system stays strict; the parser layer (not shown above in full) sits alongside `Recurrence::parse` as a second, separate "text in, typed value out" boundary.
- **web-downloader**: uses only `Instant`/`Duration` (ETA/throughput math) and never touches `LocalDate`/`ZonedDateTime`/`Recurrence` at all — a useful negative check that the elapsed-time-only use case doesn't drag in calendar/timezone machinery it doesn't need.
- **chat-server**: uses `Instant` for idle-timeout tracking and `ZonedDateTime` (converted once at message-send time) purely for human-readable timestamps in the room transcript — confirms the type separation doesn't add ceremony to the common "just timestamp this event" case.
- **process-supervisor**: uses `Instant`/`Duration` for exponential-backoff scheduling and the "N crashes in M minutes" flapping-circuit-breaker window (a small ring buffer of `Instant`s per process, pruned by comparing `Duration` against the window size) — like `web-downloader`, never touches `LocalDate`/`ZonedDateTime`/`Recurrence`, reconfirming the elapsed-time-only path stays lightweight on its own. The windowing logic itself is ordinary application code composed from `Instant::now()`/`Duration` comparisons; no new `std.chrono` primitive was needed for it.
- **kv-store-server**: uses `Instant`/`Duration` for `EXPIRE`'s TTL — a key's expiry is stored as an absolute `Instant` computed at `EXPIRE` time, and both lazy expiry (checked on access) and active expiry (a periodic sweep) compare `Instant::now()` against it. The same lightweight elapsed-time path `web-downloader`/`process-supervisor` already validate; no calendar or timezone type enters this app at all.
- **ics-calendar-tool**: the module's second-most-demanding consumer after `todo-cli`, and the one that forced `Recurrence` from a flat pattern enum into the rule/bound/exceptions composite described in "Revision (ics-calendar-tool)" above — every one of the four extensions there (ordinal BYDAY, BYMONTHDAY lists, UNTIL/COUNT, EXDATE/RDATE, DST-correct expansion) traces directly to a named feature in the app's profile (`RRULE`/`EXDATE`/`RDATE` parsing, "third Thursday," timezone-correct occurrence expansion across a DST transition). `icstool list --from --to` calls `from_rrule` once per `VEVENT` at parse time (via `std.encoding.ics`, see that module) and `occurrences_between(from, to)` per event to expand the window; `icstool conflicts` expands every recurring event in the calendar the same way and checks pairwise `ZonedDateTime` overlap on the resulting instants (not on `LocalDateTime`s, precisely because two events in different source timezones must be compared as real instants to detect a true conflict). `icstool add ... --every week:mon --time 10:00 --tz America/New_York` is the write path: it constructs a `Recurrence` programmatically (`RecurrenceRule::Weekly`, `RecurrenceBound::Never`) rather than through `from_rrule`, which is `std.encoding.ics`'s job in the other direction (serializing a `Recurrence` back to `RRULE` text) — confirming the typed-value-is-the-primitive design holds symmetrically for both parse and generate.

## Open questions / risks
**RESOLVED (was open since the original `todo-cli`-only design, closed this round by `ics-calendar-tool`):** whether `Recurrence` needs an `Exceptions` list is no longer open — `exceptions`/`additions` (RRULE `EXDATE`/`RDATE`) are now fields on `Recurrence`, and `next_after`'s signature changed to `Option<LocalDate>` as the necessary consequence (a bounded, heavily-excepted rule can run out of occurrences). See "Revision (ics-calendar-tool)" under Key design decisions for the full resolution, covering this and three further RRULE gaps (ordinal BYDAY, BYMONTHDAY lists, UNTIL/COUNT, DST-correct expansion) found at the same time. Kept here rather than deleted so the record shows this was carried as a named open question for one full round before being resolved, not asserted as settled from the start.

New, narrower open question surfaced by this resolution: `RecurrenceRule`'s `Weekly`/`Monthly`/`Yearly` variants still don't cover RRULE's full `BYSETPOS` (select the Nth result *after* combining multiple BY* filters, e.g. "the last weekday that is also the last instance of the month") or `FREQ=SECONDLY/MINUTELY/HOURLY` sub-day recurrence — `ics-calendar-tool`'s stated feature set never needed either (its examples stop at day-level granularity and don't combine filters that deeply), so both are left unaddressed rather than spuriously resolved; a future app with genuinely sub-daily or multiply-filtered recurrence would be the right forcing case.
