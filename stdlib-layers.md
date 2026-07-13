# Tuck Stdlib: Layer Map (layer 0 → high-level API)

Status: planning report, 2026-07-12. Companion to `stdlib-blocks.md` (the
layer-0 catalogue). This maps the layers ABOVE layer 0 the way large
stdlibs actually stack them, and feeds an audit back into layer 0
(§Gap audit — those rows have been added to stdlib-blocks.md §18).

## How the reference stdlibs layer

**Go** enforces its layering with the import DAG (cycles are illegal), so
its structure is empirical ground truth: `runtime` → `sync/atomic` → `sync`
→ `io` (the Reader/Writer keystone) → `bytes`/`strings`/`strconv` →
`bufio`/`fmt` → `os` → `net` → `crypto/*` → `net/http`. Notably, `io` sits
BELOW almost everything: files, buffers, compression, TLS and HTTP all
speak Reader/Writer.

**.NET** stacks inside `System.Private.CoreLib` first (primitives, String,
Span, Memory, basic collections), then `System.Collections.*` →
`System.IO.Stream` (the abstract class every transport derives from) →
`System.Text.Encoding` → `System.Net.Sockets` → `System.Net.Security`
(SslStream wraps any Stream) → `System.Net.Http`. Same shape as Go: one
stream abstraction, inserted immediately above the primitives, everything
transport-like implements it.

**Rust** splits by capability: `core` (no allocator, no OS — our layer 0
pure subset), `alloc` (Vec/String/collections), `std` (OS, `Read`/`Write`
traits, net, process). Everything above that is crates — but the blessed
ones (serde, regex, rand) follow the same dependency discipline.

**BEAM** cuts differently — everything above the VM is processes and
messages — but its bottom is the same: binaries, ETS tables, ports; then
gen_server/supervisor as the composition layer; then applications (ssl,
inets) on top.

The shared lesson: **every one of them inserts a small protocol layer (L1)
between the primitives and the world** — stream interface, hash/eq
protocol, iteration, formatting. That layer is what our layer-0 catalogue
was missing (see Gap audit).

## The map

```
L5  app services      logging  testing  config  cli-app  templating  rpc
                         │        │        │       │         │        │
L4  protocols          http client/server   websocket   smtp   tar/zip
                         │        │             │         │      │
L3  structured data    url  mime  textproto  json  xml  csv  crypto-suite  uuid
                         │     │      │        │              │
L2  pure algorithms    hex/base64  utf16  binpack  crc  sha/blake  deflate
                       bigint  regex  tz/calendar  strfmt-num
                         │        │        │           │
L1  protocols &        stream(R/W)  bufio  builder  fmt  hash/eq/ord
    composition        iterate  errors-ctx  flags
                         │        │        │
L0  building blocks    strings bytes bits ints atomics irq fixed-cap
    (stdlib-blocks.md) collections math random time memory os fs proc
                       net-sockets mailbox diagnostics
────────────────────── actor runtime cuts across: timers(L0) supervision(L5)
```

Invariant: every module names only lower-layer modules in "builds on".

### L1 — protocols & composition primitives

The layer all three reference libs insert directly above the primitives.
Mostly design + thin code, but it is THE enabler for everything above.

| Module | Builds on (lower) | Go / .NET / Rust counterpart |
|---|---|---|
| stream — reader/writer/seeker/closer interface; impls for file, socket, memory buffer | L0 fs handles, net sockets, bytes | `io` / `System.IO.Stream` / `std::io::Read+Write` |
| bufio — buffered reader/writer, read-line/until over any stream | stream, bytes | `bufio` / `BufferedStream` / `BufReader` |
| builder — growable text/byte accumulator (amortized append) | L0 strings, bytes | `strings.Builder` / `StringBuilder` / `String` |
| fmt — value→text without reflection: per-type `toStr` convention + number formatting (radix, width, precision) | L0 strings, math | `fmt`+`strconv` / `ToString`+`Format` / `Display`+`format!` |
| hash/eq/ord protocol — user types usable as Map/Set keys and sortable | L0 bit intrinsics | `hash.Hash` / `GetHashCode`+`IComparable` / `Hash`+`Ord` traits |
| iterate — iteration protocol beyond builtin `for` over Seq | language | `range` / `IEnumerable` / `Iterator` |
| errors-ctx — attach context/site to error codes as they flow up | L0 diagnostics, TuckResult | `errors.Wrap` (pkg) / exception chaining / `anyhow` |
| flags — args → typed options | L0 os args, strings | `flag` / `System.CommandLine` / `clap` (crate) |

Tuck notes: `interface` + mixins exist in the language (spec §5) — stream
is an interface + per-type impls, no new language machinery. fmt without
reflection = the C#-source-generator / Rust-derive route: compiler-known
`toStr` per declared type, or explicit per-field code. hash/eq for records
without reflection = same derive decision. This ONE decision (derive-style
codegen for records) unblocks fmt, hash, json — worth ruling once.

### L2 — encodings & pure algorithms

Pure compute: no OS, no streams required (though many gain stream fronts).
All buildable in Tuck itself or extern to Nim.

| Module | Builds on | Go / .NET / Rust | Nim shortcut |
|---|---|---|---|
| hex/base64 | bytes, strings | `encoding/hex,base64` / `Convert` / `base64` crate | `std/base64`, `strutils.toHex` |
| transcode — utf16/latin1 ↔ utf8 | bytes, strings | `unicode/utf16` / `Encoding` / — | `std/encodings` |
| binpack — scalars/records ↔ bytes at offsets, endian-aware | bytes, bit intrinsics | `encoding/binary` / `BinaryPrimitives` / `byteorder` | write (Tuck) on L0 endian blocks |
| checksums — crc32/adler32 | bytes, bit intrinsics | `hash/crc32` / — / `crc32fast` | write (Tuck) |
| digests — sha-256/512, blake2 | bytes | `crypto/sha256` / `SHA256` / `sha2` | none usable (`std/sha1` deprecated → external `checksums` pkg) — write in Tuck or wrap C |
| compress — deflate/gzip | bytes, streams(L1) | `compress/flate` / `DeflateStream` / `flate2` | `std/zippy`? no — external; wrap zlib via extern [c] |
| bigint | ints, bytes | `math/big` / `BigInteger` / `num-bigint` | no std bignum — write or wrap |
| regex | strings, collections | `regexp` / `Regex` / `regex` | `std/re` wraps PCRE; `std/nre` |
| tz/calendar — zone database, calendar arithmetic | time, strings | `time` / `TimeZoneInfo` / `chrono` | `std/times` has zones |
| strfmt-num — float shortest-round-trip, radix format | math, strings | `strconv` / — / `ryu` | Nim `$`/`formatFloat` |

### L3 — structured data & net infrastructure

| Module | Builds on | Go / .NET / Rust |
|---|---|---|
| url — parse/build/escape | strings, fmt | `net/url` / `Uri` / `url` crate |
| mime — types table, multipart | strings, streams | `mime` / `MediaTypeHeaderValue` / — |
| textproto — line-based request/response framing | bufio, strings | `net/textproto` / — / — |
| json | builder, fmt, hash protocol; **derive decision** | `encoding/json` / `System.Text.Json` / `serde_json` |
| xml / csv | same | `encoding/xml,csv` / `XmlReader` / `csv` crate |
| crypto-suite — AEAD ciphers, key exchange, signatures | digests, bigint, L0 entropy | `crypto/*` / `System.Security.Cryptography` / `ring` |
| uuid | L0 random, hex | `google/uuid` (quasi-std) / `Guid` / `uuid` |
| dns — resolver above L0 getAddrInfo | net sockets, strings | `net.Resolver` / `Dns` / `trust-dns` |

No-reflection note: Go and .NET both lean on reflection for json/xml;
Rust proves the derive route works without it. Tuck must take the
derive/codegen route (or ship manual field-mapping helpers first).

### L4 — secure transport & wire protocols

| Module | Builds on | Go / .NET / Rust |
|---|---|---|
| tls | crypto-suite, stream, net sockets | `crypto/tls` / `SslStream` / `rustls` |
| http — 1.1 client + server | url, textproto, compress, tls, streams | `net/http` / `HttpClient`+Kestrel / `hyper` |
| websocket | http (upgrade), bytes | `x/net/websocket` / `ClientWebSocket` / `tungstenite` |
| smtp/ftp-class | textproto, tls | `net/smtp` / `SmtpClient` / crates |
| archive — tar/zip | compress, streams, fs | `archive/tar,zip` / `ZipArchive` / `tar`,`zip` |

Realism note: TLS is the single biggest body of work on this map. Go and
.NET wrote their own; nearly everyone else (Node, Python, Ruby, Nim)
wraps OpenSSL/BoringSSL. Tuck's `extern [c, header: ...]` seam is exactly
the wrap-OpenSSL path — flag it now so nothing above L4 assumes a native
TLS project.

### L5 — application services (the stdlib/ecosystem boundary)

| Module | Builds on | Ship in stdlib? (what the references chose) |
|---|---|---|
| log — leveled/structured, deferred-logging front (PRD ruling) | fmt, streams, time | Go yes (`slog`), .NET yes, Rust no (`log` crate) — Tuck: yes, defmt-style is already committed |
| testing — assertions, runner, table tests | fmt, diagnostics, decision tables(!) | Go yes, .NET adjacent, Rust yes — Tuck: yes; decision tables are a natural test format |
| config — env+file+flags layering | flags, fs, json | none ship it fully — punt |
| cli-app — subcommands, help | flags, fmt | Go partial, others punt — punt to ecosystem |
| template — text/html templating | strings, fmt, io | Go yes, others punt — punt |
| rpc | http/net, json/binpack | Go legacy-yes, .NET gRPC-adjacent — punt |
| supervision — actor restart trees | actor runtime (mailbox L0, timers, monitor/link) | BEAM's OTP — Tuck: yes eventually; it is the BEAM payoff of the actor model |

## Gap audit — what the layer exercise exposed in layer 0/1

Walking the map bottom-up, these blocks are load-bearing for L1+ but were
missing from the original catalogue. **All added to stdlib-blocks.md §18**
with the same classification scheme:

| Gap | Why it surfaced | Class |
|---|---|---|
| stream reader/writer interface | every L2+ row that says "streams"; the single most load-bearing abstraction in Go/.NET/Rust | write (prelude, uses existing `interface`) |
| hash protocol (+ eq/ord for records) | Map/Set of user keys (L0 §9 was silently assuming it); json object keys | extern `hashes.hash` for primitives; derive decision for records |
| radix parse/format (hex/bin/oct ints) | binpack, hex encoding, MMIO debugging | extern `strutils.toHex/toBin/toOct/parseHexInt/parseBinInt/parseOctInt` |
| text/byte builder | fmt, json emit, textproto — O(n²) concat otherwise | extern (Nim string append `add`) — needs surfacing, not code |
| signal handling (at least ctrl-c) | any long-running server (http, actors) needs orderly shutdown | extern `system.setControlCHook`; full posix signals via `std/posix` — shim |
| path canonicalize (realpath) | archive/fs safety (symlink escape), config loading | extern (shim) `os.expandFilename` |
| derive-style codegen ruling | fmt, hash, json all block on it — it's one decision appearing three times | language-adjacent, flagged (no stdlib code) |

## Reading the map as a build order

1. **L1 almost entirely** (stream, builder, fmt-minus-derive, bufio,
   errors-ctx, flags) — small, pure, unblocks everything, and exercises
   the language's own interfaces/mixins hard (good dogfood).
2. The **derive ruling**, then hash/eq → real Map/Set → json.
3. L2 pure algorithms in any order (each is a self-contained Tuck program —
   good stdlib-in-Tuck material rather than externs).
4. L3 url/textproto/dns, then L4 http over plain TCP first.
5. TLS via `extern [c]` OpenSSL wrap when http works.
6. L5 log/testing early (they only need L1); supervision when the actor
   runtime lands monitor/link/timers (stdlib-blocks.md §16).
