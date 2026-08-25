# Domains: what a developer in each field does all day, and whether std answers it

`REPORT.md` validates by module, `INDEX.md` validates by 26 applications,
`GOVERNANCE.md` validates by who should own what. None of those ask the
orthogonal question this file asks: what does a *specific kind of developer*
do, repeatedly, across every app they'll ever build in that field — and does
the stdlib serve the workflow, not just a feature checklist. Every citation
below points at a real `modules/<tier>/<name>/API.nim.md`; every gap was
grep-confirmed absent, the same discipline `COMPARISON.md` used, so nothing
here is guessed from a module name.

**Scope, decided before writing this:** mobile includes native low-level
hardware access (camera/GPS/sensors), framed as FFI primitives, not a wrapped
SDK. Web backend includes the database/ORM question, worked through
critically — the project doesn't want anticipatory heavy abstractions, so
"what's the *minimal* primitive" is asked before "what would a framework
provide." Desktop, game, and mobile share one real finding — not a GUI
*toolkit* (`std.gui` stays excluded, per `REPORT.md`) but a lower
window/surface/input primitive layer, evaluated once in the synthesis rather
than three times.

**"Offline," corrected.** Each domain section below originally read "offline"
as *the shipped app's* network reachability — wrong reading, corrected here.
The actual question: a developer with **no package-registry access** —
air-gapped machine, restricted network, no GitHub — building a real app using
only what the Tuck toolchain already contains. Per `GOVERNANCE.md`'s revised
rung model, that requirement names a specific rung: **B1**, bundled inside
the offline installer, not merely B2 (blessed but fetched on demand — exactly
as unreachable, offline, as an unblessed rung-C package). A gap that leaves
this developer hand-rolling a database driver or an audio backend from raw
FFI is the "full framework from scratch" outcome the batteries-included
promise exists to prevent — so the domain sections below now flag, per
finding, whether it needs to be bundled (B1) or can safely stay
fetch-on-demand (B2/C) without blocking a whole category of offline work.

---

## 1. Web backend

**Persona.** Builds and operates an HTTP API: reads a request, touches a
database, writes a response, and does this thousands of times a day across
many deploys, most of the actual work being the parts *around* the handler
function — not the handler itself.

**Repeatable work items:**

- **Routing + request/response handling.** Covered: `std.net-http` (server +
  client, `REPORT.md`'s Go-`net/http`-inspired call).
- **Database access.** **Real gap, examined critically.** No database
  connectivity module exists anywhere in the 65 — confirmed by grep across
  `modules/` for `sqlite`/`database`/`sql`. Per `GOVERNANCE.md`, the right
  shape isn't a bundled ORM (V's bet, not recommended there) or silence
  (Rust's bet, which cost that ecosystem years of runtime fragmentation) —
  it's Go's `database/sql` shape: a small, stable **query/row-mapping
  interface at rung A**, with actual drivers (sqlite first, per
  `GOVERNANCE.md`'s rung-B recommendation) shipped separately. An ORM proper
  — relationship mapping, lazy loading, migrations-as-code — is exactly the
  kind of anticipatory heavy abstraction the user has said this project
  doesn't want; the primitive that's actually load-bearing for nearly every
  app is "run a parameterized query, get typed rows back," which is a much
  smaller thing than an ORM and should be scoped that small.
  **Specified in Extension round 4** — `modules/std/db/API.nim.md`, interface
  at rung A with the bundled `sqlite` submodule at rung B1, exactly this
  shape.
- **Schema migrations.** **Real gap**, distinct from the driver question —
  grep for `migrat` across `modules/` returns nothing relevant. This is
  usually solved as a thin layer over the query primitive above (a numbered
  SQL-file runner), so it's a natural extension of the same interface rather
  than a separate subsystem — worth deciding alongside the DB primitive, not
  before it.
- **Auth/session state.** **Real gap.** `std.crypto` has `hmacSha256`/`sign`/
  `verify` (good primitives for signing a session token) but grep confirms
  no `cookie`/`session` surface in `std.net-http`. This is likely a case
  where the primitive already exists (HMAC-signed cookie, built from
  existing crypto + http) and what's missing is just the glue, not a new
  module — worth resolving as an "In use" example on an existing module
  rather than a new one. **Specified in Extension round 4** — `std.net-http`
  gained a `Cookie` type (the one real gap the grep found), and session
  state itself is now that "In use" example against existing `std.crypto`
  primitives, exactly as recommended.
- **Background jobs.** Covered: `std.async::Scope`/`spawn`, already validated
  by `chat-server`/`kv-store-server`'s long-lived-task shapes.
- **Structured logging.** Covered: `std.log`, sink-based (`newJsonSink`).
- **Deploy config (env vars, secrets, feature flags).** Covered:
  `sys.env` for the first two; no feature-flag primitive exists, but that's
  consistent with every mature baseline surveyed — none ship one in std
  either (it's an ops/product concern, not a language stdlib one). Not
  flagged as a gap.
- **Health checks / readiness probes.** Not a distinct primitive anywhere,
  but trivially expressible as an ordinary `std.net-http` handler — no gap,
  just a documented pattern.

**Offline (registry-access) stress test.** This is where the corrected
reading bites hardest for this domain: "build a web backend" *is*
"talk to a database," for nearly every real app in this category. If the
query/row-mapping interface and its sqlite driver are B2 (fetch-on-demand),
an offline developer cannot build the single most common backend app shape
without hand-rolling a database driver over raw `sys.ffi` — precisely the
"write a framework from scratch" outcome batteries-included is supposed to
prevent. **Both the interface and a baseline sqlite driver need to be B1**,
bundled in the offline installer — network-backed drivers (Postgres/MySQL)
can stay B2/C, since those need a reachable server regardless of registry
access and don't block offline development the same way. Separately, once a
network *is* available, `PROTOCOLS.md`'s generic `retry(resource, attempts,
delay)` (currently hand-rolled per app, per `INDEX.md`'s finding #7) is what
the DB primitive should compose with for connection failures — a smaller,
already-named gap, not a new one.

---

## 2. Game

**Persona.** Runs a fixed-timestep simulation loop 60 times a second, loads
art/audio/level assets once at startup or on level transitions, and cannot
tolerate an allocation or a lock stall inside the hot loop — the same
real-time discipline `INDEX.md`'s mp3-player finding already forced into
`sys.sync` (`SpscRing`).

**Repeatable work items:**

- **Window/surface creation + input polling.** **Real gap** — grep confirms
  no window, framebuffer, or input-event module exists (the false-positive
  hits were all the word "surface" used to mean "API surface," not a
  graphics one). This is the finding carried to the synthesis section below,
  shared with desktop and mobile — not repeated in full here. **Specified in
  Extension round 4** — `modules/sys/window/API.nim.md`.
- **Fixed-timestep update loop.** Trivially built from `sys.time::Instant`
  (already validated, allocation-free per-call) — no gap, just a documented
  pattern, the same resolution as the web backend's health-check item.
- **Real-time audio/input threading discipline.** Covered:
  `sys.sync::SpscRing`/`Channel`, `sys.thread`, `alloc.allocator`'s arena
  strategy — this is exactly what mp3-player already validated.
- **Audio output/mixing.** **Real gap.** Grep across every module for
  `audio`/`mixer`/`pcm` returns nothing — mp3-player's own validation only
  reached the *threading* infrastructure around audio (buffers, real-time
  scheduling), never an actual "open a device, submit PCM frames" primitive.
  Every mature baseline this project could check against (Java's
  `javax.sound`, .NET's minimal built-in audio, even Go's stdlib) is thin or
  absent here too — this is a genuinely hard, platform-heterogeneous surface
  (CoreAudio/WASAPI/ALSA/PulseAudio) closer to Zig's HTTP-client reasoning
  (churns faster than a language release cycle) than to sqlite's (stable C
  ABI). Recommend rung B, not rung A — a blessed device-I/O package, not std
  (revised to B1 under the corrected offline reading below). **Specified in
  Extension round 4** — `modules/sys/audio/API.nim.md`, scoped exactly to
  the thin baseline this paragraph describes.
- **Spatial/collision math (vectors, AABB, ray/shape tests).** **Real gap.**
  `std.math` (checked directly) covers `Decimal`, unit conversion, and
  statistics — no `Vector2`/`Vector3`/AABB/collision surface exists anywhere.
  This is small, stable, decades-settled math (unlike audio) — closer to the
  priority-queue case in `COMPARISON.md` than to a churny external concern.
  Recommend rung A, scoped tightly: vector/matrix types and basic
  intersection tests, not a physics engine. **Specified in Extension round
  4** — `modules/core/geom/API.nim.md`, `core` tier per the "no heap needed"
  reasoning above.
- **Asset loading (textures, models, levels).** Partially covered: file I/O
  is `sys.fs`, and structured formats decode through `std.encoding` — but
  *binary* asset formats (a texture codec, a model format) are explicitly
  the same "no image codec" absence `image-thumbnailer` already validated as
  deliberate in `INDEX.md`. Not a new gap; restated here because game is the
  domain where that deliberate absence is felt hardest.
- **Save-file serialization.** Covered: `std.serde-derive` + `std.encoding`'s
  binary packing.

**Offline (registry-access) stress test.** A local game loop needs no
network at runtime, but the *developer* offline, with no registry access,
still needs to ship a real game — and a game with no audio and no window is
not that. Window/surface (already recommended rung A, above) and audio
output (recommended rung B, above) diverge here: the window primitive is
fine, it ships with the compiler by definition. **Audio needs re-examined as
B1, not B2** — the churn argument that justified B2 (platform-heterogeneous
device APIs) is about API *design* stability, not about whether it should be
bundled; a thin, stable "open a device, submit PCM frames" surface can be
both platform-varying under the hood *and* shipped in the offline installer,
the same way the window/surface primitive already will be. Reserve
B2/community for anything fancier (spatial audio, DSP effects chains) built
on top of that bundled baseline.

---

## 3. Desktop application

**Persona.** Ships a long-running local app: a menu-bar utility, a sync
client, a local dashboard — something that manages its own window, watches
files, remembers user settings, and has to behave when it's the *second*
copy of itself someone just launched.

**Repeatable work items:**

- **Window/surface creation + input polling.** Same gap as game, covered
  once in the synthesis section. **Specified in Extension round 4** —
  `modules/sys/window/API.nim.md`.
- **Config/settings persistence.** Covered: `std.encoding` (TOML/JSON) +
  `sys.fs` for the file itself — no gap, a documented composition.
- **File-system watching.** **Already covered**, and worth stating plainly
  since it's easy to assume missing: `sys.fs::Watcher`/`watch`/`receive`
  (confirmed present, not a gap).
- **Single-instance enforcement (\"already running\" lock).** **Real gap.**
  `sys.fs`'s full proc list (checked directly) has no advisory/exclusive
  file-lock primitive — `open`/`persist`/`resize`/`rename`/`remove` only.
  This is a small, well-understood primitive (an OS advisory lock, `flock`/
  `LockFileEx` shape) that belongs in `sys.fs` itself as one more proc, not
  a new module — same "cheap, add it" character as the priority queue in
  `COMPARISON.md`. **Specified in Extension round 4** — `sys.fs` gained
  `Lock`/`tryLock`/`close`, exactly the one-proc addition this paragraph
  recommended.
- **Inter-process "open with" / second-instance handoff.** Buildable from
  `sys.net`'s existing local-socket support once single-instance locking
  exists — no separate gap once the item above is resolved.
- **Auto-update checking.** Not present, and — checked against all four
  survey baselines — not a stdlib concern in any of them either (Python,
  Java, .NET, Go all leave this to the ecosystem or the OS's own package
  manager). Not flagged as a gap; explicitly out of scope.
- **Crash reporting / telemetry.** `std.testing::fault` (checked) covers
  *fault injection for tests*, not production crash reporting — a real but
  low-priority gap, since it's genuinely an "extended ecosystem" concern
  (telemetry backends are exactly the fast-moving, vendor-specific category
  `REPORT.md` already excludes GUI toolkits for) — rung C, no action
  recommended.

**Offline (registry-access) stress test.** This domain comes out cleanest of
the six: every work item above already resolved to rung A (window/surface,
config, fs-watching) or a one-proc addition to an existing rung-A module
(the single-instance lock) — nothing here requires a registry fetch to build
a working offline app. The one item that does reach outward — auto-update
checking — is explicitly out of scope already, correctly, since checking for
updates presupposes a reachable network regardless of the developer's own
registry access.

---

## 4. CLI

**Persona.** Ships a single binary that reads arguments, does one job, and
exits with a code something else's shell script checks — the domain this
project's own validation harness (`cli-hangman`, `log-grep`,
`process-supervisor`, and others) already exercises the most.

**Repeatable work items:**

- **Argument/subcommand parsing.** Covered: `std.cli::Command`/`Args`,
  already the most-validated module in `INDEX.md`'s coverage matrix.
- **Exit-code discipline.** Covered structurally by `core.error`/`Failure`
  and the raise convention — no gap.
- **Piping/redirection detection (is stdout a TTY).** **Small, real gap.**
  `std.cli`'s own module purpose line states it decides "when not to colour"
  output, implying a TTY check already exists *internally* — but grep of
  its full proc list confirms no public `isTerminal`/`isPiped` predicate a
  caller can use for their *own* decisions (e.g., "only show the progress
  bar if interactive"). Smallest gap in this document — one boolean-
  returning proc on an existing type, not a subsystem.
- **Progress feedback.** **Already covered**, worth restating since it was a
  suspected gap in `COMPARISON.md`'s first pass and confirmed present:
  `std.cli::Progress`/`ProgressGroup`/`Table`.
- **Config precedence (flag > env var > config file > default).** No single
  primitive, but each layer already exists (`std.cli::Args`, `sys.env`,
  `std.encoding`) — composing them is a documented pattern, not a gap.
- **Shell completion generation.** **Real gap.** Grep of `std.cli` for
  `completion` returns nothing. Present in Rust's `clap`, Python's `click`,
  and Go's `cobra` — but notably, in *none* of the base-language stdlibs
  surveyed (it's an ecosystem-package feature even in Python/Go/Rust
  proper). Same resolution as auto-update above: not flagged as a std gap,
  rung B at most if it's ever prioritized.

**Offline (registry-access) stress test.** This domain comes out clean for
the same reason desktop does: `std.cli`, `sys.fs`, `sys.env`, `core.error`
are all rung A already, so a full CLI tool builds offline with zero registry
access, no exceptions found. The remaining gaps (TTY predicate, shell
completion) are both rung A already or correctly out of scope — neither
blocks building anything.

---

## 5. Mobile

**Persona.** Ships the same Tuck source cross-compiled to a phone: needs
durable local storage that survives the app being killed mid-write,
periodic background sync when connectivity returns, and — per this
project's explicit scope decision — direct native access to camera/GPS/
sensor hardware, not a wrapped abstraction over it.

**Repeatable work items:**

- **Native hardware access (camera, GPS, sensors).** Framed correctly, per
  the scope decision, as an `sys.ffi` + `platform.hal`-shaped problem, not a
  new "mobile SDK" module: `sys.ffi` (checked) already provides exactly the
  primitive this needs — declare a foreign function, cross the boundary with
  `View[byte]`, call back into Tuck from C. A GPS reading or a camera frame
  is, at the primitive level, an OS API call through this same boundary; the
  *mobile-specific* work is the vendor SDK binding (Android's Camera2/
  CoreLocation-equivalent, iOS's AVFoundation/CoreLocation), which is
  correctly out of a general-purpose stdlib's scope for the same reason
  `platform.hal`'s vendor-escape-hatch tension is already named as
  unresolved-by-design in `REPORT.md` Part V — freezing a phone-vendor API
  shape into std risks the exact ossification that section warns against.
  **No new module recommended**; the existing FFI primitive is the correct
  foundation, and vendor bindings belong at rung B/C.
- **Window/surface + input.** Same shared gap as game/desktop, covered once
  in the synthesis. **Specified in Extension round 4** —
  `modules/sys/window/API.nim.md`.
- **Local persistent storage with migrations.** Same DB/migration gap
  already named for web backend — mobile is the second consumer of that
  same primitive, not a separate one; noted once in the synthesis.
- **Background sync (queue writes, flush when online).** **Real gap**, and
  the clearest instance of the "offline" stress test actually biting: no
  module names a durable local write-queue-with-later-flush pattern
  anywhere in the 65. `alloc.deque` gives the in-memory queue shape;
  `sys.fs` gives durable storage; nothing currently composes them into the
  specific "queued writes survive a kill, flush and reconcile once online"
  primitive this domain needs constantly. Carried to the synthesis as the
  single most load-bearing offline-specific finding in this document.
  **Specified in Extension round 4** — `modules/std/queue/API.nim.md`'s
  `DurableQueue[T]`. Writing the actual composition (rather than leaving it
  as "compose two existing modules") surfaced questions the original
  finding hadn't answered — crash-safe framing, at-least-once ack accounting
  — which is why this became a module, not only documentation.
- **Push-notification hooks.** Correctly scoped as *hooks*, not a push
  service — buildable once background sync (above) exists, since receiving
  a push is structurally "wake up, then do the same queued-sync dance."
- **Battery/lifecycle-aware background work.** Not present, and — like
  auto-update checking for desktop — genuinely OS-specific in a way no
  surveyed baseline puts in a language stdlib (this is what Android's
  WorkManager and iOS's BackgroundTasks framework exist *outside* their own
  base languages to solve). Not flagged as a std gap.
- **Secure local secret storage.** Covered in spirit: `alloc.allocator`'s
  `SecureAllocator`/`Secret[T]` (the same mechanism `secrets-vault` already
  validated) — the remaining piece is OS keychain integration, which is the
  vendor-FFI question already resolved above, not a new gap.

**Offline (registry-access) stress test.** Two separate things both called
"offline" collide in this domain, and both turn out real. The *app's own*
runtime offline behavior (background sync above) stays this document's
clearest single finding regardless of which reading of "offline" is meant —
a phone loses connectivity constantly, that's not a corrected reading, it's
additional. The *developer's* registry-access offline need adds a second,
distinct point: mobile's local storage is the second consumer of the same
DB/query primitive web backend needs (Finding B), so the same **B1**
(bundled sqlite driver, not fetch-on-demand) conclusion reached there applies
here for the identical reason — an offline mobile developer with no local
storage primitive is stuck hand-rolling one, same failure mode as the
backend case.

---

## 6. Embedded

Already covered in depth by `REPORT.md` Part IV's `platform.*` tier and
validated by two apps (`embedded-sensor-node`, `embedded-display-node`).
This pass re-checks it from the *firmware engineer's repeatable-task* angle
rather than proposing from scratch — mostly a confirmation, with two real
findings the app-driven validation didn't surface because neither validating
app's own scenario needed them.

**Repeatable work items:**

- **Bring-up / bootloader.** Covered: `platform.boot` (`RegionKind`,
  `PersistentRegion`, already extended in round 1 for the RTC-survives-reset
  case).
- **Fault recovery / watchdog.** **Real gap.** Grep across `modules/platform/`
  for `watchdog` returns nothing. A hardware watchdog timer (feed-or-reset)
  is one of the most repeatable tasks in firmware engineering — arguably
  more universal across embedded targets than several already-covered
  `platform.*` concerns. Small, stable, vendor-boundary-friendly (every MCU
  vendor's watchdog peripheral does the same three things: arm, feed,
  configure timeout) — recommend rung A, scoped as small as `platform.power`
  already is. **Specified in Extension round 4** —
  `modules/platform/watchdog/API.nim.md`.
- **Field firmware updates (OTA/DFU).** **Real gap**, and a harder one.
  Grep for `\bota\b`/`firmware.update`/`bootload` across `modules/platform/`
  returns nothing beyond the bootloader itself. Unlike the watchdog, this
  genuinely varies by vendor (dual-bank flash, signed-image verification,
  rollback strategy) closer to the audio-mixing case above — real, but
  correctly a rung B concern (a blessed package built on `platform.boot`'s
  existing primitives) rather than rung A.
- **Power-budget tuning.** Covered: `platform.power`'s `SleepDepth`/
  `WakeReason` (already validated, and extended in round 1 for
  disambiguating which wake source fired).
- **Bus-error retry / sensor read reliability.** Covered:
  `platform.hal::I2c`'s mandatory `timeout` + categorized `I2cError`,
  already `REPORT.md`'s finding #7.

**Offline (registry-access) stress test.** The device's own runtime network
state was never the point for this domain (`net-lowpower` is opt-in, not
assumed) — the power-loss-mid-write case still stands, answered by
`platform.boot`'s `PersistentRegion`. On the developer's-own-registry-access
reading: everything this domain needs — bootloader, watchdog, power/sleep,
bus-error retry — already resolved rung A above, so no promotion needed.
OTA/DFU is the one exception, and it correctly stays a fetch-on-demand
concern (B2): flashing firmware without a network is still possible via a
physical debugger/programmer, so an offline embedded developer isn't blocked
the way an offline web/mobile developer is without a DB driver.

---

## Cross-domain synthesis

### Finding A: a window/surface/input primitive layer, one gap shared by three domains — SPECIFIED, `sys.window`

Desktop, game, and mobile each independently hit the same absence: no module
anywhere in the 65 creates a window or rendering surface, polls input
events, or hands a pixel buffer/GPU context to something else. This is
**not** the `std.gui` toolkit `REPORT.md` already, deliberately, excludes —
widget layout and a raw window/input/surface layer are different altitudes,
the same distinction that separates Qt from SDL2/GLFW/raylib. The user's own
framing — "perhaps same primitives taken in different directions" — is
exactly right: one finding, three consumers, not three separate proposals.
Recommend evaluating as a single new module (tier: `sys`, since it needs an
OS but no allocator-optional story — closer to `sys.net`'s shape than
`platform.hal`'s), scoped as narrowly as the SDL2/raylib precedent (create
surface, poll events, hand back a buffer/context) rather than anything
resembling a toolkit. This is the single highest-leverage finding in this
document by consumer count. **Specified in Extension round 4** —
`modules/sys/window/API.nim.md`, exactly this scope.

### Finding B: a query/row-mapping primitive, shared by web backend and mobile — SPECIFIED, `std.db`

Both domains independently need "store structured data locally or remotely,
query it, get typed results back, survive a restart." Per `GOVERNANCE.md`'s
existing sqlite reasoning and Go's `database/sql` precedent (interface at
rung A, drivers at rung B — the mechanism that's already been shown *not* to
fragment, unlike Rust's ungoverned async-runtime split), this should resolve
as one interface, not two. Mobile's version is local-only (sqlite driver
suffices); web backend's version needs the same interface satisfied by
either a local or a networked driver — the interface is what makes that not
require two different call sites. **Revised under the corrected offline
reading** (see each domain's stress-test paragraph, above): the interface
itself stays rung A, but the sqlite driver needs to be **rung B1** — bundled
in the offline installer, not fetch-on-demand — since it's the one driver
both domains' *most common app shape* depends on. Networked drivers
(Postgres/MySQL) stay B2/C; they need a reachable server regardless.

### Finding C: a durable local-write-queue, the sharpest *runtime*-offline finding — SPECIFIED, `std.queue`

Mobile's background-sync need is this document's clearest case of the app's
*own* runtime offline behavior — distinct from, and unaffected by, the
registry-access correction above: `alloc.deque` (the queue) and `sys.fs`
(the durability) both already exist, but nothing composes them into "writes
queue durably, survive a kill, flush and reconcile once connectivity
returns." Web backend's DB-unreachable case and desktop's sync-client case
are weaker versions of the same shape. Originally recommended as a
documented composition pattern rather than a new module — revised once
writing the actual composition surfaced real design questions ("the recipe"
wasn't as simple as this paragraph assumed): crash-safe record framing,
replay ordering, and idempotent ack accounting across a kill mid-write.
**Specified in Extension round 4** — `modules/std/queue/API.nim.md`'s
`DurableQueue[T]`.

### What's needed by every domain (the real "absolutely need" bar)

`core.error`/`Failure` (error handling), `std.log` (structured logging),
`std.encoding` (config/data interchange), `std.testing` (every domain's own
`APP.md` in `apps/` assumes it), `sys.fs` (every domain touches the
filesystem somewhere), and `core.fmt` (`Showable`/`Inspectable`, needed the
instant anything gets logged or displayed). None of these are gaps — they're
the confirmation that the existing `core`/`alloc` tiers really are the
load-bearing common floor the project's Principle 5 says they should be.

### What's domain-specific, not a gap anywhere else

Fixed-timestep loop timing (game only), shell-completion generation (CLI
only, and not even a base-stdlib feature in any surveyed baseline), watchdog
timers (embedded only), single-instance locking (desktop only, though cheap
enough it costs nothing to have generally available). Listed so a future
pass doesn't mistake "domain-specific" for "forgotten."

## Gaps ranked, with rung recommendations

| Finding | Domains | Rung | Status | Why |
|---|---|---|---|---|
| Window/surface/input primitive | desktop, game, mobile | A (`sys` tier) | **Specified** — `sys.window` | Stable shape (SDL2/GLFW precedent), no protocol churn, highest consumer count |
| Query/row-mapping interface | web backend, mobile | A (interface only) | **Specified** — `std.db` | Go `database/sql` precedent — interface is what prevents fragmentation |
| sqlite driver (implements the interface above) | web backend, mobile | **B1** (revised) | **Specified** — `std.db::sqlite` | Bundled, not fetch-on-demand — blocks the single most common app shape in both domains without registry access |
| Spatial/collision math (vectors, AABB) | game | A | **Specified** — `core.geom` | Small, decades-settled, same character as `COMPARISON.md`'s priority queue |
| Advisory file lock (single-instance) | desktop | A (one proc on `sys.fs`) | **Specified** — `sys.fs::Lock` | Cheapest item on this list — a proc, not a module |
| TTY/piping predicate | CLI | A (one proc on `std.cli`) | Open | Internal logic already exists; just needs a public accessor |
| Watchdog timer | embedded | A | **Specified** — `platform.watchdog` | Universal firmware primitive, vendor-boundary-friendly |
| Schema migrations | web backend | A, extends the query interface | Open | Natural extension once Finding B exists, not standalone — `std.db` now exists to extend |
| Session/cookie glue | web backend | none — documentation | **Specified** — `std.net-http::Cookie` + an "In use" example | Primitives (`std.crypto` + `std.net-http`) already exist; needs an example, not new code |
| Durable local write-queue | mobile, (weaker: web backend, desktop) | A | **Specified** — `std.queue::DurableQueue[T]` | Revised from "composition, not a module" once writing it surfaced real crash-safety questions |
| Audio output/mixing (thin PCM baseline) | game | **B1** (revised) | **Specified** — `sys.audio` | Bundled minimal surface; fancier engines (spatial audio, DSP chains) stay B2/C on top of it |
| Field firmware update (OTA/DFU) | embedded | B2 | Open | Vendor-varies; offline-safe fallback (physical debugger flashing) already exists, unlike the DB/audio cases |

Nine of twelve findings are now specified (design-only — `API.nim.md`
signatures and types, no implementation, per `INDEX.md`'s Extension round 4).
The remaining three are the TTY predicate (a proc-level addition to
`std.cli`, not yet written), schema migrations (a natural extension of
`std.db`'s interface once someone writes it), and `std.db` connection
pooling (deliberately deferred, same reasoning `std.async`'s executor model
was until a concrete app forced the real answer) — none blocking in the way
the nine specified findings were.
| Shell completion, auto-update checking, crash telemetry, battery-aware scheduling | CLI, desktop, mobile | C / out of scope | Not present in any surveyed baseline's own stdlib either |
