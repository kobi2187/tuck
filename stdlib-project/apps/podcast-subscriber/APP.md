# App: podcast-subscriber

Subscribe to podcast RSS/Atom feeds, poll them on a schedule (or on-demand `podcast check`), detect new episodes by GUID, queue new episodes for download with configurable concurrency, and maintain a local library index (show → episodes → local file path, listened/unlistened state).

## Why this is a good validation target
It is the app that most directly stresses `std.encoding`'s claimed coherence: RSS/Atom are XML dialects, which the Part IV proposal's `std.encoding` list (json/toml/csv/base64/binary) does *not* mention. Building this app is exactly the kind of exercise the brief asked for — it surfaces a real gap rather than a hypothetical one.

## Features
- Add/remove feed subscriptions (by URL).
- Poll all feeds (parallel, rate-limited per host), parse episode lists, diff against known GUIDs.
- Queue and download new episodes with resumable, concurrent transfers (shares design with `web-downloader`).
- Local library metadata: per-show and per-episode state, listened/unlistened, download path.
- Scheduled background polling (e.g. run every N hours) vs. one-shot `check`.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| std | `std.net.http` | fetching feed XML and episode audio files |
| std | `std.encoding` | **finding: needs an XML parser added, or an explicit decision to push XML to the extended ecosystem** — see validation note |
| std | `std.chrono` | parsing `pubDate` (RFC 822/ISO 8601 in the wild, inconsistently), scheduling next poll |
| std | `std.async` | concurrent per-feed polling and per-episode downloads under a shared concurrency cap |
| sys | `sys.fs` | local library index and downloaded audio files |
| alloc | `alloc.map` | GUID-based dedup, show/episode indexing |
| std | `std.log` | poll results, download failures |
| std | `std.regex` | occasionally needed for malformed/non-conformant feed cleanup |
| core | `core.error` | malformed feed XML, unreachable host, partial downloads |

## Validation note: the gap this app found
The Part IV module list gives `std.encoding` a clean `json`/`toml`/`csv`/`base64`/binary set under one `Codec` interface, but real-world podcast feeds are XML (RSS 2.0, Atom), and "just add an XML module" is not free: XML has an entity/DTD-based security history (XXE) that JSON/TOML don't share. The resolution adopted in `modules/std/encoding/API.md` is to add `std.encoding.xml` as a *streaming-only, DTD/entity-processing-disabled-by-default* codec — matching the same one-interface contract as the others, but with foot-guns removed by construction rather than left as a "just be careful" footnote. See that module's file for the full rationale.
