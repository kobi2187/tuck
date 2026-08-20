# platform.net-lowpower — Nim API

## Purpose
Broadcast a few bytes over BLE, or join a small mesh network, without linking a sockets stack the device has no flash or battery for. A device that only advertises never links connection code at all.

## Protocols implemented
`BleRadio`: `Lifecycle` (`start`/`stop`/`isRunning`) — advertising is precisely something you turn on and off. `MeshNode`: `Messenger` (`send`/`receive`). `Advert` is a plain fixed-size value.

## The API

```nim
type
  Advert* = object                 ## exactly one legal BLE legacy advertising payload
    bytes: array[31, byte]         ## the protocol limit *is* the buffer size, so there
    used: uint8                    ## is nothing to allocate and nothing to tune
  AdvMode* = enum
    Broadcast     ## connectionless — the whole point of this module
    Connectable
    ScanReply

func advert*(data: Bytes): Option[Advert]
  ## `none` if `data` is longer than 31 bytes. Not a raise: "too long for one packet"
  ## is an ordinary thing to discover about a payload.
proc write*(a: var Advert, data: Bytes): Count   ## replace the contents, count kept

proc set*(r: var BleRadio, payload: Advert)
proc start*(r: var BleRadio, every = 1.seconds, mode = Broadcast): bool
  ## `Lifecycle`'s start, with the two things that vary as trailing named args — so
  ## generic code calling plain `start(r)` still works.
proc stop*(r: var BleRadio): bool     ## stop advertising. Does **not** power the radio down.
proc isRunning*(r: BleRadio): bool

proc powerDown*(r: var BleRadio)
  ## Actually gate the radio. Separate from `stop` on purpose: idle-but-clocked
  ## restarts fast, fully gated draws less — that trade is yours to make, not ours
  ## to hide. `platform.power`'s `enterSleep` handles the CPU; this handles the radio.
proc powerUp*(r: var BleRadio)

## --- only linked if you actually accept connections ---
type ConnHandle* = distinct uint16
proc onConnect*(p: var BlePeripheral, handler: proc (c: ConnHandle) {.nimcall.})
proc write*(p: var BlePeripheral, conn: ConnHandle,
            attribute: AttrHandle, data: Bytes): Count
proc close*(p: var BlePeripheral, conn: ConnHandle)

## --- 6LoWPAN / Thread, kept entirely separate ---
type MeshNode* = object
proc join*(n: var MeshNode, network: NetworkKey, timeout: Duration)
proc send*(n: var MeshNode, dest: Ipv6Addr, payload: Bytes)
proc receive*(n: var MeshNode, into: var openArray[byte],
              timeout: Duration): Option[Count]
proc isJoined*(n: MeshNode): bool
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `AdvPayload { data, len }` | `Advert` | Shorter, and it is the noun people say out loud. The 31-byte array stays exactly 31 bytes. |
| `set_payload(&p)` | `set(radio, payload)` | The structural `set`, keyless — a radio advertises one payload at a time. |
| `AdvMode::NonConnectable` | `Broadcast` | A double negative naming the most common case. `Broadcast` says what happens. |
| `AdvMode::ScanResponse` | `ScanReply` | Same idea, one syllable, and "reply" is what it is. |
| `start(interval, mode)` | `start(r, every = ..., mode = ...)` | Fits `Lifecycle` unchanged because both extras have defaults; `every = 1.seconds` reads as English. |
| `radio_sleep(radio)` | `powerDown(radio)` | "Sleep" is `platform.power`'s word for the CPU. Two different things should not share a verb. |
| `BleAdvertiser` / `BlePeripheral` traits | `BleRadio` / `BlePeripheral` | The advertise-only type is named for the hardware, not for the one thing it can do — and it is still the smaller of the two. |
| `LowpanStack::poll_recv` | `receive(n, into, timeout)` | The `Messenger` verb with the ordinary `Option` return; "poll" described the implementation. |
| `NetworkCredentials` | `NetworkKey` | One word for the thing you actually paste in. |

## In use — embedded-sensor-node

```nim
var radio: BleRadio
let payload = advert(latest.toBytes(order = Little)).orRaise("reading too long to advertise")

radio.set(payload)
discard radio.start(every = 2.seconds, mode = Broadcast)
# ... the radio's own timer keeps advertising while the CPU stays in Deep sleep ...
radio.powerDown()                       # explicit, so the power trade is visible
discard power.enterSleep(Deep, [wakeOn(30.seconds)])
```

## Vocabulary exceptions
`advert`, `join`, `powerDown` and `powerUp` are domain verbs. `powerDown`/`powerUp` deliberately do **not** reuse `stop`/`start`, because this module needs both pairs to mean different things at once — "stop advertising" and "gate the radio" are the exact trade the type exists to expose, and collapsing them into one verb would hide it. Everything else is structural: `set`, `start`, `stop`, `isRunning`, `write`, `send`, `receive`, `close`.

## Honest limits
- **The split is the design.** `BlePeripheral` is a separate type, not methods on `BleRadio`, so an advertise-only build never links a GATT server or a connection state machine. That is the module's whole reason for existing and it holds — but it is validated by exactly one feature of one stack.
- **`MeshNode` is speculative.** No application in this project joins a Thread or 6LoWPAN network. Its signatures are a guess at the right shape, not evidence, and they are named here as such rather than presented alongside `BleRadio` as equals.
- **Extended (BLE 5.0+) advertising is not modelled at all.** `Advert`'s fixed 31 bytes is a legacy-only assumption; a device using auxiliary packets for larger payloads breaks it, and the fix would be a second type rather than a resized field.
- **The central role lives in `sys.ble`, not here.** Scanning, filtering and connecting *out* run on a hosted OS with a Bluetooth daemon and a free-running allocator underneath — the opposite side of the freestanding boundary this tier is organised around. Growing scan/GATT-client machinery into these types would mean every advertise-only device carries code it structurally cannot use. Both modules speak the same advertising PDUs from opposite ends, and the manufacturer-data bytes are encoded and decoded by `std.encoding`, so neither has to depend on the other's tier.

**Nim-specific:** `onConnect`'s handler is `{.nimcall.}` — a bare function pointer, because Nim's default `proc` type is a closure with a heap environment this tier forbids. Connection state therefore reaches the handler through a module-level `var` or an `rtos.Queue`, and the annotation makes the compiler say so.
