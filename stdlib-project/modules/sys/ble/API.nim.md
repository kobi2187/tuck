# sys.ble — Nim API

## Purpose
Listen for Bluetooth Low Energy advertisements on a machine that has a Bluetooth stack already running, filter them, and optionally connect to a device to read or write one of its characteristics. The advertising-only, bare-metal half lives in `platform.net-lowpower`.

## Protocols implemented
`Scanner` is `Lifecycle` (`start`/`stop`/`isRunning`) + `Collection[Advert]`, per PROTOCOLS' assignment table. `Device` is `Resource` + `Gettable` + `Settable`.

## The API

```nim
type
  Uuid* = object            ## 16/32/128-bit BLE UUID
  DeviceId* = object        ## opaque, comparable, hashable. Usable as a Table key, nothing more.
                            ## Never assume it's a MAC: macOS hands out a per-install UUID instead.
  Advert* = object
    device*: DeviceId
    rssi*: int8
    name*: Option[Text]
    payload*: seq[byte]     ## manufacturer data, company-id prefixed, **undecoded**
    services*: seq[Uuid]
    seenAt*: Instant
  Scanner* = object         ## Lifecycle + Collection[Advert]

proc openScanner*(): Scanner
  ## Raises: no adapter, or the OS hasn't granted Bluetooth permission. Both are ordinary
  ## first-run outcomes on a laptop, so `tryOpenScanner` exists for callers who'd rather branch.
proc tryOpenScanner*(): Option[Scanner]
proc start*(s: var Scanner; services: openArray[Uuid] = []; namePrefix = "";
            minRssi = -128'i8): bool
  ## Filtering happens in the OS layer where it's cheap, not in your loop. All arguments
  ## default, so the bare `s.start()` that `Lifecycle` requires is also the scan-everything call.
proc stop*(s: var Scanner): bool
proc isRunning*(s: Scanner): bool
iterator list*(s: var Scanner): Advert
  ## The Collection primitive. One item per advertisement the radio actually saw — every
  ## repeat included, because RSSI-based presence logic needs exactly those repeats.

type Recent* = object       ## the dedup stage, kept separate so you can decline it
proc newRecent*(window: Duration; memory = defaultMemory()): Recent
proc isNew*(r: var Recent; a: Advert): bool
  ## False for a device already seen inside `window`. A sensor advertising at 10 Hz becomes
  ## one line in your log per meaningful reading.
iterator fresh*(adverts: iterable[Advert]; within: Duration): Advert
  ## The same thing as a `core.iter` stage, for `scanner.list().fresh(30.seconds)`.

type Device* = object       ## Resource + Gettable + Settable. Only for callers that connect
proc connect*(id: DeviceId; timeout = 10.seconds): Device
proc close*(d: var Device)
proc isOpen*(d: Device): bool
proc get*(d: Device; service, characteristic: Uuid): Option[seq[byte]]
  ## Raw bytes again. Absent if the device doesn't expose that characteristic.
proc set*(d: var Device; service, characteristic: Uuid; value: openArray[byte])
proc has*(d: Device; service: Uuid): bool
iterator list*(d: Device): (Uuid, Uuid)     ## every (service, characteristic) pair it offers
```

**What this module refuses to do.** It never decodes `payload`. It has no idea whether those bytes are an `embedded-sensor-node` temperature record or somebody's shoe tracker, and guessing per company ID would either force every scanner to link decoders it doesn't want or bake one app's schema into a system module. `std.encoding`'s binary reader takes the bytes and your record type, which is how the peripheral and central halves agree on a layout without either depending on the other's tier.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `AdvEvent` | `Advert` | it's an advertisement; "Event" was the delivery mechanism leaking into the name |
| `manufacturer_data` | `payload` | shorter, and doesn't imply a manufacturer decided anything about the shape |
| `ScanFilter` struct + `start(filter)` | `start(services =, namePrefix =, minRssi =)` | trailing named args, and `start()` with none of them still satisfies `Lifecycle` |
| `Scanner::events()` | `list(scanner)` | the `Collection` primitive, so `first`, `count` and `each` come free |
| `Dedup` / `filter(ev) -> Option` | `Recent` / `isNew(r, a)` | reads as a question with a yes/no answer, which is what the caller wants |
| `GattClient` | `Device` | "GATT" is protocol vocabulary; the thing on the other end is a device |
| `read_characteristic` / `write_characteristic` | `get` / `set` | two locators, one value — precisely `Gettable`/`Settable`, and no new words at all |
| `connect` / `disconnect` | `connect` / `close` | `close` is `Resource`'s word, and it's idempotent like every other `close` here |
| `BleError` enum | `Failure` + `problem` | one failure vocabulary for the whole library; `PermissionDenied` is `Denied` |

## In use

```nim
# ble-scanner: log one line per meaningfully new reading from the sensor fleet
var scanner = openScanner()
discard scanner.start(services = [SensorService], minRssi = -90)
var seen = newRecent(window = 30.seconds)

for advert in scanner.list():
  if not seen.isNew(advert): continue
  let r = advert.payload.decode(SensorRecord)          # std.encoding, not this module
  echo advert.name.get("(unnamed)"), " ", r.tempC, "C ", r.battery, "% rssi ", advert.rssi

# --connect mode: read the firmware-version characteristic, then let go
var dev = connect(advert.device, timeout = 5.seconds)
dev.get(DeviceInfoService, FirmwareRevision).ifSome(bytes):
  echo "  firmware ", bytes.asText()
dev.close()
```

## Vocabulary exceptions
- **`get`/`set` on `Device` take two locators.** Exactly as `alloc.vec`'s `Grid` takes `(row, col)`: a BLE characteristic is addressed by a pair, and inventing a `CharacteristicPath` type nobody asked for would be worse. Argument order still holds — target, locators, value, options.
- **`connect` and `isNew` are domain verbs.** `open` belongs to `Resource` and means re-acquiring the same handle; `openScanner` uses it correctly, while connecting to a remote radio is a different act. `isNew` reads as the question it answers.
- **`Scanner` is a `Collection` with no `add` or `remove`.** Only `list` is meaningful — you cannot put an advertisement into the air from here. The derived bundle still applies and `scanner.list().first()` is a genuinely useful line.
- **Left unresolved, on purpose.** CoreBluetooth can sit in a "waiting for the user to decide" permission state that neither a raise nor a value models well; `openScanner` currently blocks on it. And characteristic *notifications* (subscribe, then receive a push stream) would be a natural `Messenger[Advert]`-shaped addition, but no app in this set needs one, so it isn't here.
