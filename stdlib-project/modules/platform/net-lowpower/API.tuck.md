# platform.net-lowpower — Tuck translation

## Shape decision
Freeform `pending:`, scoped to advertise-only. **Compiler-verified**,
`./tuck ch`: `OK`.

```tuck
type AdvertData = {companyId: u16, payload: Seq[u8]}

type RadioError:
  | RadioBusy
  | NotSupported

pending:
  fn startAdvertising({data: AdvertData, intervalMs: u32}) -> !void [io, error: RadioError]
  fn stopAdvertising() -> void [io]
```

## Notes
- **The tier split with `sys.ble` is the important thing here**, and it
  survives: this module is the freestanding *peripheral* (advertise-only,
  no allocation, no connection state machine), while `sys.ble` is the
  hosted-OS *central* (scan/connect, wraps BlueZ/CoreBluetooth). Round-2
  called this "the clearest confirmation yet that 'layer by dependency, not
  topic' sometimes means splitting what looks like one feature across two
  tiers."
- **A device that only advertises never links connection code** — that was
  the design's promise, and Tuck's whole-program compilation makes it
  structural rather than aspirational.
- **`LowpanStack`/6LoWPAN mesh is not translated**, matching `INDEX.md`'s
  own note that it is **speculative** — the one embedded app only
  advertises, never joins a mesh. Preserved as an acknowledged gap.
