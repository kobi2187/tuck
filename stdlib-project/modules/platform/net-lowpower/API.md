# platform.net-lowpower

## Purpose
Optional, minimal hooks for low-power wireless stacks — 6LoWPAN, Thread, and BLE (including connectionless advertising) — so a device can broadcast small payloads without linking a general-purpose sockets/HTTP stack it has no power or flash budget for.

## Design lineage
Modeled on Zephyr's Bluetooth subsystem (`bt_le_adv_start`, GATT/connection APIs) for the BLE surface, and Zephyr's OpenThread/6LoWPAN integration for the mesh-networking surface — both chosen because they are the only entries in the survey (Part I, §1.4) with production BLE-mesh and Thread stacks shipped as first-party, in-tree subsystems on constrained hardware, rather than bolted-on third-party libraries.

## Proposed API
```
struct AdvPayload {
    data: [u8; 31],   // BLE legacy advertising PDU max payload
    len: u8,
}

trait BleAdvertiser {
    type Error;
    fn set_payload(&mut self, payload: &AdvPayload) -> Result<(), Self::Error>;
    fn start(&mut self, interval: Duration, mode: AdvMode) -> Result<(), Self::Error>;
    // AdvMode::NonConnectable | Connectable | ScanResponse
    fn stop(&mut self) -> Result<(), Self::Error>;
}

trait BlePeripheral: BleAdvertiser {
    // Only pulled in if the app actually needs a connection (GATT server etc.) —
    // a device that only advertises never needs this trait's methods to link.
    fn on_connect(&mut self, handler: fn(ConnHandle));
    fn gatt_write(&mut self, handle: ConnHandle, char: CharHandle, data: &[u8]) -> Result<(), BleError>;
}

trait LowpanStack {
    type Error;
    fn join(&mut self, network: NetworkCredentials) -> Result<(), Self::Error>;
    fn send(&mut self, dest: Ipv6Addr, payload: &[u8]) -> Result<(), Self::Error>;
    fn poll_recv(&mut self, buf: &mut [u8], timeout: Duration) -> Result<usize, Self::Error>;
}

fn radio_sleep(radio: &mut impl BleAdvertiser) -> Result<(), RadioError>;
// Explicit radio power-down between advertisement intervals — not implicit in `stop()`,
// since `stop()` may mean "cancel advertising" without necessarily power-gating the radio.
```

## Key design decisions
- **`BleAdvertiser` (connectionless) and `BlePeripheral` (connection-capable) are separate traits, with `BlePeripheral: BleAdvertiser` extending rather than replacing it** — a device that only ever advertises (the sensor node) depends solely on the smaller trait, so its build never links GATT server/connection-state-machine code it has no use for. This is a direct application of Principle 3 (small composable interfaces) to a domain where "just implement the whole Bluetooth stack's trait" would have meant every advertise-only device carries dead weight.
- **`AdvPayload` is a fixed 31-byte array, matching the legacy BLE advertising PDU limit exactly**, rather than a generic byte slice or allocator-backed buffer — this is a case where the "no hidden allocation" principle and the actual hardware/protocol constraint coincide exactly, so the type can be maximally concrete without losing generality: there is no smaller or larger legal payload to accommodate.
- **`radio_sleep` is a separate, explicit call from `BleAdvertiser::stop`** — deliberately not folded into `stop()` — because "stop advertising" and "power down the radio" are logically separate operations that most vendor BLE controllers also keep separate (a radio can be idle-but-clocked between advertising intervals for faster restart, or fully power-gated for lower power at the cost of restart latency); collapsing them into one call would hide a real power/latency tradeoff the sensor node's battery budget cares about.
- **`LowpanStack` (6LoWPAN/Thread) is defined but explicitly kept separate from and not required by `BleAdvertiser`** — a device using only BLE advertising (this app) never needs to implement or link `LowpanStack` at all, honoring the module's own "optional hooks" framing from Part IV rather than presenting one unified "wireless" trait that silently assumes mesh networking is always present.

## Validated by applications
The embedded-sensor-node's requirement — "periodic advertisement of the latest reading (connectionless, minimal power cost)" — is exactly why `BleAdvertiser` exists as a trait independent from `BlePeripheral`: a first design modeled too literally on Zephyr's Bluetooth subsystem (which centers connection/GATT concepts even for simple use cases, since most Zephyr BLE samples establish a connection) would have pulled connection-state-machine complexity into a device that the app explicitly never connects — it only broadcasts a reading and goes back to sleep. Narrowing the trait to `set_payload`/`start`/`stop` on a fixed 31-byte buffer is a direct, load-bearing response to that specific "connectionless, minimal power cost" requirement, not a generic simplification. The interaction with `platform.power` is real and was not obvious at first: advertising at a fixed interval while the CPU is mostly in `SleepDepth::Standby` (see `platform.power`) means the radio's advertising timer must be able to fire and complete a broadcast *without* fully waking the CPU scheduler for the whole interval — this pushed `radio_sleep` to be explicit and separate from `stop`, so the radio's own low-power behavior between advertisements is visible and controllable rather than assumed. On Part V: this module has not needed a vendor escape hatch for the sensor-node app specifically because advertising is one of the most standardized parts of the BLE spec across silicon (Nordic, ST, TI radios all expose essentially the same advertising PDU model) — but this module is validated by exactly one feature (advertise-only) of one stack (BLE); `LowpanStack`'s Thread/6LoWPAN surface is entirely unvalidated by any app in this project.

## Open questions / risks
`LowpanStack` is speculative and unvalidated — no application here joins a Thread or 6LoWPAN network, so its signatures are a best guess at the right shape, not evidence-backed the way `BleAdvertiser` is. Extended (5.0+) BLE advertising, which allows payloads well beyond 31 bytes via auxiliary packets, is not modeled at all; `AdvPayload`'s fixed 31-byte size is a legacy-only assumption that a future device using extended advertising would break.

**Related module — the BLE central role lives in `sys.ble`, not here (Extension round, `ble-scanner`):** this module's `BleAdvertiser`/`BlePeripheral` traits cover only the *peripheral* (advertise, optionally accept a connection) side of BLE, on a `no_std`, no-allocator, freestanding target — exactly the role `embedded-sensor-node` validated. `ble-scanner` needed the opposite role: *central* (scan for advertisements, filter, optionally connect as a GATT client), running on a hosted OS (Linux/macOS) with a full Bluetooth daemon and a free-allocating runtime underneath it. Rather than growing this module's traits to also cover scanning/connecting-out — which would mean every advertise-only, no_std device pulls in scan/GATT-client machinery it structurally cannot use, undermining the whole point of `BleAdvertiser` being a small trait a peripheral can implement without linking connection-state code — the central role was added as a new, separate module, `modules/sys/ble/API.md`, in the `sys` tier: hosted-OS-only, wraps the OS Bluetooth stack (BlueZ/CoreBluetooth) the same way `sys.net` wraps OS sockets, and allocates freely. Both modules speak the same wire protocol (BLE advertising PDUs) from opposite ends of the freestanding/hosted-OS boundary this whole project's tiering is organized around; the raw manufacturer-data payload bytes either side observes/emits are decoded via `std.encoding::binary::Binary`, not by either BLE module itself, so `embedded-sensor-node` (encodes, on `platform`) and `ble-scanner` (decodes, on `sys`) agree on a byte layout without either depending on the other's tier.
