# platform.libc-shim — Tuck translation

## Shape decision
A `pending:` contract a board-support package implements — which is
precisely what `pending:` is for.

```tuck
pending:
  fn shimWrite({fd: int, data: Seq[u8]}) -> int
  fn shimRead({fd: int, count: int}) -> Seq[u8]
  fn shimTicksMs() -> u64
  fn shimHeapStart() -> u32
  fn shimHeapSize() -> u32
```

## Why this module fits Tuck unusually well

Its purpose — *"the short list of things a board-support package promises
… anything above this tier that asks for something the board hasn't got
gets a clear 'unsupported' instead of a linker error"* — is exactly the
`pending:` block's semantics: **declared, not yet implemented, reported as
a TODO list on every build, with a runnable stub so the program still
runs.**

The picolibc precedent the report drew this from (a small, explicit,
must-implement syscall shim so high-level I/O degrades gracefully rather
than failing to link) maps one-to-one onto a `pending:` block that a BSP
fills in.

## Notes
- **The "clear unsupported instead of a linker error" property is
  automatic** — `pending` functions trap in debug, return a zero value as a
  release stub, or log and continue, per compiler flag (spec §5.4). That is
  the graceful degradation the module was designed to provide, supplied by
  the language.
- **This is the second module (with `sys.ffi`) where Tuck's version is
  strictly better than the Nim design's**, rather than merely equivalent.
