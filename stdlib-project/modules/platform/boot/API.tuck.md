# platform.boot — Tuck translation

## Shape decision
Freeform `pending:` over a `Region` record. **Compiler-verified**
(with the rest of the tier), `./tuck ch`: `OK`.

```tuck
type RegionKind:
  | Flash
  | Ram
  | PersistentRam
  | Peripheral

type Region = {name: str, kind: RegionKind, base: u32, size: u32}

pending:
  fn regionOf({name: str}) -> Region?
  fn isInitialized({r: Region}) -> bool
  fn markInitialized({r: Region}) -> void
```

## Notes
- **`PersistentRam` + `isInitialized`/`markInitialized` carry over
  unchanged** — round-1's real correctness fix: the prior boot model
  implicitly zeroed all RAM on reset, silently destroying the RTC's
  "have I already set the clock" flag even though the RTC hardware
  survives.
- **`static_assert` (spec §8.2) covers the linker-script half.**
  `static_assert sizeof(MqttHeader) == 2` and `offsetof(...)` are language
  features, so the "one typed description consumed by both the linker
  script and your code" goal is partly already met.
- **The reset path stays the ordering constraint**: `lastWakeReason` and
  `lastResetCause` must be read before anything else touches those
  registers — a discipline, not something the type system enforces.
