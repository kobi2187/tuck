# platform.devicetree — Nim API

## Purpose
Describe the board once — which peripherals exist, at which addresses, on which pins — and let the compiler turn that description into ready-made handles. Application code says `device"tempSensor"`, never `0x44`.

## Protocols implemented
A `DtNode` is `Gettable` at compile time (`get(node, property)`, `has(node, property)`) and its children are a `Collection` (`list`, `count`). Nothing here exists at runtime, so no protocol costs a byte.

## The API

```nim
## board.dts, unchanged from Zephyr/Linux convention:
##   &i2c1 { temp_sensor: sht4x@44 { compatible = "sensirion,sht4x";
##                                   reg = <0x44>; timeout-ms = <50>; }; };
##   &gpio0 { led0: led_0 { gpios = <&gpio0 5 GPIO_ACTIVE_HIGH>; }; };

macro board*(path: static string)
  ## Reads and compiles the .dts **at compile time**. Put it once, near the top of
  ## your firmware. A malformed file is a compile error with a line number.
macro overlay*(path: static string)
  ## Patches the board description without editing it — a rev-B PCB that moved the
  ## sensor from i2c1 to i2c2 is one extra file, not a change to reviewed code.

type DtNode* = object     ## compile-time only: never instantiated in generated code
  label*, compatible*: string
  reg*: uint32

macro device*(label: static string): untyped
  ## The one you actually type. `device"tempSensor"` expands to a concrete, already
  ## claimed handle — an `I2cDevice`, a `GpioPin`, whatever the node's `compatible`
  ## string binds to. An unknown label is a compile error listing the labels that exist.

macro node*(label: static string): DtNode        ## the description itself, for properties
proc get*(n: static DtNode, property: static string): Option[DtValue]
proc has*(n: static DtNode, property: static string): bool
iterator list*(n: static DtNode): DtNode         ## child nodes — the Collection primitive
proc count*(n: static DtNode): int

type DtValue* = int | bool | string | DtNode | seq[int]
  ## The closed set of property types, deliberately narrower than Zephyr's grammar.
  ## A smaller compiler is worth more here than the last 5% of expressiveness.

template bindDriver*(compatible: static string, body: untyped)
  ## Says how a `compatible` string becomes a handle. `device"..."` uses this to pick
  ## which driver to expand to — the vendor,device convention, not a new namespace.

macro regionsFrom*(label: static string): untyped
  ## Flash partitions declared in the .dts become `platform.boot` `Region`s, so the
  ## log partition has one definition rather than two that can disagree.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `dt_get!(label)` | `device"tempSensor"` | Nim's call syntax lets a macro take a string literal with no parentheses and no `!`. It reads like naming a thing, because that is what it is. |
| `DtNode<Compat>` + `reg()` | `node"..."` + `get(n, "reg")` | The type parameter carried the compatible string for dispatch; `bindDriver` does that job explicitly, freeing the node to be a plain compile-time record. |
| `DtNode::property::<T>(name)` | `get(node, name)` | The structural `get`, returning `Option` for "that property isn't set" — the ordinary absence idiom instead of a fourth thing to learn. |
| `DtDriver::from_node` | `bindDriver "vendor,part": ...` | Written as a declaration at the binding site rather than a trait implemented in a separate file. |
| `apply_overlay(base, ov)` | `overlay"revB.dts"` | It is a build-time instruction, so it looks like one. Nobody calls it at runtime because there is no runtime to call it from. |
| `interrupt() -> Option<IrqVector>` | `get(n, "interrupts"): Option[Irq]` | Same `Irq` type `platform.interrupt` and `platform.hal` use — one word for one thing across three modules. |

## In use — embedded-sensor-node

```nim
board"boards/sensor_node.dts"
overlay"boards/sensor_node_revB.dts"      # rev-B moved the sensor to i2c2

var sensor = device"tempSensor"           # a claimed I2cDevice, address folded in
var led    = device"led0"                 # a claimed GpioPin, pin number folded in
const busTimeout = node"tempSensor".get("timeout-ms").get(50).ms

sensor.writeThenRead(cmdMeasure, raw, timeout = busTimeout)
```

Every constant above is resolved before code generation: the emitted firmware contains `0x44` and `50`, and contains no tree, no parser and no lookup.

## Vocabulary exceptions
`board`, `overlay`, `device`, `node`, `bindDriver` and `regionsFrom` are domain verbs — a build-time description language has no structural analogue, and `open"tempSensor"` would badly misrepresent a macro that costs nothing at runtime. They keep the argument order: subject first, options last. `get`/`has`/`list`/`count` are the ordinary structural verbs, just evaluated by the compiler rather than the chip.

## Honest limits
- **Devicetree is a data format, not an interface silicon vendors implement**, so it needs no trait escape hatch — but it leans hard on `overlay` as its own. The sensor's `timeout-ms = <50>` is the evidence: "read a sensor with a timeout" could not be expressed by a `compatible` string alone, which is exactly why `DtValue` is a small *closed* set rather than a single boolean.
- **Multi-step, stateful init is not expressible here.** A device needing a power-up sequence, not just static integers, falls back to driver-side code reading the properties and doing the sequence itself — the same answer Zephyr gives. This design assumes that fallback and has not exercised it.

**Nim-specific, and the biggest thing this module gets for free:** the .dts parser is written in ordinary Nim with `seq`, `string` and recursion, and none of that violates the tier's no-`seq`/no-`string` rule — because it runs only in the compiler's VM via `staticRead`, and only its *output* is compiled for the device. The constraint that applies to emitted code does not apply to the code that emits it. Two real limits come with that: the VM has no FFI, so the parser must be pure Nim with no C dtc binary shelled out to; and `device"..."` must expand to a handle-producing expression rather than return a value, which is why it is a `macro` and why `claim` failing on a devicetree-declared pin is a compile error rather than a runtime `none`.
