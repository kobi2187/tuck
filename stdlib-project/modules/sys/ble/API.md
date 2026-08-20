# sys.ble

## Purpose
Wraps the OS-level Bluetooth Low Energy stack for the **central** role — scanning for advertisements, filtering them, and (optionally) connecting as a GATT client to read characteristics — on a hosted OS that has a Bluetooth daemon/framework already running (BlueZ on Linux, CoreBluetooth on macOS, WinRT Bluetooth APIs on Windows). This is the scan/connect half of BLE; the advertise-only peripheral half lives in `platform.net-lowpower` (see Design lineage — the boundary is deliberate, not an oversight).

## Design lineage
Modeled on `sys.net`'s own framing of itself: a thin, typed wrapper around an OS-provided stack, not a from-scratch protocol implementation — the same relationship `sys.net` has to BSD sockets, `sys.ble` has to BlueZ's D-Bus GATT/Advertisement API and CoreBluetooth's `CBCentralManager`/`CBPeripheral`. The scan-and-filter API shape borrows CoreBluetooth's `scanForPeripherals(withServices:options:)` (filter-at-scan-time by service UUID, not just after-the-fact in application code) and BlueZ's `AdvertisementMonitor` (interval/window batching so the OS layer — not this module's caller — does the platform-specific radio duty-cycling). The event-stream shape (one `AdvEvent` per observed advertisement, delivered through an iterator/callback, not a "current known devices" snapshot table) is modeled on the same `core.iter`-compatible streaming convention `sys.fs::Watcher` already established for OS event delivery, for consistency within the tier rather than inventing a third event-delivery idiom.

**Boundary with `platform.net-lowpower`:** both modules speak the same wire protocol (BLE advertising PDUs, GATT), but from opposite ends of the freestanding/hosted-OS line the whole project's tiering is organized around. `platform.net-lowpower::BleAdvertiser`/`BlePeripheral` targets a `no_std` device with no allocator and a fixed, tiny (31-byte legacy PDU) payload budget — it is the *peripheral* side, and it must never link scan/connect/GATT-client machinery it has no use for. `sys.ble` targets a hosted OS process that allocates freely, links against a full OS Bluetooth daemon, and needs the opposite capability set — scanning many advertisers, deduplicating a stream of events, optionally holding several live GATT connections open at once. Putting both roles in one module (or putting the central role under `platform`) would have forced either the embedded peripheral to carry scan/connect code it structurally cannot support, or the hosted scanner to pretend it's `no_std`-constrained when it isn't — so this is a new module in `sys`, not an extension of `platform.net-lowpower`. Decoding the raw manufacturer-data bytes either side observes is explicitly *not* this module's job (nor `net-lowpower`'s) — that's `std.encoding::binary::Binary`'s, so the two roles can agree on a byte layout without either depending on the other's tier.

## Proposed API
```
struct Uuid { .. }              // 16/32/128-bit BLE UUID, core-tier value type
struct DeviceId { .. }          // opaque, platform-stable device identifier (MAC on Linux, CBPeripheral identifier on macOS — never assume MAC format)

struct ScanFilter {
    service_uuids: alloc::vec::Vec<Uuid>,   // empty = no service filter
    name_prefix: Option<alloc::string::String>,
    min_rssi: Option<i8>,                   // drop weaker-signal adverts at the OS layer where supported
}

struct AdvEvent {
    device: DeviceId,
    rssi: i8,
    local_name: Option<alloc::string::String>,
    manufacturer_data: alloc::vec::Vec<u8>,   // company-id-prefixed raw bytes, undecoded — see Purpose
    service_uuids: alloc::vec::Vec<Uuid>,
    seen_at: std::chrono::Instant,
}

struct Scanner { .. }
impl Scanner {
    fn new() -> Result<Scanner, BleError>;                  // fails if no BT adapter / daemon unreachable
    fn start(&mut self, filter: ScanFilter) -> Result<(), BleError>;
    fn stop(&mut self) -> Result<(), BleError>;
    fn events(&mut self) -> AdvEventIter;                    // core.iter-compatible: Iterator<Item = AdvEvent>, blocks between events
}

// Dedup/rate-limit: repeated adverts from the same device collapse to one event per window,
// rather than the raw ~10 Hz per-device advertising-interval firehose.
struct Dedup { fn new(window: Duration) -> Dedup; }
impl Dedup {
    fn filter(&mut self, ev: AdvEvent) -> Option<AdvEvent>;  // None = suppressed as a within-window repeat
}

// Optional GATT-client path, for devices that support connections (distinct from pure advertising scan).
struct GattClient { .. }
impl GattClient {
    fn connect(device: DeviceId, timeout: Duration) -> Result<GattClient, BleError>;
    fn read_characteristic(&self, service: Uuid, characteristic: Uuid) -> Result<alloc::vec::Vec<u8>, BleError>;
    fn write_characteristic(&self, service: Uuid, characteristic: Uuid, data: &[u8]) -> Result<(), BleError>;
    fn disconnect(self) -> Result<(), BleError>;
}

enum BleError {
    AdapterUnavailable,
    PermissionDenied,       // BlueZ/CoreBluetooth both require explicit OS-level BT permission grants
    ConnectTimeout,
    Disconnected,
    Unsupported(&'static str),   // e.g. GATT on a platform build with only scan support wired up
}
```

## Key design decisions
- **`AdvEvent::manufacturer_data` is raw, undecoded bytes (`alloc::vec::Vec<u8>`), never a parsed struct.** This module has no idea whether the bytes came from an `embedded-sensor-node`-style temperature payload or something else entirely, and baking a specific payload schema into `sys.ble` would either force every scanner to link a decoder for formats it doesn't care about, or force this module to guess a schema per company ID. Decoding is `std.encoding::binary::Binary`'s job, given the raw bytes and a caller-supplied record type — the same "one Codec interface, format-specific detail elsewhere" separation the rest of the tiered design already uses.
- **`Dedup` is a separate, composable type layered on top of `Scanner::events()`, not a `Scanner` constructor option.** A raw BLE advertiser fires roughly every 20ms–10s per its own configured interval; without collapsing repeats, a caller processing every single PDU would re-decode and re-log the same reading dozens of times between meaningfully new data. Making dedup a pipeline stage (`events().filter_map(|ev| dedup.filter(ev))`) rather than a hidden always-on behavior keeps `Scanner` itself a faithful, low-level stream of what the radio actually observed — useful for a caller that *wants* every raw PDU (e.g. RSSI-based presence/proximity logic, where dedup would throw away exactly the repeated-signal-strength samples that logic needs).
- **`GattClient` is entirely separate from `Scanner`**, mirroring the same peripheral-side split `platform.net-lowpower` already made between `BleAdvertiser` and `BlePeripheral` — a scan-only caller (the common case: log advertisements, never connect) never has to construct, link, or reason about connection-state-machine code. `GattClient::connect` takes a `DeviceId` observed from a prior scan rather than requiring the `Scanner` and `GattClient` to be coupled through a shared session object, so a caller can scan, decide out-of-band (user picks a device from a list) to connect, and connect later without keeping the scanner alive.
- **`DeviceId` is documented as an opaque, platform-stable identifier, not typed as a MAC address.** CoreBluetooth deliberately hides real MAC addresses behind a per-app-installation UUID for privacy reasons (Apple's platform policy, not a BlueZ/CoreBluetooth API quirk this module could design around) — a `DeviceId` that assumed "MAC-address-shaped bytes" would be correct on Linux and silently wrong (or non-portable) on macOS. Treating it as opaque, comparable, hashable bytes (usable as an `alloc.map`/`alloc.set` key, nothing more) is the only shape that's honestly true on every target OS.
- **`Scanner::new()` returns `Result`, not an infallible constructor**, because "no Bluetooth adapter present" and "OS denied Bluetooth permission" are both first-run, expected failure conditions on a hosted desktop/laptop target (no adapter on a headless server, no permission grant on first run of a sandboxed app) — `core.error`'s "no expected failure via panic" rule applies here as directly as anywhere else in the tier.

## Validated by applications
- **ble-scanner**: the sole and purpose-built validation target for this entire module. `--connect` mode (optionally read a characteristic from devices that support it, distinct from the default advertise-only scan) is the direct forcing function for keeping `GattClient` a separate, optional type rather than folding connect/read into `Scanner` — the app's own default path never touches it. The dedup requirement ("deduplicate repeated advertisements from the same device within a time window") is what `Dedup` exists for verbatim; the app's log line is one entry per *meaningfully new* reading, not one per PDU. Decoding `embedded-sensor-node`-style manufacturer-data payloads (temperature/humidity/battery) via `std.encoding::binary::Binary`, fed by this module's raw `manufacturer_data` bytes, is the concrete end-to-end proof that the "same wire format, two tiers" boundary with `platform.net-lowpower` actually composes: `embedded-sensor-node` encodes with `std.encoding` on the peripheral side, `ble-scanner` decodes with `std.encoding` on the central side, and neither app's code depends on the other's tier (`platform` vs. `sys`) at all — only on the shared byte layout. Filtering by service UUID / name prefix is what `ScanFilter` exists for; a design without OS-level filtering would force every observed advertisement (from every BLE device in range, not just the target sensor nodes) through the app's own decode-and-check loop, which is both wasteful and — per CoreBluetooth's/BlueZ's own guidance — exactly the kind of filtering the OS layer is positioned to do more efficiently than userspace.

## Open questions / risks
Permission/pairing UX is genuinely OS-specific in ways this sketch elides: BlueZ's D-Bus API expects the process to already be a member of a `bluetooth` group or run under a policy that grants it access, while CoreBluetooth surfaces an interactive OS permission prompt the app must handle asynchronously (the first `Scanner::new()`/`start()` call may need to wait on a user's permission decision, not just fail or succeed instantly) — `BleError::PermissionDenied` names the failure but doesn't yet model the "pending user decision" state CoreBluetooth actually has, which is a real gap for a future GUI (rather than CLI) consumer of this module.

Extended/coded PHY advertising (BLE 5.0+, longer range or larger payloads than the legacy 31-byte PDU `platform.net-lowpower::AdvPayload` models) isn't addressed here either — `AdvEvent::manufacturer_data` is sized however the OS stack hands it back, so this module doesn't inherit `net-lowpower`'s 31-byte ceiling, but no application in this project's set has a device that actually advertises beyond it, so that headroom is unvalidated, not proven.

Whether `GattClient` should expose characteristic *notifications* (subscribe, then receive a push stream of value-changed events) in addition to one-shot `read_characteristic` is unresolved — `ble-scanner`'s `--connect` mode only ever does a single read, so a notify/subscribe API would be speculative, unvalidated surface added on spec rather than in response to a stated requirement, the same category of risk `platform.net-lowpower::LowpanStack` is already flagged for.
