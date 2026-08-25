# Governance: what's std, what's blessed, what's community

`REPORT.md` already draws one boundary — Principle 5, "batteries included at
the application tier, radically minimal below it" — and already names the
binary choice every surveyed language makes: bundle it, or leave it to a
curated-but-external ecosystem (Rust's crates.io, Go's `golang.org/x`). What
that report doesn't yet have is the *third* rung this conversation is really
about: not "in std" versus "anyone's third-party crate," but a **blessed
middle tier** — maintained by the same governance, guaranteed to work, shipped
through the package manager rather than compiled into every binary. This file
adds that rung, and uses it to place the three candidates from `COMPARISON.md`
(data structures, sqlite, profiling), plus a fourth question this raises on
its own — how not to fragment if some of `std` becomes "just interfaces."

## The three-rung model

**Rung A — `std` proper.** Ships with the compiler. Small, stable surface,
changes slowly, no version to manage. Everything currently under `core`/
`alloc`/`sys`/`std`/`platform` in this project lives here by definition.

**Rung B — blessed, separately versioned.** Written and maintained by the same
governance as the language, discoverable through one canonical registry entry
with no third-party trust decision required, but shipped and versioned
*independently* of the compiler — so a bad call in rung B doesn't wait for a
language release to fix, the same argument Rust's `std` team already makes for
keeping `regex`/`serde` out of `std` itself. The concrete precedent: .NET does
not ship SQLite in the BCL — it ships `Microsoft.Data.Sqlite`, a first-party
NuGet package, maintained by the .NET team, versioned on its own schedule,
installed with one line, trusted by default. That is the shape rung B should
copy exactly, not reinvent.

**Rung B has two sub-shapes, and the difference matters for offline work.**
"Installed with one line" quietly assumed a reachable package registry.
`DOMAINS.md`'s per-domain "offline" analysis corrected that assumption: for a
developer with no registry access — air-gapped machine, restricted network,
no GitHub — rung B is exactly as unreachable as rung C *unless* it ships
inside the same offline installer as the compiler. Split accordingly:

- **Rung B1 — bundled in the toolchain distribution.** Separately versioned
  and governed exactly as rung B already describes, but physically present
  the moment the compiler is installed, with zero network fetch needed to
  start using it — the same shape `rustup` already uses for `clippy`/
  `rustfmt`/`cargo`: one offline download, several independently-versioned
  components inside it. This is the rung anything counts as "batteries
  included" needs to sit at, per the offline-developer requirement.
- **Rung B2 — published, fetched on demand.** Everything else rung B
  already described: blessed, first-party, but requires a registry request
  to obtain. Fine for anything that isn't load-bearing for a whole category
  of application working at all.

A rung-B recommendation elsewhere in this project's docs should be read as
B2 unless stated otherwise; `DOMAINS.md` names which specific items need to
be promoted to B1.

**Rung C — community, unblessed.** No governance promise, no stability
contract, whatever the ecosystem grows. Fragmentation is expected and fine
here — it's where competing designs get to actually compete before anything
"graduates" upward.

## Placing the three candidates

**Data structures (priority queue, sorted map, bigint, growable bitset) → Rung
A.** Every mature baseline checked in `COMPARISON.md` ships these directly in
std, not as a blessed-external package — the algorithms have been settled
since the 1980s and the API surface is tiny. No protocol churn, no OS
dependency, no "design taste is still unsettled" excuse. This is exactly the
kind of thing Principle 5 says the top tiers should have with zero install
step.

*Organizational note, separate from the rung question:* "one datastructures
folder" is a topic grouping, and `REPORT.md` Principle 1 is explicit that
tiers are drawn by dependency, not topic — a fixed-size bitset needs no heap
and belongs in `core`, while a growable priority queue or arbitrary-size
bigint needs `alloc`. A single flat `data/` folder would cut across that
boundary the same way "OS-optional code leaking into OS-required code" is
already flagged in Part V as the place this architecture strains under real
pressure. Cleaner: keep the topic label as documentation grouping (a
`data-structures` *index page* cross-referencing modules that live in their
correct tier), not a folder that becomes a sixth tier. Worth deciding
explicitly rather than defaulting into it.

**SQLite → Rung B, with Go's shape for how to avoid a second driver
war.** `REPORT.md` already places "database drivers beyond `sys`-level
connection primitives" outside std — that's the right call for network
databases (Postgres/MySQL: protocol churn, auth mechanism churn, TLS
requirements that shift faster than a language release cycle, exactly Zig's
stated reason for keeping HTTP clients out of its own std). SQLite is
different in kind, not degree: it's an embedded, in-process, file-format
library with a notably stable C ABI and no network protocol to churn — which
is why .NET, and separately V (below), both treat it differently from every
other database. Recommendation: ship the *driver* for SQLite specifically at
rung B (a blessed, independently-versioned package, following
`Microsoft.Data.Sqlite`'s precedent exactly), while the *interface* it
implements ships at rung A. That interface is the piece that actually prevents
fragmentation — see below. **Specified in `DOMAINS.md`'s Extension round
4** — `modules/std/db/API.nim.md` (the rung-A interface) with a bundled
`sqlite` submodule, revised to rung **B1** once `DOMAINS.md`'s offline
analysis established that fetch-on-demand blocks the offline case this
recommendation exists for; see that file's synthesis for the correction.

**Profiling → split.** Basic wall-clock/counter measurement (a
`Stopwatch`-equivalent, counter/histogram primitives) is small, stable, and
belongs at rung A — precisely the shape of .NET's own
`System.Diagnostics.Stopwatch`, which is in-box while heavier APM tooling is
not. Sampling profilers, flamegraph generation, and OS-specific perf-counter
integration (Linux `perf`, Windows ETW, macOS Instruments) are inherently
platform-specific and belong at rung B — Go's own precedent supports this
split exactly: `runtime/pprof`'s *measurement* is std, but `go tool pprof`'s
*visualization* shells out to Graphviz, an external tool. Measurement in the
box, presentation/heavy tooling not. **The measurement half is specified**
— `modules/std/perf/API.nim.md`, exactly this split, added in `DOMAINS.md`'s
Extension round 4.

## Domain lessons from Go, Rust, Zig, .NET, and V

You asked specifically what a language that "removed lots of cruft" teaches.
Five different answers, because they cut in different places:

- **Go removed almost nothing, but never let anything new in that didn't earn
  it.** No GUI, no ORM, no web framework, to this day — despite over a decade
  of ecosystem pressure for all three. The discipline isn't restraint at
  founding, it's *refusal to relax later*, which is the harder and rarer
  version. The one place Go did standardize a boundary rather than an
  implementation is `database/sql`: the package in std is an interface plus a
  driver-registration mechanism (`sql.Register`), and every real driver
  (`lib/pq`, `go-sqlite3`, the MySQL driver) lives outside std, entirely
  unofficial, entirely community-written — and it did not fragment, because
  std owns the *shape* everyone codes against, not the implementation. This is
  the direct answer to your fourth option: "just ship interfaces" doesn't
  automatically fragment — it fragments when the interface itself is left to
  the ecosystem too. Standardize the contract at rung A; let rung B/C compete
  on implementation underneath it.

- **Rust cut std down to the bone and paid a real, measured cost for it.**
  No stdlib regex, serialization, or `rand` — all "de facto standard" by
  gravity, not governance. The cost showed up concretely: async alone had
  three competing runtimes (`tokio`, `async-std`, `smol`) for roughly six to
  eight years before the ecosystem converged on `tokio` through sheer
  adoption, not a decision anyone made. Rung B exists specifically to buy back
  that convergence time — a governance-picked "the" implementation from day
  one, versioned independently, is the whole point of not leaving rung-B-shaped
  gaps to resolve by gravity.

- **Zig cut the most, on the clearest stated principle.** No committed HTTP
  client shape, because HTTP/TLS churns faster than Zig's own release cadence
  can track responsibly — an explicit refusal to own something whose
  correctness depends on keeping pace with an external, fast-moving spec.
  Lesson for Tuck: the sqlite-vs-Postgres split above is this exact
  principle applied — own what's stable (an embedded C ABI), decline to own
  what churns (network DB wire protocols, TLS/auth requirements).

- **.NET is the closest working precedent to the three-rung model itself**,
  not just a data point for one entry. Post-.NET-Core, the BCL stayed broad
  for genuinely stable things, while anything driver- or protocol-shaped
  (SQLite, gRPC, JSON source generation, `Microsoft.Extensions.*`) moved to
  first-party NuGet packages — shipped by the same team, guaranteed
  compatible, but versioned and patchable without a runtime release. This is
  rung B, already running at scale, for exactly the reasons this
  conversation is reaching for it.

- **V went the opposite direction from Zig, and is the one genuinely
  contrarian data point.** `vlib` bundles SQLite, Postgres, and MySQL drivers,
  plus an HTTP client/server and even a web framework (`vweb`), directly in
  the standard distribution — "one binary, one command, everything works" as
  the explicit design goal, batteries-included taken further than Go itself
  goes. It's a legitimate, different bet, but it's an unproven one at scale:
  V is a much younger, much smaller project than Go or Rust, and tying the
  *language's* release cadence to the correctness of a Postgres wire-protocol
  implementation is precisely the ossification risk Part II already flags
  against Python's `urllib`. Worth naming as the road not recommended here,
  specifically because Tuck's own two-backend-parity discipline (per
  `CLAUDE.md`) is closer in spirit to Go/Rust's release discipline than to a
  young project's "ship everything" bet.

## The synthesis

Rung A gets what's stable, small, and settled (data structures, the DB
interface shape, basic measurement primitives) — no different from what
`REPORT.md` already argues for the top tier generally. Rung B is the concrete
mechanism that was missing: a named place for "blessed, instantly available,
but not compiled into every binary" — sqlite's driver, heavier profiling
tooling, and (per `REPORT.md`'s own existing call) network database drivers
if that decision is ever revisited. Rung C is where Rust's `tokio`-style
convergence-by-gravity is allowed to happen, deliberately, because some
designs really aren't settled yet and shouldn't be frozen prematurely.

The one governance decision this file adds beyond picking rungs: **a module
only qualifies for rung A's database-adjacent interface if it can be
expressed the way `database/sql` was** — a small, stable contract, not a
concrete implementation — mirroring `PROTOCOLS.md`'s own existing test ("a
module that needs fifteen novel verbs to describe itself belongs in the
extended ecosystem," applied here one level up: an *interface* that needs a
committee to agree on its shape belongs at rung B/C until someone's
implementation makes the shape obvious in practice, the way `database/sql`
itself only stabilized after driver authors had already been writing SQL
drivers against ad hoc Go interfaces for a while).
