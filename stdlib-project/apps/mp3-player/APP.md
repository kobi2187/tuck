# App: mp3-player

A CLI/TUI local audio player: load a folder or playlist file, decode and play MP3/FLAC/WAV, support play/pause/seek/next/prev/volume, read ID3v2 tags for display, and keep UI responsive while audio plays on a dedicated real-time-ish thread.

## Why this is a good validation target
Real-time audio is the sharpest test in this set for `alloc.allocator` and `sys.sync`: the audio callback thread must never block on the general-purpose allocator or a contended lock (a GC pause or malloc stall means an audible glitch), so it forces a concrete answer to "how do you hand the standard library a fixed pool allocator and lock-free handoff instead of the defaults."

## Features
- Decode MP3 (via an external codec — decoding itself is out of stdlib scope, but the *plumbing* around it is in scope) and play through the OS audio API.
- Playlist queue, shuffle/repeat, gapless-ish transition between tracks.
- ID3v2 tag reading (title/artist/album/track number) for display.
- Seek, volume control, playback position display updated ~4x/sec.
- Persist "resume where I left off" state to a small config file.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| sys | `sys.fs` | reading audio files and the playlist/config file |
| sys | `sys.io` | streaming file bytes into the decoder without loading whole files |
| sys | `sys.mmap` | memory-map large audio files instead of read()-ing them in chunks |
| sys | `sys.thread` | dedicated audio-output thread separate from UI/input thread |
| sys | `sys.sync` | lock-free/low-latency handoff of "next samples" and "seek requested" between UI and audio thread |
| sys | `sys.time` | monotonic playback clock (`Instant`) for the position display, independent of wall-clock changes |
| sys | `sys.dynload` | optionally loading a codec as a plugin (e.g. a system-provided MP3 decoder) |
| sys | `sys.ffi` | calling into a C decoding library |
| alloc | `alloc.allocator` | fixed-size pool/arena allocator dedicated to the audio callback path — no general-purpose allocation on the hot path |
| alloc | `alloc.vec` | playlist storage |
| std | `std.encoding` | binary struct decoding for ID3v2 frames |
| std | `std.cli` | TUI rendering (progress bar, key input) |
| core | `core.simd` | volume scaling / sample format conversion across a buffer |
| core | `core.error` | decode errors, missing file errors |

## Anticipated API stress points
`alloc.allocator` needs pool/arena strategies that are genuinely usable from a real-time callback (bounded worst-case time, no fallback to the system allocator on exhaustion — fail loudly instead). `sys.sync` needs a single-producer/single-consumer queue or double-buffer primitive that's zero-allocation on the steady-state path, not just a generic `Mutex`.
