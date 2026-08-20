# std.log

## Purpose
A structured, leveled logging facade: key-value attributes attached to every record, pluggable output handlers (text/JSON), zero allocation on the hot path when a level is disabled.

## Design lineage
Modeled directly on Go's `log/slog` (structured logging added to the stdlib in Go 1.21) — records are `(level, message, attrs...)`, handlers are a small interface, and attribute values are typed, not pre-formatted strings. Explicitly **not** modeled on Python's `logging` module: no `Logger` class hierarchy with runtime-mutable parent/child propagation, no `logging.config` dictConfig indirection, no object-heavy `LogRecord` requiring subclassing to extend — those are called out in the report as the "archaeological" pattern this design avoids.

## Proposed API
```
enum Level { Trace, Debug, Info, Warn, Error }

// Attrs are typed key-value pairs, not pre-stringified — handlers decide formatting.
enum Value { Str(&str), Int(i64), Float(f64), Bool(bool), Duration(core::types::Duration),
             Time(sys::time::SystemTime), Err(&dyn core::error::Error), Group(&[Attr]) }
struct Attr { key: &'static str, value: Value }
fn attr(key: &'static str, value: impl Into<Value>) -> Attr;

struct Logger;   // cheap to clone (Arc-like handle over a Handler)
impl Logger {
    fn new(handler: impl Handler + 'static) -> Logger;
    fn with(&self, attrs: &[Attr]) -> Logger;      // returns child logger, attrs merged into every record
    fn with_group(&self, name: &str) -> Logger;     // nests subsequent attrs under `name.*`

    fn log(&self, ctx: &std::async::Context, level: Level, msg: &str, attrs: &[Attr]);
    fn trace(&self, msg: &str, attrs: &[Attr]);
    fn debug(&self, msg: &str, attrs: &[Attr]);
    fn info(&self, msg: &str, attrs: &[Attr]);
    fn warn(&self, msg: &str, attrs: &[Attr]);
    fn error(&self, msg: &str, attrs: &[Attr]);

    fn enabled(&self, level: Level) -> bool;         // check before building expensive attrs
}

trait Handler {
    fn enabled(&self, level: Level) -> bool;
    fn handle(&self, record: &Record) -> core::types::Result<(), core::error::Error>;
    fn with_attrs(&self, attrs: &[Attr]) -> Box<dyn Handler>;
    fn with_group(&self, name: &str) -> Box<dyn Handler>;
}
struct Record<'a> { time: sys::time::SystemTime, level: Level, msg: &'a str, attrs: &'a [Attr] }

// Two handlers ship in the box; both write to any sys.io::Writer.
struct TextHandler;
impl TextHandler { fn new(w: impl sys::io::Writer + 'static, min_level: Level) -> TextHandler; }
struct JsonHandler;
impl JsonHandler { fn new(w: impl sys::io::Writer + 'static, min_level: Level) -> JsonHandler; }

fn default_logger() -> Logger;                   // process-wide default, set once at startup
fn set_default(logger: Logger);
```

## Key design decisions
- **Attributes are structured `Value`s, never pre-formatted into the message string** — `logger.info("download failed", &[attr("url", u), attr("attempt", n), attr("err", &e)])`, not `format!("download failed: url={} attempt={} err={}", ...)`. This is the single decision that makes `JsonHandler` produce genuinely structured, machine-parseable logs rather than JSON-wrapped free text, and it's the core departure from `printf`-style logging.
- **`Logger::with` returns a new child handle instead of mutating the caller's logger** (contrast Python's `logger.addHandler`/mutable global state) — a `Logger` bound to `{request_id, room}` is a value you pass down a call chain, not a name you look up by string, eliminating the entire class of bugs where a shared global logger's handlers or level are mutated from an unexpected call site.
- **`log()` takes a `std::async::Context`** (the leveled shortcuts don't) so handlers *can* propagate cancellation-scoped attributes (e.g. a request ID stashed via `Context::with_value`) without every call site having to re-attach them manually — this is opt-in plumbing, not a requirement.
- No logger-hierarchy/propagation model (Python's parent-logger inheritance) exists at all; composition happens by explicitly building the `Logger` value you want and holding onto it, which is more verbose at setup time but eliminates "why did this log line go to two handlers" debugging.

## Validated by applications
- **chat-server**: the primary structured-logging consumer — every connection gets `base_logger.with(&[attr("conn_id", id), attr("remote_addr", addr)])` once at accept time, after which every `log.info(...)` call in that connection's handler automatically carries those fields with no repetition, directly validating the child-logger-as-value design under the app with by far the most log call sites per run.
- **web-downloader**: exercises `logger.enabled(Level::Debug)` guards around per-chunk progress logging that would otherwise allocate a formatted string on every buffer read even when debug logging is off — confirms the "check before you build attrs" pattern is necessary, not decorative, for a high-frequency call site.
- **podcast-subscriber**: uses `with_group("feed")` per-feed during a poll cycle so JSON output nests feed-specific attributes (`feed.url`, `feed.guid_count`) distinctly from top-level poll-cycle attributes, validating that grouping composes with `with()` rather than requiring a different call shape.
- **secrets-vault**: the strongest negative-validation case — the module doc explicitly notes `Value::Err`/attrs must never be constructed from secret material, and no automatic `Debug`-based fallback formatting exists for arbitrary types precisely so a careless `attr("password", &pw)` cannot happen implicitly; the app's log calls are limited to structural events (vault opened, entry added) with values only ever a site name or count, never plaintext.
- **process-supervisor**: exercises the split between `std.log` and raw captured output that this design implies but no prior app made concrete — a supervised child's stdout/stderr is redirected byte-for-byte through `sys.fs`/`sys.io` to a rotating log file and never passes through a `Logger`/`Record` at all (the supervisor doesn't know or care what a child prints), while the supervisor's *own* events (child started, crashed, backoff scheduled, flapping breaker tripped) go through `Logger::with(&[attr("process", name)])` exactly like `chat-server`'s per-connection child logger. Confirms `std.log` is correctly scoped to the process's own structured events, not a general log-aggregation facility for arbitrary child output.

## Open questions / risks
Whether `std.log` should ship a third handler for OpenTelemetry-style span correlation out of the box, or leave that to the extended ecosystem per the "unsettled design" carve-out in Part IV, is left open; the current design only guarantees the `Context`-threading hook a future correlation handler would need.
