# platform.devicetree

## Purpose
A declarative hardware description (which peripherals exist, their addresses, pin assignments, and interrupt lines) that a build-time compiler turns into generated driver-wiring code, so application code references peripherals by logical name rather than hand-writing register addresses.

## Design lineage
Modeled directly on Zephyr's devicetree system (itself inherited from Linux devicetree) — a `.dts`/`.dtsi`/overlay source format compiled at build time into a static C header/binding layer, chosen over a runtime device-discovery model because embedded targets in this tier have no bus enumeration (no PCI, no USB descriptors in the general case) and the wiring is fixed at build time by the board, not discovered at runtime.

## Proposed API
```
// Source format (compiled, not parsed at runtime):
// sensor_node.dts
/*
&i2c1 {
    status = "okay";
    clock-frequency = <100000>;
    temp_sensor: sht4x@44 {
        compatible = "sensirion,sht4x";
        reg = <0x44>;
        timeout-ms = <50>;
    };
};
&gpio0 {
    led0: led_0 { gpios = <&gpio0 5 GPIO_ACTIVE_HIGH>; };
};
*/

// Generated build-time bindings (one struct per compiled node, zero runtime cost):
struct DtNode<Compat> {
    const fn reg(&self) -> u32;
    const fn interrupt(&self) -> Option<IrqVector>;
    const fn property<T: DtProperty>(&self, name: &'static str) -> T;
}

// Compile-time macro that resolves a devicetree label to a concrete, typed handle
// bound to a platform.hal trait implementation:
macro_rules! dt_get {
    ($label:ident) => { /* expands to a concrete I2cDevice, GpioPin, etc. */ };
}

trait DtDriver {
    type Node;               // the compatible-string-matched node type
    fn from_node(node: Self::Node) -> Self;
}

// Board-level overlay mechanism: a second .dts file that patches the base
// description (e.g. swap I2C1 for I2C2 on a rev-B PCB) without editing the base file.
fn apply_overlay(base: &DtSource, overlay: &DtSource) -> DtSource;
```

## Key design decisions
- **Devicetree is compiled, not parsed at runtime** — the `dt_get!` macro and `DtNode::reg()`/`property()` resolve to compile-time constants, so a Cortex-M0 with 64KB RAM pays zero bytes and zero cycles for "device discovery," consistent with Principle 5 (radical explicitness, nothing hidden — a Zephyr-style DT parser walking a flattened tree at boot would be a hidden runtime cost this tier's target hardware can't always afford).
- **`compatible = "sensirion,sht4x"` strings drive which `DtDriver::from_node` implementation binds to a node**, directly mirroring Zephyr/Linux's vendor,device compatible-string convention rather than inventing a new namespace — this is a deliberate reuse of a two-decades-proven convention rather than a new design, per the report's general bias toward stealing validated ideas (Part II, §2.3) over inventing new ones for solved problems.
- **The overlay mechanism is a first-class, separate artifact (not an edit to the base `.dts`)**, because board revisions are the norm in real hardware development (a rev-B PCB moving the sensor from I2C1 to I2C2 is exactly the kind of change that should not require touching, re-reviewing, or re-testing the base hardware description) — this is the devicetree-specific answer to the Part V vendor-escape-hatch risk: instead of the *trait* growing vendor-specific parameters, the *wiring* absorbs board variation, keeping `platform.hal` traits untouched.
- **`DtNode::property()` is generic over a small closed set of `DtProperty` types** (integers, booleans, phandle references, string arrays) rather than an arbitrary/open value type, deliberately narrower than Zephyr's own devicetree property grammar (which supports much richer expressions) — a bet that the 5% of expressiveness cut is worth the smaller, more auditable compiler this tier's "nothing hidden" principle demands.

## Validated by applications
The embedded-sensor-node's I2C sensor and status-LED wiring is exactly the devicetree base case — `&i2c1 { temp_sensor: sht4x@44 { ... timeout-ms = <50>; }; }` is precisely how the sensor's I2C address and the `platform.hal::I2c::write_read` timeout parameter (see `platform.hal`) become build-time constants instead of magic numbers scattered through application code, which is the concrete value devicetree adds over hand-written pin/address constants. The app's flash log region and code/RAM split (owned by `platform.boot`) is a case where devicetree and boot overlap: the flash log region's address range is itself a devicetree node (`&flash0 { partitions { log: partition@... } }` in Zephyr's own convention), so this module's node/property model must be expressive enough to describe memory regions, not just peripherals — a real design pressure this app surfaced that a peripheral-only devicetree model would have missed. On the Part V risk: this module does not need a *trait* escape hatch (devicetree is a data format, not an interface silicon vendors implement against), but it does lean hard on the overlay mechanism as its own escape hatch — the sensor's `timeout-ms = <50>` property is itself evidence that "read a sensor with a timeout" could not be expressed as a bare `compatible` string; it needed an extensible property, which is precisely why `DtProperty` is a small closed set rather than a single boolean, so future devices with different timing or retry needs can still be described without changing the compiler.

## Open questions / risks
Whether the property grammar is expressive enough for devices with genuinely multi-step, stateful init sequences (not just static integer properties) is unresolved — Zephyr's answer for complex cases is to fall back to driver-side C code reading the properties and doing vendor-specific setup itself, which this design also implicitly assumes but has not exercised, since the sensor-node app's SHT4x has a simple single-command init that does not stress this boundary.
