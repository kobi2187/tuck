# App: ble-scanner (hosted-OS BLE central, companion to embedded-sensor-node)

A desktop/Linux CLI tool: `blescan` listens for BLE advertisements, filters by device name/service UUID, decodes the manufacturer-data payload from `embedded-sensor-node`-style devices (temperature/humidity/battery), and logs readings to a local file with timestamps — the "base station" side of the sensor node built earlier in this project.

## Why this is a good validation target
`embedded-sensor-node` validated `platform.net-lowpower` for a *peripheral* (advertise-only) role running on bare metal. This app needs the *central* (scan/connect) role — and, critically, it runs on a hosted OS (a Linux laptop or Raspberry Pi with a normal OS, not bare metal), which raises an architectural question the project hasn't confronted yet: is BLE-central functionality a `platform.*` concern at all, or does it actually belong in `sys`, since a hosted-OS program has no business depending on the embedded/no_std platform tier?

## Features
- Scan for BLE advertisements, filter by service UUID / device name prefix.
- Decode manufacturer-specific data payloads (the same wire format `embedded-sensor-node`'s `BleAdvertiser` produces).
- Deduplicate repeated advertisements from the same device within a time window.
- Append decoded readings (device id, reading, RSSI, timestamp) to a local log file.
- `--connect` mode: optionally establish a GATT connection to read a characteristic directly, for devices that support it (distinct from pure advertisement scanning).

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| sys or platform | **the BLE central API itself — placement is the open question this app exists to force** | see validation note |
| std | `std.encoding` | decoding the binary manufacturer-data payload (via `binary::Binary`, the same codec `embedded-sensor-node`'s advertisement payload would use) |
| sys | `sys.fs` | appending decoded readings to a log file |
| std | `std.chrono` | timestamping each reading |
| std | `std.cli` | live scan output, filters |
| core | `core.error` | malformed/unrecognized advertisement payloads (should skip, not crash the scanner) |

## Validation note: platform.net-lowpower's scope, confronted directly
The original `platform.net-lowpower` module (from the first embedded round) was scoped entirely to the embedded/no_std peripheral role — `BleAdvertiser` — deliberately kept thin so an advertise-only device never links GATT/connection-state machinery. `ble-scanner` needs the opposite role (central/scan/connect) on a *hosted OS*, which doesn't need to be `no_std`-safe at all — it can allocate freely, use `sys.net`-style OS-level Bluetooth APIs (BlueZ on Linux, CoreBluetooth on macOS), and doesn't belong under the `platform` tier's "freestanding-friendly" umbrella. The resolution proposed in the module updates: BLE-central functionality is added as a **new module in the `sys` tier** (`sys.ble`, hosted-OS-only, allocates freely, wraps the OS Bluetooth stack) rather than extended inside `platform.net-lowpower`, and the wire-format/payload-decoding logic (which both the peripheral and central sides need to agree on) is factored out into a small shared `std.encoding`-based schema so `embedded-sensor-node` and `ble-scanner` encode/decode the same bytes without either one depending on the other's tier. This is a real architectural finding: "Bluetooth" is not one concern belonging to one tier, it's two roles that happen to speak the same wire protocol from opposite ends of the freestanding/hosted-OS boundary the whole project's tiering is built around.
